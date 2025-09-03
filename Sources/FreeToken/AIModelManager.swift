//
//  AIModelDownloadManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/30/24.
//
import Foundation
import Metal
//import LocalLLMClient
//import LocalLLMClientLlama
//import LocalLLMClientMLX
//import LocalLLMClientUtility

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import os


extension FreeToken {
    class AIModelManager: @unchecked Sendable {
        let modelCode: String
        let modelConfig: AIModelConfiguration
        let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
        let availableModelTypes: Codings.AvailableModelTypesResponse
        let deviceManager: DeviceManager
        
        private let clientConfig: Codings.ShowClientConfig
        private let clientVersion: String
        private var generationTask: Task<Void, Error>? = nil
        
        private let stateManager: AISessionsManager
        
        
        
        enum LoadState: Equatable {
            case notLoaded
            case prewarm
            case loaded
        }

        enum ModelType: Equatable {
            case llamaCpp
            case mlx
        }
        
        
        // Check if any message contains image attachments
        private func hasImageAttachments(_ messages: [Message]) -> Bool {
            return messages.contains { message in
                message.attachments?.contains { $0.type == .image } == true
            }
        }
        
        // Note: Vision support checking is handled via error catching during inference
        // since LLMSession doesn't expose a public supportsVision property
        
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
        
        class AISessionManager: @unchecked Sendable {
            // Simplified: Uses internal FreeToken.LlamaManager instead of external LLMSession.
            var llama: LlamaManager
            let config: AIModelConfiguration
            let deviceManager: DeviceManager
            let queue: AITaskQueue
            let sessionsManager: AISessionsManager
            let sessionID: String
            var messages: [Message]
            var lastRunAt: Date? = nil

            init(messages: [Message], modelPath: String, config: AIModelConfiguration, deviceManager: DeviceManager, queue: AITaskQueue, sessionsManager: AISessionsManager, sessionID: String) throws {
                self.messages = messages
                self.config = config
                self.deviceManager = deviceManager
                self.queue = queue
                self.sessionsManager = sessionsManager
                self.sessionID = sessionID
                
                let options = LlamaInitOptions(
                    contextSize: config.nCTX,
                    maxSequences: 1,  // Default to 4 parallel sequences
                    maxNewTokens: config.maxTokenCount,
                    temperature: config.temperature,
                    topK: config.topK,
                    topP: config.topP,
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
                    stopSequences: [],
                    threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                    batchSize: config.batchSize,
                    threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
                )
                
                self.llama = try LlamaManager(modelPath: modelPath, options: options)
            }

            private func middleOutMessages(messages: [Message], tokenCounter: @Sendable (_ messages: [Message]) async throws -> Int) async throws -> [Message] {
                // Goal: Middle-out messages to fit into the available context size
                var availableTokens = (config.nCTX - config.maxTokenCount) - Int(Double(config.nCTX) * 0.1) // 10% buffer
                var prioritizedMessages: [Message] = []
                let systemMessage = messages.first!
                let lastMessage = messages.last!
                availableTokens -= try await tokenCounter([systemMessage])
                
                if availableTokens < 0 {
                    throw FreeTokenError.aiRunFailed(message: "Not enough tokens to initialize session with system message")
                } else {
                    prioritizedMessages.append(systemMessage)
                }
                
                if messages.count > 1 {
                    availableTokens -= try await tokenCounter([lastMessage])
                    
                    // Collect the last few messages to fill up context
                    let messagesToAdd = messages.dropFirst().dropLast().reversed()
                    var fillMessages: [Message] = []
                    
                    for message in messagesToAdd {
                        let messageTokens = try await tokenCounter([message])
                        if availableTokens - messageTokens < 0 {
                            // Not enough tokens to add this message, stop here
                            break
                        } else {
                            availableTokens -= messageTokens
                            fillMessages.append(message)
                        }
                    }
                    
                    fillMessages = fillMessages.reversed()
                    
                    // Make sure messages alternate roles
                    if let firstFillMessage = fillMessages.first {
                        if let lastPrioritizedMessage = prioritizedMessages.last {
                            if firstFillMessage.role == lastPrioritizedMessage.role {
                                fillMessages.remove(at: 0)
                            }
                        }
                    }
                    
                    prioritizedMessages.append(contentsOf: fillMessages)
                    prioritizedMessages.append(lastMessage)
                }
                
                return prioritizedMessages
            }
            
            
            func tokenCount(for messages: [Message]) async throws -> Int {
                var total = 0
                for m in messages { total += (try await llama.tokenize(m.content).count) + 2 }
                return total
            }

