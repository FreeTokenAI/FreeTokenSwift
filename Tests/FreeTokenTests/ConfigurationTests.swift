//
//  ConfigurationTests.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/3/25.
//
import XCTest
@testable import FreeToken

class ConfigurationTests: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUp() {
        super.setUp()
        freeToken = FreeToken.shared
    }
    
    override func tearDown() {
        freeToken = nil
        super.tearDown()
    }
    
    func testConfiguration() {
        let baseURL = URL(string: "https://test.example.com")!
        let modelPath = URL(string: "file://test/model")!
        
        let configured = freeToken.configure(
            appToken: "test-token",
            baseURL: baseURL,
            overrideModelPath: modelPath
        )
        
        XCTAssertNotNil(configured)
        // Add more specific assertions based on internal state
    }
    
    func testPrivacyModeEncryption() {
        let encrypt: (String) -> String = { text in "encrypted-\(text)" }
        let decrypt: (String) -> String = { text in String(text.dropFirst(10)) }
        
        XCTAssertNoThrow(try freeToken.privacyModeEncryption(
            encrypt: encrypt,
            decrypt: decrypt
        ))
    }
}
