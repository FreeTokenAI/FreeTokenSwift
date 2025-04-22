//
//  FileReassemblyManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 3/15/25.
//

import Foundation

extension FreeToken {
    
    class FileReassemblyManager {
        
        static let couldNotReassembleFileCreateError = Codings.ErrorResponse(error: "couldNotReassembleFileCreateError", message: "Failed to reassemble file with error: Failed to create output file.", code: 5000)
        static let couldNotOpenFilePartError = Codings.ErrorResponse(error: "couldNotWriteFilePartError", message: "Failed to reassemble file with error: Failed to open file part.", code: 5001)
        static let couldNotRemoveExistingFileError = Codings.ErrorResponse(error: "couldNotRemoveExistingFileError", message: "Failed to reassemble file with error: Failed to remove existing output file.", code: 5002)
        
        /// Reassembles split files in the input directory and writes the combined files to the output directory.
        /// - Parameters:
        ///   - inputDirectory: URL of the directory containing the split files.
        ///   - outputDirectory: URL of the directory where reassembled files will be saved.
        func reassembleFiles(in inputDirectory: URL, to outputDirectory: URL) throws {
            let fileManager = FileManager.default
            
            // Ensure the output directory exists
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
            
            // Retrieve all files in the input directory
            let fileURLs = try fileManager.contentsOfDirectory(at: inputDirectory, includingPropertiesForKeys: nil)
            
            // Filter files matching the *_part_* pattern
            let partFiles = fileURLs.filter { $0.lastPathComponent.contains("part_") }
            
            var groupedFiles: [String: [URL]] = [:]
            
            partFiles.forEach { url in
                let filename = url.deletingPathExtension().lastPathComponent
                
                if groupedFiles[filename] == nil {
                    groupedFiles[filename] = []
                }
                
                groupedFiles[filename]!.append(url)
            }
            
            // Reassemble each group of files
            for (prefix, parts) in groupedFiles {
                // Sort parts based on their suffix (e.g., aa, ab, ac, ...)
                let sortedParts = parts.sorted { $0.lastPathComponent < $1.lastPathComponent }
                
                // Define the output file URL
                let outputFileURL = outputDirectory.appendingPathComponent(prefix)
                
                // If the output file already exists, remove it
                if fileManager.fileExists(atPath: outputFileURL.path) {
                    do {
                        try fileManager.removeItem(at: outputFileURL)
                    } catch {
                        FreeToken.shared.logger("Error removing existing output file: \(error)", .error)
                        throw Self.couldNotRemoveExistingFileError
                    }
                }
                
                // Create the output file
                fileManager.createFile(atPath: outputFileURL.path, contents: nil, attributes: nil)
                
                // Open a file handle for writing to the output file
                guard let outputHandle = try? FileHandle(forWritingTo: outputFileURL) else {
                    FreeToken.shared.logger("Failed to create output file handle for \(outputFileURL.path).", .error)
                    throw Self.couldNotReassembleFileCreateError
                }
                
                // Iterate over each part and append its data to the output file
                for partURL in sortedParts {
                    guard let inputHandle = try? FileHandle(forReadingFrom: partURL) else {
                        FreeToken.shared.logger("Failed to open part file: \(partURL.path)", .error)
                        throw Self.couldNotOpenFilePartError
                    }
                    
                    // Read data in chunks to handle large files efficiently
                    let chunkSize = 1024 * 1024 // 1 MB
                    while autoreleasepool(invoking: {
                        let data = inputHandle.readData(ofLength: chunkSize)
                        if data.isEmpty {
                            return false
                        }
                        outputHandle.write(data)
                        return true
                    }) {}
                    
                    inputHandle.closeFile()
                }
                
                outputHandle.closeFile()
                FreeToken.shared.logger("Reassembled file saved to \(outputFileURL.path)", .info)
                
                // Delete all file parts after reassembly
                for partURL in sortedParts {
                    do {
                        try fileManager.removeItem(at: partURL)
                    } catch {
                        FreeToken.shared.logger("Error removing part file: \(error)", .error)
                    }
                }
            }
        }
    }
}
