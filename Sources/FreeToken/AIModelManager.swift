//
//  AIModelDownloadManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/30/24.
//
import Foundation
import Metal
import LocalLLMClient
import LocalLLMClientLlama
import LocalLLMClientMLX
import LocalLLMClientUtility

extension FreeToken {
    class AIModelManager: @unchecked Sendable {
        let modelCode: String
        let modelConfig: AIModelConfiguration
        let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
        let availableModelTypes: Codings.AvailableModelTypesResponse
        let taskQueue: AITaskQueue = AITaskQueue()
        
        private let clientConfig: Codings.ShowClientConfig
        private let clientVersion: String
        private var generationTask: Task<Void, Error>? = nil
        
        internal let stateManager: AIStateManager = AIStateManager()
        
        enum DownloadState: Equatable {
            case notDownloaded
            case downloading
            case downloaded
            case failed(error: String)
        }
        
        enum LoadedState: Equatable {
            case unloaded
            case loading
            case loaded
        }
        
        enum ModelType: Equatable {
            case llamaCpp
            case mlx
        }
        
        actor AITaskQueue {
            private var isRunning = false

            func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
                while isRunning {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    FreeToken.shared.logger("⏰ Waiting for AI task queue to be free...", .info)
                }
                
                isRunning = true
                FreeToken.shared.logger("🚀 Executing AI task in queue...", .info)
                defer { isRunning = false }
                let result = try await operation()
                
                return result
            }
        }
        
        actor AIResults {
            var startTime: DispatchTime? = nil
            var endTime: DispatchTime? = nil
            var tokenCount: Int = 0
            var responseContent: String = ""
            var maxTokenCount: Int? = nil
            
            func setStartTime(_ time: DispatchTime) {
                self.startTime = time
            }
            
            func setEndTime(_ time: DispatchTime) {
                self.endTime = time
            }
            
            func addToTokenCount(_ count: Int) {
                self.tokenCount += count
            }
            
            func appendResponseContent(_ content: String) {
                self.responseContent += content
            }
            
            func setMaxTokenCount(_ count: Int) {
                self.maxTokenCount = count
            }
        }
        
