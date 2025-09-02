//
//  ModelDownloadManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 8/19/25.
//
import Foundation
import Hub

extension FreeToken {
    final class ModelDownloadManager: @unchecked Sendable {
        
        enum ModelType: Equatable {
            case llama
            case mlx
        }
        
        static func llama(modelRepo: String, modelFileName: String, mmprojFileName: String? = nil) -> ModelDownloadManager {
            ModelDownloadManager(modelType: .llama, modelRepo: modelRepo, modelFileName: modelFileName, mmprojFileName: mmprojFileName)
        }
        
        static func mlx(modelRepo: String) -> ModelDownloadManager {
            ModelDownloadManager(modelType: .mlx, modelRepo: modelRepo, modelFileName: nil, mmprojFileName: nil)
        }
        
        let modelType: ModelType
        let downloadManager = FreeToken.DownloadManager.shared
        let modelRepo: String
        let modelFileName: String?
        let mmprojFileName: String?
        
        internal required init(
            modelType: ModelType,
            modelRepo: String,
            modelFileName: String?,
            mmprojFileName: String?
        ) {
            self.modelType = modelType
            self.modelRepo = modelRepo // Huggingface Repo name like "username/repo_name"
            self.modelFileName = modelFileName // llama.cpp model gguf file
            self.mmprojFileName = mmprojFileName // llama.cpp vision mmproj sidecar model
        }
        
        func downloadState() async -> FreeToken.SessionState? {
            return await ensureSessionAndGetState()
        }

        /// Returns the current session state if a session already exists, without creating one.
        /// This is used by lightweight verification paths that must not implicitly create sessions.
        func existingSessionState() -> FreeToken.SessionState? {
            return downloadManager.getSessionState(modelRepo)
        }

        /// Ensures a `DownloadSession` exists for this model and returns its validated state.
        ///
        /// If a session already exists, it revalidates on-disk files (hash verifying when possible)
        /// using the download manager's existing logic and returns the updated state.
        ///
        /// If no session exists (e.g. it expired or app relaunched without persistence), this will:
        /// 1. Fetch the model file list & expected hashes (network metadata only, no file downloads started).
        /// 2. Create a new session pointing at the same destination directory the real download would use.
        ///    The `DownloadManager.createSession` call will immediately run `checkExistingFiles(for:)` and
        ///    mark any already-present files as completed; if all are present+valid the session state becomes `.completed`.
        /// 3. Return the resulting session state ( `.completed`, `.pending`, etc.).
        ///
        /// No network transfers (file downloads) are initiated here; callers can then decide whether to
        /// start downloads based on the returned state.
        ///
        /// - Returns: The current validated `SessionState` for this model, or `nil` if setup failed.
        @discardableResult
        func ensureSessionAndGetState() async -> FreeToken.SessionState? {
            // Fast path: session already exists – re-run existing file validation for freshness.
            if let existing = downloadManager.getSession(id: modelRepo) {
                downloadManager.checkExistingFiles(for: existing)
                return existing.state
            }

            // Derive destination directory exactly as download() would so paths align.
            let sanitizedRepo = modelRepo.replacingOccurrences(of: "/", with: "_")
#if os(iOS)
            let destinationRelative = "FreeToken/Models/" + sanitizedRepo
            let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(destinationRelative).path
#else
            let destinationRelative = ".FreeToken/Models/" + sanitizedRepo
            let destination = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(destinationRelative).path
#endif

            // Obtain model file metadata (URLs + optional SHA256 hashes). If this fails we cannot
            // build a session, so we log and return nil rather than throwing to keep signature simple.
            let modelFiles: [(URL, String?)]
            do {
                modelFiles = try await fetchModelFiles()
            } catch {
                FreeToken.shared.logger("❌ Failed to fetch model file metadata for ensureSession: \(error.localizedDescription)", .error)
                return nil
            }

            do {
                _ = try downloadManager.sessionBuilder()
                    .sessionID(modelRepo)
                    // Persist relative path to avoid sandbox UUID issues
                    .destinationDirectory(destinationRelative)
                    .addDownloads(modelFiles)
                    // No progress or completion handlers needed for a passive state check
                    .build() // createSession internally validates existing files & sets state
            } catch {
                FreeToken.shared.logger("❌ Failed to build session during ensureSession: \(error.localizedDescription)", .error)
                return nil
            }

            return downloadManager.getSession(id: modelRepo)?.state
        }
        
