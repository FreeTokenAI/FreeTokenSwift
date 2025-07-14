//
//  FreeToken.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/25/25.
//

import XCTest
import FreeToken

final class FreeTokenTests: XCTestCase {
    let freeToken = FreeToken.shared
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        _ = FreeToken.shared.configure(
            appToken: "app_tkn_3b39cb60-22cd-4877-b784-170b75f88a92",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
        // Register Device
        let semaphore = DispatchSemaphore(value: 0)
        Task {
//            try await FreeToken.shared.resetModelCaches()
            await FreeToken.shared.registerDeviceSession(scope: "swift-tests") {
                await FreeToken.shared.downloadAIModel { isLocal in
                    semaphore.signal()
                } error: { error in
                    XCTFail("Failed to download AI model: \(error.message)")
                } progressPercent: { progressPercent in
                    // Nothing to do here
                }
            } error: { error in
                XCTFail("Failed to register device session: \(error.message)")
            }
        }
        semaphore.wait() // Wait until complete
        print("---------------------------------- STOPPED WAITING ----------------------------------")
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        print("--------------------------------- RESETTING -----------------------------------------")
        try FreeToken.shared.resetDevice()
    }

    func testLocalCompletion() throws {
        let expectation = self.expectation(description: "Waiting for completion")

        Task {
            await FreeToken.shared.generateLocalCompletion(prompt: "The wheels on the bus go") { completion in
                print("Completion: \(completion.response)")
                expectation.fulfill()
            } error: { error in
                XCTFail(error.message)
            }
        }

        wait(for: [expectation], timeout: 30.0)
    }
    
