//
//  KVCacheOptimizationTests.swift
//  FreeToken
//
//  Testing the KV cache optimization system
//

import XCTest
@testable import FreeToken
import LocalLLMClient
import LocalLLMClientLlama

final class KVCacheOptimizationTests: XCTestCase {
    
    override func setUpWithError() throws {
        _ = try FreeToken.shared.configure(
            appToken: "test-token",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
    }
    
    func testKVOptimizationPlan() throws {
        // Create a thread state with system message and several conversation messages
        let messages = [
            FreeToken.Message(role: .system, content: "You are a helpful assistant."),
            FreeToken.Message(role: .user, content: "Hello, how are you?"),
            FreeToken.Message(role: .assistant, content: "I'm doing well, thank you!"),
            FreeToken.Message(role: .user, content: "What's the weather like?"),
            FreeToken.Message(role: .assistant, content: "I don't have access to current weather data."),
            FreeToken.Message(role: .user, content: "Can you help me with math?"),
            FreeToken.Message(role: .assistant, content: "Absolutely! I'd be happy to help with math questions."),
            FreeToken.Message(role: .user, content: "What is 15 * 23?"),
            FreeToken.Message(role: .assistant, content: "15 × 23 = 345"),
            FreeToken.Message(role: .user, content: "Great, thank you!")
        ]
        
        let threadState = FreeToken.AIModelManager.AIStateManager.ThreadState(
            threadId: "kv-test-thread",
            fullThread: messages,
            contextWindowSize: 100, // Small context to trigger optimization
            maxGenerationTokens: 20
        )
        
        // Simulate loaded session with position tracking
        threadState.syncLoadedSession(messages.map { message in
            switch message.role {
            case .system: return LLMInput.Message.system(message.content)
            case .user: return LLMInput.Message.user(message.content)
            case .assistant: return LLMInput.Message.assistant(message.content)
            case .tool: return LLMInput.Message(role: .custom("tool"), content: message.content)
            }
        })
        
        // Simulate position tracking for system message
        threadState.trackMessageTokens(messageIndex: 0, startPos: 0, endPos: 10) // System message: positions 0-10
        
        // Simulate position tracking for other messages
        var currentPos: Int32 = 11
        for index in 1..<messages.count {
            let messageTokens: Int32 = Int32(max(1, messages[index].content.count / 4))
            threadState.trackMessageTokens(messageIndex: index, startPos: currentPos, endPos: currentPos + messageTokens - 1)
            currentPos += messageTokens
        }
        
        // Test that optimization is needed
        let currentUsage = Double(threadState.approximateTokenCount) / Double(threadState.contextWindowSize)
        print("Current context usage: \(String(format: "%.1f", currentUsage * 100))%")
        print("Approximate token count: \(threadState.approximateTokenCount)")
        print("Context window size: \(threadState.contextWindowSize)")
        
        // Should need optimization when usage > 80%
        if currentUsage > 0.8 {
            XCTAssertTrue(threadState.shouldOptimizeKVCache(currentUsage: currentUsage), "Should need optimization with high context usage")
        } else {
            // If usage is low, artificially set it high for testing
            threadState.approximateTokenCount = Int(Double(threadState.contextWindowSize) * 0.85)
            let newUsage = Double(threadState.approximateTokenCount) / Double(threadState.contextWindowSize)
            XCTAssertTrue(threadState.shouldOptimizeKVCache(currentUsage: newUsage), "Should need optimization with artificially high context usage")
        }
        
        // Test optimization plan calculation
        let plan = threadState.calculateOptimizationPlan(currentTokens: Int32(threadState.approximateTokenCount))
        XCTAssertNotNil(plan, "Should be able to calculate optimization plan")
        
        if let plan = plan {
            XCTAssertGreaterThan(plan.preserveFromStart, 0, "Should preserve some tokens from start (system message)")
            XCTAssertGreaterThan(plan.preserveFromEnd, 0, "Should preserve some tokens from end (recent messages)")
            XCTAssertLessThan(plan.removeStartPos, plan.removeEndPos, "Remove range should be valid")
            
            print("✅ KV Optimization Plan:")
            print("   Preserve from start: \(plan.preserveFromStart) tokens")
            print("   Preserve from end: \(plan.preserveFromEnd) tokens")
            print("   Remove range: \(plan.removeStartPos) to \(plan.removeEndPos)")
        }
    }
    
    func testPositionTracking() throws {
        let threadState = FreeToken.AIModelManager.AIStateManager.ThreadState(
            threadId: "position-test",
            fullThread: [],
            contextWindowSize: 1000,
            maxGenerationTokens: 100
        )
        
        // Test position tracking
        threadState.trackMessageTokens(messageIndex: 0, startPos: 0, endPos: 15)    // System message
        threadState.trackMessageTokens(messageIndex: 1, startPos: 16, endPos: 25)  // User message
        threadState.trackMessageTokens(messageIndex: 2, startPos: 26, endPos: 35)  // Assistant message
        
        // Test system message range
        let systemRange = threadState.getSystemMessageTokenRange()
        XCTAssertNotNil(systemRange, "Should track system message range")
        XCTAssertEqual(systemRange?.start, 0, "System message should start at position 0")
        XCTAssertEqual(systemRange?.end, 15, "System message should end at position 15")
        
        // Test recent messages range
        let recentRange = threadState.getRecentMessagesTokenRange(messageCount: 2)
        XCTAssertNotNil(recentRange, "Should get recent messages range")
        XCTAssertEqual(recentRange?.start, 16, "Recent messages should start at position 16")
        XCTAssertEqual(recentRange?.end, 35, "Recent messages should end at position 35")
        
        print("✅ Position tracking test passed")
        print("   System message range: \(systemRange?.start ?? -1) to \(systemRange?.end ?? -1)")
        print("   Recent messages range: \(recentRange?.start ?? -1) to \(recentRange?.end ?? -1)")
    }
    
    func testThreadStateManager() throws {
        let manager = FreeToken.AIModelManager.AIStateManager.ThreadStateManager()
        
        // Create a conversation that will need optimization
        let largeThread = (0..<50).flatMap { i in
            [
                FreeToken.Message(role: .user, content: "This is user message \(i) with some content to fill up the context window"),
                FreeToken.Message(role: .assistant, content: "This is assistant response \(i) with corresponding content")
            ]
        }
        
        let systemMessage = FreeToken.Message(role: .system, content: "You are a helpful assistant.")
        let fullThread = [systemMessage] + largeThread
        
        let threadState = manager.getOrCreateThreadState(
            threadId: "large-thread-test",
            fullThread: fullThread,
            contextWindowSize: 200, // Small context to force optimization
            maxGenerationTokens: 50
        )
        
        // Simulate that messages are loaded
        threadState.syncLoadedSession(fullThread.map { message in
            switch message.role {
            case .system: return LLMInput.Message.system(message.content)
            case .user: return LLMInput.Message.user(message.content)
            case .assistant: return LLMInput.Message.assistant(message.content)
            case .tool: return LLMInput.Message(role: .custom("tool"), content: message.content)
            }
        })
        
        // Test that context usage is high
        let currentUsage = Double(threadState.approximateTokenCount) / Double(threadState.contextWindowSize)
        XCTAssertGreaterThan(currentUsage, 0.8, "Thread should use more than 80% of context window")
        
        // Test that optimization would be triggered
        XCTAssertTrue(threadState.shouldOptimizeKVCache(currentUsage: currentUsage), "Should need KV cache optimization")
        
        print("✅ ThreadStateManager optimization test passed")
        print("   Context usage: \(String(format: "%.1f", currentUsage * 100))%")
        print("   Approximate tokens: \(threadState.approximateTokenCount)")
        print("   Context window size: \(threadState.contextWindowSize)")
    }
}
