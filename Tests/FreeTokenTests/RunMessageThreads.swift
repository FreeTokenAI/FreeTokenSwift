//
//  RunMessageThreads.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//

import XCTest
@testable import FreeToken

class RunMessageThreads: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUp() {
        super.setUp()
        freeToken = FreeToken.shared
        _ = freeToken.configure(appToken: "test-token", baseURL: URL(string: "http://127.0.0.1:3000/api/v1/")!)
        // Register device for tests
        let expectation = XCTestExpectation(description: "Device registration")
        let freeToken = self.freeToken!
        freeToken.registerDeviceSession(scope: "test", success: {
            Task {
                await freeToken.downloadAIModel { downloaded in
                    expectation.fulfill()
                } error: { error in
                    XCTFail("Failed to download AI model: \(error.localizedDescription)")
                }
            }
        }, error: { _ in
            XCTFail("Device registration failed")
        })
        wait(for: [expectation], timeout: 120.0)
    }
    
    func testRunMessageThread() {
        let expectation = XCTestExpectation(description: "Run message thread")
        
        let freeToken = self.freeToken!
        freeToken.createMessageThread(
            pinnedContext: "Test context",
            agentScope: "test-agent",
            success: { thread in
                freeToken.addMessageToThread(messageThreadID: thread.id, role: "user", content: "Hey there!") { message in
                    freeToken.runMessageThread(id: thread.id) { messageThreadRun in
                        expectation.fulfill()
                    } error: { error in
                        XCTFail("Failed to run message thread: \(error.localizedDescription)")
                    }
                } error: { error in
                    XCTFail("Failed to add message: \(error.localizedDescription)")
                }
            },
            error: { error in
                XCTFail("Failed to create thread: \(error.localizedDescription)")
            }
        )
        
        wait(for: [expectation], timeout: 120.0) // This is so high because AI on simulator runs on CPU and is sllooooowww.
    }
}