        actor AIStateManager {
            var model:  LLMSession.DownloadModel? = nil
            var cachedSession: SessionCache? = nil
            var downloadState: DownloadState = .notDownloaded
            var loadedState: LoadedState = .unloaded
            var modelInitOptions: ModelInitOptions? = nil
            
            
            struct SessionCache {
                let runIdentifier: String
                var session: LLMSession
            }
            
            struct ModelInitOptions {
                let huggingFaceID: String
                let modelFileName: String?
                let mmproj: String?
                let configuration: AIModelConfiguration
                let modelType: ModelType
                let memoryRequirement: Int
            }
            
            func setDownloadState(_ state: DownloadState) {
                self.downloadState = state
            }
            
            func setLoadedState(_ loadedState: LoadedState) {
                self.loadedState = loadedState
            }
            
            func getLoadedState() -> LoadedState {
                return loadedState
            }
            
            func getDownloadState() -> DownloadState {
                return downloadState
            }
            
            func downloadModel(progress: @escaping @Sendable (_ progress: Double) async -> Void) async throws {
                guard let model = self.model else {
                    throw FreeTokenError.aiModelNotLoaded
                }
                setDownloadState(.downloading)
                do {
                    FreeToken.shared.logger("☁️ Starting AI model file downloads...", .info)
                    _ = try await model.downloadModel(onProgress: progress)
                    setDownloadState(.downloaded)
                } catch {
                    setDownloadState(.failed(error: error.localizedDescription))
                    throw FreeTokenError.aiModelNotDownloaded
                }
            }
            
            func initializeEngine(
                huggingFaceID: String,
                modelFileName: String?,
                mmproj: String? = nil,
                configuration: AIModelConfiguration,
                modelType: ModelType,
                memoryRequirement: Int
            ) async throws {
                self.modelInitOptions = ModelInitOptions(
                    huggingFaceID: huggingFaceID,
                    modelFileName: modelFileName,
                    mmproj: mmproj,
                    configuration: configuration,
                    modelType: modelType,
                    memoryRequirement: memoryRequirement
                )
                
                self.loadedState = .loading
                self.model = try modelFactory(initOptions: self.modelInitOptions!)
                self.loadedState = .loaded
            }
            
            func modelFactory(initOptions: ModelInitOptions) throws -> LLMSession.DownloadModel {
                let model: LLMSession.DownloadModel
                
                if initOptions.modelType == .llamaCpp {
                    model = LLMSession.DownloadModel.llama(id: initOptions.huggingFaceID, model: initOptions.modelFileName!, mmproj: initOptions.mmproj, parameter: .init(
                        context: initOptions.configuration.nCTX,
                        batch: initOptions.configuration.batchSize,
                        temperature: initOptions.configuration.temperature,
                        topK: initOptions.configuration.topK,
                        topP: initOptions.configuration.topP,
                        penaltyLastN: Int(initOptions.configuration.penaltyLastN),
                        penaltyRepeat: initOptions.configuration.penaltyRepeat,
                        options: .init(verbose: true)
                    ))
                } else if initOptions.modelType == .mlx {
                    model = LLMSession.DownloadModel.mlx(id: initOptions.huggingFaceID, parameter: .init(
                        temperature: initOptions.configuration.temperature,
                        topP: initOptions.configuration.topP,
                        repetitionPenalty: initOptions.configuration.penaltyRepeat,
                        options: .init(verbose: true)
                    ))
                } else {
                    throw FreeTokenError.unsupportedModelType(message: " Unknown type: \(initOptions.modelType)")
                }
                
                return model
            }
            
            func generateResponse(
                for messages: [Message],
                runIdentifier: String,
                aiRunConfig: AIRunConfig? = nil,
                noContextCache: Bool = false
            ) async throws -> AsyncThrowingStream<String, any Error> {
                guard model != nil else {
                    throw FreeTokenError.aiModelNotLoaded
                }
                guard let promptMessage = messages.last else {
                    throw FreeTokenError.noMessagesToSend
                }
                
                let model: LLMSession.DownloadModel
                let session: LLMSession
                var isNewSession: Bool = false
                var shouldOverrideCache: Bool = false
                
                if noContextCache {
                    isNewSession = true
                    shouldOverrideCache = false
                    
                    // Do we have enough RAM to allocate another session?
                    if self.shouldEvacuateCache(memoryRequirement: modelInitOptions!.memoryRequirement) == true {
                        self.cachedSession = nil  // Evacuate cache
                        shouldOverrideCache = true
                        isNewSession = true
                    }
                } else if cachedSession == nil || cachedSession?.runIdentifier != runIdentifier {
                    cachedSession = nil // Evacuate the cache right now.
                    isNewSession = true
                    shouldOverrideCache = true
                }
                
                if let aiRunConfig = aiRunConfig, (aiRunConfig.temperature != nil || aiRunConfig.topK != nil || aiRunConfig.topP != nil || aiRunConfig.contentWindowSize != nil), let modelInitOptions = modelInitOptions {
                    isNewSession = true
                    // AI Run Config provided, initialize a model for the cache.
                    let config = modelInitOptions.configuration
                    let nCTX = aiRunConfig.contentWindowSize ?? config.nCTX
                    let temperature = aiRunConfig.temperature ?? config.temperature
                    let topK = aiRunConfig.topK ?? config.topK
                    let topP = aiRunConfig.topP ?? config.topP

                    let modelInitOptions = ModelInitOptions(huggingFaceID: modelInitOptions.huggingFaceID,
                                                            modelFileName: modelInitOptions.modelFileName,
                                                            mmproj: modelInitOptions.mmproj,
                                                            configuration: AIModelConfiguration(
                                                                from: Codings.AiModelConfigResponse.ModelOptions(
                                                                    topK: topK,
                                                                    topP: topP,
                                                                    contextWindowSize: nCTX,
                                                                    temperature: temperature,
                                                                    maxTokenCount: config.maxTokenCount,
                                                                    penaltyLastN: config.penaltyLastN,
                                                                    penaltyRepeat: config.penaltyRepeat,
                                                                    penaltyFrequency: config.penaltyFrequency,
                                                                    penaltyPresence: config.penaltyPresence,
                                                                    batchSize: config.batchSize
                                                                )),
                                                            modelType: modelInitOptions.modelType,
                                                            memoryRequirement: modelInitOptions.memoryRequirement)
                    
                    FreeToken.shared.logger("⚙️ AI Run Config provided - initializing new model and session instances based on the parameters", .info)
                    
                    model = try modelFactory(initOptions: modelInitOptions)
                } else {
                    // Use preloaded model
                    model = self.model!
                }
                
                // Process Messages
                let messages = messages.dropLast() // Feed this in via the prompt
                let llmMessages = messages.map { message in
                    switch message.role {
                    case .assistant:
                        return LLMInput.Message.assistant(message.content)
                    case .user:
                        return LLMInput.Message.user(message.content)
                    case .system:
                        return LLMInput.Message.system(message.content)
                    case .tool:
                        return LLMInput.Message(role: .custom("tool"), content: message.content)
                    }
                }
                
                if isNewSession {
                    session = LLMSession(model: model, messages: llmMessages)
                } else {
                    session = cachedSession!.session
                    
                    // Append new messages to the existing session
                    var index = 0
                    for message in llmMessages {
                        if session.messages.endIndex <= index {
                            session.messages.append(message)
                        }
                        index += 1
                    }
                }
                
                if shouldOverrideCache {
                    self.cachedSession = SessionCache(runIdentifier: runIdentifier, session: session)
                }
                
                return session.streamResponse(to: promptMessage.content)
            }
            
            func unloadModel() {
                self.model = nil
                self.cachedSession = nil
                self.downloadState = .notDownloaded
                self.loadedState = .unloaded
            }
            
            func shouldEvacuateCache(memoryRequirement: Int) -> Bool {
                if self.cachedSession == nil {
                    return false
                }
                
                var vRAM: Int = 0
                
                // Test if memory requirement exceeds available memory
                #if os(macOS)
                    // CHeck available memory on macOS
                    if let device = MTLCreateSystemDefaultDevice() {
                        vRAM = Int(device.recommendedMaxWorkingSetSize)
                    }
                #else
                    // Check if this is iOS
                    vRAM = os_proc_available_memory()
                #endif
                
                let availableMemory = vRAM - memoryRequirement
                FreeToken.shared.logger("🖥️ Available memory: \(availableMemory) bytes, Memory requirement: \(memoryRequirement) bytes", .info)
                
                if availableMemory < 0 {
                    FreeToken.shared.logger("⚠️ Memory requirement exceeds available memory - Evacuating AI cache", .warning)
                    return true
                } else {
                    FreeToken.shared.logger("✅ Memory requirement is within available memory limits", .info)
                    return false
                }
            }
        }
        
