//
//  EncryptionTests.swift
//  FreeTokenTests
//
//  Created by Test on 1/28/25.
//

import XCTest
@testable import FreeToken

final class EncryptionTests: XCTestCase {
    var freeToken: FreeToken!
    
    override func setUpWithError() throws {
        freeToken = try FreeToken.shared.configure(appToken: "app_tkn_3b39cb60-22cd-4877-b784-170b75f88a92", baseURL: URL(string: "http://localhost:3000/api/v1/"), sharedPublicEncryptionKey: nil, userPrivateEncryptionKey: nil, logLevel: .debug)
    }
    
    override func tearDown() async throws {
        // Reset encryption state
        try await freeToken.resetDevice()
    }
    
    // MARK: - Built-in Encryption Tests
    
    func testGenerateEncryptionKey() async throws {
        // Test generating key for user private scope
        let privateKey = freeToken.enableEncryption(scope: .userPrivate)
        XCTAssertFalse(privateKey.isEmpty)
        XCTAssertTrue(freeToken.encryptionManager.isEncryptionEnabled)
        
        // Verify key is base64 encoded
        XCTAssertNotNil(Data(base64Encoded: privateKey))
        
        // Test generating key for shared public scope
        let publicKey = freeToken.enableEncryption(scope: .sharedPublic)
        XCTAssertFalse(publicKey.isEmpty)
        XCTAssertNotEqual(privateKey, publicKey)
    }
    
    func testBuiltInEncryptionDecryption() async throws {
        // Enable built-in encryption
        let encryptionScope = FreeToken.EncryptionScope.userPrivate
        
        _ = freeToken.enableEncryption(scope: encryptionScope)
        let testString = "Hello, World! This is a test message for encryption."
        
        // Test encryption
        let encrypted = try freeToken.encryptionManager.encrypt(testString, encryptionScope)
        XCTAssertNotEqual(encrypted, testString)
        XCTAssertFalse(encrypted.isEmpty)
        
        // Test decryption
        let decrypted = try freeToken.encryptionManager.decrypt(encrypted, encryptionScope)
        XCTAssertEqual(decrypted, testString)
    }
    
    func testBuiltInEncryptionWithSetKey() async throws {
        // Generate a key first
        let generatedKey = freeToken.enableEncryption(scope: .userPrivate)
        
        // Reset encryption manager
        freeToken.encryptionManager.reset()
        
        // Set the previously generated key
        try freeToken.encryptionManager.setEncryptionKey(generatedKey, scope: .userPrivate)
        XCTAssertTrue(freeToken.encryptionManager.isEncryptionEnabled)
        
        let testString = "Testing with set encryption key"
        let encryptionScope = FreeToken.EncryptionScope.userPrivate
        
        // Test encryption/decryption with set key
        let encrypted = try freeToken.encryptionManager.encrypt(testString, encryptionScope)
        let decrypted = try freeToken.encryptionManager.decrypt(encrypted, encryptionScope)
        XCTAssertEqual(decrypted, testString)
    }
    
    // MARK: - Custom Encryption Tests
    
    func testCustomEncryptionDecryption() async throws {
        // Simple XOR encryption for testing
        let xorKey: UInt8 = 42
        
        try freeToken.enableCustomEncryption(
            encrypt: { text, scope in
                let encrypted = text.utf8.map { String(format: "%02x", $0 ^ xorKey) }.joined()
                return encrypted
            },
            decrypt: { text, scope in
                var decrypted = ""
                var index = text.startIndex
                while index < text.endIndex {
                    let nextIndex = text.index(index, offsetBy: 2)
                    let hexByte = String(text[index..<nextIndex])
                    if let byte = UInt8(hexByte, radix: 16) {
                        decrypted.append(Character(UnicodeScalar(byte ^ xorKey)))
                    }
                    index = nextIndex
                }
                return decrypted
            }
        )
        
        XCTAssertTrue(freeToken.encryptionManager.isEncryptionEnabled)
        
        let testString = "Custom encryption test message!"
        let encryptionScope = FreeToken.EncryptionScope.userPrivate
        
        // Test encryption
        let encrypted = try freeToken.encryptionManager.encrypt(testString, encryptionScope)
        XCTAssertNotEqual(encrypted, testString)
        
        // Test decryption
        let decrypted = try freeToken.encryptionManager.decrypt(encrypted, encryptionScope)
        XCTAssertEqual(decrypted, testString)
    }
    
