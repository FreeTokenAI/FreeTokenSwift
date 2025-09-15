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
        _ = try FreeToken.shared.configure(
            appToken: "test-token",
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
                    // NOTE: This is not getting called during the test download
                    print("Download progress - TEST: \(progressPercent * 100.0)%")
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
        Task {
            try await FreeToken.shared.resetDevice()
        }
    }
    
    func testGetAIModelDownloadState() throws {
        let expectation = self.expectation(description: "Waiting for download state check")
        
        Task {
            do {
                // Test 1: Check default model (should be downloaded from setUp)
                let defaultState = try await FreeToken.shared.getAIModelDownloadState()
                XCTAssertEqual(defaultState, .downloaded, "Default model should be downloaded after setUp")
                print("✅ Default model state: \(defaultState)")
                
                // Test 2: Check a model that hasn't been downloaded yet
                let undownloadedModelCode = "gemma3_4b_it"
                let undownloadedState = try await FreeToken.shared.getAIModelDownloadState(modelCode: undownloadedModelCode)
                print("✅ State for undownloaded model \(undownloadedModelCode): \(undownloadedState)")
                XCTAssertEqual(undownloadedState, .notDownloaded, "Model that hasn't been downloaded should return .notDownloaded")
                
                // Test 3: Check the same undownloaded model again to ensure consistency
                let undownloadedStateAgain = try await FreeToken.shared.getAIModelDownloadState(modelCode: undownloadedModelCode)
                XCTAssertEqual(undownloadedStateAgain, .notDownloaded, "Checking again should still return .notDownloaded")
                print("✅ Consistency check for \(undownloadedModelCode): \(undownloadedStateAgain)")
                
                // Test 4: Check default model again after checking other models
                let defaultStateAgain = try await FreeToken.shared.getAIModelDownloadState()
                XCTAssertEqual(defaultStateAgain, .downloaded, "Default model should still be downloaded")
                print("✅ Default model state after other checks: \(defaultStateAgain)")
                
                expectation.fulfill()
            } catch {
                XCTFail("Failed to get download state: \(error)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
    
    func testLocalCompletion() throws {
        let expectation = self.expectation(description: "Waiting for completion")

        Task {
            await FreeToken.shared.generateLocalCompletion(prompt: "Complete the following: The wheels on the bus go") { completion in
                print("Completion: \(completion.response)")
                expectation.fulfill()
            } error: { error in
                XCTFail(error.message)
            }
        }

        wait(for: [expectation], timeout: 60.0)
    }
    
    func testLocalCompltionWithModelCode() throws {
        let expectation = self.expectation(description: "Waiting for local completion with model code")

        Task {
            let modelCode = "gemma3_4b_it"
            
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
            let modelCode = "gemma3_4b_it"
            
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
    
    func testMessageThreadRun() throws {
        let expectation = self.expectation(description: "Waiting for message thread run")

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
                    await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .localRun, success: { resultMessage in
                        XCTAssertTrue(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                        let finalMessage = await messageStream.getMessage()
                        XCTAssertEqual(resultMessage.content, finalMessage, "Expected final message to match result message")
                        expectation.fulfill()
                    }, error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    }, chatStatusStream: { token, status in
                        if let token = token {
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

        wait(for: [expectation], timeout: 300.0)
    }
    
    func testColdPrewarmCacheRun() throws {
        let expectation = self.expectation(description: "Waiting for message thread run")

        Task {
            
            let uuid = UUID().uuidString
            
            actor MessageStream {
                var message = ""
                
                func append(_ text: String) {
                    message += text
                }
                func getMessage() -> String {
                    return message
                }
            }
            
            _ = await FreeToken.shared.prewarmAIFor(runIdentifier: uuid, success: {
                let message = FreeToken.Message(role: .user, content: "What is the capital of France?")
                
                let messageStream = MessageStream()
                
                await FreeToken.shared.createMessageThread { messageThread in
                    await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                        await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .localRun, runIdentifier: uuid, success: { resultMessage in
                            XCTAssertTrue(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                            let finalMessage = await messageStream.getMessage()
                            XCTAssertEqual(resultMessage.content, finalMessage, "Expected final message to match result message")
                            expectation.fulfill()
                        }, error: { error in
                            XCTFail("Failed to run message thread: \(error.message)")
                            expectation.fulfill()
                        }, chatStatusStream: { token, status in
                            if let token = token {
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
            }, error: { error in
                XCTFail("Failed to prewarm with error: \(error.message)")
                expectation.fulfill()
            })
        }

        wait(for: [expectation], timeout: 300.0)
    }
    
    func testPrewarmCacheRun() throws {
        let expectation = self.expectation(description: "Waiting for message thread run")

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
                    
                    await FreeToken.shared.prewarmAIForMessageThread(messageThreadID: messageThread.id) {
                        await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .localRun, success: { resultMessage in
                            XCTAssertTrue(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                            let finalMessage = await messageStream.getMessage()
                            XCTAssertEqual(resultMessage.content, finalMessage, "Expected final message to match result message")
                            expectation.fulfill()
                        }, error: { error in
                            XCTFail("Failed to run message thread: \(error.message)")
                            expectation.fulfill()
                        }, chatStatusStream: { token, status in
                            if let token = token {
                                await messageStream.append(token)
                            }
                        })
                    } error: { error in
                        XCTFail("Failed to prewarm AI for message thread: \(error.message)")
                        expectation.fulfill()
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

        wait(for: [expectation], timeout: 300.0)
    }
    
    func testReallyLongMessageThreadCountRun() throws {
        let expectation = self.expectation(description: "Waiting for really long message thread run")
        
        Task {
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
            
            _ = await FreeToken.shared.createMessageThread { messageThread in
                for i in 1...501 {
                    let content: String
                    let role: FreeToken.MessageRole
                    if i.isMultiple(of: 2) {
                        // Odd messages
                        content = "Hello! This is message number \(i). How can I help you today? This is a really long message to test the limits of the message thread system. "
                        role = .assistant
                    } else {
                        // Even messages
                        content = "Hi there! How are you?"
                        role = .user
                    }
                    
                    let message = FreeToken.Message(role: role, content: content)
                    await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                        // Added a message.
                    } error: { error in
                        XCTFail("Failed to add message to thread: \(error.message)")
                        expectation.fulfill()
                    }
                }
                
                _ = await FreeToken.shared.prewarmAIForMessageThread(messageThreadID: messageThread.id)
                
                await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .localRun, success: { resultMessage in
                    let finalMessage = await messageStream.getMessage()
                    XCTAssertEqual(resultMessage.content, finalMessage, "Expected final message to match result message")
                    expectation.fulfill()
                }, error: { error in
                    XCTFail("Failed to run message thread: \(error.message)")
                    expectation.fulfill()
                }, chatStatusStream: { token, status in
                    if let token = token {
                        await messageStream.append(token)
                    }
                })
            } error: { error in
                XCTFail("Failed to create message thread: \(error.message)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 300.0)
    }
    
    func testRunMessageThreadWithModelCode() throws {
        let expectation = self.expectation(description: "Waiting for run message thread with model code")

        Task {
            let modelCode = "gemma3_4b_it"
            
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
                        await FreeToken.shared.runMessageThread(id: messageThread.id, privateDocumentStoreIds: ["foo-bar", "baz"], modelCode: modelCode, success: { resultMessage in
                            XCTAssertTrue(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                            let finalMessage = await messageStream.getMessage()
                            XCTAssertEqual(resultMessage.content, finalMessage, "Expected final message to match result message")
                            expectation.fulfill()
                        }, error: { error in
                            XCTFail("Failed to run message thread: \(error.message)")
                            expectation.fulfill()
                        }, chatStatusStream: { token, status in
                            if let token = token {
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

        wait(for: [expectation], timeout: 30.0)
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
                        await FreeToken.shared.runMessageThread(id: messageThread.id, runLocation: .automatic, success: { resultMessage in
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
                
                try FreeToken.shared.enableCustomEncryption { toEncrypt, scope in
                    return Data(toEncrypt.utf8).base64EncodedString()
                } decrypt: { toDecrypt, scope in
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
    
    func testBackAndForthConversation() {
        let expectation = self.expectation(description: "Waiting for back and forth conversation")
        
        Task {
            await FreeToken.shared.createMessageThread { mt in
                let message = FreeToken.Message(role: .user, content: "What is it like to be a tourist in Italy?")
                
                await FreeToken.shared.addMessageToThread(id: mt.id, message: message) { message1 in
                    await FreeToken.shared.runMessageThread(id: mt.id, runLocation: .localRun) { response in
                        let message = FreeToken.Message(role: .user, content: "What is it like to visit Lake Como?")
                        print("Response 1: \(response.content)")
                        
                        await FreeToken.shared.addMessageToThread(id: mt.id, message: message) { message2 in
                            await FreeToken.shared.runMessageThread(id: mt.id, runLocation: .localRun) { response2 in
                                print("Response 2: \(response2.content)")
                                
                                let message = FreeToken.Message(role: .user, content: "What about being a tourist in Rome?")
                                
                                await FreeToken.shared.addMessageToThread(id: mt.id, message: message) { message3 in
                                    await FreeToken.shared.runMessageThread(id: mt.id, runLocation: .localRun) { response3 in
                                        print("Response 3: \(response3.content)")
                                        XCTAssertTrue(response3.content.contains("Rome"), "Expected response to mention 'Rome'")
                                        expectation.fulfill()
                                    } error: { error in
                                        XCTFail("Failed to run message thread: \(error.message)")
                                        expectation.fulfill()
                                    }
                                } error: { error in
                                    XCTFail("Failed to add third message to thread: \(error.message)")
                                    expectation.fulfill()
                                }
                            } error: { error in
                                XCTFail("Failed to run message thread: \(error.message)")
                                expectation.fulfill()
                            }
                        } error: { error in
                            XCTFail("Failed to add second message to thread: \(error.message)")
                            expectation.fulfill()
                        }
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    }
                } error: { error in
                    XCTFail("Failed to add first message to thread: \(error.message)")
                    expectation.fulfill()
                }
            } error: { err in
                XCTFail("Failed to create message thread: \(err.message)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 1000.0)
    }
    
    func testPrewarmForArbitraryId() throws {
        let expectation = self.expectation(description: "Waiting for prewarm for arbitrary ID")
        
        Task {
            let arbitraryId = "test-arbitrary-id"
            let client = FreeToken.shared
            
            await FreeToken.shared.prewarmAIFor(runIdentifier: arbitraryId) {
                print("✅ Prewarm completed for arbitrary ID: \(arbitraryId)")
                
                await client.createMessageThread { messageThread in
                    let message = FreeToken.Message(role: .user, content: "What is the capital of France?")
                    await client.addMessageToThread(id: messageThread.id, message: message) { message in
                        await client.runMessageThread(id: messageThread.id, runLocation: .localRun, runIdentifier: arbitraryId, success: { resultMessage in
                            XCTAssertTrue(resultMessage.content.contains("Paris"), "Expected response to contain 'Paris'")
                            expectation.fulfill()
                        }, error: { error in
                            XCTFail("Failed to run message thread: \(error.message)")
                            expectation.fulfill()
                        })
                    } error: { error in
                        XCTFail("Failed to add message to thread: \(error.message)")
                        expectation.fulfill()
                    }
                } error: { error in
                    XCTFail("Failed to prewarm AI for arbitrary ID: \(error.message)")
                    expectation.fulfill()
                }
            }
        }
        
        wait(for: [expectation], timeout: 90.0)
    }
    
    func testDoubleDownload() throws {
        let expectation = self.expectation(description: "Waiting for double download")
        
        Task {
            await FreeToken.shared.downloadAIModel { state in
                print("✅ First time model downloaded successfully")
                // Now try to download the same model again, it should happen near instantaneiously
                let time = DispatchTime.now()
                await FreeToken.shared.downloadAIModel { state in
                    // Test if the model completion handler was called within 3 seconds
                    print("✅ Second time model downloaded successfully")
                    let elapsed = DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds
                    XCTAssert(elapsed < 3_000_000_000, "Model download took too long: \(elapsed) nanoseconds")
                    expectation.fulfill()
                } error: { error in
                    XCTFail("Failed to download model second time: \(error.message)")
                    expectation.fulfill()
                }
            } error: { error in
                // Error
                XCTFail("Failed to download model second time: \(error.message)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 300.0)
    }
    
    func testDoubleDownloadWithModelCode() throws {
        let expectation = self.expectation(description: "Waiting for double download")
        
        let modelCode = "gemma3_4b_it"
        
        Task {
            await FreeToken.shared.downloadAIModel(modelCode: modelCode) { state in
                print("🎉 First time model downloaded successfully")
                // Now try to download the same model again, it should happen near instantaneiously
                let time = DispatchTime.now()
                await FreeToken.shared.downloadAIModel(modelCode: modelCode) { state in
                    // Test if the model completion handler was called within 3 seconds
                    print("🥳 Second time model downloaded successfully")
                    let elapsed = DispatchTime.now().uptimeNanoseconds - time.uptimeNanoseconds
                    XCTAssert(elapsed < 3_000_000_000, "Model download took too long: \(elapsed) nanoseconds")
                    expectation.fulfill()
                } error: { error in
                    XCTFail("Failed to download model second time: \(error.message)")
                    expectation.fulfill()
                } progressPercent: { progressPercent in
                    print("🌎 Downloading model #2: \(modelCode): \(progressPercent)%")
                }
            } error: { error in
                // Error
                XCTFail("Failed to download model second time: \(error.message)")
                expectation.fulfill()
            } progressPercent: { progressPercent in
                print("🌎 Downloading model #1: \(modelCode): \(progressPercent)%")
            }
        }
        
        wait(for: [expectation], timeout: 300.0)
    }
    
    func testSerialAIQueue() throws {
        let franceExpectation = self.expectation(description: "Waiting for France queue")
        let italyExpectation = self.expectation(description: "Waiting for Italy queue")
        let checkExpectation = self.expectation(description: "Waiting for check queue")
        
        actor TestResult {
            let country: String
            var beginTime: Date?
            var endTime: Date?
            
            init(country: String) {
                self.country = country
            }
            
            func setBeginTime(_ time: Date) {
                self.beginTime = time
            }
            func setEndTime(_ time: Date) {
                self.endTime = time
            }
        }
        
        actor ResultCollector {
            var results: [TestResult] = []
            
            func addResult(_ result: TestResult) {
                results.append(result)
            }
            
            func getResults() -> [TestResult] {
                return results
            }
        }
        
        let resultCollector = ResultCollector()
        // Make sure the AIModelManager is only allowing one AI run at a time
        Task {
            print("🇫🇷 Starting France Test (1)")
            let franceResult = TestResult(country: "France")
            do {
                _ = try await FreeToken.shared.localChat(messages: [.init(role: .user, content: "What is the capital of France?")], runIdentifier: "france-test") { token in
                    await franceResult.setBeginTime(Date()) // Capture start time at after the first token is generated.
                }
            } catch {
                XCTFail("Failed to get Italy completion: \(error.localizedDescription)")
                franceExpectation.fulfill()
            }
            
            await franceResult.setEndTime(Date())
            await resultCollector.addResult(franceResult)
            franceExpectation.fulfill()
        }
        
        Task {
            print("🇮🇹 Starting Italy Test (2)")
            
            let italyResult = TestResult(country: "Italy")
            do {
                try await Task.sleep(nanoseconds: 1_000_000) // Ensure France has started before Italy
                _ = try await FreeToken.shared.localChat(messages: [.init(role: .user, content: "What is the capital of Italy?")], runIdentifier: "italy-test") { token in
                    await italyResult.setBeginTime(Date()) // Capture start time at after the first token is generated.
                }
            } catch {
                XCTFail("Failed to get Italy completion: \(error.localizedDescription)")
                italyExpectation.fulfill()
            }
        
            await italyResult.setEndTime(Date())
            await resultCollector.addResult(italyResult)
            italyExpectation.fulfill()
        }
        
        Task {
            // Check that expectations were met that the queues ran in serial - start dates and end dates should not overlap
            var results = await resultCollector.getResults()
            
            print("Checking for results...")
            while results.count < 2 {
                try? await Task.sleep(nanoseconds: 100_000_000) // Wait 100ms
                results = await resultCollector.getResults()
            }
                        
            let franceResult = results.first { $0.country == "France" }
            let italyResult = results.first { $0.country == "Italy" }
            
            if
                let franceResult = franceResult,
                let franceBegin = await franceResult.beginTime,
                let franceEnd = await franceResult.endTime,
                let italyResult = italyResult,
                let italyBegin = await italyResult.beginTime
            {
                // Check that France started before Italy
                XCTAssertTrue(franceBegin < italyBegin, "France should start before Italy")
                
                // Check that France ended before Italy
                XCTAssertTrue(franceEnd < italyBegin, "France should end before Italy starts")
                
                checkExpectation.fulfill()
            } else {
                XCTFail("Failed to find results for France or Italy")
                checkExpectation.fulfill()
            }
        }
        
        wait(for: [franceExpectation, italyExpectation, checkExpectation], timeout: 60.0)
    }
    
    func testTokenizer() throws {
        let expectation = self.expectation(description: "Waiting for tokenizer test")
        
        Task {
            let count = try await FreeToken.shared.countTokens(text: "Hello, world!")
            print("TOKEN COUNT: \(count)")
            XCTAssertGreaterThan(count, 0, "Expected token count to be greater than 0")
            XCTAssertLessThan(count, 10, "Expect token count to be less than 10")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
    
    func testModelIsDownloaded() async throws {
        let state = try await FreeToken.shared.getAIModelDownloadState()
        
        XCTAssert(state == .downloaded, "Expected model to be downloaded, got \(state)")
    }
    
    func testCancelLocalCompletion() throws {
        let expectation = self.expectation(description: "Waiting for cancel local completion")
        
        Task {
            await FreeToken.shared.generateCompletion(prompt: "Create a short story about how a man went the moon") { token in
                throw FreeToken.FreeTokenError.generationCancelled
            } success: { completion in
                XCTFail("Expected generation to be cancelled, but got completion: \(completion.response)")
                expectation.fulfill()
            } error: { error in
                if error == .generationCancelled {
                    XCTAssertTrue(true, "Generation was cancelled as expected")
                } else {
                    XCTFail("Expected generation to be cancelled, got error: \(error.message)")
                }
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testWebSearch() throws {
        let expectation = self.expectation(description: "Waiting for web search completion")
        
        
        Task {
            try await FreeToken.shared.resetDevice()
            
            _ = try FreeToken.shared.configure(appToken: "test-token", baseURL: URL(string: "http://localhost:3000/api/v1/"),
                                       logLevel: .debug)
            
            await FreeToken.shared.registerDeviceSession(scope: "web-search") {
                await FreeToken.shared.createMessageThread { mt in
                    await FreeToken.shared.addMessageToThread(id: mt.id, message: .init(role: .user, content: "What's the latest headlines on the internet? Be sure to use web_search tool.")) { message in
                        await FreeToken.shared.runMessageThread(id: mt.id) { result in
                            XCTAssertTrue(true)
                            expectation.fulfill()
                        } error: { err in
                            XCTFail("Failed to run message thread: \(err.message)")
                            expectation.fulfill()
                        }
                    } error: { err in
                        XCTFail("Failed to add message to thread: \(err.message)")
                        expectation.fulfill()
                    }
                } error: { err in
                    XCTFail("Failed to create message thread: \(err.message)")
                    expectation.fulfill()
                }
            } error: { err in
                XCTFail("Failed to register device session: \(err.message)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 300.0)
    }
    
}
