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
        
        let stateManager: AISessionsManager
        
        
        
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
            var llama: LlamaManager? = nil
            let config: AIModelConfiguration
            let modelPath: String
            let deviceManager: DeviceManager
            let queue: AITaskQueue
            let sessionsManager: AISessionsManager
            let sessionID: String
            var messages: [Message]
            var lastRunAt: Date? = nil

            init(messages: [Message], modelPath: String, config: AIModelConfiguration, deviceManager: DeviceManager, queue: AITaskQueue, sessionsManager: AISessionsManager, sessionID: String) {
                self.messages = messages
                self.config = config
                self.modelPath = modelPath
                self.deviceManager = deviceManager
                self.queue = queue
                self.sessionsManager = sessionsManager
                self.sessionID = sessionID
            }

            
            private func ensureLlamaLoaded() throws -> LlamaManager {
                if let l = llama { return l }
                
                // Each session loads its own model instance for complete isolation
                FreeTokenLogger.shared.log("Loading isolated model instance for session \(sessionID)", level: .info)
                
                // Map AIModelConfiguration to LlamaInitOptions
                let opts = LlamaInitOptions(
                    contextSize: config.nCTX,
                    maxSequences: 1,  // Only need 1 sequence since each session has its own model
                    maxNewTokens: config.maxTokenCount,
                    temperature: config.temperature,
                    topK: config.topK,
                    topP: config.topP,
                    repeatPenalty: config.penaltyRepeat,
                    repeatLastN: Int(config.penaltyLastN),
                    frequencyPenalty: config.penaltyFrequency,
                    presencePenalty: config.penaltyPresence,
                    stopSequences: [], // upstream provides stop sequences elsewhere
                    seed: nil,
                    useChatTemplate: true,
                    assistantPrefix: nil,
                    chatStyle: .auto, // Auto-detect from model
                    threadCount: { let (d, _) = DeviceManager.recommendedThreadCounts(reserve: 2); return d }(),
                    batchSize: config.batchSize, // heuristic prompt batch size
                    threadCountBatch: { let (_, b) = DeviceManager.recommendedThreadCounts(reserve: 2); return b }()
                )
                // Create manager with its own model instance
                let manager = try LlamaManager(modelPath: modelPath, options: opts)
                self.llama = manager
                return manager
            }

            func load() throws { _ = try ensureLlamaLoaded() }
            
            /// Create a new session with its own model instance
            func createNewSession(options: LlamaInitOptions? = nil) throws -> LlamaManager {
                
                // Use provided options or default from config
                let opts = options ?? LlamaInitOptions(
                    contextSize: config.nCTX,
                    maxNewTokens: config.maxTokenCount,
                    temperature: config.temperature,
                    topK: config.topK,
                    topP: config.topP,
                    repeatPenalty: config.penaltyRepeat,
                    repeatLastN: Int(config.penaltyLastN),
                    frequencyPenalty: config.penaltyFrequency,
                    presencePenalty: config.penaltyPresence,
                    stopSequences: [],
                    seed: nil,
                    useChatTemplate: true,
                    assistantPrefix: nil,
                    chatStyle: .auto,
                    threadCount: { let (d, _) = DeviceManager.recommendedThreadCounts(reserve: 2); return d }(),
                    batchSize: config.batchSize,
                    threadCountBatch: { let (_, b) = DeviceManager.recommendedThreadCounts(reserve: 2); return b }()
                )
                
                return try LlamaManager(modelPath: modelPath, options: opts)
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
                let l = try ensureLlamaLoaded()
                var total = 0
                for m in messages { total += (try await l.tokenize(m.content).count) + 2 }
                return total
            }

            func tokenCount(for text: String) async throws -> Int {
                let l = try ensureLlamaLoaded()
                return try await l.tokenize(text).count
            }

            func catchUp(allThreadMessages: [Message]) async throws {
                guard allThreadMessages.count > 0 else { return }
                self.messages = allThreadMessages
                // Rebuild context from scratch into llama manager
                let l = try ensureLlamaLoaded()
                let messages = try await self.middleOutMessages(messages: self.messages) { messages in
                    return try await self.tokenCount(for: messages)
                }
                try await l.updateContext(messages: messages)
            }
            
            func generate(runLocation: RunLocation) async throws -> AsyncThrowingStream<String, any Error> {
                // We return a stream whose production is serialized by the queue for its entire lifetime.
                return AsyncThrowingStream<String, any Error> { continuation in
                    Task {
                        do {
                            try await self.queue.enqueue(runLocation: runLocation) {
                                if self.deviceManager.isTooHot() { throw FreeTokenError.isTooHot }
                                self.lastRunAt = Date()
                                let l = try self.ensureLlamaLoaded()
                                let messages = try await self.middleOutMessages(messages: self.messages) { messages in
                                    return try await self.tokenCount(for: messages)
                                }
                                try await l.updateContext(messages: messages)
                                let stream = try await l.generate()
                                for try await chunk in stream { continuation.yield(chunk) }
                                continuation.finish()
                            } as Void
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }

            func generateCompletion(text: String, runLocation: RunLocation) async throws -> AsyncThrowingStream<String, any Error> {
                let message = Message(role: .user, content: text)
                
                return AsyncThrowingStream<String, any Error> { continuation in
                    Task {
                        do {
                            try await self.queue.enqueue(runLocation: runLocation) {
                                if self.deviceManager.isTooHot() { throw FreeTokenError.isTooHot }
                                self.lastRunAt = Date()
                                let l = try self.ensureLlamaLoaded()
                                try await l.updateContext(messages: [message])
                                let stream = try await l.generate()
                                for try await chunk in stream { continuation.yield(chunk) }
                                continuation.finish()
                            } as Void
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
            
            // Goal: Optimize the KV cache by removing old messages but keeping the system message and recent messages
            func optimizeKVCache() async throws {
                // Middle-out pruning handled externally before updateContext; llama manager itself only removes/ appends.
                return
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
            
            init(config: AIModelConfiguration, modelTypes: Codings.AvailableModelTypesResponse, clientConfig: Codings.ShowClientConfig, deviceManager: DeviceManager, promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig) {
                self.config = config
                self.clientConfig = clientConfig
                self.deviceManager = deviceManager
                self.promptTemplateConfig = promptTemplateConfig
                self.modelTypes = modelTypes
                
                let downloadOptions = modelTypes.llamaCpp // MLX dropped
                downloadManager = ModelDownloadManager.llama(modelRepo: downloadOptions.repo, modelFileName: downloadOptions.modelFileName!, mmprojFileName: downloadOptions.mmproj)
                
                MemoryPressureManager.shared.register(minLevel: .normal) { pressureLevel in
                    switch pressureLevel {
                    case .warning:
                        FreeToken.shared.logger("🟡 Memory pressure warning, removing all but the last AI session cache", .warning)
                        #if os(iOS)
                        FreeToken.shared.logger("Availble memory: \(os_proc_available_memory() / 1024 / 1024) MB", .debug)
                        #endif
                        Task(priority: .high) {
                            await self.removeAllButLastRunSession()
                            await self.setMemoryLevel(pressureLevel)
                        }
                    case .critical:
                        FreeToken.shared.logger("🔴 Memory pressure is critical, removing all AI sessions immediately", .error)
                        #if os(iOS)
                        FreeToken.shared.logger("Availble memory: \(os_proc_available_memory() / 1024 / 1024) MB", .debug)
                        #endif
                        Task(priority: .high) {
                            await self.reset()
                            await self.setMemoryLevel(pressureLevel)
                        }
                    case .normal:
                        FreeToken.shared.logger("🟢 Memory pressure is \(pressureLevel), no action needed", .info)
                        #if os(iOS)
                        FreeToken.shared.logger("Availble memory: \(os_proc_available_memory() / 1024 / 1024) MB", .debug)
                        #endif
                        Task {
                            await self.setMemoryLevel(pressureLevel)
                        }
                    }
                }
            }
            
            private func setMemoryLevel(_ level: MemoryPressureLevel) {
                self.memoryLevel = level
            }
            
            func lastRunSession() -> AISessionManager? {
                let sessions = self.sessions.sorted { $0.value.lastRunAt ?? Date.distantPast > $1.value.lastRunAt ?? Date.distantPast }
                return sessions.first?.value
            }
            
            private func removeAllButLastRunSession() {
                // Remove all sessions except the last one that was run
                let sortedSessions = self.sessions.sorted { $0.value.lastRunAt ?? Date.distantPast > $1.value.lastRunAt ?? Date.distantPast }
                guard let lastSession = sortedSessions.first else {
                    FreeToken.shared.logger("🔴 No AI sessions to remove", .error)
                    return
                }
                
                let lastSessionId = lastSession.key
                FreeToken.shared.logger("🔄 Removing all AI sessions except the last run session: \(lastSessionId)", .info)
                self.removeAllSessions(but: lastSessionId)
            }
            
            // Get download state
            func getDownloadState() async -> ModelDownloadState {
                let state: FreeToken.SessionState?
                
                if cachedDownloadState == nil {
                    state = await self.downloadManager.ensureSessionAndGetState()
                } else {
                    state = cachedDownloadState
                }
                
                if state == nil {
                    FreeToken.shared.logger("🔴 AI model download state is nil, assuming not downloaded", .error)
                    return .notDownloaded
                }
                
                switch state! {
                case .completed:
                    self.cachedDownloadState = state! // Cache the completed download state to prevent redundant checks
                    return .downloaded
                case .downloading:
                    return .downloading
                case .failed:
                    return .failed(error: "Model download failed")
                case .partial:
                    return .failed(error: "Model partially downloaded, but failed")
                case .pending:
                    FreeToken.shared.logger("🔵 AI model download is pending - or not verified.", .info)
                    return .notDownloaded
                }
            }
            
            func reset() async {
                FreeToken.shared.logger("🔄 Resetting AI sessions manager...", .info)
                self.modelPath = nil
                removeAllSessions()
            }
            
            // Goal: Load a temporary sesison and run one small message.
            // Why: This will make sure the model loads potentialy for the first time on the device, which can take a while
            private func prewarm() async throws {
                FreeToken.shared.logger("😎 Prewarming AI model...", .info)
                
                _ = try await generateForId("prewarm-session", messages: [Message(role: .user, content: "Answer with only one number: What's 2+2?")], runLocation: .localRun, isTemporary: true)
            }
            
            func loadModel() async throws {
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
            
            func loadSession(for id: String, with messages: [Message] = [], isTemporary: Bool = false, runConfig: AIRunConfig? = nil) async throws -> AISessionManager {
                guard await getDownloadState() == .downloaded else {
                    throw FreeTokenError.aiModelNotDownloaded
                }
                
                if modelPath == nil {
                    try await loadModel()
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
                if sessionDates[id] == nil { sessionDates[id] = stableDate }
                
                // Existing session check
                if let existingSession = self.sessions[id], existingSession.config.equals(config) {
                    // Session already exists, no need to load again
                    try await self.catchUpFor(id: id, allThreadMessages: messages)
                    return existingSession
                }
                
                let preparedMessages = try MessagePrep(
                    messages: messages,
                    promptTemplateConfig: self.promptTemplateConfig,
                    fixedDate: stableDate
                ).prepareMessages()
                
                let session = AISessionManager(messages: preparedMessages, modelPath: modelPath, config: config, deviceManager: self.deviceManager, queue: self.queue, sessionsManager: self, sessionID: id)
                if isTemporary == false {
                    self.sessions[id] = session
                }
                try session.load()
                FreeToken.shared.logger("✅ \(isTemporary ? "Temporary " : "")Session loaded and pre-warmed for ID: \(id)", .info)
                return session
            }
            
            func removeSession(for id: String) {
                // Remove the session for the given ID
                self.sessions.removeValue(forKey: id)
            }
            
            func removeAllSessions() {
                self.sessions.removeAll()
            }
            
            func removeAllSessions(but id: String) {
                // Remove all sessions except the one with the given ID
                self.sessions = self.sessions.filter { $0.key == id }
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
                return self.sessions[id] != nil
            }
            
            func generateForId(_ id: String, messages: [Message] = [], runLocation: RunLocation, isTemporary: Bool = false, runConfig: AIRunConfig? = nil) async throws -> AsyncThrowingStream<String, any Error> {
                
                guard runLocation != .cloudRun else {
                    throw FreeTokenError.aiRunFailed(message: "Cloud run is not supported in this context")
                }
                
                let sessionsManager = self
                
                // Delegate date stability to loadSession (which uses sessionDates)
                let session = try await sessionsManager.loadSession(for: id, with: messages, isTemporary: isTemporary, runConfig: runConfig)
                    
                return try await session.generate(runLocation: runLocation)
            }
            
            func generateCompletion(text: String) async throws -> AsyncThrowingStream<String, any Error> {
                // Generate a completion for a single text input
                let sessionsManager = self
                
                let session = try await sessionsManager.loadSession(for: "completion-session", isTemporary: true)
                
                try session.load()
                                    
                return try await session.generateCompletion(text: text, runLocation: .localRun)
            }
            
            func tokenCountFor(id: String? = nil, messages: [Message]) async throws -> Int {
                if modelPath == nil { try await loadModel() }
                guard let path = modelPath else { return 0 }
                // Create a lightweight ephemeral llama manager for counting (could be optimized to reuse).
                let (decodeThreads, batchThreads) = DeviceManager.recommendedThreadCounts(reserve: 2)
                let opts = LlamaInitOptions(
                    contextSize: config.nCTX,
                    maxSequences: 1,  // Only need 1 sequence since each session has its own model
                    maxNewTokens: config.maxTokenCount,
                    chatStyle: .auto,
                    threadCount: decodeThreads,
                    batchSize: 512,
                    threadCountBatch: batchThreads
                )
                let temp = try LlamaManager(modelPath: path, options: opts)
                var total = 0
                for m in messages { total += (try await temp.tokenize(m.content).count) + 2 }
                return total
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
        
        func loadModel() async -> Result<AIModelLoadingState, FreeTokenError> {
            do {
                try await stateManager.loadModel()
                
                return .success(.loaded)
            } catch {
                FreeToken.shared.logger("🔴 Error loading model: \(error.localizedDescription)", .error)
                return .failure(FreeTokenError.failedToLoadModel)
            }
        }
        
        func unloadModel() async {
            await self.stateManager.removeAllSessions()
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
            FreeToken.shared.logger("Stopping AI generation...", .info)
            generationTask?.cancel()
        }
        
        func tokensCount(for runIdentifier: String?, messages: [Message]) async throws -> Int {
            return try await stateManager.tokenCountFor(id: runIdentifier, messages: messages)
        }
        
        func sendTextToAI(text: String, runLocation: RunLocation = .automatic, aiRunConfig: AIRunConfig? = nil, tokenStream: Optional<@Sendable (_ tokens: String) async -> Void> = nil) async throws -> (response: String, usage: TokenUsage?) {
            
            let aiResults = AIResults()
            
            if let maxTokens = aiRunConfig?.maxGenerationTokens {
                await aiResults.setMaxTokenCount(maxTokens)
            } else {
                await aiResults.setMaxTokenCount(self.modelConfig.maxTokenCount)
            }
            
            var inputTokenCount = 0
            let session = try await self.stateManager.loadSession(for: "completion-session", with: [], isTemporary: true, runConfig: aiRunConfig)
            
            inputTokenCount = try await session.tokenCount(for: text)
            
            let task = Task {
                do {
                    let maxTokenCount = await aiResults.maxTokenCount
                    FreeToken.shared.logger("🧠 Beginning AI Generation for completion", .info)
                    for try await value in try await session.generateCompletion(text: text, runLocation: runLocation) {
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
        
        func sendMessagesToAI(messages: [Message], runIdentifier: String, runLocation: RunLocation = .automatic, noContextCache: Bool = false, aiRunConfig: AIRunConfig? = nil, tokenStream: Optional<@Sendable (_ tokens: String) async -> Void> = nil) async throws -> (response: String, usage: TokenUsage?) {
            
            guard messages.count > 0 else {
                throw FreeTokenError.noMessagesToSend
            }
            
            let aiResults = AIResults()
            
            if let maxTokens = aiRunConfig?.maxGenerationTokens {
                await aiResults.setMaxTokenCount(maxTokens)
            } else {
                await aiResults.setMaxTokenCount(self.modelConfig.maxTokenCount)
            }
            
            let session = try await self.stateManager.loadSession(for: runIdentifier, with: messages, isTemporary: noContextCache, runConfig: aiRunConfig)
            
            var inputTokenCount = 0
            
            inputTokenCount = try await session.tokenCount(for: messages)
            FreeToken.shared.logger("📊 Input token count: \(inputTokenCount) tokens", .info)
            
            let task = Task {
                do {
                    let maxTokenCount = await aiResults.maxTokenCount
                    FreeToken.shared.logger("🧠 Beginning AI Generation for \(runIdentifier)", .info)
                    for try await value in try await session.generate(runLocation: runLocation) {
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