        func download(
            progress: Optional<@Sendable (Double) -> Void>,
            success: @escaping @Sendable (_ destination: String) async -> Void,
            failure: @escaping @Sendable (FreeTokenError) async -> Void
        ) async throws {
#if os(iOS) || os(tvOS) || os(watchOS)
            // Replace slashes in repo (e.g. "owner/repo") so we don't create nested directories unintentionally.
            let sanitizedRepo = modelRepo.replacingOccurrences(of: "/", with: "_")
            // Set the destination directory Application Support/FreeToken/Models/<sanitizedRepo>
            let destinationRelative = "FreeToken/Models/" + sanitizedRepo
            let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(destinationRelative).path
#else
            let sanitizedRepo = modelRepo.replacingOccurrences(of: "/", with: "_")
            let destinationRelative = ".FreeToken/Models/" + sanitizedRepo
            let destination = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(destinationRelative).path
#endif
            
            
            if let existingSession = downloadManager.getSession(id: modelRepo) {
                // Always revalidate on disk files (covers app restart & any external deletions)
                downloadManager.checkExistingFiles(for: existingSession)

                let allCompleted = existingSession.getDownloads().allSatisfy { $0.state == .completed }

                if allCompleted {
                    FreeToken.shared.logger("⏭️ Model session already completed for repo \(modelRepo) – skipping re-download", .info)
                    // Emit a final progress if handler supplied
                    progress?(1.0)
                    await success(destination)
                    return
                }

                if existingSession.isDownloading {
                    FreeToken.shared.logger("🔄 Reattaching to in‑progress model download session \(modelRepo)", .info)
                    existingSession.reattachHandlers(progress: progress) { result in
                        switch result {
                        case .success:
                            FreeToken.shared.logger("✅ All model files downloaded successfully", .info)
                            Task { await success(destination) }
                        case .failure(let error):
                            FreeToken.shared.logger("❌ Failed to download model files: \(error.localizedDescription)", .error)
                            Task { await failure(FreeTokenError.aiModelNotDownloaded) }
                        }
                    }
                    return
                }

                // Partially completed (some pending/failed). Start only remaining downloads without rebuilding session
                FreeToken.shared.logger("🚀 Resuming partial model session (will download missing files) for repo \(modelRepo)", .info)
                existingSession.reattachHandlers(progress: progress) { result in
                    switch result {
                    case .success:
                        FreeToken.shared.logger("✅ All model files downloaded successfully (resume)", .info)
                        Task { await success(destination) }
                    case .failure(let error):
                        FreeToken.shared.logger("❌ Failed to download model files (resume): \(error.localizedDescription)", .error)
                        Task { await failure(FreeTokenError.aiModelNotDownloaded) }
                    }
                }
                _ = downloadManager.startSessionDownloads(sessionID: modelRepo)
                return
            }
            
            let modelFiles = try await fetchModelFiles()
            
            _ = try downloadManager.sessionBuilder()
                .sessionID(modelRepo)
                .destinationDirectory(destinationRelative)
                .addDownloads(modelFiles)
                .progress(progress)
                .completion({ result in
                    switch result {
                    case .success:
                        FreeToken.shared.logger("✅ All model files downloaded successfully", .info)
                        Task { await success(destination) }
                    case .failure(let error):
                        FreeToken.shared.logger("❌ Failed to download model files: \(error.localizedDescription)", .error)
                        Task { await failure(FreeTokenError.aiModelNotDownloaded) }
                    }
                })
                .build()
            
            if downloadManager.startSessionDownloads(sessionID: modelRepo) {
                return
            } else {
                // Failed to start download session
                FreeToken.shared.logger("❌ Failed to start download session for model \(modelRepo)", .error)
                throw FreeTokenError.aiModelDownload
            }
        }
        
        private func fetchModelFiles() async throws -> [(URL, String?)] {
            switch modelType {
            case .llama:
                return try await fetchLlamaModelFiles()
            case .mlx:
                return try await fetchMLXModelFiles()
            }
        }
        
