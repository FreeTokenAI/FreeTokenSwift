//
//  ContextFullFalsePositiveTests.swift
//  FreeToken
//
//  Testing the context_full false positive bug
//

import XCTest
@testable import FreeToken
import LocalLLMClient
import LocalLLMClientLlama

final class ContextFullFalsePositiveTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        _ = FreeToken.shared.configure(
            appToken: "test-token", 
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
    }
    
    func testContextFullFalsePositive() throws {
        let contextWindowSize = 8192
        let maxGenerationTokens = 512
        
        // Create a large thread that will need truncation (similar to your 44 messages)
        var largeThread: [FreeToken.Message] = []
        
        // Add system message
        largeThread.append(FreeToken.Message(role: .system, content: "You are a helpful assistant. You provide detailed and accurate responses to user questions. You are knowledgeable about many topics and can help with various tasks."))
        
        // Add many conversation pairs to fill up context (simulate 44+ messages like in your logs)
        for i in 1...45 {
            largeThread.append(FreeToken.Message(role: .user, content: "This is user message number \(i). I'm asking a question that requires a detailed response about various topics including technology, science, and general knowledge. Please provide comprehensive information. Let me add more content to make this longer so we can simulate a realistic token count that would fill up the context window significantly."))
            largeThread.append(FreeToken.Message(role: .assistant, content: "This is assistant response number \(i). I'm providing a detailed and comprehensive answer to your question about technology, science, and general knowledge. Here are the key points you should know about this topic, including background information, current developments, and future implications. The response continues with additional details and explanations to ensure you have a thorough understanding of the subject matter. I'll add even more comprehensive information to make this response longer and more realistic for testing purposes."))
        }
        
        print("📊 Test Setup: Created thread with \(largeThread.count) messages")
        
        // Create ThreadStateManager and ThreadState
        let manager = FreeToken.AIModelManager.AIStateManager.ThreadStateManager()
        let threadId = "test-context-full-thread"
        
        // Step 1: Create initial thread state (simulates first load)
        let threadState = manager.getOrCreateThreadState(
            threadId: threadId,
            fullThread: largeThread,
            contextWindowSize: contextWindowSize,
            maxGenerationTokens: maxGenerationTokens
        )
        
        print("📊 Step 1: Initial thread state created with \(threadState.fullThread.count) messages")
        print("📊 Initial approximateTokenCount: \(threadState.approximateTokenCount)")
        
        // Step 2: Simulate the BUG - session is rebuilt with correct truncation, 
        // but threadState.fullThread is NOT updated to reflect this truncation
        let truncatedMessages = createTruncatedMessages(from: largeThread, targetUsage: 0.5, contextWindowSize: contextWindowSize)
        
        print("📊 Step 2: Truncated messages: \(largeThread.count) → \(truncatedMessages.count)")
        
        // Create session with truncated messages (this happens correctly)
        let mockSession = createMockSession(with: truncatedMessages)
        
        // Sync the session (this happens correctly) 
        threadState.syncLoadedSession(mockSession.messages)
        
        // BUT the threadState.fullThread is NOT updated to match the truncated session!
        // This is the bug - fullThread still contains the original large thread
        
        print("📊 After truncation and sync:")
        print("📊   fullThread count: \(threadState.fullThread.count)")
        print("📊   loadedMessages count: \(threadState.loadedMessages.count)")
        print("📊   approximateTokenCount: \(threadState.approximateTokenCount)")
        
        // Step 3: Add a single new message (user's next message)
        let newUserMessage = FreeToken.Message(role: .user, content: "This is a small follow-up question.")
        let updatedThread = threadState.fullThread + [newUserMessage]
        
        print("📊 Step 3: Adding new message. Thread size: \(threadState.fullThread.count) → \(updatedThread.count)")
        
        // Step 4: THIS IS THE BUG - getOrCreateThreadState overwrites the truncated state  
        // Simulate what happens when the second message comes in
        let threadStateSecondCall = manager.getOrCreateThreadState(
            threadId: threadId,
            fullThread: updatedThread,  // This overwrites the truncated fullThread!
            contextWindowSize: contextWindowSize,
            maxGenerationTokens: maxGenerationTokens
        )
        
        print("📊 AFTER second getOrCreateThreadState call:")
        print("📊   fullThread count: \(threadStateSecondCall.fullThread.count)")
        print("📊   loadedMessages count: \(threadStateSecondCall.loadedMessages.count)") 
        print("📊   approximateTokenCount: \(threadStateSecondCall.approximateTokenCount)")
        
        // Step 5: Test the strategy planning (this is where the bug occurs)
        let strategy = manager.planMessageStrategy(
            threadState: threadStateSecondCall,
            currentSession: mockSession,
            fullThread: updatedThread
        )
        
        print("📊 Step 5: Strategy result: \(strategy)")
        
        // The test should PASS (append safely), not trigger context_full
        switch strategy {
        case .appendSafely(let messages):
            print("✅ SUCCESS: Strategy correctly identified safe append with \(messages.count) new messages")
            XCTAssertEqual(messages.count, 1, "Should have 1 new message to append")
            
        case .rebuildRequired(let reason):
            print("❌ FAILURE: Strategy incorrectly triggered rebuild with reason: \(reason)")
            XCTFail("Should not require rebuild after truncation to 50% usage. Reason: \(reason)")
            
        case .kvCacheOptimization:
            print("⚡ KV Cache optimization triggered (acceptable alternative)")
            // This is also acceptable as it's a valid optimization strategy
            
        case .noActionNeeded:
            print("❌ FAILURE: Strategy said no action needed but we have a new message")
            XCTFail("Should detect the new message that needs to be appended")
        }
    }
    
    // Helper function to create truncated messages (mimics MessagePrep logic)
    private func createTruncatedMessages(
        from messages: [FreeToken.Message], 
        targetUsage: Double, 
        contextWindowSize: Int
    ) -> [FreeToken.Message] {
        let systemMessage = messages.first { $0.role == .system }
        let nonSystemMessages = messages.filter { $0.role != .system }
        
        let targetTokens = Int(Double(contextWindowSize) * targetUsage)
        let systemTokens = systemMessage?.content.count ?? 0 / 4
        let availableForMessages = targetTokens - systemTokens - (contextWindowSize / 10) // Reserve for generation
        
        var selectedMessages: [FreeToken.Message] = []
        var tokenCount = 0
        
        // Work backwards from most recent messages
        for message in nonSystemMessages.reversed() {
            let messageTokens = max(1, message.content.count / 4)
            if tokenCount + messageTokens <= availableForMessages {
                selectedMessages.insert(message, at: 0)
                tokenCount += messageTokens
            } else {
                break
            }
        }
        
        // Combine system message + recent messages
        var result: [FreeToken.Message] = []
        if let systemMessage = systemMessage {
            result.append(systemMessage)
        }
        result.append(contentsOf: selectedMessages)
        
        return result
    }
    
    // Helper to create a mock LLMSession
    private func createMockSession(with messages: [FreeToken.Message]) -> LLMSession {
        let llmMessages = messages.map { message in
            switch message.role {
            case .system: return LLMInput.Message.system(message.content)
            case .user: return LLMInput.Message.user(message.content)
            case .assistant: return LLMInput.Message.assistant(message.content)
            case .tool: return LLMInput.Message(role: .custom("tool"), content: message.content)
            }
        }
        
        // Create a minimal mock model for testing
        let mockModel = LLMSession.DownloadModel.llama(
            id: "test-model",
            model: "test.gguf",
            mmproj: nil,
            parameter: .init(context: 8192, batch: 512)
        )
        
        return LLMSession(model: mockModel, messages: llmMessages)
    }
}