//
//  RunLocationTests.swift
//  FreeTokenTests
//
//  Created by Claude on 7/18/25.
//

import XCTest
@testable import FreeToken

class RunLocationTests: XCTestCase {
    
    func testRunLocationEnum() {
        // Test that the enum cases exist
        let automatic = FreeToken.RunLocation.automatic
        let cloudRun = FreeToken.RunLocation.cloudRun
        let localRun = FreeToken.RunLocation.localRun
        
        // Test raw values
        XCTAssertEqual(automatic.rawValue, "automatic")
        XCTAssertEqual(cloudRun.rawValue, "cloudRun")
        XCTAssertEqual(localRun.rawValue, "localRun")
        
        // Test equality
        XCTAssertEqual(automatic, FreeToken.RunLocation.automatic)
        XCTAssertNotEqual(automatic, cloudRun)
        XCTAssertNotEqual(cloudRun, localRun)
    }
    
    func testRunLocationDefaultParameter() async {
        // This test verifies that the default parameter works correctly
        // We can't actually run the message thread without a full setup,
        // but we can verify the method signature accepts both forms
        
        // Test that we can call without specifying runLocation (uses default .automatic)
        let expectation1 = XCTestExpectation(description: "Method accepts default parameter")
        
        await FreeToken.shared.runMessageThread(
            id: "test-thread-id",
            success: { _ in
                // Won't actually be called since device isn't registered
            },
            error: { error in
                // We expect deviceNotRegistered error
                if case .deviceNotRegistered = error {
                    expectation1.fulfill()
                }
            }
        )
        
        await fulfillment(of: [expectation1], timeout: 1.0)
        
        // Test that we can call with explicit runLocation
        let expectation2 = XCTestExpectation(description: "Method accepts explicit runLocation")
        
        await FreeToken.shared.runMessageThread(
            id: "test-thread-id",
            runLocation: .cloudRun,
            success: { _ in
                // Won't actually be called since device isn't registered
            },
            error: { error in
                // We expect deviceNotRegistered error
                if case .deviceNotRegistered = error {
                    expectation2.fulfill()
                }
            }
        )
        
        await fulfillment(of: [expectation2], timeout: 1.0)
    }
}