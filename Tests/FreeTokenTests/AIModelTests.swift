//
//  AIModelTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//

// AIModelTests.swift
import XCTest
@testable import FreeToken

class AIModelTests: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUp() {
        super.setUp()
        freeToken = FreeToken.shared
        _ = freeToken.configure(appToken: "test-token", baseURL: URL(string: "http://127.0.0.1:3000/api/v1/")!)
        // Register device
        let expectation = XCTestExpectation(description: "Device registration")
        freeToken.registerDeviceSession(scope: "test", success: {
            expectation.fulfill()
        }, error: { _ in
            XCTFail("Device registration failed")
        })
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testDownloadAIModel() async {
        let expectation = XCTestExpectation(description: "Download AI model")
        
        await freeToken.downloadAIModel(
            success: { isModelDownloaded in
                XCTAssertTrue(isModelDownloaded)
                expectation.fulfill()
            },
            error: { error in
                XCTFail("Failed to download model: \(error.localizedDescription)")
            },
            progressPercent: { progress in
                XCTAssertGreaterThanOrEqual(progress, 0.0)
                XCTAssertLessThanOrEqual(progress, 1.0)
            }
        )
        
        await fulfillment(of: [expectation], timeout: 30.0)
    }
    
    func testLoadModel() {
        let expectation = XCTestExpectation(description: "Load model")
        let freeToken = self.freeToken!
        
        Task {
            await freeToken.downloadAIModel { downloaded in
                freeToken.loadModel(
                    success: { isLoaded in
                        XCTAssertTrue(isLoaded)
                        expectation.fulfill()
                    },
                    error: { error in
                        XCTFail("Failed to load model: \(error.localizedDescription)")
                    }
                )
            } error: { error in
                XCTFail("Failed to download model: \(error.localizedDescription)")
            }
        }
        
        wait(for: [expectation], timeout: 80.0)
    }
    
    func testLocalChat() throws {
        let freeToken = self.freeToken!
        let expectation = XCTestExpectation(description: "Chat complete")
        Task {
            await freeToken.downloadAIModel { downloaded in
                freeToken.loadModel(
                    success: { isLoaded in
                        let result = try? freeToken.localChat(content: "Hey there!", role: "user")
                        XCTAssertNotNil(result)
                        XCTAssertNotNil(result?["content"])
                        expectation.fulfill()
                    },
                    error: { error in
                        XCTFail("Failed to load model: \(error.localizedDescription)")
                    }
                )
            } error: { error in
                XCTFail("Failed to download model: \(error.localizedDescription)")
            }
        }
        
        wait(for: [expectation], timeout: 80.0)
    }

}
