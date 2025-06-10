//
//  AIModelDownloadManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/30/24.
//
import Foundation

import Hub
import Tokenizers

extension FreeToken {
    class AIModelManager: @unchecked Sendable {
        let modelBasePath: URL
        let modelCode: String
        let specialTokens: Codings.AiModelConfigResponse.SpecialTokens
        let modelOptions: Codings.AiModelConfigResponse.ModelOptions
        
        private let clientConfig: Codings.ShowClientConfig
        private let clientVersion: String
        private let modelFiles: [Codings.DownloadableFile]
        private let verifyFiles: [Codings.FileVerify]
        internal let stateManager: AIStateManager = AIStateManager()
        private var modelPathOverride: Bool = false
        private var modelSizeBytes: Int = 0
        
        // Errors
        private let unsupportedVersionError = Codings.ErrorResponse(error: "unsupportedVersion", message: "The AI model sent by the server is not supported by this client", code: 2000)
        public let aiModelNotDownloadedError = Codings.ErrorResponse(error: "aiModelNotDownloaded", message: "AI model has not yet been downloded. Try .downloadAIModel() first", code: 2001)
        public let modelAlreadyLoadingError = Codings.ErrorResponse(error: "aiModelAlreadyLoading", message: "Model already loading. Wait until AI Model is loaded and try again", code: 2002)
        public let failedToLoadModelError = Codings.ErrorResponse(error: "failedToLoadModel", message: "Failed to load model", code: 2003)
        static public let aiModelNotLoadedError = Codings.ErrorResponse(error: "aiModelNotLoaded", message: "AI model is not loaded. Try .loadModel() first", code: 2004)
        
        enum ModelState: Equatable {
            case unverified
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
        
        actor AIStateManager {
            @LlamaCppSwiftActor
            var engine: LlamaCppSimpleRun?
            var state: ModelState = .unverified
            var loadedState: LoadedState = .unloaded
            
            func setState(_ state: ModelState) {
                self.state = state
            }
            
            func setLoadedState(_ loadedState: LoadedState) {
                self.loadedState = loadedState
            }
            
            func getState() -> ModelState {
                return state
            }
            
            func getLoadedState() async -> LoadedState {
                if let engine = await getEngine() {
                    if await engine.isModelLoaded() {
                        loadedState = .loaded
                    } else {
                        loadedState = .unloaded
                    }
                } else {
                    loadedState = .unloaded
                }
                
                return loadedState
            }
            
            
            @LlamaCppSwiftActor
            private func getEngine() -> LlamaCppSimpleRun? {
                return engine
            }
            
            @LlamaCppSwiftActor
            func initializeEngine(modelPath: String, configuration: AIModelConfiguration) async {
                self.engine = LlamaCppSimpleRun(modelPath: modelPath, configuration: configuration)
            }
            
            @LlamaCppSwiftActor
            func unloadEngine() async {
                self.engine?.cleanup()
                self.engine = nil
                await self.setLoadedState(.unloaded)
            }
            
            @LlamaCppSwiftActor
            func tokenCount(_ text: String, addBos: Bool = false) async throws -> Int {
                guard let engine = self.engine else {
                    throw AIModelManager.aiModelNotLoadedError
                }
                
                if await getLoadedState() != .loaded {
                    throw AIModelManager.aiModelNotLoadedError
                }
                
                return engine.tokenCount(text, addBos: addBos)
            }
            
            @LlamaCppSwiftActor
            func generate(for prompt: String, maxTokens: Int? = nil, runIdentifier: String) async throws -> AsyncThrowingStream<String, Error> {
                guard let engine = self.engine else {
                    throw AIModelManager.aiModelNotLoadedError
                }
                
                if await getLoadedState() != .loaded {
                    throw AIModelManager.aiModelNotLoadedError
                }
                
                return engine.generate(prompt: prompt, runIdentifier: runIdentifier, maxTokens: maxTokens)
            }
            
            @LlamaCppSwiftActor
            func lastRunStats() async -> LastRunStats? {
                let stats = engine?.lastRunStats
                
                if let stats = stats {
                    return LastRunStats(totalTokens: stats.totalTokens, elapsed: stats.elapsed, tokensPerSecond: stats.tokensPerSecond)
                } else {
                    return nil
                }
            }
            
            @LlamaCppSwiftActor
            func stopGeneration() async {
                guard let engine = self.engine else {
                    return
                }
                
                engine.stopGeneration()
            }
            
            struct LastRunStats {
                let totalTokens: Int
                let elapsed: TimeInterval
                let tokensPerSecond: Double
            }
        }
        
