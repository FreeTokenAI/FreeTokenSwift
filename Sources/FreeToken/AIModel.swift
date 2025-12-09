//
//  AIModel.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/20/25.
//
import Foundation

extension FreeToken {
    public class AIModel: @unchecked Sendable {
        public let code: String
        public let name: String
        public let cloudOnly: Bool
        public let capabilities: AIModelCapabilities
        public let recommendedPlatforms: AIModelRecommendedPlatforms
        
        internal let trainingCutoffDate: String
        internal let coding: Codings.AiModelResponse
        internal let downloadManager: ModelDownloadManager?
        internal let deviceManager: DeviceManager?
        
        // MARK: Computed Properties
        internal var repo: String? {
            coding.modelTypes?.llamaCpp.repo
        }
        internal var modelFileName: String? {
            coding.modelTypes?.llamaCpp.modelFileName
        }
        internal var serverConfig: Codings.AiModelConfigResponse {
            return coding.config
        }
        internal var aiModelConfiguration: AIModelConfiguration {
            return AIModelConfiguration(from: serverConfig.defaultSettings)
        }
        internal var jsonToolResults: Bool {
            return coding.config.promptTemplateConfig.jsonToolResults
        }
        internal var jsonToolCalls: Bool {
            return coding.jsonToolCalls ?? false
        }
        
        internal init(from: Codings.AiModelResponse) throws {
            self.code = from.code
            self.name = from.name
            self.trainingCutoffDate = from.trainingCutoffDate
            self.cloudOnly = from.cloudOnly
            self.coding = from
            self.capabilities = AIModelCapabilities(from: from.capabilities)
            self.recommendedPlatforms = AIModelRecommendedPlatforms(from: from.recommendedPlatforms)
            
            if !cloudOnly {
                if let llamaCpp = coding.modelTypes?.llamaCpp {
                    self.downloadManager = ModelDownloadManager(modelType: .llama, modelRepo: llamaCpp.repo, modelFileName: llamaCpp.modelFileName, mmprojFileName: llamaCpp.modelFileName)
                } else {
                    self.downloadManager = nil
                }
                
#if os(iOS)
                self.deviceManager = DeviceManager(memoryRequirement: coding.clientsConfig["iOS"]!.requiredMemoryBytes)
#else
                self.deviceManager = DeviceManager(memoryRequirement: coding.clientsConfig["macOS"]!.requiredMemoryBytes)
#endif
            } else {
                downloadManager = nil
                deviceManager = nil
            }
        }
        
        func downloadStatus() async throws -> ModelDownloadState {
            if cloudOnly {
                return .cloudOnly
            }
            
            // Check if model files exist
            let modelFileNames = try modelRepoFileNames()
            
            var fileExistResults: [Bool] = []
            for fileName in modelFileNames {
                let fileURL = getRootModelPath().appendingPathComponent(fileName)
                
                fileExistResults.append(FileManager.default.fileExists(atPath: fileURL.path))
            }
            
            if fileExistResults.allSatisfy({ $0 }) {
                return .downloaded
            }
            
            // Is the model currently downloading?
            let downloadStatus = await downloadManager!.downloadState()
            
            switch downloadStatus {
            case .pending:        /// Not started
                return .downloading
            case .downloading:    /// At least one download is active
                return .downloading
            case .completed:      /// All downloads completed successfully
                return .downloaded
            case .failed:         /// All downloads failed
                return .failed(error: "Model download failed.")
            case .partial:        /// Mix of completed, failed, and/or pending downloads
                return .failed(error: "Some files failed to download.")
            case .none:
                return .failed(error: "Failed to get download session state")
            }
        }
        
        func download(progress: Optional<@Sendable (Double) -> Void> = nil) async throws -> DownloadedState {
            if cloudOnly {
                return .cloudOnly
            }
            
            if deviceManager!.isAICapable == false {
                return .aiNotSupported
            }
            
            if try await downloadStatus() == .downloaded {
                return .downloaded
            }
            
            _ = try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        try await downloadManager!.download(progress: progress) { destination in
                            continuation.resume(returning: destination)
                        } failure: { error in
                            continuation.resume(throwing: error)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            return .downloaded
        }

        func deleteModelFiles() throws {
            let modelFileNames = try modelRepoFileNames()
            for fileName in modelFileNames {
                let fileURL = getRootModelPath().appendingPathComponent(fileName)
                
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        func canInitializeOnDevice() -> Bool {
            if cloudOnly {
                return true
            }
            
            return deviceManager!.isAICapable
        }
        
        func availableMemoryToLoad() -> Bool {
            if cloudOnly {
                return true
            }
            
            return deviceManager!.availableMemoryForRequestedSize()
        }
        
        internal func llamaManager(aiRunConfig: AIRunConfig? = nil) throws -> LlamaManager {
            if cloudOnly {
                throw FreeTokenError.isCloudOnlyModel
            }
            
            let modelPath = getRootModelPath()
                .appendingPathComponent(try modelRepoFileNames().first!)
                .path
            
            let config = aiModelConfiguration
            
            
            
            let options = LlamaInitOptions(
                contextSize: aiRunConfig?.contextWindowSize ?? config.nCTX,
                maxSequences: 1,  // Default to 4 parallel sequences
                maxNewTokens: aiRunConfig?.maxGenerationTokens ?? config.maxTokenCount,
                temperature: aiRunConfig?.temperature ?? config.temperature,
                topK: aiRunConfig?.topK ?? config.topK,
                topP: aiRunConfig?.topP ?? config.topP,
                repeatPenalty: config.penaltyRepeat,
                repeatLastN: Int(config.penaltyLastN),
                frequencyPenalty: config.penaltyFrequency,
                presencePenalty: config.penaltyPresence,
                dryMultiplier: config.dryMultiplier,
                dryBase: config.dryBase,
                dryAllowedLength: Int(config.dryAllowedLength),
                dryPenaltyLastN: Int(config.dryPenaltyLastN),
                xtcProbability: config.xtcProbability,
                xtcThreshold: config.xtcThreshold,
                threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                batchSize: config.batchSize,
                threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
            )
            
            return try LlamaManager(modelPath: modelPath, options: options, repoName: repo!)
        }
        
        internal func getRootModelPath() -> URL {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("FreeToken")
                .appendingPathComponent("Models")
        }
        
        internal func messagePreparer() -> MessagePreparer {
            return MessagePreparer(promptTemplateConfig: coding.config.promptTemplateConfig)
        }
        
        private func modelRepoFileNames() throws -> [String] {
            if let llamaCpp = coding.modelTypes?.llamaCpp {
                return ["\(llamaCpp.repo.replacingOccurrences(of: "/", with: "_"))/\(llamaCpp.modelFileName!)"]
            } else {
                throw FreeTokenError.unsupportedModelType(message: "Only Llmaa.ccp models are supported currently.")
            }
        }
        
        
        
    }
}
