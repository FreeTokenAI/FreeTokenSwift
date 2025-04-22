//
//  ModelDownloadManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/2/25.
//
import Foundation

extension FreeToken {

    class ModelDownloadManager {
        let modelFiles: [Codings.DownloadableFile]
        let downloadManager: FileDownload
        let modelDownloadPath: URL
        
        init(modelDownloadPath: URL, modelFiles: [Codings.DownloadableFile]) {
            self.modelFiles = modelFiles
            self.downloadManager = FileDownload(baseDownloadPath: modelDownloadPath)
            self.modelDownloadPath = modelDownloadPath
        }
        
        actor ResultsCollector {
            private var results: [Result<URL, Error>] = []
            private var downloadedBytes: Int = 0
            private let totalBytes: Int
            
            init(bytesToDownload: Int) {
                totalBytes = bytesToDownload
            }
            
            func append(_ result: Result<URL, Error>, bytes: Int) {
                downloadedBytes += bytes
                results.append(result)
            }
            
            func getResults() -> [Result<URL, Error>] {
                results
            }
            
            func percentDownloaded() -> Double {
                return Double(downloadedBytes) / Double(totalBytes)
            }
        }
        
        func start(progress: Optional<@Sendable (_ percentage: Double) -> Void> = nil) async -> [Result<URL, Error>] {
            let modelDownloadPath = self.modelDownloadPath.path
            let resultsCollector = ResultsCollector(bytesToDownload: modelFiles.reduce(0) { $0 + $1.sizeBytes })
            let modelFiles = self.modelFiles
            let downloadManager = self.downloadManager
            
            await withTaskGroup(of: Void.self) { group in
                for downloadFile in modelFiles {
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            downloadManager.downloadFile(from: downloadFile.file) {
                                let fileName = URL(string: downloadFile.file)!.lastPathComponent
                                let fileFullPath = URL(fileURLWithPath: "\(modelDownloadPath)/\(fileName)")
                                let fileVerify = VerifyFilesManager.FileVerify(file: fileFullPath, expectedMD5: downloadFile.md5)
                                let verifyResult = fileVerify.verify()
                                
                                return verifyResult
                            } completion: { result in
                                Task {
                                    await resultsCollector.append(result, bytes: downloadFile.sizeBytes)
                                    
                                    if let progressCallback = progress {
                                        progressCallback(await resultsCollector.percentDownloaded())
                                    }
                                    continuation.resume()
                                }
                            }
                        }
                    }
                }
                
                await group.waitForAll()
            }
        
            return await resultsCollector.getResults()
        }
        
        // MARK: - FileDownloadManager
        
        class FileDownload: @unchecked Sendable {
            let baseDownloadPath: URL
            
            init(baseDownloadPath: URL) {
                self.baseDownloadPath = baseDownloadPath
            }
            
            func downloadFile(from urlString: String, verifyFile: @escaping @Sendable () -> Bool, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
                
                guard let url = URL(string: urlString) else {
                    completion(.failure(NSError(domain: "Invalid URL", code: -1, userInfo: nil)))
                    return
                }
                
                let fileManager = FileManager.default
                let finalPath = URL(fileURLWithPath: "\(self.baseDownloadPath.path)/\(url.lastPathComponent)")
                let fileExists = fileManager.fileExists(atPath: finalPath.path)
                
                if fileExists, verifyFile() {
                    // Verify file exists & passes verify, complete without downloading
                    completion(.success(url))
                    return
                }
                
                
                let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }
                    
                    guard let tempURL = tempURL else {
                        completion(.failure(NSError(domain: "File not downloaded", code: -1, userInfo: nil)))
                        return
                    }
                    
                    do {
                        FreeToken.shared.logger("File \(url.lastPathComponent) downloaded successfully", .info)
                        
                        let fileManager = FileManager.default
                        let fileExists = fileManager.fileExists(atPath: finalPath.path)
                        
                        // Move downloaded file to the desired location
                        if fileExists {
                            // Final file already exists, delete the file and move the temp file in place
                            do {
                                try fileManager.removeItem(at: finalPath)
                            } catch {
                                completion(.failure(error))
                                return
                            }
                        }
                        
                        try fileManager.moveItem(at: tempURL, to: finalPath)
                        completion(.success(finalPath))
                    } catch {
                        FreeToken.shared.logger("Could not move downloaded file to final location: \(error.localizedDescription)", .error)
                        completion(.failure(error))
                    }
                }
                
                task.resume()
            }
        }

    }
    
}
