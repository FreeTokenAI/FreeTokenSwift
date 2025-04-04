//
//  DocumentTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//

import XCTest
@testable import FreeToken

class DocumentTests: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUp() {
        super.setUp()
        freeToken = FreeToken.shared
        _ = freeToken.configure(appToken: "test-token", baseURL: URL(string: "http://127.0.0.1:3000/api/v1/")!)
        // Register device
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
    
    func testCreateDocument() {
        let expectation = XCTestExpectation(description: "Create document")
        
        freeToken.createDocument(
            content: "Test document content",
            metadata: "TITLE: Test Document",
            searchScope: "test-scope",
            success: { document in
                XCTAssertNotNil(document.id)
                expectation.fulfill()
            },
            error: { error in
                XCTFail("Failed to create document: \(error.localizedDescription)")
            }
        )
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testGetDocument() {
        let createExpectation = XCTestExpectation(description: "Create document")
        let getExpectation = XCTestExpectation(description: "Get document")
        
        let freeToken = self.freeToken!
        freeToken.createDocument(
            content: "Test content",
            searchScope: "test-scope",
            success: { documentCreate in
                createExpectation.fulfill()
                let docId = documentCreate.id
                
                freeToken.getDocument(id: docId, success: { document in
                    XCTAssertEqual(document.id, docId)
                    getExpectation.fulfill()
                }, error: { error in
                    XCTFail("Failed to get document: \(error.localizedDescription)")
                })
            },
            error: { _ in
                XCTFail("Failed to create document")
            }
        )
        
        wait(for: [createExpectation, getExpectation], timeout: 5.0)
    }
}
