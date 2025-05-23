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
        
        public enum ModelState: Equatable {
            case unverified
            case notDownloaded
            case downloading
            case downloaded
            case failed(error: String)
        }
        
        public enum LoadedState: Equatable {
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
            
            func getLoadedState() -> LoadedState {
                return loadedState
            }
            
            @LlamaCppSwiftActor
            func initializeEngine(modelPath: String, configuration: AIModelConfiguration) throws {
                self.engine = LlamaCppSimpleRun(modelPath: modelPath, configuration: configuration)
            }
            
            @LlamaCppSwiftActor
            func unloadEngine() async {
                await self.engine?.cleanup()
                self.engine = nil
            }
            
            @LlamaCppSwiftActor
            func tokenCount(_ text: String, addBos: Bool = false) async throws -> Int {
                guard let engine = self.engine else {
                    throw NSError(domain: "AIStateManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not loaded"])
                }
                
                return try await engine.tokenCount(text, addBos: addBos)
            }
            
            @LlamaCppSwiftActor
            func generate(for prompt: String) async throws -> AsyncThrowingStream<String, Error> {
                guard let engine = self.engine else {
                    throw NSError(domain: "AIStateManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not loaded"])
                }
                
                return try await engine.generate(prompt: prompt)
            }
            
            @LlamaCppSwiftActor
            func lastRunStats() async -> LastRunStats? {
                let stats = await engine?.lastRunStats
                
                if let stats = stats {
                    return LastRunStats(totalTokens: stats.totalTokens, elapsed: stats.elapsed, tokensPerSecond: stats.tokensPerSecond)
                } else {
                    return nil
                }
            }
            
            struct LastRunStats {
                let totalTokens: Int
                let elapsed: TimeInterval
                let tokensPerSecond: Double
            }
        }
        
        public init(modelConfig: Codings.AiModelResponse, clientVersion: String, overrideModelPath: Optional<URL> = nil) {
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
        
        public func downloadIfNeeded(progress: Optional<@Sendable (_ percentage: Double) -> Void> = nil) async -> Bool {
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
        
        public func resetCache() -> Bool {
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
        
        public func loadModel() async -> Result<Bool, Codings.ErrorResponse> {
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
                
                let configuration = AIModelConfiguration(topK: modelOptions.topK, topP: modelOptions.topP, nCTX: modelOptions.contextWindowSize, temperature: modelOptions.temperature, maxTokenCount: modelOptions.maxTokenCount, stopTokens: modelOptions.stopTokens)
                
                try await self.stateManager.initializeEngine(modelPath: "\(modelPath.path)/\(ggufFile)", configuration: configuration)
                return .success(true)
            } catch {
                FreeToken.shared.logger("Error loading model: \(error.localizedDescription)", .error)
                return .failure(failedToLoadModelError)
            }
        }
        
        public func unloadModel() {
            Task {
                await self.stateManager.unloadEngine()
                await self.stateManager.setLoadedState(.unloaded)
            }
        }
        
        public func localChat(content: String, role: String) async throws -> [String: String] {
            guard await self.stateManager.getState() == .downloaded else {
                throw self.aiModelNotDownloadedError
            }
            
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            let message = Codings.ShowMessageResponse(id: nil, role: role, content: content, toolCalls: nil, toolResult: nil, isToolMessage: nil, encryptionEnabled: nil, createdAt: nil, updatedAt: nil, tokenUsage: nil)
            
            let prompt = generateMessagesPrompt(messages: [message])
            
            var response: [String: String] = [:]
            (response, _) = try await self.runEngine(prompt: prompt)

            response["role"] = "assistant"
            
            return response
        }
        
        public func tokenCount(_ text: String) async throws -> Int {
            guard await self.stateManager.getState() == .downloaded else {
                throw self.aiModelNotDownloadedError
            }
            
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            return try await self.stateManager.tokenCount(text)
        }
        
        public func sendMessagesToAI(messages: [Codings.ShowMessageResponse], tokenStream: Optional<@Sendable (String) -> Void> = nil) async throws -> Codings.ShowMessageResponse {
            guard await self.stateManager.getState() == .downloaded else {
                throw self.aiModelNotDownloadedError
            }
            
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            var response: [String: String] = [:]
            var usage: Codings.TokenUsageResponse? = nil
            
            // Main task for sending messages to the AI engine

            let contextWindowManager = ContextWindowManager(contextWindowSize: modelOptions.contextWindowSize, maxGenerationTokens: modelOptions.maxTokenCount, modelManager: self)
            let prompt = try await contextWindowManager.generate(messages: messages)
            
            FreeToken.shared.logger("Context Managed Prompt: \(prompt)", .info)
            
            (response, usage) = try await self.runEngine(prompt: prompt, tokenStream: tokenStream)
            
            var responseContent = response["content"]!
            
            let toolCallParser = ParseToolCalls(toolCalls: responseContent)
            
            try? toolCallParser.call()
            
            var toolCalls: String? = nil
            if let allTools = toolCallParser.allTools {
                toolCalls = allTools
                responseContent = ""
            } else {
                FreeToken.shared.logger("No tool calls found in response: \(responseContent)", .info)
            }

            return Codings.ShowMessageResponse(
                id: nil,
                role: "assistant",
                content: responseContent,
                toolCalls: toolCalls,
                toolResult: nil,
                isToolMessage: toolCalls != nil,
                encryptionEnabled: nil,
                createdAt: nil,
                updatedAt: nil,
                tokenUsage: usage!
            )
        }
        
        func generateMessagesPrompt(messages: [Codings.ShowMessageResponse]) -> String {
            let tokens = self.specialTokens
            var prompt = tokens.beginningOfText
            
            for message in messages {
                prompt += generateMessagePrompt(message: message)
            }
            
            // Add the assistant header
            prompt += tokens.startHeaderId
            prompt += "assistant"
            prompt += tokens.endHeaderId
            
            return prompt
        }
        
        func generateMessagePrompt(message: Codings.ShowMessageResponse, headerOnly: Bool = false) -> String {
            // Just encode via LLama Tokens for now - later drive these from the server.
            let tokens = self.specialTokens

            var prompt = tokens.startHeaderId
            if message.role == "tool" {
                prompt += modelOptions.toolRole
            } else {
                prompt += message.role
            }
            prompt += tokens.endHeaderId
            
            if headerOnly {
                return prompt
            }
            
            if message.toolCalls != nil {
                prompt += message.toolCalls!
            } else if message.toolResult != nil {
                prompt += "{ \"output\": \"\(message.toolResult!)\" }"
            } else {
                prompt += message.content
            }
                
            prompt += tokens.endOfTurnId
            
            return prompt
        }
        
        internal func runEngine(prompt: String, tokenStream: Optional<@Sendable (_ tokens: String) -> Void> = nil) async throws -> (response: [String: String], usage: Codings.TokenUsageResponse) {
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            var response = ["role": "assistant", "content": ""]
            var responseContent = ""
            
            let tokenCount = try await self.stateManager.tokenCount(prompt)

            FreeToken.shared.logger("Prompt tokens count: \(tokenCount)", .info)
            
            

            for try await value in try await self.stateManager.generate(for: prompt) {
                responseContent += value
                if let streamHandler = tokenStream {
                    streamHandler(value)
                }
            }
            
            let lastRunStats = await self.stateManager.lastRunStats()
            let completionTokenCount = try await self.stateManager.tokenCount(responseContent, addBos: false)
            let tokensPerSecond = lastRunStats?.tokensPerSecond ?? 0.0
            
            response["content"] = responseContent
            
            let tokenUsage = Codings.TokenUsageResponse(promptTokens: tokenCount, completionTokens: completionTokenCount, totalTokens: (tokenCount + completionTokenCount), prefillTokensPerSecond: nil, decodeTokensPerSecond: Float(tokensPerSecond), numPrefillTokens: nil)
            
            return (response, tokenUsage)
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
