//
//  EmbeddingManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 2/3/25.
//

import Foundation
import llama

extension FreeToken {
    
    class EmbeddingManager: @unchecked Sendable {
        static let shared = EmbeddingManager()
        
        enum ManagerState: Equatable {
            case unknown
            case configured
        }
        
        actor ModelStateActor {
            var modelState: ModelState = .unknown
            
            func setModelState(_ state: ModelState) {
                modelState = state
            }
        }
        
        enum ModelState: Equatable {
            case unknown
            case downloading
            case downloadInvalid
            case ready
        }
        
        struct Config {
            let modelName: String
            let modelConfig: Codings.EmbeddingModelResponse
            var modelDirectoryPath: String? = nil // Absolute path to FreeToken/Models/{repo}
        }

        let modelStateActor = ModelStateActor()

        var config: Config? = nil
        var deviceAICapable: Bool? = nil
        private var modelDownloadManager: ModelDownloadManager?
        var managerState: ManagerState = .unknown
        var embeddingModelName: String {
            get {
                return config?.modelName ?? "Unknown"
            }
        }
        
        func config(modelConfig: Codings.EmbeddingModelResponse, deviceAICapable: Bool) {
            self.config = Config(modelName: modelConfig.name, modelConfig: modelConfig)
            self.managerState = .configured
            self.deviceAICapable = deviceAICapable
        }
        
        private init() {}

        // MARK: - Downloading
        
        func downloadModel(
            progress progressCompleted: Optional<@Sendable (_ percentage: Double) -> Void> = nil,
            successCallback: Optional<@Sendable () -> Void> = nil,
            failureCallback: Optional<@Sendable (FreeTokenError) -> Void> = nil
        ) async {

            if await modelStateActor.modelState == .ready {
                FreeToken.shared.logger("Embedding model is already downloaded.", .info)
                progressCompleted?(100.0)
                successCallback?()
                return
            }
            
            if await modelStateActor.modelState == .downloading {
                FreeToken.shared.logger("Embedding model is already downloading.", .info)
                failureCallback?(FreeTokenError.modelAlreadyDownloading)
                return
            }
            
            if managerState != .configured {
                FreeToken.shared.logger("Embedding manager is not configured.", .error)
                failureCallback?(FreeTokenError.managerNotConfigured)
                return
            }
            guard var config = self.config else {
                failureCallback?(FreeTokenError.managerNotConfigured)
                return
            }

            let modelRepo = config.modelConfig.modelTypes.llamaCpp.repo
            let modelFileName = config.modelConfig.modelTypes.llamaCpp.modelFileName!

            // Create ModelDownloadManager (same pattern as AI models)
            let downloadManager = ModelDownloadManager.llama(
                modelRepo: modelRepo,
                modelFileName: modelFileName
            )
            self.modelDownloadManager = downloadManager

            // Check if already downloaded via session state
            if let state = await downloadManager.downloadState(), state == .completed {
                let sanitizedRepo = modelRepo.replacingOccurrences(of: "/", with: "_")
                let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("FreeToken/Models/\(sanitizedRepo)").path

                let modelFilePath = URL(fileURLWithPath: modelDir).appendingPathComponent(modelFileName).path
                if FileManager.default.fileExists(atPath: modelFilePath) {
                    FreeToken.shared.logger("✅ Embedding model already downloaded, skipping.", .info)
                    config.modelDirectoryPath = modelDir
                    self.config = config
                    await modelStateActor.setModelState(.ready)
                    progressCompleted?(100.0)
                    successCallback?()
                    return
                }
            }

            // Start download
            await modelStateActor.setModelState(.downloading)

            // Capture config values for use in closures
            let capturedConfig = config

            do {
                try await downloadManager.download(
                    progress: { percent in
                        progressCompleted?(percent * 100.0)
                    },
                    success: { [weak self] destination in
                        guard let self = self else { return }
                        var updatedConfig = capturedConfig
                        updatedConfig.modelDirectoryPath = destination
                        self.config = updatedConfig
                        Task {
                            await self.modelStateActor.setModelState(.ready)
                        }
                        FreeToken.shared.logger("✅ Embedding model downloaded to: \(destination)", .info)
                        successCallback?()
                    },
                    failure: { [weak self] error in
                        FreeToken.shared.logger("🔴 Failed to download embedding model: \(error)", .error)
                        Task {
                            await self?.modelStateActor.setModelState(.downloadInvalid)
                        }
                        failureCallback?(error)
                    }
                )
            } catch {
                FreeToken.shared.logger("🔴 Error starting embedding model download: \(error.localizedDescription)", .error)
                await modelStateActor.setModelState(.downloadInvalid)
                failureCallback?(FreeTokenError.aiModelDownload)
            }
        }
        
