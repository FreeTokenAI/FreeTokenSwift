//
//  DeviceManagementTests 2.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//


//
//  DeviceManagementTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//

import XCTest
@testable import FreeToken

class ResetTests: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUp() {
        super.setUp()
        self.freeToken = FreeToken.shared
        
        _ = freeToken.configure(appToken: "test-token", baseURL: URL(string: "http://127.0.0.1:3000/api/v1/")!)
        
        let semaphore = DispatchSemaphore(value: 0)
        let freeToken = self.freeToken!
        freeToken.registerDeviceSession(scope: "test-scope", success: {
            Task {
                await freeToken.downloadAIModel { isDownloaded in
                    semaphore.signal()
                } error: { error in
                    XCTFail("AI Model download failed: \(error.localizedDescription)")
                    semaphore.signal()
                }
            }
        }, error: { error in
            XCTFail("Device registration failed: \(error.localizedDescription)")
            semaphore.signal()
        })
        
        semaphore.wait()
    }
    
    override func tearDown() {
        try? freeToken.resetDevice()
        freeToken = nil
        super.tearDown()
    }
    
    @objc func test1_testResetDevice() async throws {
        try freeToken.resetDevice()
        
        XCTAssertNil(freeToken.deviceDetails)
        XCTAssertNil(freeToken.deviceSessionToken)
        XCTAssertNil(freeToken.aiModelManager)
        XCTAssertNil(freeToken.deviceMode)
        XCTAssertNil(freeToken.encrypt)
        XCTAssertNil(freeToken.decrypt)
    }
    
    @objc func test2_testResetAIModelCache() async throws {
        let freeToken = self.freeToken!
        let fileManager = FileManager.default
        let cachePath = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = URL(fileURLWithPath: "\(cachePath.path)/FreeToken/AIModels/\(freeToken.deviceDetails!.aiModel.clientsConfig["iOS"]!.modelId)")
        
        try freeToken.resetAIModelCache()
        // Add assertions to verify cache reset
        
        let exists = fileManager.fileExists(atPath: directory.path)
        XCTAssertFalse(exists)
        XCTAssertTrue(freeToken.aiModelManager?.state == .notDownloaded)
    }
    
    @objc func test3_testResetEmbeddingModelCache() throws {
        let fileManager = FileManager.default
        let fileName = freeToken.deviceDetails!.embeddingModel.files.toVerify[0].file
        let modelPath = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FreeToken/EmbeddingModels/\(fileName)")
        
        try freeToken.resetEmbeddingModelCache()
        // Add assertions to verify embedding cache reset
        
        let exists = fileManager.fileExists(atPath: modelPath.path)
        XCTAssertFalse(exists)
    }
}
