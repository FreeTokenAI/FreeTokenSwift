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
        let taskQueue: AITaskQueue
        let deviceManager: DeviceManager
        
        private let clientConfig: Codings.ShowClientConfig
        private let clientVersion: String
        private var generationTask: Task<Void, Error>? = nil
        
        let stateManager: AISessionsManager
        
        enum DownloadState: Equatable {
            case notDownloaded
            case downloading
            case downloaded
            case failed(error: String)
        }
        
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
        
        actor AITaskQueue {
            private var isRunning = false
            
            func enqueue<T: Sendable>(runLocation: RunLocation, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
                let startTime = DispatchTime.now()
                
                while isRunning {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    FreeToken.shared.logger("⏰ Waiting for AI task queue to be free...", .info)
                    if runLocation == .automatic, DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds > 30_000_000 { // 30 seconds
                        FreeToken.shared.logger("⏰ AI task queue timeout reached, aborting operation", .error)
                        throw FreeTokenError.aiQueueTimeout
                    }
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
        
        class AISessionManager: @unchecked Sendable {
            // Goal: Unified manager that keeps track of:
            // * Primary interface with LLMSession for generation
            // * Initialize LLMSession
            // * Allocation of tokens in the context window per message (kv cache management)
            // * Tokenizer
            // * Evacuation of specific messages based on incoming needs
            
            var session: LLMSession? = nil
            let config: AIModelConfiguration
            let model: LLMSession.DownloadModel
            var messages: [Message]
            private var _tempSession: LLMSession? = nil

            init(messages: [Message], model: LLMSession.DownloadModel, config: AIModelConfiguration) {
                self.messages = messages
                self.config = config
                self.model = model
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
            
            func llmSession() async throws -> LLMSession {
                if let session = self.session {
                    return session
                } else {
                    // Initialize a new LLMSession
                    let availableContextTokens = (config.nCTX - config.maxTokenCount) - Int(Double(config.nCTX) * 0.1) // 10% buffer
                    let initTokenCount = try await self.tokenCount(for: messages, tempSession: true)
                    
                    if availableContextTokens - initTokenCount < 0 {
                        // Not enough tokens to initialize full session, need to prioritize messages
                        // Prioritize the system message first and then the last few messages to fill up context
                        
                        let prioritizedMessages = try await middleOutMessages(messages: messages) { messages in
                            try await self.tokenCount(for: messages, tempSession: true)
                        }
                        
                        self._tempSession = nil
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
                    if tempSession {
                        if _tempSession == nil {
                            _tempSession = LLMSession(model: model)
                        }
                        total += await _tempSession!.tokenize(message.content) + 2 // +2 for role and separator
                    } else {
                        total += try await llmSession().tokenize(message.content) + 2
                    }
                }
                
                return total
            }
            
            func tokenCount(for text: String, tempSession: Bool = false) async throws -> Int {
                if tempSession {
                    if _tempSession == nil {
                        _tempSession = LLMSession(model: model)
                    }
                    return await _tempSession!.tokenize(text)
                } else {
                    return try await llmSession().tokenize(text)
                }
            }
            
            func catchUp(allThreadMessages: [Message]) async throws {
                guard allThreadMessages.count > 0 else {
                    FreeToken.shared.logger("⚠️ No messages in thread to catch up context", .warning)
                    return
                }
                
                let messageDelta = allThreadMessages.count - messages.count
                
                guard messageDelta > 1 else {
                    // No need to catch up, we are already in sync
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
                    
                    FreeToken.shared.logger("🔄 Catching up session cache with \(messageDelta) messages", .info)
                } else {
                    // Just add all messages
                    try await llmSession().messages = llmMessages()
                }
            }
            
            func generate() async throws -> AsyncThrowingStream<String, any Error> {
                // Kickoff an AITaskQueue
                try await optimizeKVCache()
                
                // Generate the response using LLMSession
                return try await llmSession().streamResponse()
            }
            
            func generateCompletion(text: String) async throws -> AsyncThrowingStream<String, any Error> {
                // Generate a completion for a single text input
                try await optimizeKVCache()
                
                // Use LLMSession to generate the completion
                return try await llmSession().streamResponse(to: text)
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
            
            private let model: LLMSession.DownloadModel
            private var sessions: [String: AISessionManager] = [:]
            private let queue = AITaskQueue()
            private let config: AIModelConfiguration
            private let clientConfig: Codings.ShowClientConfig
            private let deviceManager: DeviceManager
            private let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
            private var downloadState: DownloadState = .notDownloaded
            
            init(config: AIModelConfiguration, modelTypes: Codings.AvailableModelTypesResponse, clientConfig: Codings.ShowClientConfig, deviceManager: DeviceManager, promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig) {
                self.config = config
                self.clientConfig = clientConfig
                self.deviceManager = deviceManager
                self.promptTemplateConfig = promptTemplateConfig

                if let downloadOptions = modelTypes.mlx {
                    model = LLMSession.DownloadModel.mlx(id: downloadOptions.repo, parameter: .init(
                        maxTokens: config.maxTokenCount, temperature: config.temperature, topP: config.topP, repetitionPenalty: config.penaltyRepeat, repetitionContextSize: Int(config.penaltyLastN), options: .init(verbose: true)
                    ))
                } else {
                    // Use LlamaCpp by default
                    let downloadOptions = modelTypes.llamaCpp
                    
                    model = LLMSession.DownloadModel.llama(id: downloadOptions.repo, model: downloadOptions.modelFileName!, mmproj: downloadOptions.mmproj, parameter: .init(
                        context: config.nCTX,
                        batch: config.batchSize,
                        temperature: config.temperature,
                        topK: config.topK,
                        topP: config.topP,
                        penaltyLastN: Int(config.penaltyLastN),
                        penaltyRepeat: config.penaltyRepeat,
                        options: .init(verbose: true)
                    ))
                }
            }
            
            // Get download state
            func getDownloadState() async -> DownloadState {
                return self.downloadState
            }
            
            func reset() async {
                FreeToken.shared.logger("🔄 Resetting AI sessions manager...", .info)
                removeAllSessions()
                self.downloadState = .notDownloaded
            }
            
            // Goal: Load a temporary sesison and run one small message.
            // Why: This will make sure the model loads potentialy for the first time on the device, which can take a while
            func prewarm() async throws {
                FreeToken.shared.logger("😎 Prewarming AI model...", .info)
                
                _ = try await generateForId("prewarm-session", messages: [Message(role: .user, content: "Answer with only one number: What's 2+2?")], runLocation: .localRun , isTemporary: true)
            }
            
            func loadSession(for id: String, with messages: [Message] = [], isTemporary: Bool = false, runConfig: AIRunConfig? = nil) async throws -> AISessionManager {
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
                
                if deviceHasEnoughMemoryForNewSession() == false {
                    // Prune all other sessions and try again
                    FreeToken.shared.logger("⚠️ Device memory is low, removing all existing LLM sessions to free up memory", .warning)
                    self.sessions.removeAll()
                }
                
                let session = AISessionManager(messages: preparedMessages, model: model, config: config)
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
            
            func downloadModel(onProgress: Optional<@Sendable (Double) async -> Void>) async throws {
                self.downloadState = .downloading
                
                do {
                    _ = try await model.downloadModel(onProgress: { percent in
                        await onProgress?(percent)
                    })
                } catch {
                    self.downloadState = .failed(error: error.localizedDescription)
                    FreeToken.shared.logger("❌ AI model download failed: \(error.localizedDescription)", .error)
                    throw FreeTokenError.aiModelDownload
                }
                
                self.downloadState = .downloaded
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
                
                return try await queue.enqueue(runLocation: runLocation) {
                    if await sessionsManager.deviceTooHot() {
                        throw FreeTokenError.isTooHot
                    }
                    
                    return try await session.generate()
                }
            }
            
            func generateCompletion(text: String) async throws -> AsyncThrowingStream<String, any Error> {
                // Generate a completion for a single text input
                let sessionsManager = self
                
                let session = try await sessionsManager.loadSession(for: "completion-session", isTemporary: true)
                
                try await session.load()
                
                return try await queue.enqueue(runLocation: .localRun) {
                    if await sessionsManager.deviceTooHot() {
                        throw FreeTokenError.isTooHot
                    }
                    
                    return try await session.generateCompletion(text: text)
                }
            }
            
            func tokenCountFor(id: String? = nil, messages: [Message]) async throws -> Int {
                if id == nil {
                    // Setup a temporary session
                    let tempSession = try await loadSession(for: "temp-session", with: [], isTemporary: true)
                    return try await tempSession.tokenCount(for: messages)
                } else if let session = self.sessions[id!] {
                    return try await session.tokenCount(for: messages)
                } else {
                    FreeToken.shared.logger("🔴 AI session for ID \(id!) does not exist", .error)
                    throw FreeTokenError.aiModelNotLoaded
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
            self.taskQueue = AITaskQueue()
            self.deviceManager = DeviceManager(memoryRequirement: clientConfig.requiredMemoryBytes)
            
            self.stateManager = AISessionsManager(config: self.modelConfig, modelTypes: modelConfig.modelTypes!, clientConfig: self.clientConfig, deviceManager: self.deviceManager, promptTemplateConfig: self.promptTemplateConfig)
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
            
            do {
                _ = try await stateManager.downloadModel(onProgress: progressCallback)
                return true
            } catch {
                return false
            }
        }
        
        func loadModel() async -> Result<AIModelLoadingState, FreeTokenError> {
            do {
                try await stateManager.prewarm()
                
                return .success(.loaded)
            } catch {
                FreeToken.shared.logger("🔴 Error loading model: \(error.localizedDescription)", .error)
                return .failure(FreeTokenError.failedToLoadModel)
            }
        }
        
        func unloadModel() async {
            await self.stateManager.removeAllSessions()
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
                    for try await value in try await session.generateCompletion(text: text) {
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
                    for try await value in try await session.generate() {
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
