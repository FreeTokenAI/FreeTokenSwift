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
            // Goal: Unified manager that keeps track of:
            // * Primary interface with LLMSession for generation
            // * Initialize LLMSession
            // * Allocation of tokens in the context window per message (kv cache management)
            // * Tokenizer
            // * Evacuation of specific messages based on incoming needs
            
            var session: LLMSession? = nil
            let config: AIModelConfiguration
            let model: LLMSession.LocalModel
            let deviceManager: DeviceManager
            let queue: AITaskQueue
            let sessionsManager: AISessionsManager
            let sessionID: String
            var messages: [Message]
            var tokenizer: LocalLLMTokenizer
            var lastRunAt: Date? = nil

            init(messages: [Message], model: LLMSession.LocalModel, tokenizer: LocalLLMTokenizer, config: AIModelConfiguration, deviceManager: DeviceManager, queue: AITaskQueue, sessionsManager: AISessionsManager, sessionID: String) {
                self.messages = messages
                self.config = config
                self.model = model
                self.tokenizer = tokenizer
                self.deviceManager = deviceManager
                self.queue = queue
                self.sessionsManager = sessionsManager
                self.sessionID = sessionID
            }
            
            func load() async throws {
                _ = try await llmSession()
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
            
            private func llmSession() async throws -> LLMSession {
                if let session = self.session {
                    return session
                } else {
                    // Test for available memory, prune all other sessions if not enough memory.
                    if self.deviceManager.availableMemoryForRequestedSize() == false {
                        FreeToken.shared.logger("⚠️ Device memory is low, removing all resident LLM sessions to free up memory", .warning)
                        await self.sessionsManager.removeAllSessions(but: self.sessionID)
                    } else {
                        FreeToken.shared.logger("🏎️ Device memory is sufficient for LLM session", .info)
                    }
                    
                    // Initialize a new LLMSession
                    let availableContextTokens = (config.nCTX - config.maxTokenCount) - Int(Double(config.nCTX) * 0.1) // 10% buffer
                    let initTokenCount = try await self.tokenCount(for: messages, tempSession: true)
                    
                    if availableContextTokens - initTokenCount < 0 {
                        // Not enough tokens to initialize full session, need to prioritize messages
                        // Prioritize the system message first and then the last few messages to fill up context
                        
                        let prioritizedMessages = try await middleOutMessages(messages: messages) { messages in
                            try await self.tokenCount(for: messages, tempSession: true)
                        }
                        
                        self.session = LLMSession(model: model, messages: llmMessages(messages: prioritizedMessages))
                        
                        try await session!.prewarm()
                        return session!
                    } else {
                        // We can initialize the session with all messages
                        self.session = LLMSession(model: model, messages: llmMessages())
                        try await session!.prewarm()
                        return session!
                    }
                }
            }
            
            func tokenCount(for messages: [Message], tempSession: Bool = false) async throws -> Int {
                var total = 0
                for message in messages {
                    if session != nil {
                        total += await session!.tokenize(message.content) + 2
                    } else {
                        total += try tokenizer.tokenCount(message.content) + 2
                    }
                }
                
                return total
            }
            
            func tokenCount(for text: String, tempSession: Bool = false) async throws -> Int {
                let total: Int
                if session != nil {
                    total = await session!.tokenize(text)
                } else {
                    total = try tokenizer.tokenCount(text)
                }
                
                return total
            }
            
            func catchUp(allThreadMessages: [Message]) async throws {
                guard allThreadMessages.count > 0 else {
                    FreeToken.shared.logger("⚠️ No messages in thread to catch up context", .warning)
                    return
                }
                
                self.messages = allThreadMessages
                
                if (try await llmSession().messageAwareCacheManager) != nil {
                    // Coming from behind - a few messages were generated somewhere else (cloud or another model) and now the user wants to continue the conversation on this model in this session. It's behind and needs to be caught up.
                    
                    let prioritizedMessages = try await middleOutMessages(messages: allThreadMessages) { messages in
                        try await self.tokenCount(for: messages)
                    }

                    let llmMessages = llmMessages(messages: prioritizedMessages)

                    // Take the new optimized array and use:
                    try await llmSession().messages = llmMessages
                    
                    FreeToken.shared.logger("🔄 Caught up session cache", .info)
                } else {
                    // Just add all messages
                    try await llmSession().messages = llmMessages()
                }
            }
            
            func generate(runLocation: RunLocation) async throws -> AsyncThrowingStream<String, any Error> {
                // We return a stream whose production is serialized by the queue for its entire lifetime.
                return AsyncThrowingStream<String, any Error> { continuation in
                    Task {
                        do {
                            try await self.queue.enqueue(runLocation: runLocation) {
                                try await self.optimizeKVCache()
                                
                                if self.deviceManager.isTooHot() {
                                    throw FreeTokenError.isTooHot
                                }
                                self.lastRunAt = Date()
                                let underlying = try await self.llmSession().streamResponse()
                                for try await token in underlying {
                                    continuation.yield(token)
                                }
                                continuation.finish()
                            } as Void
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }

            func generateCompletion(text: String, runLocation: RunLocation) async throws -> AsyncThrowingStream<String, any Error> {
                try await optimizeKVCache()
                return AsyncThrowingStream<String, any Error> { continuation in
                    Task {
                        do {
                            try await self.queue.enqueue(runLocation: runLocation) {
                                if self.deviceManager.isTooHot() {
                                    throw FreeTokenError.isTooHot
                                }
                                self.lastRunAt = Date()
                                let underlying = try await self.llmSession().streamResponse(to: text)
                                for try await token in underlying {
                                    continuation.yield(token)
                                }
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
                if let cacheManager = try await llmSession().messageAwareCacheManager {
                    // Typical Conversation Pattern
                    // 1. System Message (Optional)
                    // 2. User Message < This is initial run
                    // 3. Assistant Message (tool call)
                    // 4. Tool Message < This is second run
                    // 5. Assistant Message (response to tool)
                    // 6. User Message (follow-up) < This is third run
                    
                    FreeToken.shared.logger("🔄 KV Cache Optimization started - executing middle-out KV cache optimization strategy", .info)
                    
                    let wasOptimized = await cacheManager.optimizeMessageCache(preserveFirstMessages: 1, preserveLastMessages: 1, targetUsagePercentage: 0.6, triggerThreshold: 0.9)
                    
                    if wasOptimized {
                        FreeToken.shared.logger("♻️ KV Cache Optimization: middle-out strategy completed successfully", .info)
                    } else {
                        FreeToken.shared.logger("⏭️ KV Cache Optimization did not change the cache state", .info)
                    }
                } else {
                    // Cache management is not possible with this model type.
                    FreeToken.shared.logger("⚠️ KV Cache Management is not available with this model type", .warning)
                }
            }
            
            func llmMessages(messages: [Message]? = nil) -> [LLMInput.Message] {
                let processMessages: [Message]
                
                if let messages = messages {
                    processMessages = messages
                } else {
                    // Use self.messages
                    processMessages = self.messages
                }
                
                return processMessages.map { message in
                    let attachments = message.attachments?.compactMap { attachment -> LLMAttachment? in
                        guard attachment.type == .image else { return nil }
                        
                        #if canImport(UIKit)
                        if let image = UIImage(data: attachment.data) {
                            return LLMAttachment.image(image)
                        }
                        #elseif canImport(AppKit)
                        if let image = NSImage(data: attachment.data) {
                            return LLMAttachment.image(image)
                        }
                        #endif
                        
                        if let inputImage = LLMInputImage(data: attachment.data) {
                            return LLMAttachment.image(inputImage)
                        }
                        
                        return nil
                    } ?? []
                    
                    switch message.role {
                    case .assistant:
                        return LLMInput.Message.assistant(message.content, attachments: attachments)
                    case .user:
                        return LLMInput.Message.user(message.content, attachments: attachments)
                    case .system:
                        return LLMInput.Message.system(message.content)
                    case .tool:
                        return LLMInput.Message(role: .custom("tool"), content: message.content, attachments: attachments)
                    }
                }
            }
        }
        
        actor AISessionsManager {
            // Goal: Manage multiple AI sessions, evacuation & overall memory state
            
            private let downloadManager: ModelDownloadManager
            private var model: LLMSession.LocalModel?
            private var modelPath: String? = nil
            private var sessions: [String: AISessionManager] = [:]
            private let queue = AITaskQueue.shared
            private let config: AIModelConfiguration
            private let clientConfig: Codings.ShowClientConfig
            private let deviceManager: DeviceManager
            private let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
            private let modelTypes: Codings.AvailableModelTypesResponse
            private var tokenizer: LocalLLMTokenizer? = nil
            private var cachedDownloadState: FreeToken.SessionState? = nil
            private var memoryLevel: MemoryPressureLevel = .normal
            
            init(config: AIModelConfiguration, modelTypes: Codings.AvailableModelTypesResponse, clientConfig: Codings.ShowClientConfig, deviceManager: DeviceManager, promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig) {
                self.config = config
                self.clientConfig = clientConfig
                self.deviceManager = deviceManager
                self.promptTemplateConfig = promptTemplateConfig
                self.modelTypes = modelTypes
                
                if let downloadOptions = modelTypes.mlx {
                    // If it's MLX, use MLX downloader
                    downloadManager = ModelDownloadManager.mlx(modelRepo: downloadOptions.repo)
                } else {
                    let downloadOptions = modelTypes.llamaCpp
                    downloadManager = ModelDownloadManager.llama(modelRepo: downloadOptions.repo, modelFileName: downloadOptions.modelFileName!, mmprojFileName: downloadOptions.mmproj)
                }
                
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
                self.model = nil
                self.tokenizer = nil
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

                if let downloadOptions = modelTypes.mlx {
                    let mlxModel = modelBaseURL.appendingPathComponent(downloadOptions.repo.replacingOccurrences(of: "/", with: "_"))
                    model = LLMSession.LocalModel.mlx(url: mlxModel, parameter: .init(
                        maxTokens: config.maxTokenCount, temperature: config.temperature, topP: config.topP, repetitionPenalty: config.penaltyRepeat, repetitionContextSize: Int(config.penaltyLastN), options: .init(verbose: true)))
                    tokenizer = MLXTokenizer(modelURL: mlxModel)
                } else {
                    // Use LlamaCpp by default
                    let downloadOptions = modelTypes.llamaCpp
                    let modelURL = modelBaseURL.appendingPathComponent(downloadOptions.repo.replacingOccurrences(of: "/", with: "_"))
                    let modelFileURL = modelURL.appendingPathComponent(downloadOptions.modelFileName!)
                    let mmprojURL: URL? = downloadOptions.mmproj != nil ? modelURL.appendingPathComponent(downloadOptions.mmproj!) : nil

                    model = LLMSession.LocalModel.llama(url: modelFileURL, mmprojURL: mmprojURL, parameter: .init(
                        context: config.nCTX,
                        batch: config.batchSize,
                        temperature: config.temperature,
                        topK: config.topK,
                        topP: config.topP,
                        penaltyLastN: Int(config.penaltyLastN),
                        penaltyRepeat: config.penaltyRepeat,
                        options: .init(verbose: true)
                    ))
                    tokenizer = LlamaTokenizer(modelURL: modelFileURL)
                }
            }
            
            func loadSession(for id: String, with messages: [Message] = [], isTemporary: Bool = false, runConfig: AIRunConfig? = nil) async throws -> AISessionManager {
                guard await getDownloadState() == .downloaded else {
                    throw FreeTokenError.aiModelNotDownloaded
                }
                
                if model == nil {
                    try await loadModel()
                }
                
                let model = self.model!
                let tokenizer = self.tokenizer!
                
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
                
                let preparedMessages = try MessagePrep(
                    messages: messages,
                    promptTemplateConfig: self.promptTemplateConfig
                ).prepareMessages()
                
                if let existingSession = self.sessions[id], existingSession.config.equals(config) {
                    // Session already exists, no need to load again
                    try await self.catchUpFor(id: id, allThreadMessages: preparedMessages)
                    return existingSession
                }
                
                let session = AISessionManager(messages: preparedMessages, model: model, tokenizer: tokenizer, config: config, deviceManager: self.deviceManager, queue: self.queue, sessionsManager: self, sessionID: id)
                if isTemporary == false {
                    self.sessions[id] = session
                }
                try await session.load()
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
                let preparedMessages = try MessagePrep(
                    messages: allThreadMessages,
                    promptTemplateConfig: self.promptTemplateConfig
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
                
                let preparedMessages = try MessagePrep(
                    messages: messages,
                    promptTemplateConfig: self.promptTemplateConfig
                ).prepareMessages()
                
                let session = try await sessionsManager.loadSession(for: id, with: preparedMessages, isTemporary: isTemporary, runConfig: runConfig)
                    
                return try await session.generate(runLocation: runLocation)
            }
            
            func generateCompletion(text: String) async throws -> AsyncThrowingStream<String, any Error> {
                // Generate a completion for a single text input
                let sessionsManager = self
                
                let session = try await sessionsManager.loadSession(for: "completion-session", isTemporary: true)
                
                try await session.load()
                                    
                return try await session.generateCompletion(text: text, runLocation: .localRun)
            }
            
            func tokenCountFor(id: String? = nil, messages: [Message]) async throws -> Int {
                if tokenizer == nil {
                    try await self.loadModel()
                }
                
                var total = 0
                for message in messages {
                    total += try self.tokenizer!.tokenCount(message.content) + 2
                }
                
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
            
            // Count input tokens using the tokenizer if available
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