            func tokenCount(for text: String) async throws -> Int {
                return try await llama.tokenize(text).count
            }

            func catchUp(allThreadMessages: [Message]) async throws {
                guard allThreadMessages.count > 0 else { return }
                self.messages = allThreadMessages
                // Rebuild context from scratch into llama manager
                let messages = try await self.middleOutMessages(messages: self.messages) { messages in
                    return try await self.tokenCount(for: messages)
                }
                try await llama.updateContext(messages: messages)
            }
            
            func generate(runLocation: RunLocation) async throws -> AsyncThrowingStream<String, any Error> {
                // We return a stream whose production is serialized by the queue for its entire lifetime.
                // Log GPU memory remaining
                let gpuStats = self.deviceManager.getGPUMemoryStats()
                FreeToken.shared.logger("🚀 GPU memory: \(gpuStats.current / 1024 / 1024) MB used / \(gpuStats.max / 1024 / 1024) MB available (\(String(format: "%.1f", gpuStats.percentage * 100))%)", .info)
                
                if self.deviceManager.isTooHot() {
                    throw FreeTokenError.isTooHot
                }
                self.lastRunAt = Date()
                
                let messages = try await self.middleOutMessages(messages: self.messages) { messages in
                    return try await self.tokenCount(for: messages)
                }
                
                try await self.llama.updateContext(messages: messages)
                return try await self.llama.generate()
            }

            func generateCompletion(text: String, runLocation: RunLocation) async throws -> AsyncThrowingStream<String, any Error> {
                let message = Message(role: .user, content: text)
                
                let gpuStats = self.deviceManager.getGPUMemoryStats()
                FreeToken.shared.logger("🚀 GPU memory: \(gpuStats.current / 1024 / 1024) MB used / \(gpuStats.max / 1024 / 1024) MB available (\(String(format: "%.1f", gpuStats.percentage * 100))%)", .info)
                
                if self.deviceManager.isTooHot() {
                    throw FreeTokenError.isTooHot
                }
                self.lastRunAt = Date()
                
                try await self.llama.updateContext(messages: [message])
                
                return try await self.llama.generate()
            }
        
            func unload() async {
                await self.llama.unload()
            }
        }
        
