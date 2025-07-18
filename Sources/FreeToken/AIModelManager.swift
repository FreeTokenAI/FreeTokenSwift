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

extension FreeToken {
    class AIModelManager: @unchecked Sendable {
        let modelCode: String
        let modelConfig: AIModelConfiguration
        let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
        let availableModelTypes: Codings.AvailableModelTypesResponse
        let taskQueue: AITaskQueue
        
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
            private var isTurboMode: Bool = false

            init(isTurboMode: Bool = false) {
                self.isTurboMode = isTurboMode
            }
            
            func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
                let startTime = DispatchTime.now()
                let isTurboMode = self.isTurboMode
                
                while isRunning {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    FreeToken.shared.logger("⏰ Waiting for AI task queue to be free...", .info)
                    if isTurboMode, DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds > 30_000_000 { // 30 seconds
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
        
        actor AIStateManager {
            var model:  LLMSession.DownloadModel? = nil
            var cachedSession: SessionCache? = nil
            var downloadState: DownloadState = .notDownloaded
            var loadedState: AIModelLoadingState = .unloaded
            var modelInitOptions: ModelInitOptions? = nil
            
            // Thread state management
            private var threadStateManager = ThreadStateManager()
            
            struct SessionCache: @unchecked Sendable {
                let runIdentifier: String
                var session: LLMSession
            }
            
            class ThreadState {
                let threadId: String
                var fullThread: [Message]
                var loadedMessages: [Message]
                var lastLoadedIndex: Int
                var approximateTokenCount: Int
                var lastTruncationPoint: Int?
                var contextWindowSize: Int
                var maxGenerationTokens: Int
                
                // State tracking
                var needsRebuild: Bool = false
                var lastRebuildReason: String?
                
                // KV Cache position tracking
                var messageTokenPositions: [(messageIndex: Int, startPos: Int32, endPos: Int32)] = []
                var currentMaxPosition: Int32 = -1
                var systemMessageTokenRange: (start: Int32, end: Int32)?
                
                init(threadId: String, fullThread: [Message], contextWindowSize: Int, maxGenerationTokens: Int) {
                    self.threadId = threadId
                    self.fullThread = fullThread
                    self.loadedMessages = []
                    self.lastLoadedIndex = -1
                    self.approximateTokenCount = 0
                    self.lastTruncationPoint = nil
                    self.contextWindowSize = contextWindowSize
                    self.maxGenerationTokens = maxGenerationTokens
                }
                
                func updateFullThread(_ messages: [Message]) {
                    self.fullThread = messages
                }
                
                func syncLoadedSession(_ messages: [LLMInput.Message]) {
                    // Convert LLMInput.Message back to Message format for tracking
                    self.loadedMessages = messages.map { llmMessage in
                        let role: MessageRole
                        switch llmMessage.role {
                        case .system: role = .system
                        case .user: role = .user
                        case .assistant: role = .assistant
                        case .custom(let customRole):
                            role = customRole == "tool" ? .tool : .user
                        }
                        return Message(role: role, content: llmMessage.content)
                    }
                    
                    // Update token count estimation
                    self.approximateTokenCount = estimateTokens(self.loadedMessages)
                }
                
                private func estimateTokens(_ messages: [Message]) -> Int {
                    var totalTokens = 0
                    for message in messages {
                        totalTokens += max(1, message.content.count / 4)
                    }
                    return Int(Double(totalTokens) * 1.1) // Add buffer
                }
                
                func canAppendSafely(_ newMessages: [Message]) -> Bool {
                    let newTokens = estimateTokens(newMessages)
                    let availableSpace = contextWindowSize - maxGenerationTokens - approximateTokenCount
                    let canAppend = newTokens <= availableSpace
                    
                    let currentUsage = Double(approximateTokenCount) / Double(contextWindowSize) * 100
                    let projectedUsage = Double(approximateTokenCount + newTokens) / Double(contextWindowSize) * 100
                    
                    FreeToken.shared.logger("🔍 Context Analysis: Current=\(approximateTokenCount) tokens (\(String(format: "%.1f", currentUsage))%), New=\(newTokens) tokens, Available=\(availableSpace) tokens", .info)
                    FreeToken.shared.logger("🔍 Projected usage after append: \(String(format: "%.1f", projectedUsage))%", .info)
                    
                    if !canAppend {
                        FreeToken.shared.logger("❌ Cannot append: would exceed context window (need \(newTokens), have \(availableSpace))", .warning)
                    }
                    
                    return canAppend
                }
                
                func getNewMessagesToAppend() -> [Message] {
                    // After truncation, loadedMessages might not correspond to fullThread indices
                    // We need to find which messages from fullThread are actually new
                    
                    // If loadedMessages is empty, all fullThread messages are new
                    guard !loadedMessages.isEmpty else { return fullThread }
                    
                    // Find the last loaded message in fullThread by content matching
                    let lastLoadedContent = loadedMessages.last?.content ?? ""
                    
                    // Find where the last loaded message appears in fullThread
                    var lastLoadedIndex = -1
                    for (index, message) in fullThread.enumerated().reversed() {
                        if message.content == lastLoadedContent && message.role == loadedMessages.last?.role {
                            lastLoadedIndex = index
                            break
                        }
                    }
                    
                    // If we found the last loaded message, return everything after it
                    if lastLoadedIndex >= 0 && lastLoadedIndex < fullThread.count - 1 {
                        return Array(fullThread[(lastLoadedIndex + 1)...])
                    }
                    
                    // Fallback: if we can't match by content, assume only the very last message is new
                    // This handles the common case of adding one new message
                    if fullThread.count > loadedMessages.count {
                        return Array(fullThread.suffix(1))
                    }
                    
                    return []
                }
                
                func requiresRebuild(for newMessages: [Message]) -> (Bool, String?) {
                    if needsRebuild {
                        return (true, lastRebuildReason ?? "manual_rebuild_flag")
                    }
                    
                    if !canAppendSafely(newMessages) {
                        return (true, "context_full")
                    }
                    
                    // Check if we have too many new messages to append safely
                    // This should only trigger if there are actually many unprocessed messages
                    if newMessages.count > 10 { // Only trigger if many new messages need to be appended
                        return (true, "large_message_gap")
                    }
                    
                    return (false, nil)
                }
                
                // MARK: - KV Cache Position Tracking
                
                func trackMessageTokens(messageIndex: Int, startPos: Int32, endPos: Int32) {
                    messageTokenPositions.append((messageIndex, startPos, endPos))
                    currentMaxPosition = max(currentMaxPosition, endPos)
                    
                    // Track system message separately
                    if messageIndex == 0 {
                        systemMessageTokenRange = (startPos, endPos)
                    }
                }
                
                func updateCurrentPosition(position: Int32) {
                    currentMaxPosition = position
                }
                
                func clearPositionTracking() {
                    messageTokenPositions.removeAll()
                    currentMaxPosition = -1
                    systemMessageTokenRange = nil
                }
                
                func getSystemMessageTokenRange() -> (start: Int32, end: Int32)? {
                    return systemMessageTokenRange
                }
                
                func getRecentMessagesTokenRange(messageCount: Int) -> (start: Int32, end: Int32)? {
                    guard messageTokenPositions.count >= messageCount else {
                        return nil
                    }
                    
                    let recentPositions = Array(messageTokenPositions.suffix(messageCount))
                    guard let firstRecent = recentPositions.first,
                          let lastRecent = recentPositions.last else {
                        return nil
                    }
                    
                    return (firstRecent.startPos, lastRecent.endPos)
                }
                
                func shouldOptimizeKVCache(currentUsage: Double) -> Bool {
                    // Optimize when using > 80% of context window
                    return currentUsage > 0.8
                }
                
                func calculateOptimizationPlan(currentTokens: Int32) -> KVOptimizationPlan? {
                    guard let systemRange = systemMessageTokenRange else {
                        return nil
                    }
                    
                    // Calculate how much to preserve from start and end
                    let preserveFromStart = systemRange.end + 1 // System message + 1 token buffer
                    let recentMessageCount = min(10, messageTokenPositions.count / 2) // Keep last 10 messages or half
                    
                    guard let recentRange = getRecentMessagesTokenRange(messageCount: recentMessageCount) else {
                        return nil
                    }
                    
                    let preserveFromEnd = currentMaxPosition - recentRange.start + 1
                    
                    return KVOptimizationPlan(
                        preserveFromStart: preserveFromStart,
                        preserveFromEnd: preserveFromEnd,
                        removeStartPos: preserveFromStart,
                        removeEndPos: recentRange.start
                    )
                }
            }
            
            struct KVOptimizationPlan {
                let preserveFromStart: Int32
                let preserveFromEnd: Int32
                let removeStartPos: Int32
                let removeEndPos: Int32
            }
            
            class ThreadStateManager {
                private var threadStates: [String: ThreadState] = [:]
                
                func getOrCreateThreadState(
                    threadId: String,
                    fullThread: [Message],
                    contextWindowSize: Int,
                    maxGenerationTokens: Int
                ) -> ThreadState {
                    if let existing = threadStates[threadId] {
                        existing.updateFullThread(fullThread)
                        existing.contextWindowSize = contextWindowSize
                        existing.maxGenerationTokens = maxGenerationTokens
                        return existing
                    }
                    
                    let newState = ThreadState(
                        threadId: threadId,
                        fullThread: fullThread,
                        contextWindowSize: contextWindowSize,
                        maxGenerationTokens: maxGenerationTokens
                    )
                    threadStates[threadId] = newState
                    return newState
                }
                
                func removeThreadState(_ threadId: String) {
                    threadStates.removeValue(forKey: threadId)
                }
                
                func getThreadState(_ threadId: String) -> ThreadState? {
                    return threadStates[threadId]
                }
                
                func planMessageStrategy(
                    threadState: ThreadState,
                    currentSession: LLMSession?,
                    fullThread: [Message]
                ) -> AppendStrategy {
                    threadState.updateFullThread(fullThread)
                    
                    // If no session exists, we need to create one
                    guard let session = currentSession else {
                        return .rebuildRequired(reason: "no_session")
                    }
                    
                    // Sync current session state with thread state
                    threadState.syncLoadedSession(session.messages)
                    
                    // Get messages that need to be appended
                    let newMessages = threadState.getNewMessagesToAppend()
                    guard !newMessages.isEmpty else {
                        // Even if no new messages, check if we need KV optimization
                        if tryKVCacheOptimization(session: session, threadState: threadState) {
                            return .kvCacheOptimization
                        }
                        return .noActionNeeded
                    }
                    
                    // Check if we need to rebuild for normal reasons
                    let (needsRebuild, reason) = threadState.requiresRebuild(for: newMessages)
                    if needsRebuild {
                        return .rebuildRequired(reason: reason ?? "unknown")
                    }
                    
                    // Check if appending these messages would trigger KV optimization need
                    let estimatedNewTokens = newMessages.reduce(0) { sum, message in
                        sum + max(1, message.content.count / 4)
                    }
                    let projectedTokenCount = threadState.approximateTokenCount + estimatedNewTokens
                    let projectedUsage = Double(projectedTokenCount) / Double(threadState.contextWindowSize)
                    
                    // If we're approaching the context limit after appending, trigger KV optimization instead
                    if projectedUsage > 0.8 && tryKVCacheOptimization(session: session, threadState: threadState) {
                        FreeToken.shared.logger("🔄 KV optimization triggered before append - projected usage: \(String(format: "%.1f", projectedUsage * 100))%", .info)
                        return .kvCacheOptimization
                    }
                    
                    // We can safely append
                    return .appendSafely(messages: newMessages)
                }
                
                func executeTruncatedRebuild(
                    threadState: ThreadState,
                    model: LLMSession.DownloadModel,
                    promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
                ) throws -> LLMSession {
                    FreeToken.shared.logger("🔄 ThreadStateManager: Rebuilding session for thread \(threadState.threadId)", .info)
                    
                    // Use the messages from threadState.fullThread - these should already be prepared/truncated
                    let messagesToUse = threadState.fullThread
                    
                    FreeToken.shared.logger("🔄 ThreadStateManager: Creating session with \(messagesToUse.count) messages (no additional truncation)", .info)
                    
                    // Convert to LLMInput.Message format with attachments
                    let llmMessages = messagesToUse.map { message in
                        let attachments = message.attachments?.compactMap { attachment -> LLMAttachment? in
                            guard attachment.type == .image else { return nil }
                            
                            FreeToken.shared.logger("🖼️ [Session Init] Converting image attachment: \(attachment.data.count) bytes, type: \(attachment.contentType)", .debug)
                            
                            #if canImport(UIKit)
                            if let image = UIImage(data: attachment.data) {
                                FreeToken.shared.logger("🖼️ [Session Init] Successfully created UIImage: \(image.size)", .debug)
                                return LLMAttachment.image(image)
                            }
                            #elseif canImport(AppKit)
                            if let image = NSImage(data: attachment.data) {
                                FreeToken.shared.logger("🖼️ [Session Init] Successfully created NSImage: \(image.size)", .debug)
                                return LLMAttachment.image(image)
                            }
                            #endif
                            
                            if let inputImage = LLMInputImage(data: attachment.data) {
                                FreeToken.shared.logger("🖼️ [Session Init] Successfully created LLMInputImage", .debug)
                                return LLMAttachment.image(inputImage)
                            }
                            
                            FreeToken.shared.logger("🖼️ [Session Init] Failed to create any image type from attachment data", .error)
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
                    
                    // Create new session
                    let newSession = LLMSession(model: model, messages: llmMessages)
                    
                    // Update thread state to reflect what's now loaded
                    threadState.syncLoadedSession(llmMessages)
                    threadState.needsRebuild = false
                    threadState.lastRebuildReason = nil
                    threadState.lastTruncationPoint = messagesToUse.count
                    threadState.clearPositionTracking() // Clear old position data after rebuild
                    
                    let contextUsage = Double(threadState.approximateTokenCount) / Double(threadState.contextWindowSize) * 100
                    FreeToken.shared.logger("🔄 ThreadStateManager: Session rebuilt with \(llmMessages.count) messages (targeting 50% context usage)", .info)
                    FreeToken.shared.logger("📊 Context after rebuild: \(threadState.approximateTokenCount)/\(threadState.contextWindowSize) tokens (\(String(format: "%.1f", contextUsage))%)", .info)
                    
                    return newSession
                }
                
                // MARK: - KV Cache Optimization
                
                func tryKVCacheOptimization(
                    session: LLMSession?,
                    threadState: ThreadState
                ) -> Bool {
                    // Check if we have a session to optimize
                    guard session != nil else { return false }
                    
                    // Check if optimization is needed
                    let currentUsage = Double(threadState.approximateTokenCount) / Double(threadState.contextWindowSize)
                    guard threadState.shouldOptimizeKVCache(currentUsage: currentUsage) else {
                        return false
                    }
                    
                    // Calculate optimization plan
                    guard let plan = threadState.calculateOptimizationPlan(currentTokens: Int32(threadState.approximateTokenCount)) else {
                        FreeToken.shared.logger("🔴 KV optimization: Could not calculate optimization plan", .warning)
                        return false
                    }
                    
                    FreeToken.shared.logger("🔄 KV optimization: Context usage at \(String(format: "%.1f", currentUsage * 100))% - optimization recommended", .info)
                    FreeToken.shared.logger("🔄 KV optimization plan: preserve start \(plan.preserveFromStart), preserve end \(plan.preserveFromEnd), remove \(plan.removeStartPos)-\(plan.removeEndPos)", .debug)
                    
                    return true
                }
                
                func executeKVCacheOptimization(
                    session: LLMSession,
                    threadState: ThreadState
                ) -> Bool {
                    // Calculate optimization plan
                    guard let plan = threadState.calculateOptimizationPlan(currentTokens: Int32(threadState.approximateTokenCount)) else {
                        FreeToken.shared.logger("🔴 KV optimization: Could not calculate optimization plan", .warning)
                        return false
                    }
                    
                    // Try to get the Context instance to perform KV cache optimization
                    // This requires access to the session's internal context
                    // For now, we'll simulate the optimization by rebuilding with fewer messages
                    
                    FreeToken.shared.logger("⚡ Executing KV cache optimization: removing tokens \(plan.removeStartPos) to \(plan.removeEndPos)", .info)
                    
                    // Calculate which messages to keep based on the optimization plan
                    var optimizedMessages: [Message] = []
                    
                    // Add system message if it exists
                    if let systemMessage = threadState.fullThread.first(where: { $0.role == .system }) {
                        optimizedMessages.append(systemMessage)
                    }
                    
                    // Calculate how many recent messages to preserve based on plan.preserveFromEnd
                    let nonSystemMessages = threadState.fullThread.filter { $0.role != .system }
                    let estimatedTokensPerMessage = Int32(50) // Rough estimate
                    let recentMessagesToKeep = max(2, Int(plan.preserveFromEnd / estimatedTokensPerMessage))
                    
                    // Add recent messages
                    let recentMessages = Array(nonSystemMessages.suffix(recentMessagesToKeep))
                    optimizedMessages.append(contentsOf: recentMessages)
                    
                    // Update threadState to reflect the optimization
                    threadState.loadedMessages = optimizedMessages
                    threadState.lastLoadedIndex = optimizedMessages.count - 1
                    threadState.approximateTokenCount = Int(plan.preserveFromStart + plan.preserveFromEnd)
                    
                    // Update session messages to match optimized state
                    let llmMessages = optimizedMessages.map { message in
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
                    
                    // Replace session messages with optimized set
                    session.messages = llmMessages
                    
                    FreeToken.shared.logger("⚡ KV optimization completed: \(threadState.fullThread.count) → \(optimizedMessages.count) messages (~\(String(format: "%.1f", Double(threadState.approximateTokenCount) / Double(threadState.contextWindowSize) * 100))% context usage)", .info)
                    
                    return true
                }
                
                func updatePositionTracking(
                    session: LLMSession,
                    threadState: ThreadState
                ) {
                    // This would be called after AI generation to update position tracking
                    // For now, we'll estimate based on message content
                    
                    var estimatedPosition: Int32 = 0
                    for (index, message) in threadState.loadedMessages.enumerated() {
                        let messageTokens = Int32(max(1, message.content.count / 4))
                        let startPos = estimatedPosition
                        let endPos = estimatedPosition + messageTokens - 1
                        
                        threadState.trackMessageTokens(messageIndex: index, startPos: startPos, endPos: endPos)
                        estimatedPosition += messageTokens
                    }
                    
                    threadState.updateCurrentPosition(position: estimatedPosition)
                }
            }
            
            enum AppendStrategy {
                case appendSafely(messages: [Message])
                case rebuildRequired(reason: String)
                case noActionNeeded
                case kvCacheOptimization
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
            
            func setLoadedState(_ loadedState: AIModelLoadingState) {
                self.loadedState = loadedState
            }
            
            func getLoadedState() -> AIModelLoadingState {
                return loadedState
            }
            
            func getDownloadState() -> DownloadState {
                return downloadState
            }
            
            func downloadModel(progress: @escaping @Sendable (_ progress: Double) async -> Void) async throws {
                // Check if already downloaded
                if getDownloadState() == .downloaded {
                    await progress(1.0)
                    return
                }
                
                // Create model object for downloading (even if not loaded)
                let model: LLMSession.DownloadModel
                if let existingModel = self.model {
                    model = existingModel
                } else {
                    // Create a model just for downloading
                    guard let modelInitOptions = self.modelInitOptions else {
                        throw FreeTokenError.aiModelNotLoaded
                    }
                    model = try modelFactory(initOptions: modelInitOptions)
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
                promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig,
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
                var session: LLMSession
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
                
                if let aiRunConfig = aiRunConfig, (aiRunConfig.temperature != nil || aiRunConfig.topK != nil || aiRunConfig.topP != nil || aiRunConfig.contextWindowSize != nil), let modelInitOptions = modelInitOptions {
                    isNewSession = true
                    // AI Run Config provided, initialize a model for the cache.
                    let config = modelInitOptions.configuration
                    let nCTX = aiRunConfig.contextWindowSize ?? config.nCTX
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
                
                // Get context window size and max generation tokens  
                let contextWindowSize = aiRunConfig?.contextWindowSize ?? modelInitOptions?.configuration.nCTX ?? 2048
                let maxGenerationTokens = aiRunConfig?.maxGenerationTokens ?? 512
                
                // Process Messages (all except the last one which becomes the prompt)
                // The 'messages' parameter here are already the prepared messages from sendMessagesToAI
                let conversationMessages = Array(messages.dropLast())
                
                // Get or create thread state
                let threadState = threadStateManager.getOrCreateThreadState(
                    threadId: runIdentifier,
                    fullThread: conversationMessages,
                    contextWindowSize: contextWindowSize,
                    maxGenerationTokens: maxGenerationTokens
                )
                
                // Log initial context window status
                let contextUsage = Double(threadState.approximateTokenCount) / Double(contextWindowSize) * 100
                FreeToken.shared.logger("📊 Context Window Status: \(threadState.approximateTokenCount)/\(contextWindowSize) tokens (\(String(format: "%.1f", contextUsage))% used)", .info)
                FreeToken.shared.logger("📊 Reserved for generation: \(maxGenerationTokens) tokens", .info)
                FreeToken.shared.logger("📊 Thread: \(conversationMessages.count) messages in full thread, \(threadState.loadedMessages.count) messages loaded", .info)
                
                if isNewSession {
                    // For new sessions, use thread state manager to create optimized session
                    FreeToken.shared.logger("🧠 Creating new AI session for thread \(runIdentifier)", .info)
                    session = try threadStateManager.executeTruncatedRebuild(
                        threadState: threadState,
                        model: model,
                        promptTemplateConfig: promptTemplateConfig
                    )
                } else {
                    // Use ThreadStateManager to determine the best strategy
                    let currentSession = cachedSession?.session
                    let strategy = threadStateManager.planMessageStrategy(
                        threadState: threadState,
                        currentSession: currentSession,
                        fullThread: conversationMessages
                    )
                    
                    switch strategy {
                    case .noActionNeeded:
                        session = currentSession!
                        FreeToken.shared.logger("✅ ThreadState: No changes needed, reusing session with \(session.messages.count) messages", .info)
                        let usage = Double(threadState.approximateTokenCount) / Double(contextWindowSize) * 100
                        FreeToken.shared.logger("📊 Context usage after strategy: \(String(format: "%.1f", usage))%", .info)
                        
                    case .appendSafely(let newMessages):
                        session = currentSession!
                        let newLLMMessages = newMessages.map { message in
                            let attachments = message.attachments?.compactMap { attachment -> LLMAttachment? in
                                guard attachment.type == .image else { return nil }
                                
                                FreeToken.shared.logger("🖼️ Converting image attachment: \(attachment.data.count) bytes, type: \(attachment.contentType)", .debug)
                                
                                #if canImport(UIKit)
                                if let image = UIImage(data: attachment.data) {
                                    FreeToken.shared.logger("🖼️ Successfully created UIImage: \(image.size)", .debug)
                                    return LLMAttachment.image(image)
                                }
                                #elseif canImport(AppKit)
                                if let image = NSImage(data: attachment.data) {
                                    FreeToken.shared.logger("🖼️ Successfully created NSImage: \(image.size)", .debug)
                                    return LLMAttachment.image(image)
                                }
                                #endif
                                
                                if let inputImage = LLMInputImage(data: attachment.data) {
                                    FreeToken.shared.logger("🖼️ Successfully created LLMInputImage", .debug)
                                    return LLMAttachment.image(inputImage)
                                }
                                
                                FreeToken.shared.logger("🖼️ Failed to create any image type from attachment data", .error)
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
                        
                        // Append new messages
                        for newMessage in newLLMMessages {
                            session.messages.append(newMessage)
                        }
                        
                        // Update thread state to reflect appended messages
                        threadState.syncLoadedSession(session.messages)
                        
                        FreeToken.shared.logger("✅ ThreadState: Safely appended \(newMessages.count) messages to session (now \(session.messages.count) messages)", .info)
                        let usage = Double(threadState.approximateTokenCount) / Double(contextWindowSize) * 100
                        FreeToken.shared.logger("📊 Context usage after append: \(String(format: "%.1f", usage))%", .info)
                        
                    case .kvCacheOptimization:
                        session = currentSession!
                        let optimizationSuccess = threadStateManager.executeKVCacheOptimization(
                            session: session,
                            threadState: threadState
                        )
                        
                        if !optimizationSuccess {
                            FreeToken.shared.logger("⚠️ KV cache optimization failed, falling back to session rebuild", .warning)
                            session = try threadStateManager.executeTruncatedRebuild(
                                threadState: threadState,
                                model: model,
                                promptTemplateConfig: promptTemplateConfig
                            )
                        } else {
                            FreeToken.shared.logger("⚡ KV cache optimization successful", .info)
                            shouldOverrideCache = true  // Ensure optimized session is cached
                            let usage = Double(threadState.approximateTokenCount) / Double(contextWindowSize) * 100
                            FreeToken.shared.logger("📊 Context usage after KV optimization: \(String(format: "%.1f", usage))%", .info)
                        }
                        
                    case .rebuildRequired(let reason):
                        FreeToken.shared.logger("🔄 ThreadState: Rebuilding session due to: \(reason)", .warning)
                        session = try threadStateManager.executeTruncatedRebuild(
                            threadState: threadState,
                            model: model,
                            promptTemplateConfig: promptTemplateConfig
                        )
                        shouldOverrideCache = true  // Ensure rebuilt session is cached
                        let usage = Double(threadState.approximateTokenCount) / Double(contextWindowSize) * 100
                        FreeToken.shared.logger("📊 Context usage after rebuild: \(String(format: "%.1f", usage))%", .info)
                    }
                }
                
                if shouldOverrideCache {
                    self.cachedSession = SessionCache(runIdentifier: runIdentifier, session: session)
                }
                
                // Log final context state before generation
                let finalUsage = Double(threadState.approximateTokenCount) / Double(contextWindowSize) * 100
                FreeToken.shared.logger("📊 Starting generation with context: \(threadState.approximateTokenCount)/\(contextWindowSize) tokens (\(String(format: "%.1f", finalUsage))%)", .info)
                FreeToken.shared.logger("📊 Prompt: \"\(promptMessage.content.prefix(50))...\"", .debug)
                FreeToken.shared.logger("🔍 DEBUGGING: Model code: \(self.modelInitOptions?.huggingFaceID ?? "unknown")", .info)
                FreeToken.shared.logger("🔍 DEBUGGING: Model type: \(self.modelInitOptions?.modelType ?? .llamaCpp)", .info)
                
                // Check for vision requirements before streaming
                let hasImages = messages.contains { message in
                    message.attachments?.contains { $0.type == .image } == true
                }
                if hasImages {
                    FreeToken.shared.logger("🔍 About to stream response with image attachments - checking vision model compatibility", .info)
                }
                
                
                // Check if any message in the conversation has image attachments
                let hasImagesInConversation = messages.contains { message in
                    message.attachments?.contains { $0.type == .image } == true
                }
                
                if hasImagesInConversation {
                    FreeToken.shared.logger("🖼️ ✅ Conversation contains image attachments - using full conversation context", .info)
                    
                    // Log details about which messages have images
                    for (index, message) in messages.enumerated() {
                        let imageCount = message.attachments?.filter { $0.type == .image }.count ?? 0
                        if imageCount > 0 {
                            FreeToken.shared.logger("🖼️ Message \(index) (\(message.role)): \(imageCount) image(s)", .info)
                        }
                    }
                }
                
                // Convert FreeToken attachments to LLMAttachments for the current prompt
                let llmAttachments: [LLMAttachment] = (promptMessage.attachments ?? []).compactMap { attachment in
                    switch attachment.type {
                    case .image:
                        #if os(iOS) || os(tvOS)
                        if let image = UIImage(data: attachment.data) {
                            return LLMAttachment.image(image)
                        }
                        #elseif os(macOS)
                        if let image = NSImage(data: attachment.data) {
                            return LLMAttachment.image(image)
                        }
                        #endif
                        return nil
                    }
                }
                
                return session.streamResponse(to: promptMessage.content, attachments: llmAttachments)
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
            
            func willCreateNewSession(
                runIdentifier: String, 
                noContextCache: Bool,
                aiRunConfig: AIRunConfig? = nil
            ) -> Bool {
                if noContextCache {
                    return true
                }
                
                if cachedSession == nil || cachedSession?.runIdentifier != runIdentifier {
                    return true
                }
                
                if let modelInitOptions = modelInitOptions,
                   shouldEvacuateCache(memoryRequirement: modelInitOptions.memoryRequirement) {
                    return true
                }
                
                if let aiRunConfig = aiRunConfig,
                   (aiRunConfig.temperature != nil || aiRunConfig.topK != nil || 
                    aiRunConfig.topP != nil || aiRunConfig.contextWindowSize != nil) {
                    return true
                }
                
                return false
            }
        }
        
        init(modelConfig: Codings.AiModelResponse, clientVersion: String, deviceMode: DeviceMode) {
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
            self.taskQueue = AITaskQueue(isTurboMode: deviceMode == .compatibilityQuickStartMode)
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
            
            // First initialize the engine to set up modelInitOptions
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
                
                _ = try await stateManager.downloadModel { progress in
                    Task { @MainActor in
                        progressCallback?(progress)
                    }
                }
                FreeToken.shared.logger("⬇️ AI model downloaded successfully", .info)
                
                // Now try to load the model to verify it works
                let loadResult = await loadModel()
                
                switch loadResult {
                case .success(_):
                    FreeToken.shared.logger("🧠 AI engine initialized successfully", .info)
                    return true
                case .failure(let error):
                    FreeToken.shared.logger("🔴 Failed to load AI model after download: \(error.localizedDescription)", .error)
                    return true // Still return true because download succeeded
                }
                
            } catch {
                FreeToken.shared.logger("🔴 Error downloading AI model: \(error.localizedDescription)", .error)
                _ = await self.stateManager.setDownloadState(.failed(error: error.localizedDescription))
                return false
            }
        }
        
        func loadModel() async -> Result<AIModelLoadingState, FreeTokenError> {
            if await self.stateManager.getLoadedState() == .loaded {
                return .success(.loaded)
            }
            
            if await self.stateManager.getLoadedState() == .loading {
                return .success(.loading) // Already loading, no need to reinitialize
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
                
                // Perform invisible warm-up to ensure model is ready
                _ = await performInvisibleWarmup()
                await self.stateManager.setLoadedState(.loaded)
                
                return .success(.loaded)
            } catch {
                FreeToken.shared.logger("🔴 Error loading model: \(error.localizedDescription)", .error)
                await self.stateManager.setLoadedState(.failed)
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
        
        private func performInvisibleWarmup() async -> Bool {
            let warmupConfig = AIRunConfig(
                maxGenerationTokens: 5,
                temperature: 0.1
            )
            
            let warmupMessage = [Message(role: .user, content: "What is 2+2?")]
            
            do {
                let _ = try await sendMessagesToAI(
                    messages: warmupMessage,
                    runIdentifier: "warmup-\(UUID().uuidString)",
                    noContextCache: true,
                    aiRunConfig: warmupConfig
                )
                FreeToken.shared.logger("💾 Model warm-up completed successfully", .info)
                return true
            } catch {
                FreeToken.shared.logger("💾 Model warm-up failed: \(error.localizedDescription)", .error)
                return false
            }
        }
        
        func sendMessagesToAI(messages: [Message], runIdentifier: String, noContextCache: Bool = false, aiRunConfig: AIRunConfig? = nil, tokenStream: Optional<@Sendable (_ tokens: String) async -> Void> = nil) async throws -> (response: String, usage: TokenUsage?) {
            if await self.stateManager.getLoadedState() != .loaded {
                _ = await loadModel()
            }
            
            guard messages.count > 0 else {
                throw FreeTokenError.noMessagesToSend
            }
            
            // Note: Vision support is checked during inference by LocalLLMClient
            // The client will throw appropriate errors if images are used with non-vision models

            // Make sure we're not going to blow out the memory! 
            _ = await FreeToken.shared.aiModelsManager.unloadAllOtherModels(except: modelCode)
            
            // Get context window size from current configuration
            let contextWindowSize = aiRunConfig?.contextWindowSize ?? modelConfig.nCTX
            
            // Get the current model for token counting
            let currentModel = await stateManager.model
            
            // Determine if this will create a new session
            let willCreateNewSession = await stateManager.willCreateNewSession(
                runIdentifier: runIdentifier,
                noContextCache: noContextCache,
                aiRunConfig: aiRunConfig
            )
            
            // Debug: Log the incoming messages
            FreeToken.shared.logger("🔍 SEND MESSAGES DEBUG: Processing \(messages.count) messages", .info)
            for (index, message) in messages.enumerated() {
                let imageCount = message.attachments?.filter { $0.type == .image }.count ?? 0
                FreeToken.shared.logger("🔍 SEND MESSAGES DEBUG: Message \(index) (\(message.role)): \(imageCount) image(s)", .info)
            }
            
            let preparedMessages: [Message] = try MessagePrep(
                messages: messages, 
                promptTemplateConfig: promptTemplateConfig,
                contextWindowSize: contextWindowSize,
                model: currentModel,
                isNewSession: willCreateNewSession
            ).prepareMessages()
            
            // Debug: Log the prepared messages
            FreeToken.shared.logger("🔍 PREPARED MESSAGES DEBUG: After prep: \(preparedMessages.count) messages", .info)
            for (index, message) in preparedMessages.enumerated() {
                let imageCount = message.attachments?.filter { $0.type == .image }.count ?? 0
                FreeToken.shared.logger("🔍 PREPARED MESSAGES DEBUG: Message \(index) (\(message.role)): \(imageCount) image(s)", .info)
            }
            
            let aiResults = AIResults()
            
            if let maxTokens = aiRunConfig?.maxGenerationTokens {
                await aiResults.setMaxTokenCount(maxTokens)
            }
            
            // Generate response using the AIStateManager
            let task = Task {
                _ = try await taskQueue.enqueue {
                    do {
                        let maxTokenCount = await aiResults.maxTokenCount
                        for try await value in try await self.stateManager.generateResponse(for: preparedMessages, runIdentifier: runIdentifier, promptTemplateConfig: self.promptTemplateConfig, aiRunConfig: aiRunConfig, noContextCache: noContextCache) {
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
                        FreeToken.shared.logger("Error generating response: \(error.localizedDescription)", .error)
                        FreeToken.shared.logger("Error type: \(type(of: error))", .error)
                        
                        // Check if this might be a vision-related error
                        let hasImages = messages.contains { message in
                            message.attachments?.contains { $0.type == .image } == true
                        }
                        if hasImages {
                            FreeToken.shared.logger("🔍 Vision error detected: Message contains image attachments", .error)
                            FreeToken.shared.logger("🔍 Error details: \(error)", .error)
                            
                            // Check if the error suggests vision capability issues
                            let errorDescription = error.localizedDescription.lowercased()
                            if errorDescription.contains("vision") || 
                               errorDescription.contains("image") || 
                               errorDescription.contains("multimodal") ||
                               errorDescription.contains("no mmproj file") {
                                FreeToken.shared.logger("🔍 Likely vision capability error - model may not support images", .error)
                                throw FreeTokenError.visionModelRequired
                            }
                        }
                        
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
