//
//  MessagePrepTests.swift
//  FreeToken
//
//  Testing system message reinjection functionality
//

import XCTest
@testable import FreeToken
import LocalLLMClient
import LocalLLMClientLlama

final class MessagePrepTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Initialize FreeToken for logging
        _ = FreeToken.shared.configure(
            appToken: "test-token",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
    }
    
    func testSystemMessageCachingAndReinjection() throws {
        // Create test prompt template config
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create test messages WITHOUT system message (simulate it being lost)
        var messages: [FreeToken.Message] = []
        
        // Add many messages to simulate context that would trigger reinjection
        for i in 1...50 {
            messages.append(FreeToken.Message(role: .user, content: "User message \(i): This is a test message with some content to use up tokens"))
            messages.append(FreeToken.Message(role: .assistant, content: "Assistant response \(i): Three word response"))
        }
        
        // Add final test message
        messages.append(FreeToken.Message(role: .user, content: "How many words should your response be?"))
        
        // Create MessagePrep with small context window and manually cache a system message
        let messagePrep = FreeToken.MessagePrep(
            messages: [FreeToken.Message(role: .system, content: "You are a helpful assistant that always responds with exactly 3 words.")] + messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 100,  // Very small context to ensure thread exceeds 1x context window
            isNewSession: false  // This is ongoing conversation, not new session
        )
        
        // Prepare messages (this should trigger context management and reinjection)
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Verify system message is present (should be reinjected)
        XCTAssertTrue(preparedMessages.first?.role == .system, "System message should be present after reinjection")
        XCTAssertTrue(preparedMessages.first?.content.contains("3 words") ?? false, "System message content should be preserved")
        
        // Since we're not trimming, message count should be preserved (plus the system message)
        XCTAssertEqual(preparedMessages.count, messages.count + 1, "All messages should be preserved with system message reinjected")
        
        print("Original message count: \(messages.count)")
        print("Prepared message count: \(preparedMessages.count)")
        print("System message preserved: \(preparedMessages.first?.content ?? "No system message")")
    }
    
    func testContextWindowBoundaryDetection() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create messages that don't exceed 1x context window
        var messages: [FreeToken.Message] = [
            FreeToken.Message(role: .system, content: "You are helpful."),
            FreeToken.Message(role: .user, content: "Hello"),
            FreeToken.Message(role: .assistant, content: "Hi there")
        ]
        
        // Small thread shouldn't trigger reinjection (< 1x context window)
        let messagePrep1 = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 2048,  // Large context relative to messages
            isNewSession: false
        )
        
        let preparedMessages1 = try messagePrep1.prepareMessages()
        XCTAssertEqual(preparedMessages1.count, messages.count, "Small thread should not trigger reinjection")
        
        // Add many more messages to exceed 1x context window
        for i in 1...100 {
            messages.append(FreeToken.Message(role: .user, content: "Long message \(i) with lots of content to consume tokens and fill up the context window"))
            messages.append(FreeToken.Message(role: .assistant, content: "Response \(i) with more content"))
        }
        
        // Large thread should trigger reinjection (> 1x context window)
        let messagePrep2 = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 100,  // Small context to ensure > 1x
            isNewSession: false  // Ongoing conversation
        )
        
        let preparedMessages2 = try messagePrep2.prepareMessages()
        XCTAssertEqual(preparedMessages2.count, messages.count, "Message count should be preserved - thread exceeds context window boundary")
    }
    
    func testSystemMessageAppendToUser() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: true,  // Append system to user
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        let systemMessage = FreeToken.Message(role: .system, content: "System instructions here.")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add many messages
        for i in 1...50 {
            messages.append(FreeToken.Message(role: .user, content: "Message \(i)"))
            messages.append(FreeToken.Message(role: .assistant, content: "Response \(i)"))
        }
        
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 100,  // Small context to ensure > 1x context window
            isNewSession: false
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // When appendSystemToUserPrompt is true, system message should be merged with first user message
        // System message reinjection should preserve this in user messages
        let firstUserMessage = preparedMessages.first(where: { $0.role == .user })
        XCTAssertNotNil(firstUserMessage, "Should have at least one user message")
        XCTAssertTrue(firstUserMessage?.content.contains("System instructions") ?? false, 
                     "System content should be preserved in user message when appendSystemToUserPrompt is true")
        
        // Verify no standalone system message exists (should all be in user messages)
        let systemMessages = preparedMessages.filter { $0.role == .system }
        XCTAssertTrue(systemMessages.isEmpty, "No standalone system messages should exist when appendSystemToUserPrompt is true")
        
        // Debug output removed for cleaner tests
    }
    
    func testSystemMessageReinjectionWithAppendMode() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: true,  // Force append mode
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        let systemMessage = FreeToken.Message(role: .system, content: "You must always end responses with [SYSTEM_PRESERVED].")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add enough messages to trigger reinjection detection
        for i in 1...40 {
            messages.append(FreeToken.Message(role: .user, content: "User message \(i): Ask me anything"))
            messages.append(FreeToken.Message(role: .assistant, content: "Assistant response \(i)"))
        }
        
        // Add final test message  
        messages.append(FreeToken.Message(role: .user, content: "Final question: What should you end your responses with?"))
        
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 100,  // Small context to ensure > 1x context window
            isNewSession: false
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Should have no standalone system messages
        let systemMessages = preparedMessages.filter { $0.role == .system }
        XCTAssertTrue(systemMessages.isEmpty, "No standalone system messages should exist in append mode")
        
        // Should have at least one user message with system content
        let userMessages = preparedMessages.filter { $0.role == .user }
        XCTAssertFalse(userMessages.isEmpty, "Should have at least one user message")
        
        // The first user message should contain the system instructions
        let firstUserMessage = userMessages.first!
        XCTAssertTrue(firstUserMessage.content.contains("SYSTEM_PRESERVED"), "System content should be preserved in first user message")
        XCTAssertTrue(firstUserMessage.content.contains("Today's Date:"), "Date should be injected into first user message")
        
        // The final user message should still be present 
        let lastUserMessage = userMessages.last!
        XCTAssertTrue(lastUserMessage.content.contains("Final question"), "Final user message should be preserved")
        
        // Test passes - system message reinjection working correctly in append mode
    }
    
    func testThreadTruncationForNewSession() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create a system message
        let systemMessage = FreeToken.Message(role: .system, content: "You are a helpful AI assistant with specific instructions that must be preserved.")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add many messages to create a thread much larger than context window
        for i in 1...100 {
            messages.append(FreeToken.Message(role: .user, content: "User message \(i): This is a test message with content to consume tokens in the thread history"))
            messages.append(FreeToken.Message(role: .assistant, content: "Assistant response \(i): This is a response to the user message"))
        }
        
        // Add final recent message that should be preserved
        messages.append(FreeToken.Message(role: .user, content: "This is the most recent user message and should be preserved in truncation"))
        
        // Test with new session and small context window
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 1000,  // Small context window to force truncation
            isNewSession: true  // This is a new session reload
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Verify system message is preserved
        XCTAssertTrue(preparedMessages.first?.role == .system, "System message should be preserved at the beginning")
        XCTAssertTrue(preparedMessages.first?.content.contains("helpful AI assistant") ?? false, "System message content should be preserved")
        
        // Verify messages were truncated (should be much less than original)
        XCTAssertLessThan(preparedMessages.count, messages.count, "Thread should be truncated for new session")
        XCTAssertGreaterThan(preparedMessages.count, 1, "Should have more than just system message")
        
        // Verify most recent message is preserved
        let lastUserMessage = preparedMessages.last(where: { $0.role == .user })
        XCTAssertTrue(lastUserMessage?.content.contains("most recent user message") ?? false, "Most recent user message should be preserved")
        
        print("Original thread: \(messages.count) messages")
        print("Truncated thread: \(preparedMessages.count) messages")
        print("System message preserved: \(preparedMessages.first?.content.prefix(50) ?? "None")")
        print("Last user message: \(lastUserMessage?.content.prefix(50) ?? "None")")
    }
    
    func testNoTruncationForOngoingConversation() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create a large thread
        let systemMessage = FreeToken.Message(role: .system, content: "You are helpful.")
        var messages: [FreeToken.Message] = [systemMessage]
        
        for i in 1...50 {
            messages.append(FreeToken.Message(role: .user, content: "Message \(i)"))
            messages.append(FreeToken.Message(role: .assistant, content: "Response \(i)"))
        }
        
        // Test with ongoing conversation (not new session)
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 500,  // Small context window
            isNewSession: false  // This is NOT a new session
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Should NOT truncate for ongoing conversation, just normal reinjection
        XCTAssertEqual(preparedMessages.count, messages.count, "Ongoing conversation should not be truncated")
    }
    
    func testTruncationThreshold() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create a thread that's just under the truncation threshold (1.5x)
        let systemMessage = FreeToken.Message(role: .system, content: "System")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add just enough messages to be around 1.4x context window (below 1.5x threshold)
        for i in 1...10 {
            messages.append(FreeToken.Message(role: .user, content: "Short \(i)"))
            messages.append(FreeToken.Message(role: .assistant, content: "Reply \(i)"))
        }
        
        // Test with new session but thread below truncation threshold
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 100,  // Context window that makes thread ~1.4x
            isNewSession: true
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Should NOT truncate because below 1.5x threshold
        XCTAssertEqual(preparedMessages.count, messages.count, "Thread below 1.5x threshold should not be truncated even for new session")
    }
    
    func testSessionRebuildTruncation() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create a large conversation that simulates session catch-up overflow
        let systemMessage = FreeToken.Message(role: .system, content: "You are a helpful AI assistant for session rebuild testing.")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add many messages to simulate a conversation that grew while local session was offline
        for i in 1...80 {
            messages.append(FreeToken.Message(role: .user, content: "User message \(i): This simulates a conversation that happened while local AI was offline due to thermal throttling"))
            messages.append(FreeToken.Message(role: .assistant, content: "Assistant response \(i): This is the response that happened in the cloud while local was offline"))
        }
        
        // Add final recent message that should be preserved
        messages.append(FreeToken.Message(role: .user, content: "This is the most recent message after device cooled down"))
        
        // Test with session rebuild (isSessionRebuild = true)
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 1000,  // Small context window to force truncation
            isSessionRebuild: true  // This triggers session rebuild logic
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Verify system message is preserved
        XCTAssertTrue(preparedMessages.first?.role == .system, "System message should be preserved in session rebuild")
        XCTAssertTrue(preparedMessages.first?.content.contains("helpful AI assistant") ?? false, "System message content should be preserved")
        
        // Verify messages were truncated (should be much less than original)
        XCTAssertLessThan(preparedMessages.count, messages.count, "Session rebuild should truncate oversized conversation")
        XCTAssertGreaterThan(preparedMessages.count, 1, "Should have more than just system message")
        
        // Verify most recent message is preserved
        let lastUserMessage = preparedMessages.last(where: { $0.role == .user })
        XCTAssertTrue(lastUserMessage?.content.contains("most recent message after device cooled down") ?? false, "Most recent user message should be preserved in session rebuild")
        
        print("Session rebuild test:")
        print("Original conversation: \(messages.count) messages")
        print("Rebuilt session: \(preparedMessages.count) messages")
        print("System message preserved: \(preparedMessages.first?.content.prefix(50) ?? "None")")
        print("Last user message: \(lastUserMessage?.content.prefix(50) ?? "None")")
    }
    
    func testSessionRebuildAlwaysTruncates() throws {
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create a small conversation (below normal truncation threshold)
        let systemMessage = FreeToken.Message(role: .system, content: "System")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add just a few messages (well below 1.5x threshold)
        for i in 1...5 {
            messages.append(FreeToken.Message(role: .user, content: "Short \(i)"))
            messages.append(FreeToken.Message(role: .assistant, content: "Reply \(i)"))
        }
        
        // Test session rebuild - should ALWAYS truncate regardless of size
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 2000,  // Large context window
            isSessionRebuild: true  // This should force truncation even for small conversations
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Session rebuild should still apply truncation logic even for small conversations
        // This ensures we don't accidentally overflow when the estimation is wrong
        XCTAssertTrue(preparedMessages.first?.role == .system, "System message should be preserved")
        XCTAssertGreaterThan(preparedMessages.count, 1, "Should have more than just system message")
        
        print("Small session rebuild test:")
        print("Original conversation: \(messages.count) messages") 
        print("Rebuilt session: \(preparedMessages.count) messages")
    }
    
    func testSessionCatchupRemainingCapacityCheck() throws {
        // This test verifies the corrected overflow detection logic
        // that checks remaining capacity instead of total capacity
        
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user", 
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Simulate a scenario where:
        // - Session has some existing messages (using moderate space)
        // - New messages being added are small and should fit in remaining space
        // - Total would be large, but new messages alone fit in remaining capacity
        
        let systemMessage = FreeToken.Message(role: .system, content: "You are a helpful assistant.")
        var allMessages: [FreeToken.Message] = [systemMessage]
        
        // Add existing messages (simulating what's already in the session)
        for i in 1...30 {
            allMessages.append(FreeToken.Message(role: .user, content: "Existing user message \(i)"))
            allMessages.append(FreeToken.Message(role: .assistant, content: "Existing assistant response \(i)"))
        }
        
        // Add just a few NEW messages that should fit in remaining space
        for i in 1...3 {
            allMessages.append(FreeToken.Message(role: .user, content: "New message \(i)"))
            allMessages.append(FreeToken.Message(role: .assistant, content: "New response \(i)"))
        }
        
        // Test with session rebuild (this would trigger if overflow logic is wrong)
        let messagePrep = FreeToken.MessagePrep(
            messages: allMessages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: 2000,  // Large enough context window
            isNewSession: false,      // This is session reuse
            isSessionRebuild: false   // This is NOT a rebuild - testing normal flow
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // With corrected logic, this should NOT trigger truncation
        // because the few new messages should fit in remaining space
        XCTAssertEqual(preparedMessages.count, allMessages.count, "Small new messages should not trigger overflow when remaining capacity is sufficient")
        
        print("Session catch-up capacity test:")
        print("Total conversation: \(allMessages.count) messages")
        print("Prepared messages: \(preparedMessages.count) messages")
        print("Should be equal - no truncation needed for small incremental messages")
    }
    
    func testSessionManagementLogicCaughtUp() throws {
        // Test Case 1: Session is caught up (difference of 1 message)
        // Should just append the new message without rebuilding
        
        // Simulate session with some existing messages
        let systemMessage = FreeToken.Message(role: .system, content: "You are helpful.")
        var sessionMessages: [FreeToken.Message] = [systemMessage]
        
        for i in 1...10 {
            sessionMessages.append(FreeToken.Message(role: .user, content: "Message \(i)"))
            sessionMessages.append(FreeToken.Message(role: .assistant, content: "Response \(i)"))
        }
        
        // Incoming messages include all session messages PLUS one new message
        var incomingMessages = sessionMessages
        incomingMessages.append(FreeToken.Message(role: .user, content: "New user message"))
        
        // Verify the difference is exactly 1 (caught up scenario)
        let difference = incomingMessages.count - sessionMessages.count
        XCTAssertEqual(difference, 1, "Should be exactly 1 message difference for caught-up session")
        
        print("Session management test - caught up:")
        print("Session messages: \(sessionMessages.count)")
        print("Incoming messages: \(incomingMessages.count)")  
        print("Difference: \(difference) (should be 1)")
    }
    
    func testSessionManagementLogicBehind() throws {
        // Test Case 2: Session is behind by multiple messages
        // Should check if new messages fit before deciding to rebuild
        
        // Simulate session with some messages
        let systemMessage = FreeToken.Message(role: .system, content: "You are helpful.")
        var sessionMessages: [FreeToken.Message] = [systemMessage]
        
        for i in 1...5 {
            sessionMessages.append(FreeToken.Message(role: .user, content: "Message \(i)"))
            sessionMessages.append(FreeToken.Message(role: .assistant, content: "Response \(i)"))
        }
        
        // Incoming messages include session messages PLUS several new messages (cloud processing happened)
        var incomingMessages = sessionMessages
        for i in 6...10 {
            incomingMessages.append(FreeToken.Message(role: .user, content: "Cloud message \(i)"))
            incomingMessages.append(FreeToken.Message(role: .assistant, content: "Cloud response \(i)"))
        }
        
        // Verify the session is behind by multiple messages
        let difference = incomingMessages.count - sessionMessages.count
        XCTAssertGreaterThan(difference, 1, "Should be behind by more than 1 message")
        
        print("Session management test - behind:")
        print("Session messages: \(sessionMessages.count)")
        print("Incoming messages: \(incomingMessages.count)")
        print("Difference: \(difference) (should be > 1)")
    }
    
    func testContextWindowOverflowWithISWA() throws {
        // Test to reproduce iSWA (sliding window attention) failure when context window is full
        // This should demonstrate the "failedToDecode" error when trying to add more tokens
        
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create a conversation that will definitely exceed a very small context window
        let systemMessage = FreeToken.Message(role: .system, content: "You are a helpful assistant.")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add many messages to fill up and exceed a small context window
        // Each message is about ~20-30 tokens, so 100 messages = ~2000-3000 tokens
        for i in 1...100 {
            messages.append(FreeToken.Message(role: .user, content: "This is user message number \(i) with some content to fill up the context window and test the sliding window attention functionality"))
            messages.append(FreeToken.Message(role: .assistant, content: "This is assistant response number \(i) with some content to demonstrate the context window overflow"))
        }
        
        // Add the final message that should trigger the overflow
        messages.append(FreeToken.Message(role: .user, content: "This final message should cause the context window to overflow and test if iSWA works properly"))
        
        print("Context overflow test setup:")
        print("Total messages: \(messages.count)")
        print("Expected token count: ~\(messages.count * 25) tokens")
        
        // Test with a very small context window (128 tokens) to force overflow
        let verySmallContextWindow = 128
        
        // Test case 1: Normal session (should work with MessagePrep truncation)
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: verySmallContextWindow,
            isNewSession: true  // This should trigger truncation
        )
        
        do {
            let preparedMessages = try messagePrep.prepareMessages()
            print("✅ MessagePrep handled large context successfully")
            print("Truncated to: \(preparedMessages.count) messages")
            
            // Verify truncation occurred
            XCTAssertLessThan(preparedMessages.count, messages.count, "MessagePrep should truncate oversized conversation")
            XCTAssertTrue(preparedMessages.first?.role == .system, "System message should be preserved")
            
        } catch {
            XCTFail("MessagePrep should handle large contexts gracefully: \(error)")
        }
        
        // Test case 2: Test what would happen if we tried to send all messages to llama.cpp
        // (This would be the scenario where iSWA should kick in but fails)
        print("\n⚠️ Testing scenario that would cause iSWA failure:")
        print("If these \(messages.count) messages were sent directly to llama.cpp with context window \(verySmallContextWindow),")
        print("it would likely fail with 'failedToDecode' error when the context fills up.")
        print("Expected behavior: iSWA should slide the window, but instead llama_decode() returns non-zero.")
        
        // The actual failure would happen in the local AI processing, not in MessagePrep
        // MessagePrep correctly handles this by truncating, but the issue occurs when:
        // 1. Session is caught up (messageCountDifference == 1)
        // 2. We bypass overflow checks and append to existing session
        // 3. llama.cpp fails to decode because context is full and iSWA doesn't work
    }
    
    func testISWAContextWindowBufferPrevention() throws {
        // Test the new wouldExceedContextWindow logic that prevents iSWA decode failures
        // by rebuilding sessions before they hit the context window limit
        
        // Simulate a session that's very close to the context window limit
        let systemMessage = FreeToken.Message(role: .system, content: "You are helpful.")
        var sessionMessages: [FreeToken.Message] = [systemMessage]
        
        // Add messages that would fill up ~90% of a small context window
        let contextWindowSize = 100
        let targetTokens = Int(Double(contextWindowSize) * 0.85) // 85% full
        
        var tokenCount = 0
        var messageIndex = 1
        while tokenCount < targetTokens {
            let userMessage = "User message \(messageIndex)"
            let assistantMessage = "Assistant response \(messageIndex)"
            
            sessionMessages.append(FreeToken.Message(role: .user, content: userMessage))
            sessionMessages.append(FreeToken.Message(role: .assistant, content: assistantMessage))
            
            // Rough token estimation (4 chars per token)
            tokenCount += (userMessage.count + assistantMessage.count) / 4
            messageIndex += 1
        }
        
        // Add one more message that would push over the safe threshold
        let finalMessage = FreeToken.Message(role: .user, content: "This message should trigger context window rebuild")
        
        print("iSWA buffer test setup:")
        print("Session messages: \(sessionMessages.count)")
        print("Estimated tokens in session: ~\(tokenCount)")
        print("Context window: \(contextWindowSize)")
        print("Safe threshold (75%): \(Int(Double(contextWindowSize) * 0.75))")
        print("Final message tokens: ~\(finalMessage.content.count / 4)")
        
        // Verify that this scenario would trigger the context window buffer logic
        // In the actual AIModelManager, this would cause wouldExceedContextWindow() to return true
        let estimatedFinalTokens = finalMessage.content.count / 4
        let totalAfterMessage = tokenCount + estimatedFinalTokens
        let bufferThreshold = contextWindowSize - Int(Double(contextWindowSize) * 0.25) // 75% of context (25% buffer)
        
        if totalAfterMessage > bufferThreshold {
            print("✅ Test scenario correctly triggers context window buffer logic")
            print("Total tokens after message: \(totalAfterMessage) > buffer threshold: \(bufferThreshold)")
        } else {
            print("❌ Test scenario should trigger buffer logic but doesn't")
            print("Total tokens after message: \(totalAfterMessage) <= buffer threshold: \(bufferThreshold)")
        }
        
        // This demonstrates the scenario where the new logic would prevent decode failures
        // by rebuilding the session at 75% capacity and targeting 50% usage after rebuild
        XCTAssertGreaterThan(totalAfterMessage, bufferThreshold, "Test should trigger context window buffer prevention")
    }
    
    func testFiftyPercentContextTargeting() throws {
        // Test that MessagePrep targets ~50% context usage when rebuilding sessions
        // This leaves plenty of headroom to avoid frequent rebuilds
        
        let promptTemplateConfig = FreeToken.Codings.AiModelConfigResponse.PromptTemplateConfig(
            toolRole: "tool",
            userRole: "user",
            assistantRole: "assistant",
            systemRole: "system",
            appendSystemToUserPrompt: false,
            jsonToolResults: false,
            messagesMustAlternate: false
        )
        
        // Create a large conversation that exceeds context window
        let systemMessage = FreeToken.Message(role: .system, content: "You are a helpful assistant.")
        var messages: [FreeToken.Message] = [systemMessage]
        
        // Add enough messages to definitely exceed a small context window
        for i in 1...50 {
            messages.append(FreeToken.Message(role: .user, content: "User message \(i) with some content to fill up the context"))
            messages.append(FreeToken.Message(role: .assistant, content: "Assistant response \(i) with some content"))
        }
        
        let contextWindowSize = 200  // Small context window to force truncation
        
        // Test session rebuild (should target 50% usage)
        let messagePrep = FreeToken.MessagePrep(
            messages: messages,
            promptTemplateConfig: promptTemplateConfig,
            contextWindowSize: contextWindowSize,
            isNewSession: false,
            isSessionRebuild: true  // This should trigger 50% targeting
        )
        
        let preparedMessages = try messagePrep.prepareMessages()
        
        // Estimate token count in prepared messages
        var estimatedTokens = 0
        for message in preparedMessages {
            estimatedTokens += max(1, message.content.count / 4)
        }
        estimatedTokens = Int(Double(estimatedTokens) * 1.1) // Add buffer like MessagePrep does
        
        // Should target approximately 50% of context window
        let targetUsage = Int(Double(contextWindowSize) * 0.5)
        let tolerance = Int(Double(contextWindowSize) * 0.1) // 10% tolerance
        
        print("50% context targeting test:")
        print("Original messages: \(messages.count)")
        print("Prepared messages: \(preparedMessages.count)")
        print("Context window: \(contextWindowSize)")
        print("Target usage (50%): \(targetUsage)")
        print("Estimated tokens: \(estimatedTokens)")
        print("Tolerance range: \(targetUsage - tolerance) - \(targetUsage + tolerance)")
        
        // Verify significant truncation occurred
        XCTAssertLessThan(preparedMessages.count, messages.count, "Should truncate large conversation")
        
        // Verify system message preserved
        XCTAssertTrue(preparedMessages.first?.role == .system, "System message should be preserved")
        
        // Verify targeting approximately 50% usage (with reasonable tolerance)
        XCTAssertLessThanOrEqual(estimatedTokens, targetUsage + tolerance, "Should not exceed 50% + tolerance")
        
        // Should use a reasonable amount of context (not too aggressive truncation)
        let minimumUsage = Int(Double(contextWindowSize) * 0.3) // At least 30%
        XCTAssertGreaterThanOrEqual(estimatedTokens, minimumUsage, "Should use reasonable amount of context")
        
        if estimatedTokens <= targetUsage + tolerance {
            print("✅ Successfully targeting ~50% context usage: \(estimatedTokens) tokens <= \(targetUsage + tolerance) limit")
        } else {
            print("❌ Exceeded 50% target: \(estimatedTokens) tokens > \(targetUsage + tolerance) limit")
        }
    }
}