        init(modelConfig: Codings.AiModelResponse, clientVersion: String, overrideModelPath: Optional<URL> = nil) {
            self.modelCode = modelConfig.code
            self.modelFiles = modelConfig.files.toDownload
            self.verifyFiles = modelConfig.files.toVerify
            self.clientConfig = modelConfig.clientsConfig["iOS"]!
            self.clientVersion = clientVersion
            self.modelPathOverride = overrideModelPath != nil
            self.modelSizeBytes = modelConfig.sizeBytes
            self.specialTokens = modelConfig.config.specialTokens
            self.modelOptions = modelConfig.config.defaultSettings
            
            if overrideModelPath == nil {
                // Model should be setup for download
                let fileManager = FileManager.default
                let cachePath = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                self.modelBasePath = URL(fileURLWithPath: "\(cachePath.path)/FreeToken/AIModels/\(clientConfig.modelId)")
                
                if fileManager.fileExists(atPath: self.modelBasePath.path) == false {
                    do {
                        try fileManager.createDirectory(at: self.modelBasePath, withIntermediateDirectories: true)
                        FreeToken.shared.logger("Model cache directory created successfully", .info)
                    } catch {
                        FreeToken.shared.logger("Failed to create model directory.", .error)
                        return
                    }
                }
            } else {
                FreeToken.shared.logger("AI Model path is defined - ignoring all model definitions from cloud", .info)
                self.modelBasePath = overrideModelPath!
                Task {
                    await self.stateManager.setState(.downloaded)
                }
            }
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
        
        func downloadIfNeeded(progress: Optional<@Sendable (_ percentage: Double) -> Void> = nil) async -> Bool {
            let profiler = Profiler()
            
            
            if await self.stateManager.getState() == .downloading {
                FreeToken.shared.logger("Currently downloading AI model - Cannot download more than once", .info)
                return false
            }
            
            if modelPathOverride {
                FreeToken.shared.logger("Model files are baked into the app, no downloading required.", .info)
                return true
            }
            
            switch verifyClientVersionSupported() {
            case .success(_):
                FreeToken.shared.logger("Client version is compatible with AI model", .info)
            case .failure(_):
                FreeToken.shared.logger("Client version is NOT compatible with AI model", .error)
                profiler.end(eventType: .downloadModel, eventTypeID: modelCode, isSuccess: false, errorMessage: "Client version is not compatible with AI model.")
                return false
            }
            
            FreeToken.shared.logger("Starting AI model file downloads...", .info)
            let downloadPipeline = DownloadPipelineManager(baseDirectory: modelBasePath, downloadFiles: modelFiles, verifyFiles: verifyFiles, progressTracker: progress)
            
            do {
                let downloadResult = try await downloadPipeline.run()
                
                switch downloadResult {
                case .success(_):
                    profiler.end(eventType: .downloadModel, eventTypeID: modelCode, isSuccess: true)
                    await self.stateManager.setState(.downloaded)
                    return true
                case .failure(let error):
                    profiler.end(eventType: .downloadModel, eventTypeID: modelCode, isSuccess: false, errorMessage: error.localizedDescription)
                    await self.stateManager.setState(.failed(error: error.localizedDescription))
                    return false
                }
            } catch {
                FreeToken.shared.logger("Error downloading AI model: \(error.localizedDescription)", .error)
                await self.stateManager.setState(.failed(error: error.localizedDescription))
                return false
            }
        }
        
        func resetCache() -> Bool {
            let fileManager = FileManager.default
            
            unloadModel()
            
            do {
                try fileManager.removeItem(atPath: self.modelBasePath.path)
                Task {
                    FreeToken.shared.logger("Successfully reset model cache", .info)
                    await self.stateManager.setState(.notDownloaded)
                }
                return true
            } catch {
                Task {
                    FreeToken.shared.logger("Failed to remove AI Model Cache with error: \(error.localizedDescription)", .error)
                    await self.stateManager.setState(.unverified)
                }
                return false
            }
        }
        
        func loadModel() async -> Result<Bool, Codings.ErrorResponse> {
            let modelPath = self.modelBasePath
            
            if await self.stateManager.getLoadedState() == .loaded {
                return .success(true)
            }
            
            if await self.stateManager.getLoadedState() == .loading {
                return .failure(modelAlreadyLoadingError)
            }
            
            await self.stateManager.setLoadedState(.loading)
            
            guard await self.stateManager.getState() == .downloaded else {
                FreeToken.shared.logger("AI model has not been downloaded", .error)
                return .failure(self.aiModelNotDownloadedError)
            }
            
            do {
                // Find the first .gguf file in the modelPath directory
                let ggufFiles = try FileManager.default.contentsOfDirectory(atPath: modelPath.path).filter { $0.hasSuffix(".gguf") }
                guard let ggufFile = ggufFiles.first else {
                    FreeToken.shared.logger("No .gguf file found in model directory", .error)
                    return .failure(failedToLoadModelError)
                }
                
                let configuration = AIModelConfiguration(from: self.modelOptions)
                
                await self.stateManager.initializeEngine(modelPath: "\(modelPath.path)/\(ggufFile)", configuration: configuration)
                return .success(true)
            } catch {
                FreeToken.shared.logger("Error loading model: \(error.localizedDescription)", .error)
                return .failure(failedToLoadModelError)
            }
        }
        
        func unloadModel() {
            Task {
                await self.stateManager.unloadEngine()
            }
        }
        
        
        func localChat(messages: [Message], runIdentifier: String) async throws -> Message {
            guard await self.stateManager.getState() == .downloaded else {
                throw self.aiModelNotDownloadedError
            }
            
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            
            let prompt = generateMessagesPrompt(messages: messages)
            
            let response: String
            let usage: TokenUsage
            (response, usage) = try await self.runEngine(prompt: prompt, runIdentifier: runIdentifier)
            
            return Message(role: .assistant, content: response, tokenUsage: usage)
        }
        
        func tokenCount(_ text: String) async throws -> Int {
            guard await self.stateManager.getState() == .downloaded else {
                throw self.aiModelNotDownloadedError
            }
            
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            return try await self.stateManager.tokenCount(text)
        }
        
        func sendPromptToAI(prompt: String, runIdentifier: String, tokenStream: Optional<@Sendable (String) -> Void> = nil) async throws -> (response: String, usage: TokenUsage) {
            guard await self.stateManager.getState() == .downloaded else {
                throw self.aiModelNotDownloadedError
            }
            
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            return try await self.runEngine(prompt: prompt, runIdentifier: runIdentifier, tokenStream: tokenStream)
        }
        
        func sendMessagesToAI(messages: [Message], runIdentifier: String, tokenStream: Optional<@Sendable (String) -> Void> = nil) async throws -> (response: Message, usage: TokenUsage) {
            guard await self.stateManager.getState() == .downloaded else {
                throw self.aiModelNotDownloadedError
            }
            
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            let response: String
            let usage: TokenUsage

            let contextWindowManager = ContextWindowManager(modelManager: self)
            let prompt = try await contextWindowManager.generate(messages: messages)
            
            (response, usage) = try await self.runEngine(prompt: prompt, runIdentifier: runIdentifier, tokenStream: tokenStream)
            
            return (Message(role: .assistant, content: response), usage)
        }
        
        func stopGeneration() async {
            await self.stateManager.stopGeneration()
        }
        
        func generateMessagesPrompt(messages: [Message]) -> String {
            let tokens = self.specialTokens
            var prompt = tokens.beginningOfText
            
            for message in messages {
                let messagePrompt: String
                (messagePrompt, _) = generateMessagePrompt(message: message)
                prompt += messagePrompt
            }
            
            // Add the assistant header
            let (messagePrompt, _) = generateMessagePrompt(message: Message(role: .assistant, content: ""), headerOnly: true)
            
            prompt += messagePrompt
            
            return prompt
        }
        
        func generateMessagePrompt(message: Message, headerOnly: Bool = false) -> (prompt: String, tokenCount: Int) {
            let tokens = self.specialTokens
            var tokenCount = 0

            var prompt = tokens.startHeaderId
            if tokens.startHeaderId != "" {
                tokenCount += 1
            }
            
            if message.role == .tool {
                prompt += modelOptions.toolRole
            } else {
                prompt += message.role.rawValue
            }
            tokenCount += 1 // Token for user/assistant/etc.
            
            prompt += tokens.endHeaderId
            if tokens.endHeaderId != "" {
                tokenCount += 1
            }
            
            if headerOnly {
                return (prompt, tokenCount)
            }
            
            prompt += message.content
            if message.content != "" {
                let messageTokenCount = message.tokenCount ?? 0
                tokenCount += messageTokenCount
                
                if messageTokenCount == 0 {
                    FreeToken.shared.logger("✉️ Message has a ZERO token count attribute - this may cause context window calculation problems - message content: \(message.content)", .warning)
                }
            }
                
            prompt += tokens.endOfTurnId
            if tokens.endOfTurnId != "" {
                tokenCount += 1
            }
            
            return (prompt, tokenCount)
        }
        
        internal func runEngine(prompt: String, maxTokens: Int? = nil, runIdentifier: String, tokenStream: Optional<@Sendable (_ tokens: String) -> Void> = nil) async throws -> (response: String, usage: TokenUsage) {
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            var responseContent = ""
            
            let tokenCount = try await self.stateManager.tokenCount(prompt)
            
            FreeToken.shared.logger("Running AI model with prompt:", .info)
            FreeToken.shared.logger(prompt, .info)

            FreeToken.shared.logger("Prompt tokens count: \(tokenCount)", .info)

            for try await value in try await self.stateManager.generate(for: prompt, maxTokens: maxTokens, runIdentifier: runIdentifier) {
                print(value, terminator: "")
                responseContent += value
                if let streamHandler = tokenStream {
                    streamHandler(value)
                }
            }
            
            let lastRunStats = await self.stateManager.lastRunStats()
            let completionTokenCount = try await self.stateManager.tokenCount(responseContent, addBos: false)
            let tokensPerSecond = lastRunStats?.tokensPerSecond ?? 0.0
            
            let tokenUsage = TokenUsage(promptTokens: tokenCount, completionTokens: completionTokenCount, totalTokens: (tokenCount + completionTokenCount), tokensPerSecond: Float(tokensPerSecond))
            
            return (responseContent, tokenUsage)
        }
        
        private func verifyClientVersionSupported() -> Result<Bool, Codings.ErrorResponse> {
            let versionTest = VersionTester(minVersion: clientConfig.min, maxVersion: clientConfig.max)
            
            if versionTest.isVersionSupported(version: clientVersion) {
                return .success(true)
            } else {
                return .failure(self.unsupportedVersionError)
            }
        }
    }
}