        private func fetchLlamaModelFiles() async throws -> [(URL, String?)] {
            // Create a dispatch group to synchronize async operation
            var modelFiles: [(URL, String?)] = []
                
            do {
                let repo = Hub.Repo(id: modelRepo)
                let hubApi = HubApi(downloadBase: FileManager.default.temporaryDirectory)
                
                // Build list of files to fetch metadata for
                var filesToFetch: [String] = []
                
                // Add main model file if specified
                if let modelFileName = modelFileName {
                    filesToFetch.append(modelFileName)
                }
                
                // Add vision model file if specified
                if let mmprojFileName = mmprojFileName {
                    filesToFetch.append(mmprojFileName)
                }
                
                // If no specific files specified, fetch all GGUF files
                if filesToFetch.isEmpty {
                    let allFiles = try await hubApi.getFilenames(from: repo, matching: ["*.gguf"])
                    filesToFetch = allFiles
                }
                
                // Get metadata for each file
                let metadata = try await hubApi.getFileMetadata(from: repo, matching: filesToFetch)
                
                // Build result array with URLs and SHA256 hashes
                for file in metadata {
                    // Construct the download URL
                    let fileURL = URL(string: file.location) ?? URL(string: "https://huggingface.co/\(modelRepo)/resolve/main/\(file.location)")!
                    
                    // Extract SHA256 from etag if it's a valid hash (LFS files have SHA256 as etag)
                    let sha256Pattern = "^[0-9a-f]{64}$"
                    let sha256: String?
                    
                    if let etag = file.etag,
                       let regex = try? NSRegularExpression(pattern: sha256Pattern),
                       regex.firstMatch(in: etag, options: [], range: NSRange(location: 0, length: etag.count)) != nil {
                        // etag is a valid SHA256 hash
                        sha256 = etag
                    } else {
                        // For non-LFS files or files without SHA256 etag, use empty string
                        // The download manager will skip verification for these
                        sha256 = nil
                        FreeToken.shared.logger("⚠️ No SHA256 hash available for \(file.location)", .warning)
                    }
                    
                    modelFiles.append((fileURL, sha256))
                    
                    let hashInfo = sha256 == nil ? " (no hash)" : " (SHA256: \(sha256!.prefix(8))...)"
                    FreeToken.shared.logger("📄 Found Llama model file: \(file.location)\(hashInfo)", .debug)
                }
                
            } catch {
                FreeToken.shared.logger("❌ Failed to fetch Llama model files: \(error.localizedDescription)", .error)
                throw FreeTokenError.failedToFetchModelFiles(error.localizedDescription)
            }
            
            return modelFiles
        }
        
        private func fetchMLXModelFiles() async throws -> [(URL, String?)] {
            // Create a dispatch group to synchronize async operation
            var modelFiles: [(URL, String?)] = []
            
            do {
                let repo = Hub.Repo(id: modelRepo)
                let hubApi = HubApi(downloadBase: FileManager.default.temporaryDirectory)
                                
                // Get all files in the repository
                let relevantFiles = try await hubApi.getFilenames(from: repo)
                                
                // Get metadata for all relevant files
                let metadata = try await hubApi.getFileMetadata(from: repo, matching: relevantFiles)
                
                // Build result array with URLs and SHA256 hashes
                for file in metadata {
                    // Construct the download URL
                    let fileURL = URL(string: file.location) ?? URL(string: "https://huggingface.co/\(modelRepo)/resolve/main/\(file.location)")!
                    
                    // Extract SHA256 from etag if it's a valid hash (LFS files have SHA256 as etag)
                    let sha256Pattern = "^[0-9a-f]{64}$"
                    let sha256: String?
                    
                    if let etag = file.etag,
                       let regex = try? NSRegularExpression(pattern: sha256Pattern),
                       regex.firstMatch(in: etag, options: [], range: NSRange(location: 0, length: etag.count)) != nil {
                        // etag is a valid SHA256 hash
                        sha256 = etag
                    } else {
                        // For non-LFS files or files without SHA256 etag, use empty string
                        // The download manager will skip verification for these
                        sha256 = nil
                        
                        // Only log warning for large files without hashes
                        if let size = file.size, size > 1024 * 1024 { // > 1MB
                            FreeToken.shared.logger("⚠️ No SHA256 hash available for large file: \(file.location) (\(size) bytes)", .warning)
                        }
                    }
                    
                    modelFiles.append((fileURL, sha256))
                    
                    let sizeInfo = file.size != nil ? " (\(file.size!) bytes)" : ""
                    let hashInfo = sha256 == nil ? "" : " [SHA256: \(sha256!.prefix(8))...]"
                    FreeToken.shared.logger("📄 Found MLX model file: \(file.location)\(sizeInfo)\(hashInfo)", .debug)
                }
                
                FreeToken.shared.logger("✅ Found \(modelFiles.count) MLX model files in \(modelRepo)", .info)
                
            } catch {
                FreeToken.shared.logger("❌ Failed to fetch MLX model files: \(error.localizedDescription)", .error)
            }
                        
            return modelFiles
        }
        
    }
}
