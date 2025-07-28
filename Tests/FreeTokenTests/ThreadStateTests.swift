//
//  ThreadStateTests.swift  
//  FreeToken
//
//  Testing the new ThreadState management system
//

import XCTest
@testable import FreeToken
import LocalLLMClient

final class ThreadStateTests: XCTestCase {
    
    override func setUpWithError() throws {
        _ = try FreeToken.shared.configure(
            appToken: "test-token",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
    }
    
    func testThreadStateBasicFunctionality() throws {
        // Create a thread state with a few messages
        let messages = [
            FreeToken.Message(role: .system, content: "You are helpful."),
            FreeToken.Message(role: .user, content: "Hello"),
            FreeToken.Message(role: .assistant, content: "Hi there!"),
            FreeToken.Message(role: .user, content: "How are you?")
        ]
        
        let threadState = FreeToken.AIModelManager.AIStateManager.ThreadState(
            threadId: "test-thread-1",
            fullThread: messages,
            contextWindowSize: 100,
            maxGenerationTokens: 20
        )
        
        // Test initial state
        XCTAssertEqual(threadState.threadId, "test-thread-1")
        XCTAssertEqual(threadState.fullThread.count, 4)
        XCTAssertEqual(threadState.loadedMessages.count, 0)
        XCTAssertEqual(threadState.approximateTokenCount, 0)
        
        // Test new messages detection
        let newMessages = threadState.getNewMessagesToAppend()
        XCTAssertEqual(newMessages.count, 4, "Should detect all messages as new when session is empty")
        
        print("✅ ThreadState basic functionality test passed")
    }
    
    func testThreadStateManager() throws {
        let manager = FreeToken.AIModelManager.AIStateManager.ThreadStateManager()
        
        let messages = [
            FreeToken.Message(role: .system, content: "System prompt"),
            FreeToken.Message(role: .user, content: "First message"),
            FreeToken.Message(role: .assistant, content: "First response")
        ]
        
        // Test creating thread state
        let threadState1 = manager.getOrCreateThreadState(
            threadId: "thread-1",
            fullThread: messages,
            contextWindowSize: 200,
            maxGenerationTokens: 50
        )
        
        XCTAssertEqual(threadState1.threadId, "thread-1")
        XCTAssertEqual(threadState1.fullThread.count, 3)
        
        // Test retrieving existing thread state
        let threadState2 = manager.getOrCreateThreadState(
            threadId: "thread-1",
            fullThread: messages + [FreeToken.Message(role: .user, content: "New message")],
            contextWindowSize: 200,
            maxGenerationTokens: 50
        )
        
        // Should be the same instance, but with updated thread
        XCTAssertEqual(threadState2.threadId, "thread-1")
        XCTAssertEqual(threadState2.fullThread.count, 4, "Thread should be updated with new message")
        
        print("✅ ThreadStateManager test passed")
    }
    
    func testAppendStrategy() throws {
        let manager = FreeToken.AIModelManager.AIStateManager.ThreadStateManager()
        
        // Create a small thread that fits in context window
        let smallThread = [
            FreeToken.Message(role: .system, content: "System"),
            FreeToken.Message(role: .user, content: "Question"),
            FreeToken.Message(role: .assistant, content: "Answer")
        ]
        
        let threadState = manager.getOrCreateThreadState(
            threadId: "small-thread",
            fullThread: smallThread,
            contextWindowSize: 1000, // Large context window
            maxGenerationTokens: 100
        )
        
        // Test strategy when no session exists
        let strategy1 = manager.planMessageStrategy(
            threadState: threadState,
            currentSession: nil,
            fullThread: smallThread
        )
        
        if case .rebuildRequired(let reason) = strategy1 {
            XCTAssertEqual(reason, "no_session")
        } else {
            XCTFail("Should require rebuild when no session exists")
        }
        
        print("✅ Append strategy test passed")
    }
}
