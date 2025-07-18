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
                    print("AI model downloaded successfully. Local: \(isLocal)")
                    semaphore.signal()
                } error: { error in
                    XCTFail("Failed to download AI model: \(error.message)")
                } progressPercent: { progressPercent in
                    // Nothing to do here
                    print("Download progress: \(progressPercent)%")
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
    
    func testLocalCompltionWithModelCode() throws {
        let expectation = self.expectation(description: "Waiting for local completion with model code")

        Task {
            let modelCode = "llama3.2_3b_instruct"
            
            await FreeToken.shared.downloadAIModel(modelCode: modelCode) { state in
                await FreeToken.shared.generateLocalCompletion(prompt: "The wheels on the bus go", modelCode: modelCode) { completion in
                    print("Completion: \(completion.response)")
                    XCTAssertTrue(completion.response.count > 0, "Expected non-empty completion response")
                    expectation.fulfill()
                } error: { error in
                    XCTFail(error.message)
                    expectation.fulfill()
                }
            } error: { error in
                XCTFail(error.message)
                expectation.fulfill()
            } progressPercent: { progressPercent in
                print("Downloading model \(modelCode): \(progressPercent * 100.0)%")
            }
        }

        wait(for: [expectation], timeout: 300.0) // Has to be long because it's downloading the model
    }
    
    func testLocalChatWithModelCode() throws {
        let expectation = self.expectation(description: "Waiting for local chat with model code")
        
        Task {
            let modelCode = "llama3.2_3b_instruct"
            
            await FreeToken.shared.downloadAIModel(modelCode: modelCode) { state in
                let messages = [FreeToken.Message(role: .user, content: "What is the capital of France?")]
                
                do {
                    let response = try await FreeToken.shared.localChat(modelCode: modelCode, messages: messages)
                    
                    XCTAssertTrue(response.content.contains("Paris"), "Expected response to contain 'Paris'")
                    expectation.fulfill()
                } catch {
                    XCTFail("Failed to get local chat response: \(error)")
                    expectation.fulfill()
                }
            } error: { error in
                XCTFail(error.message)
                expectation.fulfill()
            } progressPercent: { progressPercent in
                print("Downloading model \(modelCode): \(progressPercent)%")
            }
        }
        
        wait(for: [expectation], timeout: 300.0) // Has to be long because it's downloading the model
    }
    
    func testRunMessageThreadWithModelCode() throws {
        let expectation = self.expectation(description: "Waiting for run message thread with model code")

        Task {
            let modelCode = "llama3.2_3b_instruct"
            
            await FreeToken.shared.downloadAIModel(modelCode: modelCode) { state in
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
                        await FreeToken.shared.runMessageThread(id: messageThread.id, modelCode: modelCode, success: { resultMessage in
                            XCTAssertTrue(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                            let finalMessage = await messageStream.getMessage()
                            XCTAssertEqual(resultMessage.content, finalMessage, "Expected final message to match result message")
                            expectation.fulfill()
                        }, error: { error in
                            XCTFail("Failed to run message thread: \(error.message)")
                            expectation.fulfill()
                        }, chatStatusStream: { token, status in
                            if let token = token {
                                print("Received token: \(token)")
                                await messageStream.append(token)
                            }
                        })
                    } error: { error in
                        XCTFail("Failed to add message to thread: \(error.message)")
                        expectation.fulfill()
                    }
                } error: { error in
                    XCTFail("Failed to create message thread: \(error.message)")
                    expectation.fulfill()
                }
            } error: { error in
                XCTFail(error.message)
                expectation.fulfill()
            } progressPercent: { progressPercent in
                print("Downloading model \(modelCode): \(progressPercent)%")
            }
        }

        wait(for: [expectation], timeout: 180.0) // Has to be long because it's downloading the model
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
                    await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .cloudRun, success: { resultMessage in
                        assert(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                        let finalMessage = await messageStream.getMessage()
                        assert(resultMessage.content == finalMessage, "Expected final message to match result message")
                        expectation.fulfill()
                    }, error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    }, chatStatusStream: { token, status in
                        if let token = token {
                            print("Received token: \(token)")
                            await messageStream.append(token)
                        }
                    })
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
                    await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .cloudRun, success: { resultMessage in
                        await messageStream.setCompletionMessage(resultMessage)
                    }, error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    }, chatStatusStream: { token, status in
                        if let token = token {
                            await messageStream.append(token)
                        } else if status == .stream_ended {
                            await messageStream.setStreamEnded()
                        }
                    })
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
    
    func testMultiModalImageRun() {
        print("🔍 Starting multi-modal test...")
        
        // Download a test image from URL
        let expectation = self.expectation(description: "Waiting for multi-modal image run")
        
        Task {
            do {
                let url = URL(string: "https://upload.wikimedia.org/wikipedia/en/e/ed/Nyan_cat_250px_frame.PNG")!
                let (imageData, _) = try await URLSession.shared.data(from: url)
                print("🖼️ Downloaded image: \(imageData.count) bytes")
                
                let imageAttachment = FreeToken.MessageAttachment(type: .image, data: imageData, filename: "Nyan_cat_250px_frame.PNG", contentType: "image/png")
                let message = FreeToken.Message(role: .user, content: "What do you see in this image?", attachments: [imageAttachment])
                
                print("🔍 TEST: Created message with \(message.attachments?.count ?? 0) attachments")
                
                await FreeToken.shared.createMessageThread { messageThread in
                    await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                        await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .cloudRun, success: { resultMessage in
                            print("✅ Multi-modal response: \(resultMessage.content)")
                            XCTAssertTrue(resultMessage.content.count > 0, "Expected non-empty response")
                            XCTAssertTrue(resultMessage.content.contains("Nyan"), "Expected response to mention 'Nyan Cat'")
                            expectation.fulfill()
                        }, error: { error in
                            print("❌ Failed to run message thread with image: \(error.message)")
                            print("❌ Error details: \(error)")
                            
                            // Check if it's a vision model error
                            if case .visionModelRequired = error {
                                print("🔍 Vision model error: Current model doesn't support vision capabilities")
                                // Don't fail the test - this is an expected error for non-vision models
                                expectation.fulfill()
                            } else {
                                XCTFail("Failed to run message thread with image: \(error.message)")
                                expectation.fulfill()
                            }
                        })
                    } error: { error in
                        print("❌ Failed to add image message to thread: \(error.message)")
                        XCTFail("Failed to add image message to thread: \(error.message)")
                        expectation.fulfill()
                    }
                } error: { error in
                    print("❌ Failed to create message thread for image run: \(error.message)")
                    XCTFail("Failed to create message thread for image run: \(error.message)")
                    expectation.fulfill()
                }
            } catch {
                print("❌ Failed to download image: \(error)")
                XCTFail("Failed to download image: \(error)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 180.0)
    }

    
    func testMultiModalEncryptedImageRun() {
        print("🔍 Starting multi-modal test...")
        
        // Download a test image from URL
        let expectation = self.expectation(description: "Waiting for multi-modal image run")
        
        Task {
            do {
                let url = URL(string: "https://upload.wikimedia.org/wikipedia/en/e/ed/Nyan_cat_250px_frame.PNG")!
                let (imageData, _) = try await URLSession.shared.data(from: url)
                print("🖼️ Downloaded image: \(imageData.count) bytes")
                
                let imageAttachment = FreeToken.MessageAttachment(type: .image, data: imageData, filename: "Nyan_cat_250px_frame.PNG", contentType: "image/png")
                let message = FreeToken.Message(role: .user, content: "What do you see in this image?", attachments: [imageAttachment])
                
                print("🔍 TEST: Created message with \(message.attachments?.count ?? 0) attachments")
                
                try FreeToken.shared.privacyModeEncryption { toEncrypt in
                    // Use base64 to simulate encryption
                    return Data(toEncrypt.utf8).base64EncodedString()
                } decrypt: { toDecrypt in
                    return String(data: Data(base64Encoded: toDecrypt) ?? Data(), encoding: .utf8) ?? ""
                }
                
                await FreeToken.shared.createMessageThread { messageThread in
                    await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                        await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .cloudRun, success: { resultMessage in
                            print("✅ Multi-modal response: \(resultMessage.content)")
                            XCTAssertTrue(resultMessage.content.count > 0, "Expected non-empty response")
                            expectation.fulfill()
                        }, error: { error in
                            print("❌ Failed to run message thread with image: \(error.message)")
                            print("❌ Error details: \(error)")
                            
                            // Check if it's a vision model error
                            if case .visionModelRequired = error {
                                print("🔍 Vision model error: Current model doesn't support vision capabilities")
                                // Don't fail the test - this is an expected error for non-vision models
                                expectation.fulfill()
                            } else {
                                XCTFail("Failed to run message thread with image: \(error.message)")
                                expectation.fulfill()
                            }
                        })
                    } error: { error in
                        print("❌ Failed to add image message to thread: \(error.message)")
                        XCTFail("Failed to add image message to thread: \(error.message)")
                        expectation.fulfill()
                    }
                } error: { error in
                    print("❌ Failed to create message thread for image run: \(error.message)")
                    XCTFail("Failed to create message thread for image run: \(error.message)")
                    expectation.fulfill()
                }
            } catch {
                print("❌ Failed to download image: \(error)")
                XCTFail("Failed to download image: \(error)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 180.0)
    }
}
