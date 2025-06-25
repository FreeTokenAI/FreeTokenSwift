//
//  DocumentManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 2/3/25.
//
import Foundation

extension FreeToken {
    internal class DocumentManager {
        let chunker: DocumentChunker
        
        internal init(chunkSize: Int, overlapSize: Int) {
            self.chunker = DocumentChunker(chunkSize: chunkSize, overlapSize: overlapSize)
        }
        
        internal func processDocument(content: String, metadata: String? = nil) throws -> Document {
            let document = Document(content: content, metadata: metadata, documentManager: self)
    
            return document
        }
        
        class Document {
            let documentManager: DocumentManager

            var chunks: [DocumentChunk] = []
            
            let content: String
            let metadata: String?
                        
            init(content: String, metadata: String?, documentManager: DocumentManager) {
                self.documentManager = documentManager
                self.content = content
                self.metadata = metadata
            }
            
            func chunkDocument() throws -> Document {
                let contentChunks = documentManager.chunker.chunkDocument(document: content)
                let embeddor = EmbeddingManager.shared
                var documentChunks: [DocumentChunk] = []
                
                for contentChunk in contentChunks {
                    let documentChunk = DocumentChunk(documentManager: documentManager, content: contentChunk)
                    try documentChunk.embed(embeddor: embeddor)
                    documentChunks.append(documentChunk)
                }
                self.chunks = documentChunks
                return self
            }
        }
        
        class DocumentChunk: @unchecked Sendable {
            let documentManager: DocumentManager
            let embeddingModelName: String

            let chunkContent: String
            var documentMetadata: String? = nil
            var embedding: [Float]? = nil
                        
            init(documentManager: DocumentManager, content: String) {
                self.documentManager = documentManager
                self.embeddingModelName = EmbeddingManager.shared.embeddingModelName
                self.chunkContent = content
            }
            
            func embed(embeddor: EmbeddingManager) throws -> Void {
                self.embedding = try embeddor.generate(text: chunkContent)
            }
            
        }
        
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
