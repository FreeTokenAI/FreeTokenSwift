//
//  EmbeddingManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 2/3/25.
//

import Foundation
import llama
import Hub

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
            let modelPath: URL // Where the model is stored in the app cache directory
            let modelConfig: Codings.EmbeddingModelResponse
        }
        
        let modelStateActor = ModelStateActor()
        
        var config: Config? = nil
        var deviceAICapable: Bool? = nil
        var managerState: ManagerState = .unknown
        var embeddingModelName: String {
            get {
                return config?.modelName ?? "Unknown"
            }
        }
        
        func config(modelConfig: Codings.EmbeddingModelResponse, deviceAICapable: Bool) {
            let modelPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FreeToken/EmbeddingModels/\(modelConfig.name)")
            
            self.config = Config(modelName: modelConfig.name, modelPath: modelPath, modelConfig: modelConfig)
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
            let config = self.config!
            
            // If the model path doesn't exist, create it
            if !FileManager.default.fileExists(atPath: config.modelPath.path) {
                do {
                    try FileManager.default.createDirectory(at: config.modelPath, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    FreeToken.shared.logger("🔴 Error creating embedding model directory: \(error.localizedDescription)", .error)
                    return
                }
            }
            
            let repo = Hub.Repo(id: config.modelConfig.modelTypes.llamaCpp.repo)
            let filesToDownload = [config.modelConfig.modelTypes.llamaCpp.modelFileName!] // Should always exist
            let downloadPath: URL
            
            // Check if the model is already downloaded
            if filesToDownload.allSatisfy({ FileManager.default.fileExists(atPath: config.modelPath.appendingPathComponent($0).path) }) {
                FreeToken.shared.logger("✅ Embedding model files already exist, skipping download.", .info)
                await modelStateActor.setModelState(.ready)
                progressCompleted?(100.0)
                successCallback?()
                return
            }
            
            do {
                await modelStateActor.setModelState(.downloading)
                downloadPath = try await Hub.snapshot(from: repo) { progress in
                    progressCompleted?(progress.fractionCompleted * 100.0)
                }
            } catch {
                FreeToken.shared.logger("🔴 Error downloading embedding model files: \(error.localizedDescription)", .error)
                await modelStateActor.setModelState(.downloadInvalid)
                failureCallback?(FreeTokenError.aiModelDownload)
                return
            }
            
            // Move the downloaded files to the model path
            let fileManager = FileManager.default
            
            for fileName in filesToDownload {
                let sourceURL = downloadPath.appendingPathComponent(fileName)
                let destinationURL = config.modelPath.appendingPathComponent(fileName)
                
                do {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                } catch {
                    FreeToken.shared.logger("🔴 Error moving downloaded model file \(fileName): \(error.localizedDescription)", .error)
                    failureCallback?(FreeTokenError.modelDownload)
                    return
                }
            }
            
            await modelStateActor.setModelState(.ready)
            successCallback?()
        }
        
        func resetCache() async throws {
            let fileManager = FileManager.default
            
            do {
                let modelStore = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FreeToken/EmbeddingModels")
                try fileManager.removeItem(at: modelStore)
                
                await modelStateActor.setModelState(.unknown)
            } catch {
                FreeToken.shared.logger("Error removing embedding model directory: \(error.localizedDescription)", .error)
                throw FreeTokenError.couldNotRemoveModel
            }
        }

        
        private func initializeModel() async throws -> LlamaEmbeddingClient? {
            if await modelStateActor.modelState != .ready {
                return nil
            }
            
            if managerState != .configured {
                return nil
            }
            
            let config = self.config!
            
            let pathToGGUF = config.modelPath.appendingPathComponent(config.modelConfig.modelTypes.llamaCpp.modelFileName!).path
            
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
