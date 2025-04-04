//
//  DeviceManagementTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//

import XCTest
@testable import FreeToken

class DeviceManagementTests: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUp() {
        super.setUp()
        freeToken = FreeToken.shared
        _ = freeToken.configure(appToken: "test-token", baseURL: URL(string: "http://127.0.0.1:3000/api/v1/")!)
    }
    
    override func tearDown() {
        try? freeToken.resetDevice()
        freeToken = nil
        super.tearDown()
    }
    
    func testRegisterDeviceSession() async {
        let expectation = XCTestExpectation(description: "Device registration")
        
        freeToken.registerDeviceSession(scope: "test-scope", success: {
            expectation.fulfill()
        }, error: { error in
            XCTFail("Device registration failed: \(error.localizedDescription)")
        })
        
        await fulfillment(of: [expectation], timeout: 5.0)
    }
    
}
