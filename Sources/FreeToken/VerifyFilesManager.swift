//
//  VerifyFilesManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/2/25.
//

import Foundation
import CryptoKit

extension FreeToken {
    
    class VerifyFilesManager {
        let filesToVerify: [FileToVerify]
        
        actor ResultsCollector {
            var results: [[String: Bool]] = []
            
            func addResult(file: String, result: Bool) {
                results.append([file: result])
            }
        }
        
        class FileVerify {
            private let file: URL
            private let bufferSize = 1024 * 1024 // Size of chunks to read
            private let expectedMD5: String
            private var context = Insecure.MD5()
            
            init(file: URL, expectedMD5: String) {
                self.file = file
                self.expectedMD5 = expectedMD5
            }
            
            public func verify() -> Bool {
                if readStream() != true {
                    return false
                }
                
                let md5Hash = context.finalize()
                let md5String = md5Hash.map { String(format: "%02hhx", $0) }.joined()
                
                return md5String.lowercased() == expectedMD5.lowercased()
            }
            
            private func readStream() -> Bool {
                guard let stream = InputStream(url: file) else {
                    FreeToken.shared.logger("Unable to open file stream for verification: \(file.path)", .error)
                    return false
                }
                
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                    if bytesRead < 0 {
                        FreeToken.shared.logger("Error reading file stream,", .error)
                        return false
                    }
                    context.update(data: Data(buffer[..<bytesRead]))
                }
                
                return true
            }
        }
        
        struct FileToVerify {
            let name: String
            let url: URL
            let md5: String
        }
        
        init(verifyFiles: [Codings.FileVerify], baseFileURL: URL) {
            self.filesToVerify = verifyFiles.map { FileToVerify(name: $0.file, url: baseFileURL.appendingPathComponent($0.file), md5: $0.md5) }
        }
        
        init(downloadFiles: [Codings.DownloadableFile], baseFileURL: URL) {
            self.filesToVerify = downloadFiles.map { file in
                let downloadURL = URL(string: file.file)!
                return FileToVerify(name: downloadURL.lastPathComponent, url: baseFileURL.appending(path: downloadURL.lastPathComponent), md5: file.md5)
            }
        }
        
        init(toVerify: [FileToVerify]) {
            self.filesToVerify = toVerify
        }   
        
        func verify() async -> Bool {
            let collector = ResultsCollector()
        
            await withTaskGroup(of: Void.self) { group in
                for file in filesToVerify {
                    group.addTask {
                        let fileVerify = FileVerify(file: file.url, expectedMD5: file.md5)
                        let verified = fileVerify.verify()
                        await collector.addResult(file: file.name, result: verified)
                    }
                }
                await group.waitForAll()
            }
            
            let results = await collector.results
            return results.allSatisfy { dict in
                dict.values.first ?? false
            }
        }
        
    }
    
}
