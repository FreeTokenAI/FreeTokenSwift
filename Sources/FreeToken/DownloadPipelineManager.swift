//
//  DownloadPipelineManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/2/25.
//

import Foundation

extension FreeToken {
    
    class DownloadPipelineManager {
        let baseDirectory: URL
        let downloadFiles: [Codings.DownloadableFile]
        let verifyFiles: [Codings.FileVerify]
        let downloadsVerifyFilesManager: VerifyFilesManager
        let finalVerifyFilesManager: VerifyFilesManager
        var progressTracker: Optional<@Sendable (_ percentage: Double) -> Void> = nil
                
        enum PipelineError: LocalizedError {
            case downloadFailed
            case downloadVerificationFailed
            case reassemblyFailed
            case decompressionFailed
            case finalVerificationFailed

            var errorDescription: String? {
                switch self {
                case .downloadFailed:
                    return "Failed to download one or more required files"
                case .downloadVerificationFailed:
                    return "Downloaded files failed integrity check"
                case .reassemblyFailed:
                    return "Failed to reassemble split downloaded files"
                case .decompressionFailed:
                    return "Failed to decompress files"
                case .finalVerificationFailed:
                    return "Verification of files failed"
                }
            }
        }
        
        init(baseDirectory: URL, downloadFiles: [Codings.DownloadableFile], verifyFiles: [Codings.FileVerify], progressTracker: Optional<@Sendable (_ percentage: Double) -> Void> = nil) {
            self.baseDirectory = baseDirectory
            self.downloadFiles = downloadFiles
            self.verifyFiles = verifyFiles
            self.progressTracker = progressTracker
            
            var finalList: [VerifyFilesManager.FileToVerify] = []
            self.downloadFiles.forEach { file in
                if !file.isFilePart {
                    let downloadURL = URL(fileURLWithPath: file.file)
                    let name = downloadURL.lastPathComponent
                    let fileURL = baseDirectory.appending(path: name)
                    finalList.append(VerifyFilesManager.FileToVerify(name: name, url: fileURL, md5: file.md5))
                }
            }
            
            self.verifyFiles.forEach { file in
                let url = baseDirectory.appending(path: file.file)
                finalList.append(VerifyFilesManager.FileToVerify(name: file.file, url: url, md5: file.md5))
            }
            
            self.finalVerifyFilesManager = VerifyFilesManager(toVerify: finalList)
            self.downloadsVerifyFilesManager = VerifyFilesManager(downloadFiles: downloadFiles, baseFileURL: baseDirectory)
        }
        
        func run() async throws -> Result<Void, PipelineError> {
            print("[FreeToken] Starting download pipeline.")
            
            print("[FreeToken] Verifying existing files on disk.")
            if await finalVerify() {
                progressTracker?(1.0)
                return .success(())
            } else {
                print("[FreeToken] All files are not verified. Starting download pipeline.")
            }
            
            guard await downloadFiles() else {
                return .failure(.downloadFailed)
            }
            
            print("[FreeToken] Downloaded files. Verifying integrity.")
            guard await verifyDownloadedFiles() else {
                return .failure(.downloadVerificationFailed)
            }
            
            print("[FreeToken] Downloaded files verified. Reassembling split files.")
            guard try await reassembleFiles() else {
                return .failure(.reassemblyFailed)
            }
            
            print("[FreeToken] Reassembled files. Decompressing files.")
            guard try await decompressFiles() else {
                return .failure(.decompressionFailed)
            }
            
            print("[FreeToken] Decompressed files. Verifying all final files.")
            guard await finalVerify() else {
                return .failure(.finalVerificationFailed)
            }
            
            return .success(())
        }
        
        // MARK: - Private
        
        private func finalVerify() async -> Bool {
            return await finalVerifyFilesManager.verify()
        }
        
        private func downloadFiles() async -> Bool {
            let downloadManager = ModelDownloadManager(modelDownloadPath: baseDirectory, modelFiles: downloadFiles)
            
            let results = await downloadManager.start(progress: progressTracker)
            
            return results.allSatisfy { result in
                switch result {
                case .success: return true
                case .failure: return false
                }
            }
        }
        
        private func verifyDownloadedFiles() async -> Bool {
            return await downloadsVerifyFilesManager.verify()
        }
        
        private func reassembleFiles() async throws -> Bool {
            let reassemblyManager = FileReassemblyManager()
            
            do {
                try reassemblyManager.reassembleFiles(in: baseDirectory, to: baseDirectory)
                return true
            } catch {
                return false
            }
        }

        private func decompressFiles() async throws -> Bool {
            let modelDecompressManager = ModelDecompressionManager(modelDownloadPath: baseDirectory)
            
            do {
                try modelDecompressManager.decompressFiles()
                return true
            } catch {
                return false
            }
        }
        
    }
    
}
