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
    
    func testChatSession() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")
        
        Task {
            let session = try await FreeToken.shared.getChatSession()
            
            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Italy"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }, toolUseHandler: nil)
            
            await session.unload()
            XCTAssertTrue(response.content.contains("Rome"), "Expected response to contain 'Rome'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testCloudChatSession() throws {
        let expectation = self.expectation(description: "Waiting for cloud chat session test")
        
        Task {
            let session = try await FreeToken.shared.getChatSession(runLocation: .cloudRun)
            
            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Germany"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }, toolUseHandler: nil)
            
            await session.unload()
            XCTAssertTrue(response.content.contains("Berlin"), "Expected response to contain 'Berlin'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testCompletionSession() throws {
        let expectation = self.expectation(description: "Waiting for completion session test")
        
        Task {
            let session = try await FreeToken.shared.getCompletionSession()
            
            let response = try await session.generateCompletion(from: "Tell me a fun fact about space", chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
            })
            
            await session.unload()
            XCTAssertTrue(response.response.contains("space"), "Expected response to contain 'space'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testCloudCompletionSession() throws {
        let expectation = self.expectation(description: "Waiting for cloud completion session test")
        
        Task {
            let session = try await FreeToken.shared.getCompletionSession(runLocation: .cloudRun)
            
            let response = try await session.generateCompletion(from: "Tell me a fun fact about oceans", chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
            })
            
            await session.unload()
            XCTAssertTrue(response.response.contains("ocean"), "Expected response to contain 'ocean'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testMemoryChatSession() throws {
        let expectation = self.expectation(description: "Waiting for memory chat session test")
        
        Task {
            let session = try await FreeToken.shared.getMemoryChatSession()
            
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Japan"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
            }, toolUseHandler: nil)
            
            await session.unload()
            XCTAssertTrue(response.content.contains("Tokyo"), "Expected response to contain 'Tokyo'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testChatSessionToolCalling() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")
        
        Task {
            // name and definition can be empty for this test
            // definition is OpenAI JSON tool spec
            let getWeatherToolCall = FreeToken.ToolDefinition(name: "get_weather", definition: """
                    { "name": "get_weather",
                      "description": "Get the current weather for a given location",
                      "parameters": {
                        "type": "object",
                        "properties": {
                          "location": {
                            "type": "string",
                            "description": "The city and state, e.g. San Francisco, CA"
                          }
                        },
                        "required": ["location"]
                      }
                    }
                """)
            await FreeToken.shared.registerToolDefinitions([getWeatherToolCall])
            
            let session = try await FreeToken.shared.getChatSession()
            
            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the weather in Rome Italy?"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }) { toolCalls in
                var results = ""
                for toolCall in toolCalls {
                    if toolCall.name == "get_weather" {
                        // Simulate getting weather data
                        let location = toolCall.arguments["location"]
                        
                        if let location = location {
                            results += "The current weather in \(location) is sunny with a high of 25°C.\n"
                        } else {
                            results += "Location not provided.\n"
                        }
                    }
                }
                return results
            }
            
            await session.unload()
            await FreeToken.shared.removeAllToolDefinitions()
            XCTAssertTrue(response.content.contains("25°C"), "Expected response to contain '25°C'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testMemoryChatToolCalling() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")
        
        Task {
            // name and definition can be empty for this test
            // definition is OpenAI JSON tool spec
            let getWeatherToolCall = FreeToken.ToolDefinition(name: "get_weather", definition: """
                    { "name": "get_weather",
                      "description": "Get the current weather for a given location",
                      "parameters": {
                        "type": "object",
                        "properties": {
                          "location": {
                            "type": "string",
                            "description": "The city and state, e.g. San Francisco, CA"
                          }
                        },
                        "required": ["location"]
                      }
                    }
                """)
            await FreeToken.shared.registerToolDefinitions([getWeatherToolCall])
            
            let session = try await FreeToken.shared.getMemoryChatSession()
            
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the weather in Rome Italy?"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }) { toolCalls in
                var results = ""
                for toolCall in toolCalls {
                    if toolCall.name == "get_weather" {
                        // Simulate getting weather data
                        let location = toolCall.arguments["location"]
                        
                        if let location = location {
                            results += "The current weather in \(location) is sunny with a high of 25°C.\n"
                        } else {
                            results += "Location not provided.\n"
                        }
                    }
                }
                return results
            }
            
            await session.unload()
            await FreeToken.shared.removeAllToolDefinitions()
            XCTAssertTrue(response.content.contains("25°C"), "Expected response to contain '25°C'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testMultiMessageConversation() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")
        
        Task {
            let session = try await FreeToken.shared.getChatSession()
            
            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Italy"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }, toolUseHandler: nil)
            
            
            XCTAssertTrue(response.content.contains("Rome"), "Expected response to contain 'Rome'")
            
            _ = try await session.addMessage(message: .init(role: .user, content: "Now what is the capital of Germany?"))
            
            let response2 = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }, toolUseHandler: nil)
            
            XCTAssertTrue(response2.content.contains("Berlin"), "Expected response to contain 'Berlin'")
            
            await session.unload()
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }

}