        func resetCache() async throws {
            if let config = self.config {
                let modelRepo = config.modelConfig.modelTypes.llamaCpp.repo

                // Remove the download session from DownloadManager
                FreeToken.DownloadManager.shared.removeSession(id: modelRepo)

                // Delete the model files from disk
                if let modelDirectoryPath = config.modelDirectoryPath {
                    try? FileManager.default.removeItem(atPath: modelDirectoryPath)
                    FreeToken.shared.logger("Deleted embedding model files at: \(modelDirectoryPath)", .info)
                }

                // Clear config path reference
                var updatedConfig = config
                updatedConfig.modelDirectoryPath = nil
                self.config = updatedConfig
            }

            self.modelDownloadManager = nil
            await modelStateActor.setModelState(.unknown)
            FreeToken.shared.logger("Embedding model cache cleared", .info)
        }

        
        private func initializeModel() async throws -> LlamaEmbeddingClient? {
            if await modelStateActor.modelState != .ready {
                return nil
            }

            if managerState != .configured {
                return nil
            }

            guard let config = self.config,
                  let modelDirectoryPath = config.modelDirectoryPath else {
                FreeToken.shared.logger("🔴 Embedding model directory path not set", .error)
                return nil
            }

            let pathToGGUF = URL(fileURLWithPath: modelDirectoryPath)
                .appendingPathComponent(config.modelConfig.modelTypes.llamaCpp.modelFileName!)
                .path

            let model = LlamaEmbeddingClient(modelPath: pathToGGUF, contextSize: config.modelConfig.config.contextSize, batchSize: config.modelConfig.config.contextSize, poolingType: config.modelConfig.config.poolingType, deviceAICapable: deviceAICapable!)
            try model.loadModel()
            return model
        }
        
        func generate(text: String) async throws -> [Float] {
            // Check if model is ready
            if await modelStateActor.modelState == .ready {
                let model = try await initializeModel()
                guard let model = model else {
                    throw FreeTokenError.unableToInitializeModel
                }
                
                do {
                    return try model.generateEmbedding(text: text)
                } catch {
                    FreeToken.shared.logger("Error generating embedding: \(error.localizedDescription)", .error)
                    throw FreeTokenError.unableToGenerateEmbedding
                }
            }
            
            // Check if model is in invalid state
            if await modelStateActor.modelState == .downloadInvalid {
                throw FreeTokenError.modelDownload
            }
            
            // If model state is unknown and not configured, throw error
            if managerState != .configured {
                FreeToken.shared.logger("🔴 Generate called on embedding manager, but manager not configured.", .error)
                throw FreeTokenError.managerNotConfigured
            }
            
            // Start download if not already downloading
            FreeToken.shared.logger("⚠️ Generate called on embedding manager, but model not ready. Starting download...", .warning)
            _ = await self.downloadModel()
            
            if await modelStateActor.modelState == .ready {
                return try await self.generate(text: text) // Run again after download
            } else {
                FreeToken.shared.logger("🔴 Generate called on embedding manager, but model still not ready after download.", .error)
                throw FreeTokenError.modelDownload
            }
        }
        
        func generate(requests: [EmbeddingRequest]) async throws -> [EmbeddingResult] {
            if await modelStateActor.modelState == .ready {
                let model = try await initializeModel()
                guard let model = model else {
                    throw FreeTokenError.unableToInitializeModel
                }
                
                var results: [EmbeddingResult] = []
                // Generate multiple embeddings
                for request in requests {
                    let embedding = try model.generateEmbedding(text: request.content)
                    results.append(EmbeddingResult(id: request.id, embedding: embedding))
                }
                
                return results
            }
            
            // Check if model is in invalid state
            if await modelStateActor.modelState == .downloadInvalid {
                throw FreeTokenError.modelDownload
            }
            
            // If model state is unknown and not configured, throw error
            if managerState != .configured {
                FreeToken.shared.logger("🔴 Generate called on embedding manager, but manager not configured.", .error)
                throw FreeTokenError.managerNotConfigured
            }
            
            // Start download if not already downloading
            FreeToken.shared.logger("⚠️ Generate called on embedding manager, but model not ready. Starting download...", .warning)
            _ = await self.downloadModel()
            
            if await modelStateActor.modelState == .ready {
                return try await self.generate(requests: requests) // Run again after download
            } else {
                FreeToken.shared.logger("🔴 Generate called on embedding manager, but model still not ready after download.", .error)
                throw FreeTokenError.modelDownload
            }
        }
        
        struct EmbeddingResult {
            let id: Int
            let embedding: [Float]
        }
        struct EmbeddingRequest {
            let id: Int
            let content: String
        }
    }
}
