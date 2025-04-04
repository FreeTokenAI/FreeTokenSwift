//
//  DocumentManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 2/3/25.
//

// TODO:
// * Chunk Documents
// * Generate Embedding
// * Encrypt
// What it doesn't do: POST data, lookup data

import Foundation

extension FreeToken {
    class DocumentManager {
        var encrypt: Optional<(_ toEncrypt: String) -> String> = nil
        var decrypt: Optional<(_ toDecrypt: String) -> String> = nil
        let chunker: DocumentChunker
        
        internal init(chunkSize: Int, overlapSize: Int, encrypt: Optional<(_ toEncrypt: String) -> String> = nil, decrypt: Optional<(_ toDecrypt: String) -> String> = nil) {
            self.encrypt = encrypt
            self.decrypt = decrypt
            self.chunker = DocumentChunker(chunkSize: chunkSize, overlapSize: overlapSize)
        }
        
        internal func processDocument(content: String, metadata: String? = nil) throws -> Document {
            let document = Document(documentManager: self)
            document.content = content
            document.metadata = metadata
            
            _ = try document.chunkDocument().encrypt()
            
            return document
        }
        
        internal func processEncryptedDocument(encryptedContent: String, encryptedMetdata: String? = nil) -> Document {
            let document = Document(documentManager: self)
            document.encryptedContent = encryptedContent
            document.encryptedMetadata = encryptedMetdata
            
            _ = document.decrypt()
            
            return document
        }
                
        internal func processEncryptedDocumentChunk(encryptedContent: String, documentMetadata: String? = nil) -> DocumentChunk {
            let documentChunk = DocumentChunk(documentManager: self)
            documentChunk.encryptedContent = encryptedContent
            documentChunk.documentMetadata = documentMetadata
            
            _ = documentChunk.decrypt()
            
            return documentChunk
        }
        
        class Document {
            let documentManager: DocumentManager

            var chunks: [DocumentChunk] = []
            
            var encryptedMetadata: String? = nil // JSON-ify the metadata and encrypt
            var encryptedContent: String? = nil
            var content: String? = nil
            var metadata: String? = nil
                        
            init(documentManager: DocumentManager) {
                self.documentManager = documentManager
            }
            
            func chunkDocument() throws -> Document {
                if let content = content {
                    let contentChunks = documentManager.chunker.chunkDocument(document: content)
                    let embeddor = EmbeddingManager.shared
                    var documentChunks: [DocumentChunk] = []
                    
                    for contentChunk in contentChunks {
                        let documentChunk = DocumentChunk(documentManager: documentManager, content: contentChunk)
                        _ = documentChunk.embed(embeddor: embeddor).encrypt()
                        documentChunks.append(documentChunk)
                    }
                    self.chunks = documentChunks
                }
                return self
            }
            
            func encrypt() -> Document {
                
                if let encrypt = documentManager.encrypt {
                    if let content = content {
                        self.encryptedContent = encrypt(content)
                    }
                    
                    if let metadata = metadata {
                        self.encryptedMetadata = encrypt(metadata)
                    }
                }

                
                return self
            }
            
            func decrypt() -> Document {
                if let decrypt = documentManager.decrypt {
                    if let encryptedContent = encryptedContent {
                        self.content = decrypt(encryptedContent)
                    }
                    
                    if let encryptedMetadata = encryptedMetadata {
                        self.metadata = decrypt(encryptedMetadata)
                    }
                }

                return self
            }
            
            func sendableContent() -> String? {
                if encryptedContent == nil {
                    return content
                } else {
                    return encryptedContent
                }
            }
            
            func sendableMetadata() -> String? {
                if encryptedMetadata == nil {
                    return metadata
                } else {
                    return encryptedMetadata
                }
            }
            
        }
        
        class DocumentChunk: @unchecked Sendable {
            let documentManager: DocumentManager
            let embeddingModelName: String

            var chunkContent: String? = nil
            var documentMetadata: String? = nil
            var encryptedContent: String? = nil
            var encryptedMetadata: String? = nil
            var embedding: [Float]? = nil
                        
            init(documentManager: DocumentManager, content: Optional<String> = nil) {
                self.documentManager = documentManager
                self.embeddingModelName = EmbeddingManager.shared.embeddingModelName
                self.chunkContent = content
            }
            
            func embed(embeddor: EmbeddingManager) -> DocumentChunk {
                if let chunkContent = chunkContent {
                    self.embedding = try? embeddor.generate(text: chunkContent)
                }

                return self
            }
            
            func encrypt() -> DocumentChunk {
                if let encrypt = documentManager.encrypt {
                    if let content = chunkContent {
                        self.encryptedContent = encrypt(content)
                    }
                    
                    if let metadata = documentMetadata {
                        self.encryptedMetadata = encrypt(metadata)
                    }
                }
                
                return self
            }
            
            func decrypt() -> DocumentChunk {
                if let decrypt = documentManager.decrypt {
                    if let encryptedContent = encryptedContent {
                        self.chunkContent = decrypt(encryptedContent)
                    }
                    
                    if let documentMetadata = documentMetadata {
                        self.documentMetadata = decrypt(documentMetadata)
                    }
                }
                
                return self
            }
            
        }
        
        // Example usage
        //        let text = """
        //        Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
        //        """
        //
        //        let chunker = DocumentChunker(document: text)
        //        let chunks = chunker.chunkDocument()
        //        print(chunks)
        class DocumentChunker {
            let chunkSize: Int
            let overlapSize: Int
            
            init(chunkSize: Int, overlapSize: Int) {
                self.chunkSize = chunkSize
                self.overlapSize = overlapSize
            }
            
            func chunkDocument(document: String) -> [String] {
                let words = document.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                guard !words.isEmpty else { return [] }
                
                var chunks: [String] = []
                var startIndex = 0
                
                while startIndex <= words.count {
                    
                    var chunkBegin = max(startIndex - (overlapSize / 2), 0)
                    let chunkEnd = min(startIndex + chunkSize + (overlapSize / 2), words.count)
                    
                    // if the last chunk is too small, move the beginning of the chunk back                    
                    if chunkEnd == words.count, (chunkEnd - chunkBegin) < chunkSize {
                        chunkBegin = max(words.count - chunkSize, 0)
                    }
                    
                    let chunk = words[chunkBegin..<chunkEnd].joined(separator: " ")
                    chunks.append(chunk)
                    
                    startIndex = startIndex + chunkSize
                }
                
                return chunks
            }
        }
        
    }
}
