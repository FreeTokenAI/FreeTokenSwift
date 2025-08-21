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
            
            
            await FreeToken.shared.runMessageThread(
              id: "msg-thr-id",
              runLocation: .localRun,
              success: { resultMessage in
                // Successfully ran the message thread on the local device
                print("Message thread result: \(resultMessage.content)")
            }, error: { error in
                // If the run location is not supported on the device,
                // or there are not enough resources, an error will be returned
            }, toolCallback: { toolCalls in
              // Iterate through the tool calls and concatenate the responses
              return toolCalls.map { toolCall in
                // Handle each tool call based on its name
                let response: String
                if toolCall.name == "get_current_weather" {
                  // Execute the tool call with the parameters provided by the AI model
                    let location = toolCall.arguments["location"] ?? "Unknown location"
                    let format = toolCall.arguments["format"] ?? "celsius"
                  
                  // Call your weather API or perform the action to get the weather
                  response = "The current weather in \(location) is 20 degrees \(format)."
                } else {
                    response = ""
                }
                
                return response
              }.joined(separator: "\n")
            })
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
    
    func testJsonToolCall() throws {
        let expectation = self.expectation(description: "Waiting for JSON tool call via message thread")
        let toolDefinition = self.getCurrentWeatherToolDefinition
        
        Task {
            // Register tool
            await FreeToken.shared.addToolDefinition(name: "get_current_weather", definitionJSON: toolDefinition)
            
            // Create a message that should trigger tool call
            // The AI model will use JSON syntax if jsonToolCalls is true in the model response
            let message = FreeToken.Message(role: .user, content: "What is the weather in New York, NY in celsius?")
            
            await FreeToken.shared.createMessageThread { messageThread in
                await FreeToken.shared.addMessageToThread(id: messageThread.id, message: message) { message in
                    await FreeToken.shared.runMessageThread(id: messageThread.id) { resultMessage in
                        expectation.fulfill()
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.message)")
                        expectation.fulfill()
                    } toolCallback: { toolCalls in
                        // Verify we got the expected tool call
                        XCTAssertTrue(toolCalls.contains(where: { $0.name == "get_current_weather" }), "Tool call for 'get_current_weather' not found")
                        if let weatherCall = toolCalls.first(where: { $0.name == "get_current_weather" }) {
                            // Note: The exact arguments depend on what the AI model generates
                            print("Tool call arguments: \(weatherCall.arguments)")
                        }
                        expectation.fulfill()
                        return "Weather data: 20°C, sunny"
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
    
    // Removed testMixedToolCallSyntax since ParseToolCalls is now internal
    // The JSON tool call syntax is tested through the actual message thread flow above
    
}
