//
//  DownloadTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 9/2/25.
//

import XCTest
import FreeToken

final class DownloadTests: XCTestCase {
 
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        _ = try FreeToken.shared.configure(
            appToken: "test-token",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await FreeToken.shared.registerDeviceSession(scope: "swift-tests") {
                semaphore.signal()
            } error: { error in
                XCTFail("Failed to register device session: \(error.message)")
                semaphore.signal()
            }
        }
     
        semaphore.wait()
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        print("--------------------------------- RESETTING -----------------------------------------")
        Task {
            try await FreeToken.shared.resetDevice()
        }
    }
    
    func testModelCodeDownloadedState() throws {
        let expectation = XCTestExpectation(description: "Model code download state")
        
        Task {
            let state = try await FreeToken.shared.getAIModelDownloadState(modelCode: "gemma3n_e2b_it")
            
            XCTAssertEqual(state, .downloaded, "Model code should be in downloaded state")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
    
    func testUndownloadedModelCodeDownloadedState() throws {
        let expectation = XCTestExpectation(description: "Model code download state")
        
        Task {
            let state = try await FreeToken.shared.getAIModelDownloadState(modelCode: "llama3.2_3b_instruct")
            
            XCTAssertEqual(state, .notDownloaded, "Model code should be in not downloaded state")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
}
