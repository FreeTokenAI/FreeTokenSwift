//
//  EncryptionManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/20/25.
//

import Foundation
import CryptoKit

extension FreeToken {
    class EncryptionManager {
        private var encryptionState: EncryptionState = .notEnabled
        private var encryptor: Optional<(_ toEncrypt: String, _ scope: EncryptionScope) throws -> String> = nil
        private var decryptor: Optional<(_ toDecrypt: String, _ scope: EncryptionScope) throws -> String> = nil
        private var userPrivateEncryptionKey: SymmetricKey? = nil
        private var sharedPublicEncryptionKey: SymmetricKey? = nil
        
        enum EncryptionState: Equatable {
            case notEnabled
            case customEncryption
            case builtInEncryption
        }
        
        var isEncryptionEnabled: Bool {
            return encryptionState != .notEnabled
        }
                
        internal func enableCustomEncryption(
            encryptor: @escaping @Sendable (_ toEncrypt: String, _ scope: EncryptionScope) throws -> String,
            decryptor: @escaping @Sendable (_ toDecrypt: String, _ scope: EncryptionScope) throws -> String
        ) {
            self.encryptor = encryptor
            self.decryptor = decryptor
            self.encryptionState = .customEncryption
        }
        
        internal func encrypt(_ string: String, _ scope: EncryptionScope) throws -> String {
            if encryptionState == .builtInEncryption {
                guard let key = userPrivateEncryptionKey else {
                    throw FreeTokenError.encryptionKeyNotSet
                }
                
                guard let data = string.data(using: .utf8) else {
                    throw FreeTokenError.stringToUTF8DataFailed
                }
                        
                // Encrypt using AES-GCM
                let sealedBox = try AES.GCM.seal(data, using: key)
                
                // Combine IV + ciphertext + tag into a single data object
                guard let combined = sealedBox.combined else {
                    throw FreeTokenError.encryptionFailed
                }
                
                return combined.base64EncodedString()
            } else if encryptionState == .customEncryption {
                guard let encryptor = encryptor else {
                    throw FreeTokenError.customEncryptionClosureNotSet
                }
                return try encryptor(string, scope)
            } else {
                // No encryption enabled
                return string
            }
        }
        
        internal func decrypt(_ string: String, _ scope: EncryptionScope) throws -> String {
            if encryptionState == .builtInEncryption {
                guard let key = userPrivateEncryptionKey else {
                    throw FreeTokenError.encryptionKeyNotSet
                }
                
                guard let combinedData = Data(base64Encoded: string) else {
                    throw FreeTokenError.decryptionFailed
                }
                
                let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
                let decryptedData = try AES.GCM.open(sealedBox, using: key)
                
                guard let decryptedString = String(data: decryptedData, encoding: .utf8) else {
                    throw FreeTokenError.decryptionFailed
                }
                
                return decryptedString
            } else if encryptionState == .customEncryption {
                guard let decryptor = decryptor else {
                    throw FreeTokenError.customDecryptionClosureNotSet
                }
                return try decryptor(string, scope)
            } else {
                // No encryption enabled
                return string
            }
        }
        
        internal func reset() {
            encryptor = nil
            decryptor = nil
            encryptionState = .notEnabled
            userPrivateEncryptionKey = nil
            sharedPublicEncryptionKey = nil
        }
        
        internal func setEncryptionKey(_ key: String, scope: EncryptionScope) throws {
            guard let keyData = Data(base64Encoded: key) else {
                FreeToken.shared.logger("🔴 Failed to decode encryption key from base64.", .error)
                throw FreeTokenError.decodingEncryptionKeyFailed
            }
            
            // Create the symmetric key first to ensure it's valid
            let symmetricKey = SymmetricKey(data: keyData)
            
            // Set the key based on scope
            if scope == .sharedPublic {
                self.sharedPublicEncryptionKey = symmetricKey
            } else {
                self.userPrivateEncryptionKey = symmetricKey
            }
            
            // Set the state last, after everything else succeeds
            self.encryptionState = .builtInEncryption
        }
        
        internal func generateEncryptionKey(for scope: EncryptionScope) -> String {
            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            
            self.encryptionState = .builtInEncryption
            
            if scope == .sharedPublic {
                self.sharedPublicEncryptionKey = key
            } else {
                self.userPrivateEncryptionKey = key
            }
            
            return keyData.base64EncodedString()
        }
    }
}
