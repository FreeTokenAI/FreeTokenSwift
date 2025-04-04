//
//  MessageThreadTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//

import XCTest
@testable import FreeToken

class MessageThreadTests: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUp() {
        super.setUp()
        freeToken = FreeToken.shared
        _ = freeToken.configure(appToken: "test-token", baseURL: URL(string: "http://127.0.0.1:3000/api/v1/")!)
        // Register device for tests
        let expectation = XCTestExpectation(description: "Device registration")
        freeToken.registerDeviceSession(scope: "test", success: {
            expectation.fulfill()
        }, error: { _ in
            XCTFail("Device registration failed")
        })
        wait(for: [expectation], timeout: 120.0)
    }
    
    func testCreateMessageThread() {
        let expectation = XCTestExpectation(description: "Create message thread")
        
        freeToken.createMessageThread(
            pinnedContext: "Test context",
            agentScope: "test-agent",
            success: { thread in
                XCTAssertNotNil(thread.id)
                expectation.fulfill()
            },
            error: { error in
                XCTFail("Failed to create thread: \(error.localizedDescription)")
            }
        )
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testGetMessageThread() {
        let createExpectation = XCTestExpectation(description: "Create thread")
        let getExpectation = XCTestExpectation(description: "Get thread")
        
        let freeToken = self.freeToken!
        
        // First create a thread
        freeToken.createMessageThread(success: { createThread in
            createExpectation.fulfill()
            
            // Then get the thread
            freeToken.getMessageThread(id: createThread.id, success: { thread in
                XCTAssertNotNil(thread)
                getExpectation.fulfill()
            }, error: { error in
                XCTFail("Failed to get thread: \(error.localizedDescription)")
            })
        }, error: { _ in
            XCTFail("Failed to create thread")
        })
        
        wait(for: [createExpectation, getExpectation], timeout: 5.0)
    }
}