        actor AISessionsManager {
            // Goal: Manage multiple AI sessions, evacuation & overall memory state
            
            private let downloadManager: ModelDownloadManager
            private var modelPath: String? = nil
            private var sessions: [String: AISessionManager] = [:]
            private let queue = AITaskQueue.shared
            private let config: AIModelConfiguration
            private let clientConfig: Codings.ShowClientConfig
            private let deviceManager: DeviceManager
            private let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
            private let modelTypes: Codings.AvailableModelTypesResponse
            private var cachedDownloadState: FreeToken.SessionState? = nil
            private var memoryLevel: MemoryPressureLevel = .normal
            private var sessionDates: [String: Date] = [:] // stable per-session date for message prep
            private var tokenizer: LlamaTokenizer? = nil
            // Integrity verification state (in-memory only)
            private var integrityResult: ModelIntegrityChecker.IntegrityResult = .unverified
            private var validatedFileSizes: [String: Int64] = [:]
            private var hashesValidatedOnce: Bool = false
            private let integrityChecker = ModelIntegrityChecker()
            private var downloadInspector: ModelDownloadInspector? = nil
            
            init(config: AIModelConfiguration, modelTypes: Codings.AvailableModelTypesResponse, clientConfig: Codings.ShowClientConfig, deviceManager: DeviceManager, promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig) {
                self.config = config
                self.clientConfig = clientConfig
                self.deviceManager = deviceManager
                self.promptTemplateConfig = promptTemplateConfig
                self.modelTypes = modelTypes
                
                let downloadOptions = modelTypes.llamaCpp // MLX dropped
                downloadManager = ModelDownloadManager.llama(modelRepo: downloadOptions.repo, modelFileName: downloadOptions.modelFileName!, mmprojFileName: downloadOptions.mmproj)
                
                let gpuStats = self.deviceManager.getGPUMemoryStats()
                FreeToken.shared.logger("GPU memory: \(gpuStats.current / 1024 / 1024) MB used / \(gpuStats.max / 1024 / 1024) MB available (\(String(format: "%.1f", gpuStats.percentage * 100))%)", .info)
                
                let dl = modelTypes.llamaCpp
                self.downloadInspector = ModelDownloadInspector(repo: dl.repo, modelFileName: dl.modelFileName, mmprojFileName: dl.mmproj)
            }
            
            private func setMemoryLevel(_ level: MemoryPressureLevel) {
                self.memoryLevel = level
            }
            
            func lastRunSession() -> AISessionManager? {
                let sessions = self.sessions.sorted { $0.value.lastRunAt ?? Date.distantPast > $1.value.lastRunAt ?? Date.distantPast }
                return sessions.first?.value
            }
            
            private func removeAllButLastRunSession() async {
                // Remove all sessions except the last one that was run
                let sortedSessions = self.sessions.sorted { $0.value.lastRunAt ?? Date.distantPast > $1.value.lastRunAt ?? Date.distantPast }
                guard let lastSession = sortedSessions.first else {
                    FreeToken.shared.logger("🔴 No AI sessions to remove", .error)
                    return
                }
                
                let lastSessionId = lastSession.key
                FreeToken.shared.logger("🔄 Removing all AI sessions except the last run session: \(lastSessionId)", .info)
                await self.removeAllSessions(but: lastSessionId)
            }
            
            // Get download state
            func getDownloadState() async -> ModelDownloadState {
                guard let inspector = downloadInspector else { return .notDownloaded }
                let state = await inspector.getState()
                return state
            }
            
            func reset() async {
                FreeToken.shared.logger("🔄 Resetting AI sessions manager...", .info)
                self.modelPath = nil
                await removeAllSessions()
            }
            
            // Goal: Load a session and have it memory resident for quick future execution.
            func prewarmForID(id: String) async throws {
                FreeToken.shared.logger("😎 Prewarming AI model ID: \(id)...", .info)
                
                try await loadSession(for: id)
                try await catchUpFor(id: id, allThreadMessages: [])
            }
            
            func getModelDetails() async throws {
                guard await getDownloadState() == .downloaded else {
                    FreeToken.shared.logger("🔴 AI model not downloaded yet", .error)
                    throw FreeTokenError.aiModelNotDownloaded
                }

                // Set the destination directory Application Support/FreeToken/Models/<modelRepo>
#if os(iOS) || os(tvOS) || os(watchOS)
                let modelBaseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("FreeToken")
                    .appendingPathComponent("Models")
#else
                let modelBaseURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".FreeToken") // Use a shared directory just in case they have more than one FreeToken supported app
                    .appendingPathComponent("Models")
#endif

                let downloadOptions = modelTypes.llamaCpp
                let modelURL = modelBaseURL.appendingPathComponent(downloadOptions.repo.replacingOccurrences(of: "/", with: "_"))
                let modelFileURL = modelURL.appendingPathComponent(downloadOptions.modelFileName!)
                self.modelPath = modelFileURL.path
            }
            