        init(modelConfig: Codings.AiModelResponse, clientVersion: String) {
            self.modelCode = modelConfig.code
            #if os(macOS)
            self.clientConfig = modelConfig.clientsConfig["macOS"]!
            #else
            self.clientConfig = modelConfig.clientsConfig["iOS"]!
            #endif
            self.clientVersion = clientVersion
            self.modelConfig = AIModelConfiguration(from: modelConfig.config.defaultSettings)
            self.promptTemplateConfig = modelConfig.config.promptTemplateConfig
            self.availableModelTypes = modelConfig.modelTypes
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
        
        func downloadIfNeeded(progress progressCallback: Optional<@Sendable (_ percentage: Double) -> Void> = nil) async throws -> Bool {
            let profiler = Profiler()
            if await self.stateManager.getDownloadState() == .downloading {
                FreeToken.shared.logger("Currently downloading AI model - Cannot download more than once", .info)
                return false
            }
            
            switch verifyClientVersionSupported() {
            case .success(_):
                FreeToken.shared.logger("Client version is compatible with AI model", .info)
            case .failure(_):
                FreeToken.shared.logger("Client version is NOT compatible with AI model", .error)
                profiler.end(eventType: .downloadModel, eventTypeID: modelCode, isSuccess: false, errorMessage: "Client version is not compatible with AI model.")
                return false
            }
            
            FreeToken.shared.logger("🔄 Loading AI model...", .info)
            let loadResult = await loadModel()
            
            switch loadResult {
            case .success(_):
                FreeToken.shared.logger("🧠 AI engine initialized successfully", .info)
                
                do {
                    _ = try await stateManager.downloadModel { progress in
                        FreeToken.shared.logger("☁️ Download progress: \(progress * 100.0)%", .info)
                        progressCallback?(progress)
                    }
                    return true
                } catch {
                    FreeToken.shared.logger("🔴 Error downloading AI model: \(error.localizedDescription)", .error)
                    _ = await self.stateManager.setDownloadState(.failed(error: error.localizedDescription))
                    return false
                }
                
            case .failure(let error):
                FreeToken.shared.logger("🔴 Failed to load AI model: \(error.localizedDescription)", .error)
                profiler.end(eventType: .downloadModel, eventTypeID: modelCode, isSuccess: false, errorMessage: error.localizedDescription)
                return false
            }
        }
        
        func loadModel() async -> Result<Bool, FreeTokenError> {
            if await self.stateManager.getLoadedState() == .loaded {
                return .success(true)
            }
            
            if await self.stateManager.getLoadedState() == .loading {
                return .failure(FreeTokenError.modelAlreadyLoading)
            }
            
            await self.stateManager.setLoadedState(.loading)
                        
            do {
                let huggingfaceModel: Codings.HuggingfaceModelResponse
                let modelType: ModelType
                
                (huggingfaceModel, modelType) = modelSelection()
                
                _ = try await self.stateManager.initializeEngine(
                    huggingFaceID: huggingfaceModel.repo,
                    modelFileName: huggingfaceModel.modelFileName,
                    mmproj: huggingfaceModel.mmproj,
                    configuration: modelConfig,
                    modelType: modelType,
                    memoryRequirement: clientConfig.requiredMemoryBytes
                )
                return .success(true)
            } catch {
                FreeToken.shared.logger("Error loading model: \(error.localizedDescription)", .error)
                return .failure(FreeTokenError.failedToLoadModel)
            }
        }
        
        func modelSelection() -> (Codings.HuggingfaceModelResponse, ModelType) {
            if let mlx = availableModelTypes.mlx {
                return (mlx, .mlx)
            } else {
                return (availableModelTypes.llamaCpp, .llamaCpp)
            }
        }
        
        func unloadModel() async {
            await self.stateManager.unloadModel()
        }
        
        func stopGeneration() async {
            FreeToken.shared.logger("Stopping AI generation...", .info)
            generationTask?.cancel()
        }
        
        func sendMessagesToAI(messages: [Message], runIdentifier: String, noContextCache: Bool = false, aiRunConfig: AIRunConfig? = nil, tokenStream: Optional<@Sendable (_ tokens: String) -> Void> = nil) async throws -> (response: String, usage: TokenUsage?) {
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            guard messages.count > 0 else {
                throw FreeTokenError.noMessagesToSend
            }
            
            let preparedMessages: [Message] = try MessagePrep(messages: messages, promptTemplateConfig: promptTemplateConfig).prepareMessages()
            
            let aiResults = AIResults()
            
            if let maxTokens = aiRunConfig?.maxGenerationTokens {
                await aiResults.setMaxTokenCount(maxTokens)
            }
            
            // Generate response using the AIStateManager
            let task = Task {
                _ = try await taskQueue.enqueue {
                    do {
                        let maxTokenCount = await aiResults.maxTokenCount
                        for try await value in try await self.stateManager.generateResponse(for: preparedMessages, runIdentifier: runIdentifier, aiRunConfig: aiRunConfig, noContextCache: noContextCache) {
                            if Task.isCancelled { break }
                            if await aiResults.startTime == nil {
                                await aiResults.setStartTime(DispatchTime.now())
                            }
                            print(value, terminator: "")
                            await aiResults.appendResponseContent(value)
                            if let streamHandler = tokenStream {
                                streamHandler(value)
                            }
                            await aiResults.addToTokenCount(1)
                            let tokenCount = await aiResults.tokenCount
                            if let maxTokenCount = maxTokenCount, tokenCount >= maxTokenCount {
                                break
                            }
                        }
                        await aiResults.setEndTime(DispatchTime.now())
                        
                    } catch {
                        FreeToken.shared.logger("Error generating response: \(error.localizedDescription)", .error)
                        throw FreeTokenError.aiRunFailed(message: error.localizedDescription)
                    }
                }
            }
            self.generationTask = task
            _ = try await task.value
            self.generationTask = nil
            
            // Calculate duration
            var usage: TokenUsage? = nil
            let startTime = await aiResults.startTime
            let endTime = await aiResults.endTime
            let tokenCount = await aiResults.tokenCount
            
            if let start = startTime, let endTime = endTime {
                let duration = Double(endTime.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                let tokensPerSecond = Float(Double(await aiResults.tokenCount) / (duration / 1000.0))
                usage = TokenUsage(totalTokens: tokenCount, tokensPerSecond: tokensPerSecond)
                FreeToken.shared.logger("🧠 AI response generated \(tokenCount) tokens in \(duration) ms @ \(tokensPerSecond) tokens/s", .info)
            }
            
            let responseContent = await aiResults.responseContent
            
            return (responseContent, usage)
        }
                
        private func verifyClientVersionSupported() -> Result<Bool, FreeTokenError> {
            let versionTest = VersionTester(minVersion: clientConfig.min, maxVersion: clientConfig.max)
            
            if versionTest.isVersionSupported(version: clientVersion) {
                return .success(true)
            } else {
                return .failure(FreeTokenError.unsupportedVersion)
            }
        }
    }
}
