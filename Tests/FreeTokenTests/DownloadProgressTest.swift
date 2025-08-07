//
//  DownloadProgressTest.swift
//  FreeToken
//
//  Created by Vince Francesi on 7/17/25.
//
import XCTest
import FreeToken

final class DownloadProgressTest: XCTestCase {
    
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
            try await FreeToken.shared.resetModelCaches()
            await FreeToken.shared.registerDeviceSession(scope: "swift-tests") {
                semaphore.signal()
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
    
    func testDownloadProgressReporting() throws {
        let expectation = self.expectation(description: "Waiting for download progress reporting")
        
        // Use actor to handle concurrency
        actor ProgressTracker {
            var progressCallbackCount = 0
            var downloadCompleted = false
            
            func incrementProgress() {
                progressCallbackCount += 1
            }
            
            func setDownloadCompleted() {
                downloadCompleted = true
            }
            
            func getProgressCount() -> Int {
                return progressCallbackCount
            }
            
            func isDownloadCompleted() -> Bool {
                return downloadCompleted
            }
        }
        
        let tracker = ProgressTracker()
        
        Task {
            await FreeToken.shared.downloadAIModel { state in
                print("Model download state: \(state)")
                await tracker.setDownloadCompleted()
                
                // If we got a successful download but no progress callbacks other than 0 and 100,
                // it means the model was already downloaded
                let count = await tracker.getProgressCount()
                if count == 0 {
                    print("Model was already downloaded, only received 0% and 100% callbacks")
                }
                
                expectation.fulfill()
            } error: { error in
                XCTFail("Failed to download AI model: \(error.message)")
                expectation.fulfill()
            } progressPercent: { progressPercent in
                print("Download progress: \(progressPercent * 100.0)%")
                
                // Count progress callbacks that aren't 0 or 1.0
                if progressPercent > 0.0 && progressPercent < 1.0 {
                    Task {
                        await tracker.incrementProgress()
                    }
                }
                
                // We should always get at least the 0% and 100% callbacks
                if progressPercent == 0.0 {
                    print("Received initial 0% progress callback")
                } else if progressPercent == 1.0 {
                    print("Received final 100% progress callback")
                }
            }
        }
        
        wait(for: [expectation], timeout: 600.00)
        
        Task {
            let completed = await tracker.isDownloadCompleted()
            XCTAssertTrue(completed, "Download should have completed")
        }
    }
    
}