            func loadSession(for id: String, with messages: [Message] = [], isTemporary: Bool = false, runConfig: AIRunConfig? = nil) async throws {
                guard await getDownloadState() == .downloaded else {
                    throw FreeTokenError.aiModelNotDownloaded
                }
                
                if modelPath == nil {
                    try await getModelDetails()
                }
                let modelPath = self.modelPath!
                
                // Convert RunConfig to AIModelConfiguration if provided
                var config: AIModelConfiguration
                
                if let runConfig = runConfig {
                    // Update the model config with runConfig values
                    config = self.config
                    config.temperature = runConfig.temperature ?? self.config.temperature
                    config.topP = runConfig.topP ?? self.config.topP
                    config.maxTokenCount = runConfig.maxGenerationTokens ?? self.config.maxTokenCount
                    config.nCTX = runConfig.contextWindowSize ?? self.config.nCTX
                    config.topK = runConfig.topK ?? self.config.topK
                } else {
                    // Use default config
                    config = self.config
                }
                
                // Stable date for this session id
                let stableDate = sessionDates[id] ?? Date()
                if sessionDates[id] == nil {
                    sessionDates[id] = stableDate
                }
                
                if deviceManager.isHighlanderMode {
                    // Only one session at a time - reuse the existing session by resetting it.
                    // Disreard the session ID and just use the first session.
                    
                    let preparedMessages = try MessagePrep(
                        messages: messages,
                        promptTemplateConfig: self.promptTemplateConfig,
                        fixedDate: stableDate
                    ).prepareMessages()
                    
                    if sessions.count > 0 {
                        let session = sessions.first!.value
                        let sessionID = sessions.first!.key
                        
                        if sessions.count > 1 {
                            FreeToken.shared.logger("⚔️ Highlander mode - removing all other sessions except ID: \(id)", .info)
                            await self.removeAllSessions(but: sessionID)
                        }
                        
                        if session.config.equals(config) {
                            if sessionID != id {
                                _ = await session.llama.resetSession() // Reset it so it's like new
                                // Rename session key so that next time it won't reset the session
                                if let value = self.sessions.removeValue(forKey: sessionID) {
                                    self.sessions[id] = value // perform a move without copy
                                }
                            }
                            try await session.catchUp(allThreadMessages: preparedMessages) // Load all the tokens into the thread
                            return
                        } else {
                            FreeToken.shared.logger("⚔️ Highlander mode - removing existing session with different config (ID: \(sessionID))", .info)
                            _ = await self.removeAllSessions()
                            // This will now fall through to create a new session below
                        }
                    }
                    
                    if !deviceHasEnoughMemoryForNewSession() {
                        FreeToken.shared.logger("🔴 Does not have enough GPU memory after unloading all other sessions, cannot load new session", .error)
                        throw FreeTokenError.aiRunFailed(message: "Insufficient memory for new AI session")
                    }
                    
                    let session = try AISessionManager(messages: preparedMessages, modelPath: modelPath, config: config, deviceManager: self.deviceManager, queue: self.queue, sessionsManager: self, sessionID: id)
                    self.sessions[id] = session
                    
                    return
                }
                
                // Existing session check
                if let existingSession = self.sessions[id], existingSession.config.equals(config) {
                    // Session already exists, no need to load again
                    try await self.catchUpFor(id: id, allThreadMessages: messages)
                    return
                }
                
                let preparedMessages = try MessagePrep(
                    messages: messages,
                    promptTemplateConfig: self.promptTemplateConfig,
                    fixedDate: stableDate
                ).prepareMessages()
                
                // If there will not be enough GPU memory, unload all other sessions
                if !deviceHasEnoughMemoryForNewSession() {
                    FreeToken.shared.logger("🟡 Not enough memory for new session, unloading all other sessions before loading new one", .warning)
                    _ = await self.removeAllSessions()
                    
                    // Wait 100ms and try again - if still not enough memory, fail
                    try await Task.sleep(nanoseconds: 100 * 1_000_000)
                    if !deviceHasEnoughMemoryForNewSession() {
                        FreeToken.shared.logger("🔴 Still not enough memory after unloading all other sessions, cannot load new session", .error)
                        throw FreeTokenError.aiRunFailed(message: "Insufficient memory for new AI session")
                    }
                }
                
                let session = try AISessionManager(messages: preparedMessages, modelPath: modelPath, config: config, deviceManager: self.deviceManager, queue: self.queue, sessionsManager: self, sessionID: id)
                if isTemporary == false {
                    self.sessions[id] = session
                }
                
                FreeToken.shared.logger("✅ \(isTemporary ? "Temporary " : "")Session loaded and pre-warmed for ID: \(id)", .info)
            }
            
