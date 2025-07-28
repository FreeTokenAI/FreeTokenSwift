//
//  ToolCallTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 7/20/25.
//

import XCTest
import FreeToken

final class ToolCallTests: XCTestCase {
    let freeToken = FreeToken.shared
    
    let getCurrentWeatherToolDefinition = """
        {
          "type": "function",
          "function": {
            "name": "get_current_weather",
            "description": "Get the current weather for a location",
            "parameters": {
              "type": "object",
              "properties": {
                "location": {
                  "type": "string",
                  "description": "The location to get the weather for, e.g. San Francisco, CA"
                },
                "format": {
                  "type": "string",
                  "description": "The format to return the weather in, e.g. 'celsius' or 'fahrenheit'",
                  "enum": [
                    "celsius",
                    "fahrenheit"
                  ]
                }
              },
              "required": [
                "location",
                "format"
              ]
            }
          }
        }
    """
    
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        _ = try FreeToken.shared.configure(
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
        Task {
            try await FreeToken.shared.resetDevice()
        }
    }
    
    func testToolCall() throws {
        let expectation = self.expectation(description: "Waiting for run message thread with model code")
        let toolDefinition = self.getCurrentWeatherToolDefinition
        
        Task {
            // Register tool
            await FreeToken.shared.addToolDefinition(name: "get_current_weather", definitionJSON: toolDefinition)
            
            // Ask for the tool with a message
            let message = FreeToken.Message(role: .user, content: "What is the weather in San Francisco, CA?")
            
            await FreeToken.shared.createMessageThread { messageThread in
                await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                    await FreeToken.shared.runMessageThread(id: messageThread.id) { resultMessage in
                        expectation.fulfill()
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    } toolCallback: { toolCalls in
                        XCTAssertTrue(toolCalls.contains(where: { $0.name == "get_current_weather" }), "Tool call for 'get_current_weather' not found in response")
                        expectation.fulfill()
                        return ""
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

        wait(for: [expectation], timeout: 30.0) // Allow some time for local generation
    }
    
    
    func testRunMessageThreadToolMasking() throws {
        let expectation = self.expectation(description: "Waiting for run message thread with model code")
        let toolDefinition = self.getCurrentWeatherToolDefinition
        
        Task {
            // Register tool
            await FreeToken.shared.addToolDefinition(name: "get_current_weather", definitionJSON: toolDefinition)
            
            // Ask for the tool with a message
            let message = FreeToken.Message(role: .user, content: "What is the weather in San Francisco, CA?")
            
            await FreeToken.shared.createMessageThread { messageThread in
                await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                    await FreeToken.shared.runMessageThread(id: messageThread.id, toolAccess: [.denyAll]) { resultMessage in
                        expectation.fulfill()
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    } toolCallback: { toolCalls in
                        XCTFail("Tool calls should not be allowed with denyAll access")
                        expectation.fulfill()
                        return ""
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

        wait(for: [expectation], timeout: 30.0) // Allow some time for local generation
    }
    
    func testCreateMessageThreadToolMasking() throws {
        let expectation = self.expectation(description: "Waiting for run message thread with model code")
        let toolDefinition = self.getCurrentWeatherToolDefinition
        
        Task {
            // Register tool
            await FreeToken.shared.addToolDefinition(name: "get_current_weather", definitionJSON: toolDefinition)
            
            // Ask for the tool with a message
            let message = FreeToken.Message(role: .user, content: "What is the weather in San Francisco, CA?")
            
            await FreeToken.shared.createMessageThread(toolAccess: [.denyAll]) { messageThread in
                await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                    await FreeToken.shared.runMessageThread(id: messageThread.id) { resultMessage in
                        expectation.fulfill()
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    } toolCallback: { toolCalls in
                        XCTFail("Tool calls should not be allowed with denyAll access")
                        expectation.fulfill()
                        return ""
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

        wait(for: [expectation], timeout: 30.0) // Allow some time for local generation
    }
    
}
