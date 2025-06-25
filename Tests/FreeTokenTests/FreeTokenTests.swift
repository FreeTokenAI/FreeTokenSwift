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
            await FreeToken.shared.registerDeviceSession(scope: "swift-tests") {
                await FreeToken.shared.downloadAIModel { isLocal in
                    semaphore.signal()
                } error: { error in
                    XCTFail("Failed to download AI model: \(error.message)")
                } progressPercent: { progressPercent in
                    print("Download Progress: \(progressPercent)%")
                }
            } error: { error in
                XCTFail("Failed to register device session: \(error.message)")
            }
        }
        _ = semaphore.wait(timeout: DispatchTime.now() + .seconds(10))
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
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

        wait(for: [expectation], timeout: 10.0)
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

}