            func removeSession(for id: String) {
                // Remove the session for the given ID
                if let session = self.sessions[id] {
                    Task {
                        await session.unload()
                    }
                }

                self.sessions.removeValue(forKey: id)
            }
            
            func removeAllSessions() async {
                for (_, session) in sessions {
                    await session.unload()
                }
                self.sessions.removeAll()
            }
            
            func removeAllSessions(but id: String) async {
                // Remove all sessions except the one with the given ID
                for (sessionID, session) in sessions {
                    if sessionID != id {
                        await session.unload()
                        FreeToken.shared.logger("🗑️ Removing AI session with ID: \(sessionID)", .info)
                    }
                }
                if let session = self.sessions[id] {
                    self.sessions = [id: session]
                }
            }
            
            func downloadModel(
                onProgress: Optional<@Sendable (Double) -> Void>,
                success: @escaping @Sendable () async -> Void,
                failure: @escaping @Sendable (FreeToken.FreeTokenError) async -> Void
            ) async throws {
                let downloadState = await self.getDownloadState()
                
                if downloadState == .downloaded {
                    FreeToken.shared.logger("🔵 AI model is already downloaded", .info)
                    await success()
                    return
                }
                
                try await downloadManager.download(
                    progress: onProgress,
                    success: { modelPath in
                        FreeToken.shared.logger("✅ Model downloaded successfully to \(modelPath)", .info)
                        await success()
                    },
                    failure: failure
                )
            }
            
            func catchUpFor(id: String, allThreadMessages: [Message]) async throws {
                // Prepared Messages
                var id = id
                if deviceManager.isHighlanderMode {
                    id = self.sessions.first!.key
                }
                
                let stableDate = sessionDates[id] ?? Date()
                if sessionDates[id] == nil { sessionDates[id] = stableDate }
                let preparedMessages = try MessagePrep(
                    messages: allThreadMessages,
                    promptTemplateConfig: self.promptTemplateConfig,
                    fixedDate: stableDate
                ).prepareMessages()
                
                // Catch up the session with all messages
                let session: AISessionManager
                if let foundSession = self.sessions[id] {
                    session = foundSession
                    try await session.catchUp(allThreadMessages: preparedMessages)
                } else {
                    // New session
                    _ = try await self.loadSession(for: id, with: preparedMessages, isTemporary: false)
                }
            }
            
            func deviceTooHot() -> Bool {
                return self.deviceManager.isTooHot()
            }
            
            func deviceHasEnoughMemoryForNewSession() -> Bool {
                return self.deviceManager.availableMemoryForRequestedSize()
            }
            
            func sessionExists(for id: String) -> Bool {
                if deviceManager.isHighlanderMode {
                    return self.sessions.count > 0
                } else {
                    return self.sessions[id] != nil
                }
            }
            
            func generateForId(_ id: String, messages: [Message] = [], runLocation: RunLocation, isTemporary: Bool = false, runConfig: AIRunConfig? = nil) async throws -> AsyncThrowingStream<String, any Error> {
                
                guard runLocation != .cloudRun else {
                    throw FreeTokenError.aiRunFailed(message: "Cloud run is not supported in this context")
                }
                
                try await loadSession(for: id, with: messages, isTemporary: isTemporary, runConfig: runConfig)
                
                if deviceManager.isHighlanderMode {
                    let session = self.sessions.first!.value
                    return try await session.generate(runLocation: runLocation)
                } else {
                    let session = self.sessions[id]!
                        
                    return try await session.generate(runLocation: runLocation)
                }
            }
            