    func testGenerateCompletion() throws {
        let expectation = self.expectation(description: "Waiting for completion")

        Task {
            await FreeToken.shared.generateCompletion(prompt: "The wheels on the bus go") { completion in
                print("Completion: \(completion.response)")
                XCTAssertTrue(completion.response.count > 0, "Expected non-empty completion response")
                expectation.fulfill()
            } error: { error in
                XCTFail(error.message)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 30.0)
    }
    
    func testCloudCompletion() throws {
        let expectation = self.expectation(description: "Waiting for completion")

        Task {
            await FreeToken.shared.generateCloudCompletion(prompt: "The wheels on the bus go") { completion in
                print("Completion: \(completion.response)")
                expectation.fulfill()
            } error: { error in
                XCTFail(error.message)
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }
    
    func testLocalChatCompletion() throws {
        let expectation = self.expectation(description: "Waiting for chat completion")

        Task {
            let messages = [FreeToken.Message(role: .user, content: "What is the capital of France?")]
            
            let response = try await FreeToken.shared.localChat(messages: messages)
            
            assert(response.content.contains("Paris"), "Expected response to contain 'Paris'")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }
    
    func testCloudChatCompletion() throws {
        let expectation = self.expectation(description: "Waiting for cloud chat completion")

        Task {
            let message = FreeToken.Message(role: .user, content: "What is the capital of France?")
            
            actor MessageStream {
                var message = ""
                
                func append(_ text: String) {
                    message += text
                }
                func getMessage() -> String {
                    return message
                }
            }
            
            let messageStream = MessageStream()
            
            await FreeToken.shared.createMessageThread { messageThread in
                await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                    await FreeToken.shared.runMessageThread(id: messageThread.id, forceCloudRun: true) { resultMessage in
                        assert(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                        let finalMessage = await messageStream.getMessage()
                        assert(resultMessage.content == finalMessage, "Expected final message to match result message")
                        expectation.fulfill()
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    } chatStatusStream: { token, status in
                        if let token = token {
                            print("Received token: \(token)")
                            await messageStream.append(token)
                        }
                    }
                } error: { error in
                    XCTFail("Failed to add message to thread: \(error.message)")
                    expectation.fulfill()
                }
            } error: { error in
                XCTFail("Failed to create message thread: \(error.message)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }
    
    func testCloudMessageContinuity() throws {
        let expectation = self.expectation(description: "Waiting for cloud chat completion")

        Task {
            let message = FreeToken.Message(role: .user, content: "Write a short story about a robot in Paris.")
            
            actor MessageStream {
                var message = ""
                var streamEnded = false
                var completionMessage: FreeToken.Message?
                let completionCallback: @Sendable () -> Void
                
                init(completionCallback: @Sendable @escaping () -> Void) {
                    self.completionCallback = completionCallback
                }
                
                func append(_ text: String) {
                    message += text
                }
                
                func getMessage() -> String {
                    return message
                }
                
                func setStreamEnded() {
                    streamEnded = true
                    checkForCompletion()
                }
                
                func setCompletionMessage(_ message: FreeToken.Message) {
                    completionMessage = message
                    checkForCompletion()
                }
                
                private func checkForCompletion() {
                    if streamEnded, let resultMessage = completionMessage {
                        Task {
                            // Small delay to ensure final tokens are processed
                            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                            
                            let finalMessage = getMessage()
                            let result = resultMessage.content == finalMessage
                            
                            if !result {
                                print("MISMATCH DETECTED:")
                                print("Expected: \(resultMessage.content)")
                                print("Got: \(finalMessage)")
                            }
                            
                            assert(result, "Expected final message to match result message")
                            completionCallback()
                        }
                    }
                }
            }
            
            let messageStream = MessageStream {
                expectation.fulfill()
            }
            
            await FreeToken.shared.createMessageThread { messageThread in
                await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                    await FreeToken.shared.runMessageThread(id: messageThread.id, forceCloudRun: true) { resultMessage in
                        await messageStream.setCompletionMessage(resultMessage)
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    } chatStatusStream: { token, status in
                        if let token = token {
                            await messageStream.append(token)
                        } else if status == .stream_ended {
                            await messageStream.setStreamEnded()
                        }
                    }
                } error: { error in
                    XCTFail("Failed to add message to thread: \(error.message)")
                    expectation.fulfill()
                }
            } error: { error in
                XCTFail("Failed to create message thread: \(error.message)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 30.0)
    }
    
    func testSystemMessageReinjection() throws {
        let expectation = self.expectation(description: "Waiting for system message reinjection test")
        
        Task {
            do {
                // Create a system message that establishes specific behavior
                let systemMessage = FreeToken.Message(role: .system, content: "You are a helpful assistant that ALWAYS responds with exactly 3 words, no more, no less.")
                
                // Create many user messages to potentially overflow context
                var messages: [FreeToken.Message] = [systemMessage]
                
                // Add many messages to approach context limit
                // Each message pair (user + assistant) uses roughly 50-100 tokens
                for i in 1...30 {
                    messages.append(FreeToken.Message(role: .user, content: "Question \(i): What is the meaning of life?"))
                    messages.append(FreeToken.Message(role: .assistant, content: "Three word answer"))
                }
                
                // Add final test message
                messages.append(FreeToken.Message(role: .user, content: "How many words should your response contain?"))
                
                // Run local chat with small context window to force trimming
                let response = try await FreeToken.shared.localChat(
                    messages: messages,
                    uniqueID: "test-reinjection"
                )
                
                print("System message reinjection test response: \(response.content)")
                
                // Verify the AI still follows the system message instruction
                let wordCount = response.content.split(separator: " ").count
                XCTAssertLessThanOrEqual(wordCount, 5, "Expected response to be concise (around 3 words) per system message")
                
                // Check if response mentions "three" or "3"
                let mentionsThree = response.content.lowercased().contains("three") || response.content.contains("3")
                XCTAssertTrue(mentionsThree, "Expected response to acknowledge the 3-word constraint from system message")
                
                expectation.fulfill()
            } catch {
                XCTFail("Test failed with error: \(error)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 60.0)
    }

}
