//
//  ModelDecompressionManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/2/25.
//

import Foundation
import Gzip

extension FreeToken {
    class ModelDecompressionManager {
        static let failedToWriteError = Codings.ErrorResponse(error: "failedToWrite", message: "Failed to write decompressed file.", code: 6000)
        static let failedToLoadError = Codings.ErrorResponse(error: "failedToLoad", message: "Failed to load compressed file.", code: 6001)
        static let failedToRemoveError = Codings.ErrorResponse(error: "failedToRemove", message: "Failed to remove compressed file.", code: 6002)
        static let failedToDecompressError = Codings.ErrorResponse(error: "failedToDecompress", message: "Failed to decompress file.", code: 6003)
        
        let modelDownloadPath: URL
        
        init(modelDownloadPath: URL) {
            self.modelDownloadPath = modelDownloadPath
        }
        
        func decompressFiles() throws {
            let fileManager = FileManager.default
            let enumerator = fileManager.enumerator(at: modelDownloadPath, includingPropertiesForKeys: nil)
            
            while let filePath = enumerator?.nextObject() as? URL {
                // Check if the file is gzipped
                if filePath.pathExtension == "gz" {
                    try decompessFile(filePath: filePath)
                }
            }
        }
        
        func decompessFile(filePath: URL) throws {
            let compressedModelData: Data
            let uncompressedModelData: Data
            let fileManager = FileManager.default

            do {
                compressedModelData = try Data(contentsOf: filePath)
            } catch {
                print("[FreeToken] Error loading compressed file: \(Self.failedToLoadError.message ?? error.localizedDescription)")
                throw Self.failedToLoadError
            }
            
            do {
                uncompressedModelData = try compressedModelData.gunzipped()
            } catch {
                print("[FreeToken] Error decompressing file: \(Self.failedToDecompressError.message ?? error.localizedDescription)")
                throw Self.failedToDecompressError
            }
            
            do {
                // if the file exists, remove it
                if fileManager.fileExists(atPath: filePath.deletingPathExtension().path) {
                    try fileManager.removeItem(at: filePath.deletingPathExtension())
                }
                try uncompressedModelData.write(to: filePath.deletingPathExtension(), options: .atomic)
            } catch {
                print("[FreeToken] Error writing decompressed file: \(Self.failedToWriteError.message ?? error.localizedDescription)")
                throw Self.failedToWriteError
            }
            
            // Remove the gzipped file
            do {
                try FileManager.default.removeItem(at: filePath)
            } catch {
                print("[FreeToken] Error removing gzipped file: \(Self.failedToRemoveError.message ?? error.localizedDescription)")
                throw Self.failedToRemoveError
            }
        }

    }
}