            func generateCompletion(text: String, runConfig: AIRunConfig? = nil) async throws -> AsyncThrowingStream<String, any Error> {
                
                // Generate a completion for a single text input
                let sessionID = "completion-session"
                let message = Message(role: .user, content: text)
                try await self.loadSession(for: sessionID, with: [message], runConfig: runConfig)
                
                return try await self.generateForId(sessionID, runLocation: .localRun)
            }
            
            func tokenCountFor(messages: [Message]) async throws -> Int {
                if modelPath == nil { try await getModelDetails() }
                guard let path = modelPath else { return 0 }
                if sessions.isEmpty {
                    if tokenizer == nil {
                        tokenizer = LlamaTokenizer(modelPath: path)
                    }
                    var count = 0
                    
                    for message in messages {
                        count += tokenizer!.tokenize(text: message.content).count + 2
                    }
                    
                    return count
                } else {
                    let firstSession = sessions.first!.value
                    return try await firstSession.tokenCount(for: messages)
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
            self.availableModelTypes = modelConfig.modelTypes!
            self.deviceManager = DeviceManager(memoryRequirement: clientConfig.requiredMemoryBytes)
            
            self.stateManager = AISessionsManager(config: self.modelConfig, modelTypes: modelConfig.modelTypes!, clientConfig: self.clientConfig, deviceManager: self.deviceManager, promptTemplateConfig: self.promptTemplateConfig)
        }
        
        func downloadIfNeeded(progress progressCallback: Optional<@Sendable (_ percentage: Double) -> Void> = nil, success: @escaping @Sendable () async -> Void, failure: @escaping @Sendable (Error) async -> Void) async throws {
            let profiler = Profiler()
            if await self.stateManager.getDownloadState() == .downloading {
                FreeToken.shared.logger("Currently downloading AI model - Cannot download more than once", .info)
            }
            
            switch verifyClientVersionSupported() {
            case .success(_):
                FreeToken.shared.logger("Client version is compatible with AI model", .info)
            case .failure(_):
                FreeToken.shared.logger("Client version is NOT compatible with AI model", .error)
                profiler.end(eventType: .downloadModel, eventTypeID: modelCode, isSuccess: false, errorMessage: "Client version is not compatible with AI model.")
                throw FreeTokenError.clientAIVersionMismatch
            }
            
            do {
                _ = try await stateManager.downloadModel(onProgress: progressCallback, success: success, failure: failure)
            } catch {
                await failure(error)
            }
        }
        
        func getDownloadState() async -> ModelDownloadState {
            return await self.stateManager.getDownloadState()
        }
        
        func loadModel() async -> Result<AIModelLoadingState, FreeTokenError> {
            do {
                return try await AITaskQueue.shared.enqueue(name: "loadModel", runLocation: .localRun) {
                    if self.deviceManager.isHighlanderMode {
                        await AIModelsManager.shared.unloadAllModels(except: self.modelCode)
                    }
                    try await self.stateManager.getModelDetails()
                    
                    return .success(.loaded)
                }
            } catch {
                FreeToken.shared.logger("🔴 Error loading model: \(error.localizedDescription)", .error)
                return .failure(FreeTokenError.failedToLoadModel)
            }
        }
        
        func loadSession(for id: String, with messages: [Message] = [], runConfig: AIRunConfig?) async throws {
            try await AITaskQueue.shared.enqueue(name: "loadSession(\(id))", runLocation: .localRun) {
                if self.deviceManager.isHighlanderMode {
                    await AIModelsManager.shared.unloadAllModels(except: self.modelCode)
                }
                try await self.stateManager.loadSession(for: id, with: messages, isTemporary: false)
            }
        }
        
        func unloadModel() async {
            await self.stateManager.removeAllSessions()
        }
        
        func prewarmForId(id: String) async throws {
            try await AITaskQueue.shared.enqueue(name: "prewarmForId(\(id))", runLocation: .localRun) {
                if self.deviceManager.isHighlanderMode {
                    await AIModelsManager.shared.unloadAllModels(except: self.modelCode)
                }
                try await self.stateManager.prewarmForID(id: id)
            }
        }
        
        func lastUsedAt() async -> Date? {
            // Returns the last used session date
            if let lastSession = await self.stateManager.lastRunSession() {
                return lastSession.lastRunAt
            } else {
                return nil
            }
        }
        
        func stopGeneration() async {
            FreeToken.shared.logger("🛑 Stopping AI generation...", .info)
            generationTask?.cancel()
        }
        
        func tokensCount(messages: [Message]) async throws -> Int {
            return try await AITaskQueue.shared.enqueue(name: "tokensCount", runLocation: .localRun) {
                if self.deviceManager.isHighlanderMode {
                    await AIModelsManager.shared.unloadAllModels(except: self.modelCode)
                }
                return try await self.stateManager.tokenCountFor(messages: messages)
            }
        }
        
        func sendTextToAI(text: String, runLocation: RunLocation = .automatic, aiRunConfig: AIRunConfig? = nil, tokenStream: Optional<@Sendable (_ tokens: String) async -> Void> = nil) async throws -> (response: String, usage: TokenUsage?) {
            return try await AITaskQueue.shared.enqueue(name: "sendTextToAI", runLocation: runLocation) {
                if self.deviceManager.isHighlanderMode {
                    await AIModelsManager.shared.unloadAllModels(except: self.modelCode)
                }
                let aiResults = AIResults()
                
                if let maxTokens = aiRunConfig?.maxGenerationTokens {
                    await aiResults.setMaxTokenCount(maxTokens)
                } else {
                    await aiResults.setMaxTokenCount(self.modelConfig.maxTokenCount)
                }
                
                var inputTokenCount = 0
                
                let task = Task {
                    do {
                        let maxTokenCount = await aiResults.maxTokenCount
                        FreeToken.shared.logger("🧠 Beginning AI Generation for completion", .info)
                        for try await value in try await self.stateManager.generateCompletion(text: text) {
                            if Task.isCancelled { break }
                            if await aiResults.startTime == nil {
                                await aiResults.setStartTime(DispatchTime.now())
                            }
                            
                            print(value, terminator: "")
                            await aiResults.appendResponseContent(value)
                            if let streamHandler = tokenStream {
                                await streamHandler(value)
                            }
                            await aiResults.addToTokenCount(1)
                            let tokenCount = await aiResults.tokenCount
                            if let maxTokenCount = maxTokenCount, tokenCount >= maxTokenCount {
                                break
                            }
                        }
                        inputTokenCount = try await self.stateManager.tokenCountFor(messages: [Message(role: .user, content: text)]) - 2
                        await aiResults.setEndTime(DispatchTime.now())
                    } catch {
                        FreeToken.shared.logger("🔴 Failed generating response from AI Model: \(error.localizedDescription)", .error)
                        
                        throw FreeTokenError.aiRunFailed(message: error.localizedDescription)
                    }
                }
                
                // Store the task in the generationTask property
                self.generationTask = task
                _ = try await task.value
                self.generationTask = nil
                
                // Calculate duration
                var usage: TokenUsage? = nil
                let startTime = await aiResults.startTime
                let endTime = await aiResults.endTime
                let outputTokenCount = await aiResults.tokenCount
                
                if let start = startTime, let endTime = endTime {
                    let duration = Double(endTime.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    let tokensPerSecond = Float(Double(outputTokenCount) / (duration / 1000.0))
                    let totalTokens = inputTokenCount + outputTokenCount
                    usage = TokenUsage(
                        totalTokens: totalTokens,
                        tokensPerSecond: tokensPerSecond,
                        inputTokens: inputTokenCount,
                        outputTokens: outputTokenCount,
                        modelCode: self.modelCode
                    )
                    FreeToken.shared.logger("🧠 AI response generated - Input: \(inputTokenCount) tokens, Output: \(outputTokenCount) tokens, Total: \(totalTokens) tokens in \(duration) ms @ \(tokensPerSecond) tokens/s", .info)
                }
                
                let responseContent = await aiResults.responseContent
                
                return (responseContent, usage)
            }
        }
        
        func sendMessagesToAI(messages: [Message], runIdentifier: String, runLocation: RunLocation = .automatic, noContextCache: Bool = false, aiRunConfig: AIRunConfig? = nil, tokenStream: Optional<@Sendable (_ tokens: String) async -> Void> = nil) async throws -> (response: String, usage: TokenUsage?) {
            
            guard messages.count > 0 else {
                throw FreeTokenError.noMessagesToSend
            }
            
            return try await AITaskQueue.shared.enqueue(name: "sendMessagesToAI(\(runIdentifier))", runLocation: runLocation) {
                if self.deviceManager.isHighlanderMode {
                    await AIModelsManager.shared.unloadAllModels(except: self.modelCode)
                }
                let aiResults = AIResults()
                
                if let maxTokens = aiRunConfig?.maxGenerationTokens {
                    await aiResults.setMaxTokenCount(maxTokens)
                } else {
                    await aiResults.setMaxTokenCount(self.modelConfig.maxTokenCount)
                }
                
                var inputTokenCount = 0
                
                let task = Task {
                    do {
                        let maxTokenCount = await aiResults.maxTokenCount
                        FreeToken.shared.logger("🧠 Beginning AI Generation for \(runIdentifier)", .info)
                        for try await value in try await self.stateManager.generateForId(runIdentifier, runLocation: runLocation, runConfig: aiRunConfig) {
                            if Task.isCancelled { break }
                            if await aiResults.startTime == nil {
                                await aiResults.setStartTime(DispatchTime.now())
                            }
                            
                            print(value, terminator: "")
                            await aiResults.appendResponseContent(value)
                            if let streamHandler = tokenStream {
                                await streamHandler(value)
                            }
                            await aiResults.addToTokenCount(1)
                            let tokenCount = await aiResults.tokenCount
                            if let maxTokenCount = maxTokenCount, tokenCount >= maxTokenCount {
                                break
                            }
                        }
                        await aiResults.setEndTime(DispatchTime.now())
                        inputTokenCount = try await self.stateManager.tokenCountFor(messages: messages)
                    } catch {
                        FreeToken.shared.logger("🔴 Failed generating response from AI Model: \(error.localizedDescription)", .error)
                        
                        throw FreeTokenError.aiRunFailed(message: error.localizedDescription)
                    }
                }
                
                // Store the task in the generationTask property
                self.generationTask = task
                _ = try await task.value
                self.generationTask = nil
                
                // Calculate duration
                var usage: TokenUsage? = nil
                let startTime = await aiResults.startTime
                let endTime = await aiResults.endTime
                let outputTokenCount = await aiResults.tokenCount
                
                if let start = startTime, let endTime = endTime {
                    let duration = Double(endTime.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    let tokensPerSecond = Float(Double(outputTokenCount) / (duration / 1000.0))
                    let totalTokens = inputTokenCount + outputTokenCount
                    usage = TokenUsage(
                        totalTokens: totalTokens,
                        tokensPerSecond: tokensPerSecond,
                        inputTokens: inputTokenCount,
                        outputTokens: outputTokenCount,
                        modelCode: self.modelCode
                    )
                    FreeToken.shared.logger("🧠 AI response generated - Input: \(inputTokenCount) tokens, Output: \(outputTokenCount) tokens, Total: \(totalTokens) tokens in \(duration) ms @ \(tokensPerSecond) tokens/s", .info)
                }
                
                let responseContent = await aiResults.responseContent
                
                return (responseContent, usage)
            }
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