    func testCustomEncryptionWithScopes() async throws {
        
        try freeToken.enableCustomEncryption(
            encrypt: { text, scope in
                // Simple reverse string encryption
                return String(text.reversed())
            },
            decrypt: { text, scope in
                // Reverse back
                return String(text.reversed())
            }
        )
        
        let privateMessage = "Private message"
        let publicMessage = "Public message"
        
        // Test with different scopes
        let encryptedPrivate = try freeToken.encryptionManager.encrypt(privateMessage, .userPrivate)
        let encryptedPublic = try freeToken.encryptionManager.encrypt(publicMessage, .sharedPublic)
        
        XCTAssertEqual(encryptedPrivate, String(privateMessage.reversed()))
        XCTAssertEqual(encryptedPublic, String(publicMessage.reversed()))
        
        // Test decryption
        let decryptedPrivate = try freeToken.encryptionManager.decrypt(encryptedPrivate, .userPrivate)
        let decryptedPublic = try freeToken.encryptionManager.decrypt(encryptedPublic, .sharedPublic)
        
        XCTAssertEqual(decryptedPrivate, privateMessage)
        XCTAssertEqual(decryptedPublic, publicMessage)
        
    }
    
    // MARK: - Encryption State Tests
    
    func testEncryptionStateTransitions() async throws {
        // Initial state - no encryption
        XCTAssertFalse(freeToken.encryptionManager.isEncryptionEnabled)
        
        // Enable built-in encryption
        _ = freeToken.enableEncryption(scope: .userPrivate)
        XCTAssertTrue(freeToken.encryptionManager.isEncryptionEnabled)
        
        // Reset and enable custom encryption
        freeToken.encryptionManager.reset()
        XCTAssertFalse(freeToken.encryptionManager.isEncryptionEnabled)
        
        try freeToken.enableCustomEncryption(
            encrypt: { text, _ in return text },
            decrypt: { text, _ in return text }
        )
        XCTAssertTrue(freeToken.encryptionManager.isEncryptionEnabled)
    }
    
    func testNoEncryptionBehavior() async throws {
        // With no encryption enabled, text should pass through unchanged
        let testString = "No encryption test"
        let encryptionScope = FreeToken.EncryptionScope.userPrivate
        
        let encrypted = try freeToken.encryptionManager.encrypt(testString, encryptionScope)
        XCTAssertEqual(encrypted, testString)
        
        let decrypted = try freeToken.encryptionManager.decrypt(testString, encryptionScope)
        XCTAssertEqual(decrypted, testString)
    }
    
    func testInvalidBase64Key() async throws {
        // Test setting an invalid base64 key
        do {
            try freeToken.encryptionManager.setEncryptionKey("not-valid-base64!", scope: .userPrivate)
            XCTFail("Expected setEncryptionKey to throw an error")
        } catch FreeToken.FreeTokenError.decodingEncryptionKeyFailed {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        // Verify encryption is not enabled after failed key set
        XCTAssertFalse(freeToken.encryptionManager.isEncryptionEnabled)
    }
    
    func testCustomEncryptionError() async throws {
        try freeToken.enableCustomEncryption(
            encrypt: { _, _ in
                throw FreeToken.FreeTokenError.encryptionFailed
            },
            decrypt: { _, _ in
                throw FreeToken.FreeTokenError.decryptionFailed
            }
        )
        
        // Test that errors are propagated
        do {
            _ = try freeToken.encryptionManager.encrypt("test", .userPrivate)
            XCTFail("Expected encryption to fail")
        } catch FreeToken.FreeTokenError.encryptionFailed {
            // Expected
        }
        
        do {
            _ = try freeToken.encryptionManager.decrypt("test", .userPrivate)
            XCTFail("Expected decryption to fail")
        } catch FreeToken.FreeTokenError.decryptionFailed {
            // Expected
        }
    }
    
    // MARK: - Integration Tests
    
    func testEncryptionWithEmptyString() async throws {
        _ = freeToken.enableEncryption(scope: .userPrivate)
        
        let emptyString = ""
        let encrypted = try freeToken.encryptionManager.encrypt(emptyString, .userPrivate)
        let decrypted = try freeToken.encryptionManager.decrypt(encrypted, .userPrivate)
        
        XCTAssertEqual(decrypted, emptyString)
    }
    
    func testEncryptionWithSpecialCharacters() async throws {
        _ = freeToken.enableEncryption(scope: .userPrivate)
        
        let specialString = "🎉 Special chars: !@#$%^&*()_+-=[]{}|;':\",./<>?\\n\\t"
        let encrypted = try freeToken.encryptionManager.encrypt(specialString, .userPrivate)
        let decrypted = try freeToken.encryptionManager.decrypt(encrypted, .userPrivate)
        
        XCTAssertEqual(decrypted, specialString)
    }
    
    func testEncryptionWithLargeText() async throws {
        _ = freeToken.enableEncryption(scope: .userPrivate)
        
        // Generate a large text
        let largeText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 1000)
        let encrypted = try freeToken.encryptionManager.encrypt(largeText, .userPrivate)
        let decrypted = try freeToken.encryptionManager.decrypt(encrypted, .userPrivate)
        
        XCTAssertEqual(decrypted, largeText)
        XCTAssertNotEqual(encrypted, largeText)
    }
}
