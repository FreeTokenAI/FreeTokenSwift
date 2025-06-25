//
//  EncryptionManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/20/25.
//

extension FreeToken {
    class EncryptionManager {
        var encryptor: Optional<(_ toEncrypt: String) -> String> = nil
        var decryptor: Optional<(_ toDecrypt: String) -> String> = nil
        
        var isEncryptionEnabled: Bool {
            return encryptor != nil && decryptor != nil
        }
        
        internal func enableEncryption(encryptor: @escaping (_ toEncrypt: String) -> String, decryptor: @escaping (_ toDecrypt: String) -> String) {
            self.encryptor = encryptor
            self.decryptor = decryptor
        }
        
        internal func encrypt(_ string: String) -> String {
            guard let encryptor = encryptor else {
                return string
            }
            
            return encryptor(string)
        }
        
        internal func decrypt(_ string: String) -> String {
            guard let decryptor = decryptor else {
                return string
            }
            
            return decryptor(string)
        }
        
        internal func reset() {
            encryptor = nil
            decryptor = nil
        }
    }
}
