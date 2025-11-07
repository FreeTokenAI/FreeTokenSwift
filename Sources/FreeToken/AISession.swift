//
//  AISession.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/5/25.
//

import Foundation

extension FreeToken {
    
    public protocol ChatSessionProtocol {
        func prewarm() async
        func createMessageThread() async throws -> MessageThread
        func addMessage(message: Message) async throws -> Message
        func getMessages() async throws -> [Message]
        func generateNewMessage(
            documentSearchScope: String?,
            privateDocumentStoreIDs: [String]?,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String>
        ) async throws -> Message
        func countTokens(for text: String) async throws -> Int
        func unload() async
        func load() async throws
    }
    
    internal protocol ChatSessionInternalProtocol: ChatSessionProtocol {
        var runID: String { get }
        var modelCode: String { get }

        func updateModelContext() async throws
        func kvTokenCount() async -> Int
        func generate(for runID: String) async throws -> AsyncThrowingStream<String, Error>
        func getLastGenerationMetrics() async -> LlamaManager.GenerationMetrics?
        func saveSession() async throws
    }
    
    
    public protocol CompletionSessionProtocol {
        func generateCompletion(from text: String, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>) async throws -> Completion
        func unload() async
        func load() async throws
    }
    
    
    // Notes:
    // For API consistency - this can be for Local Models or Cloud Models
    // Goal:
    // - Put memory management in the hands of the developer?
    //   - You checkout a memory chunk, use it for chat - then free it when done.
    //   - You checkout a memory chunk for use with completion - then free when done.
    //   - If not enough memory to load the model - it throws a warning and falls back to the cloud.
    //
    //
    // - ChatSession - holds state, to get rid of stateless API
    //   - init(threadID: Optional, runConfig: Optional)
    //   - addMessage
    //   - getMessages
    //   - runThread
    //   - stopGeneration
    //   - countTokens
    // - CompletionSession
    //   - runCompletion
    //   - countTokens
    //   - stopGeneration
    
    // Local chat session that can fall back to the cloud when needed.
    public class ChatSession: ChatSessionInternalProtocol, @unchecked Sendable {
        let client: FreeToken
        var messageThreadID: String?
        let runLocation: RunLocation
        var isPrewarmed: Bool = false
        
        let deviceManager: DeviceManager
        let messagesManager: MessagesManager
        let messagePreparer: MessagePreparer
        let toolDefinitionsManager: ToolDefinitionsManager
        let jsonToolResults: Bool
        let queue: AITaskQueue
        var model: LlamaManager
        let systemMessage: Message
        let toolAccess: [ToolRunMask]
        let runID: String = UUID().uuidString
        let modelCode: String
        let config: AIModelConfiguration
        let modelPath: String
        let repoName: String
        
        internal init(
            client: FreeToken,
            messagePreparer: MessagePreparer,
            systemMessage: Message,
            runLocation: RunLocation,
            config: AIModelConfiguration,
            modelPath: String,
            modelRepoName: String,
            deviceManager: DeviceManager,
            messagesManager: MessagesManager,
            toolDefinitionsManager: ToolDefinitionsManager,
            toolAccess: [ToolRunMask] = [.allowAll],
            jsonToolResults: Bool,
            modelCode: String,
            queue: AITaskQueue,
            messageThreadID: String? = nil
        ) async throws {
            self.client = client
            self.messagePreparer = messagePreparer
            self.deviceManager = deviceManager
            self.queue = queue
            self.messageThreadID = messageThreadID
            self.runLocation = runLocation
            self.systemMessage = systemMessage
            self.messagesManager = messagesManager
            self.toolDefinitionsManager = toolDefinitionsManager
            self.toolAccess = toolAccess
            self.jsonToolResults = jsonToolResults
            self.modelCode = modelCode
            self.config = config
            self.modelPath = modelPath
            self.repoName = modelRepoName
            
            // Initialize Model
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
                threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                batchSize: config.batchSize,
                threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
            )
            
            self.model = try LlamaManager(modelPath: modelPath, options: options, repoName: modelRepoName)
            
            await self.prewarm()
        }
        
        public func prewarm() async {
            guard deviceManager.availableMemoryForRequestedSize() else {
                client.logger("⚠️ Not enough available memory to load model", .warning)
                return
            }
            
            if isPrewarmed {
                return
            }
            
            if let messageThreadID = self.messageThreadID {
                // There is a thread - prewarm with existing messages
                
                await messagesManager.getMessageThread(id: messageThreadID) { messageThread, _ in
                    do {
                        try await self.model.loadSession(fileName: "\(messageThreadID).bin", systemMessage: self.systemMessage, runID: self.runID)
                        self.client.logger("✅ Loaded existing session from disk for prewarming.", .info)
                    } catch {
                        self.client.logger("Failed to load session from disk. Likely does not exist. Proceeding with new creation.", .info)
                    }
                    
                    do {
                        try await self.model.updateContext(messages: messageThread.messages, runID: self.runID)
                        self.client.logger("✅ Updated model context with existing messages for prewarming.", .info)
                    } catch {
                        // Failed to prewarm
                        self.client.logger("❌ Failed to update model session context: \(error.localizedDescription)", .error)
                        return
                    }
                    
                    self.isPrewarmed = true
                    
                    self.client.logger("✅ Successfully prewarmed model session with existing message thread.", .info)
                    
                    // Update the session after loading / updating context
                    try? await self.model.saveSession(fileName: "\(messageThreadID).bin")
                } failure: { error in
                    self.client.logger("❌ Failed to retrieve message thread for prewarming: \(error.localizedDescription)", .error)
                    return
                }
            } else {
                // There is no thread - just prewarm an empty session
                do {
                    try await model.prewarmSession(systemMessage: self.systemMessage, runID: runID)
                    self.isPrewarmed = true
                    client.logger("✅ Successfully prewarmed empty model session.", .info)
                } catch {
                    // Prewarm buffer file does not already exist, create it
                    do {
                        try await model.generatePrewarmBuffer(systemMessage)
                    } catch {
                        client.logger("❌ Failed to prewarm empty model session: \(error.localizedDescription)", .error)
                        return
                    }
                }
            }
        }
        
        public func createMessageThread() async throws -> MessageThread {
            guard messageThreadID == nil else {
                client.logger("❌ Cannot create new message thread - session already has a thread ID.", .error)
                throw FreeTokenError.error(message: "Message thread already exists on this chat session. Create a new one to start a new thread.", code: 10001)
            }
            
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    await client.createMessageThread(toolAccess: toolAccess) { messageThread in
                        self.messageThreadID = messageThread.id
                        continuation.resume(returning: messageThread)
                    } error: { error in
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        public func addMessage(message: Message) async throws -> Message {
            if let messageThreadID = messageThreadID {
                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await client.addMessageToThread(id: messageThreadID, message: message) { message in
                            continuation.resume(returning: message)
                        } error: { error in
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }
        
        public func getMessages() async throws -> [Message] {
            if let messageThreadID = messageThreadID {
                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await client.getMessageThread(id: messageThreadID) { messageThread in
                            continuation.resume(returning: messageThread.messages)
                        } error: { error in
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }

        public func generateNewMessage(
            documentSearchScope: String? = nil,
            privateDocumentStoreIDs: [String]? = nil,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil
        ) async throws -> Message {
            guard messageThreadID != nil else {
                client.logger("❌ Cannot run chat thread - message thread is not on session.", .error)
                throw FreeTokenError.messageThreadNotCreated
            }
            
            try await chatStatusStream?(nil, .starting)
            
            // Determine Run Location (local or fallback to cloud)
            var effectiveRunLocation = runLocation
            if runLocation == .automatic {
                if deviceManager.isAICapable && deviceManager.availableMemoryForRequestedSize() {
                    // Run Locally
                    client.logger("✅ Local AI run possible - proceeding with local generation.", .info)
                    effectiveRunLocation = .localRun
                    try await chatStatusStream?(nil, .sending_to_local_ai)
                } else {
                    effectiveRunLocation = .cloudRun
                }
            }
            
            let cloudSession = CloudChatSession(client: client, messsagePreparer: messagePreparer, config: config, messagesManager: messagesManager, toolDefinitionsManager: toolDefinitionsManager, jsonToolResults: jsonToolResults, modelCode: modelCode)
            
            if effectiveRunLocation == .cloudRun {
                client.logger("⚠️ Local AI run not possible, falling back to cloud.", .info)
                try await chatStatusStream?(nil, .cloud_fallback)
                
                return try await cloudSession.generateNewMessage(documentSearchScope: documentSearchScope, privateDocumentStoreIDs: privateDocumentStoreIDs, chatStatusStream: chatStatusStream, toolUseHandler: toolUseHandler)
            }
            
            try await self.updateModelContext()
            
            let workflowSteps: [WorkflowStep.Type] = [
                RunLocalChatSession.self, // Run Generation
                ChatSessionRunToolCalls.self // Handle Tool Calls
            ]
            
            let workflowContext = ChatSessionRunWorkflowContext(
                chatSession: self,
                documentSearchScope: documentSearchScope,
                privateDocumentStoreIDs: privateDocumentStoreIDs,
                chatStatusStream: chatStatusStream,
                toolUseHandler: toolUseHandler,
                jsonToolResults: jsonToolResults,
                toolDefinitionsManager: toolDefinitionsManager
            )
            
            let workflow = WorkflowManager(context: workflowContext, steps: workflowSteps)
            
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        try await queue.enqueue(name: "Run New Message", runLocation: .localRun) {
                            await workflow.execute { context in
                                let finalContext = context as! ChatSessionRunWorkflowContext
                                if let lastMessage = finalContext.lastGeneratedMessage {
                                    // Save session after generation
                                    continuation.resume(returning: lastMessage)
                                } else {
                                    continuation.resume(throwing: FreeTokenError.failedToRunAIWithError(message: "Failed to Generate Message"))
                                }
                            } failure: { error, context in
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            } catch {
                // Optional Cloud Fallback
                if runLocation == .automatic {
                    client.logger("⚠️ Local generation failed, falling back to Cloud: \(error.localizedDescription)", .warning)
                    try await chatStatusStream?(nil, .cloud_fallback)
                    
                    return try await cloudSession.generateNewMessage(documentSearchScope: documentSearchScope, privateDocumentStoreIDs: privateDocumentStoreIDs, chatStatusStream: chatStatusStream, toolUseHandler: toolUseHandler)
                } else {
                    throw error
                }
            }
        }

        public func countTokens(for text: String) async throws -> Int {
            return try await self.model.tokenize(text).count
        }
        
        public func unload() async {
            await model.unload()
            isPrewarmed = false
        }
        
        public func load() async throws {
            await unload()
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
                threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                batchSize: config.batchSize,
                threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
            )
            
            self.model = try LlamaManager(modelPath: modelPath, options: options, repoName: repoName)
            
            await self.prewarm()
        }
        
        internal func updateModelContext() async throws {
            let messages = try await getMessages()
            let preparedMessages = try messagePreparer.prepareMessages(messages)
            try await self.model.updateContext(messages: preparedMessages, runID: runID)
        }
        
        internal func saveSession() async throws {
            if let messageThreadID {
                try await self.model.saveSession(fileName: "\(messageThreadID).bin")
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }
        
        internal func kvTokenCount() async -> Int {
            return await self.model.templatedTokenCount
        }
        
        internal func generate(for runID: String) async throws -> AsyncThrowingStream<String, any Error> {
            return try await self.model.generate(runID: runID)
        }
        
        internal func getLastGenerationMetrics() async -> LlamaManager.GenerationMetrics? {
            return await self.model.getLastGenerationMetrics()
        }
        
    }
    
    // Cloud Only Chat Session
    public class CloudChatSession: ChatSessionInternalProtocol, @unchecked Sendable {
        let client: FreeToken
        let messagePreparer: MessagePreparer
        var messageThreadID: String?
        var config: AIModelConfiguration
        var runID: String = UUID().uuidString
        
        let messagesManager: MessagesManager
        let toolDefinitionsManager: ToolDefinitionsManager
        let jsonToolResults: Bool
        let toolAccess: [ToolRunMask]
        let modelCode: String
        
        internal init(
            client: FreeToken,
            messsagePreparer: MessagePreparer,
            config: AIModelConfiguration,
            messagesManager: MessagesManager,
            toolDefinitionsManager: ToolDefinitionsManager,
            jsonToolResults: Bool,
            modelCode: String,
            toolAccess: [ToolRunMask] = [.allowAll],
            messageThreadID: String? = nil
        ) {
            self.client = client
            self.messagePreparer = messsagePreparer
            self.config = config
            self.messagesManager = messagesManager
            self.toolDefinitionsManager = toolDefinitionsManager
            self.jsonToolResults = jsonToolResults
            self.modelCode = modelCode
            self.messageThreadID = messageThreadID
            self.toolAccess = toolAccess
        }
        
        public func prewarm() async {
            // No-op for cloud session
            client.logger("ℹ️ Prewarm not required for Cloud Sessions.", .info)
        }
        
        public func load() async throws {
            client.logger("ℹ️ Loading is not required for Cloud Sessions.", .info)
        }
        
        public func unload() async {
            client.logger("ℹ️ Unloading is not required for Cloud Sessions.", .info)
        }
        
        public func createMessageThread() async throws -> MessageThread {
            guard messageThreadID == nil else {
                client.logger("❌ Cannot create new message thread - session already has a thread ID.", .error)
                throw FreeTokenError.error(message: "Message thread already exists on this chat session. Create a new one to start a new thread.", code: 10001)
            }
            
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    await client.createMessageThread(toolAccess: toolAccess) { messageThread in
                        self.messageThreadID = messageThread.id
                        continuation.resume(returning: messageThread)
                    } error: { error in
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        public func addMessage(message: Message) async throws -> Message {
            if let messageThreadID = messageThreadID {
                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await client.addMessageToThread(id: messageThreadID, message: message) { message in
                            continuation.resume(returning: message)
                        } error: { error in
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }
        
        public func getMessages() async throws -> [Message] {
            if let messageThreadID = messageThreadID {
                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await client.getMessageThread(id: messageThreadID) { messageThread in
                            continuation.resume(returning: messageThread.messages)
                        } error: { error in
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }

        public func generateNewMessage(
            documentSearchScope: String? = nil,
            privateDocumentStoreIDs: [String]? = nil,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil
        ) async throws -> Message {
            guard messageThreadID != nil else {
                client.logger("❌ Cannot run chat thread - message thread ID not set.", .error)
                throw FreeTokenError.messageThreadNotCreated
            }
            
            try await chatStatusStream?(nil, .starting)
            
            
            let workflowSteps: [WorkflowStep.Type] = [
                RunCloudChatSession.self, // Run Generation
                ChatSessionRunToolCalls.self // Handle Tool Calls
            ]
            
            let aiRunConfig = AIRunConfig(
                maxGenerationTokens: self.config.maxTokenCount,
                contentWindowSize: self.config.nCTX,
                topK: self.config.topK,
                topP: self.config.topP,
                temperature: self.config.temperature
            )
            
            let workflowContext = CloudChatSessionRunWorklowContext(
                chatSession: self,
                documentSearchScope: documentSearchScope,
                privateDocumentStoreIDs: privateDocumentStoreIDs,
                modelCode: self.modelCode,
                aiRunConfig: aiRunConfig,
                chatStatusStream: chatStatusStream,
                toolUseHandler: toolUseHandler,
                jsonToolResults: jsonToolResults,
                toolDefinitionsManager: toolDefinitionsManager
            )
            
            let workflow = WorkflowManager(context: workflowContext, steps: workflowSteps)
            
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    await workflow.execute { context in
                        let finalContext = context as! CloudChatSessionRunWorklowContext
                        if let lastMessage = finalContext.lastGeneratedMessage {
                            // Save session after generation
                            continuation.resume(returning: lastMessage)
                        } else {
                            continuation.resume(throwing: FreeTokenError.failedToRunAIWithError(message: "Failed to Generate Message"))
                        }
                    } failure: { error, context in
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        public func countTokens(for text: String) async throws -> Int {
            throw FreeTokenError.error(message: "Counting tokens is not supported on cloud models", code: 10002)
        }
        
        internal func updateModelContext() async throws {
            // No-op for cloud session
            client.logger("ℹ️ Updating model context is not required for Cloud Sessions.", .info)
        }
        
        internal func kvTokenCount() async -> Int {
            return 0
        }
        
        internal func generate(for runID: String) async throws -> AsyncThrowingStream<String, any Error> {
            throw FreeTokenError.error(message: "Direct generation is not supported on cloud models", code: 10003)
        }
        
        func getLastGenerationMetrics() async -> FreeToken.LlamaManager.GenerationMetrics? {
            return nil
        }
        
        func saveSession() async throws {
            // No-op for cloud session
            client.logger("ℹ️ Saving session is not required for Cloud Sessions.", .info)
        }
    }
    
    public class CompletionSession: CompletionSessionProtocol, @unchecked Sendable {
        let client: FreeToken
        let runLocation: RunLocation
        
        let deviceManager: DeviceManager
        let queue: AITaskQueue
        var model: LlamaManager
        let runID: String = UUID().uuidString
        let modelCode: String
        let config: AIModelConfiguration
        let modelPath: String
        let repoName: String
        
        internal init(
            client: FreeToken,
            runLocation: RunLocation,
            config: AIModelConfiguration,
            modelPath: String,
            modelRepoName: String,
            deviceManager: DeviceManager,
            modelCode: String,
            queue: AITaskQueue
        ) throws {
            self.client = client
            self.deviceManager = deviceManager
            self.queue = queue
            self.runLocation = runLocation
            self.modelCode = modelCode
            self.config = config // Keep this for cloud fallbacks
            self.modelPath = modelPath
            self.repoName = modelRepoName
            
            // Initialize Model
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
                threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                batchSize: config.batchSize,
                threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
            )
            
            self.model = try LlamaManager(modelPath: modelPath, options: options, repoName: modelRepoName)
        }
        
        public func generateCompletion(from text: String, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil) async throws -> Completion {
            let message = Message(role: .user, content: text, attachments: nil)
            
            var effectiveRunLocation = runLocation
            if runLocation == .automatic {
                if deviceManager.isAICapable && deviceManager.availableMemoryForRequestedSize() {
                    // Run Locally
                    client.logger("✅ Local AI run possible - proceeding with local generation.", .info)
                    effectiveRunLocation = .localRun
                    try await chatStatusStream?(nil, .sending_to_local_ai)
                } else {
                    effectiveRunLocation = .cloudRun
                }
            }
            
            if effectiveRunLocation == .cloudRun {
                client.logger("⚠️ Local AI run not possible, falling back to cloud.", .info)
                try await chatStatusStream?(nil, .cloud_fallback)
                
                let cloudSession = CloudCompletionSession(client: client, config: config, modelCode: modelCode)
                
                return try await cloudSession.generateCompletion(from: text, chatStatusStream: chatStatusStream)
            }
            
            try await self.model.updateContext(messages: [message], runID: self.runID)
            
            do {
                let (result, tokenUsage) = try await queue.enqueue(name: "Completion Session", runLocation: .localRun) {
                    var resultContent = ""
                    let inputTokensCount = await self.model.templatedTokenCount
                    var tokenCount = 0
                    for try await nextChunk in try await self.model.generate(runID: self.runID) {
                        try await chatStatusStream?(nextChunk, .streaming_tokens)
                        resultContent += nextChunk
                        tokenCount += 1
                    }
                    
                    let generationMetrics = await self.model.getLastGenerationMetrics()
                    
                    // Convert generationMetrics.tokensPersecond to Float from Double
                    let tokensPerSecond = Float(generationMetrics?.tokensPerSecond ?? 0.0)
                    
                    let tokenUsage = TokenUsage(totalTokens: (inputTokensCount + tokenCount), tokensPerSecond: tokensPerSecond, inputTokens: inputTokensCount, outputTokens: tokenCount, modelCode: self.modelCode)
                    return (resultContent, tokenUsage)
                }
                
                return Completion(response: result, tokenUsage: tokenUsage)
            } catch {
                // Cloud fallback if runLocation is .automatic
                if runLocation == .automatic {
                    client.logger("⚠️ Local completion generation failed, falling back to Cloud: \(error.localizedDescription)", .warning)
                    try await chatStatusStream?(nil, .cloud_fallback)
                    
                    let cloudSession = CloudCompletionSession(client: client, config: config, modelCode: modelCode)
                    
                    return try await cloudSession.generateCompletion(from: text, chatStatusStream: chatStatusStream)
                } else {
                    throw error
                }
            }
        }
        
        public func unload() async {
            await model.unload()
        }
        
        public func load() async throws {
            await unload()
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
                threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                batchSize: config.batchSize,
                threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
            )
            
            self.model = try LlamaManager(modelPath: modelPath, options: options, repoName: repoName)
        }
    }
    
    public class CloudCompletionSession: CompletionSessionProtocol, @unchecked Sendable {
        let client: FreeToken
        var config: AIModelConfiguration
        let modelCode: String
        
        internal init(
            client: FreeToken,
            config: AIModelConfiguration,
            modelCode: String
        ) {
            self.client = client
            self.config = config
            self.modelCode = modelCode
        }
        
        public func generateCompletion(from text: String, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil) async throws -> Completion {
            
            let message = Message(role: .user, content: text)
            let messages = [message]
            
            let aiRunConfig = AIRunConfig(
                maxGenerationTokens: self.config.maxTokenCount,
                contentWindowSize: self.config.nCTX,
                topK: self.config.topK,
                topP: self.config.topP,
                temperature: self.config.temperature
            )
            
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    await client.generateCloudChatCompletion(messages: messages, model: modelCode, aiRunConfig: aiRunConfig, chatStatusStream: chatStatusStream) { message in
                        let result = Completion(response: message.content, tokenUsage: message.tokenUsage)
                        continuation.resume(returning: result)
                    } error: { error in
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        public func unload() async {
            client.logger("ℹ️ Unloading is not required for Cloud Completion Sessions.", .info)
        }
        
        public func load() async throws {
            client.logger("ℹ️ Loading is not required for Cloud Completion Sessions.", .info)
        }
        
    }
    
    public class MemoryChatSession: ChatSessionInternalProtocol, @unchecked Sendable {
        var runID: String
        var messages: [Message]
        var isPrewarmed: Bool = false
        var model: LlamaManager
        
        let client: FreeToken
        let messagePreparer: MessagePreparer
        let config: AIModelConfiguration
        let modelPath: String
        let repoName: String
        let deviceManager: DeviceManager
        let toolDefinitionsManager: ToolDefinitionsManager
        let toolAccess: [ToolRunMask]
        let jsonToolResults: Bool
        let modelCode: String
        let queue: AITaskQueue
        let systemMessage: Message
        
        init(
            client: FreeToken,
            messagePreparer: MessagePreparer,
            systemMessage: Message,
            config: AIModelConfiguration,
            modelPath: String,
            modelRepoName: String,
            deviceManager: DeviceManager,
            toolDefinitionsManager: ToolDefinitionsManager,
            toolAccess: [ToolRunMask] = [.allowAll],
            jsonToolResults: Bool,
            modelCode: String,
            queue: AITaskQueue,
            runID: String = UUID().uuidString,
            messages: [Message] = []
        ) async {
            self.client = client
            self.messagePreparer = messagePreparer
            self.config = config
            self.modelPath = modelPath
            self.repoName = modelRepoName
            self.deviceManager = deviceManager
            self.toolDefinitionsManager = toolDefinitionsManager
            self.toolAccess = toolAccess
            self.jsonToolResults = jsonToolResults
            self.modelCode = modelCode
            self.queue = queue
            self.systemMessage = systemMessage
            self.runID = runID
            self.messages = messages
            
            self.model = try! LlamaManager(
                modelPath: modelPath,
                options: LlamaInitOptions(
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
                    threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                    batchSize: config.batchSize,
                    threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
                ),
                repoName: modelRepoName
            )
            
            _ = try? await self.addMessage(message: systemMessage)
            await self.prewarm()
        }
        
        public func prewarm() async {
            guard deviceManager.availableMemoryForRequestedSize() else {
                client.logger("⚠️ Not enough available memory to load model", .warning)
                return
            }
            
            if isPrewarmed {
                return
            }
            
            if messages.count > 0 {
                do {
                    try await self.model.loadSession(fileName: "local_chat_\(runID).bin", systemMessage: self.systemMessage, runID: self.runID)
                    self.client.logger("✅ Loaded existing session from disk for prewarming.", .info)
                } catch {
                    self.client.logger("Failed to load session from disk. Likely does not exist. Proceeding with new creation.", .info)
                }
                
                do {
                    try await self.model.updateContext(messages: messages, runID: self.runID)
                    self.client.logger("✅ Updated model context with existing messages for prewarming.", .info)
                } catch {
                    // Failed to prewarm
                    self.client.logger("❌ Failed to update model session context: \(error.localizedDescription)", .error)
                    return
                }
                
                self.isPrewarmed = true
                
                self.client.logger("✅ Successfully prewarmed model session with existing message thread.", .info)
                
                // Update the session after loading / updating context
                try? await self.model.saveSession(fileName: "local_chat_\(runID).bin")
            } else {
                // There is no thread - just prewarm an empty session
                do {
                    try await model.prewarmSession(systemMessage: self.systemMessage, runID: runID)
                    self.isPrewarmed = true
                    client.logger("✅ Successfully prewarmed empty model session.", .info)
                } catch {
                    // Prewarm buffer file does not already exist, create it
                    do {
                        try await model.generatePrewarmBuffer(systemMessage)
                    } catch {
                        client.logger("❌ Failed to prewarm empty model session: \(error.localizedDescription)", .error)
                        return
                    }
                }
            }
        }
        
        public func createMessageThread() async throws -> MessageThread {
            throw FreeTokenError.error(message: "Creating message threads is not supported in MemoryChatSession", code: 10004)
        }
        
        public func addMessage(message: Message) async throws -> Message {
            self.messages.append(message)
            return message
        }
        
        public func getMessages() async throws -> [Message] {
            return self.messages
        }

        public func generateNewMessage(
            documentSearchScope: String? = nil,
            privateDocumentStoreIDs: [String]? = nil,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil
        ) async throws -> Message {
            try await chatStatusStream?(nil, .starting)
                                    
            try await self.updateModelContext()
            
            let workflowSteps: [WorkflowStep.Type] = [
                RunLocalChatSession.self, // Run Generation
                ChatSessionRunToolCalls.self // Handle Tool Calls
            ]
            
            let workflowContext = ChatSessionRunWorkflowContext(
                chatSession: self,
                documentSearchScope: documentSearchScope,
                privateDocumentStoreIDs: privateDocumentStoreIDs,
                chatStatusStream: chatStatusStream,
                toolUseHandler: toolUseHandler,
                jsonToolResults: jsonToolResults,
                toolDefinitionsManager: toolDefinitionsManager
            )
            
            let workflow = WorkflowManager(context: workflowContext, steps: workflowSteps)
            
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    try await queue.enqueue(name: "Run New Message", runLocation: .localRun) {
                        await workflow.execute { context in
                            let finalContext = context as! ChatSessionRunWorkflowContext
                            if let lastMessage = finalContext.lastGeneratedMessage {
                                // Save session after generation
                                continuation.resume(returning: lastMessage)
                            } else {
                                continuation.resume(throwing: FreeTokenError.failedToRunAIWithError(message: "Failed to Generate Message"))
                            }
                        } failure: { error, context in
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }

        public func countTokens(for text: String) async throws -> Int {
            return try await self.model.tokenize(text).count
        }
        
        public func unload() async {
            await model.unload()
            isPrewarmed = false
        }
        
        public func load() async throws {
            await unload()
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
                threadCount: DeviceManager.recommendedThreadCounts(reserve: 2).decode,
                batchSize: config.batchSize,
                threadCountBatch: DeviceManager.recommendedThreadCounts(reserve: 2).batch
            )
            
            self.model = try LlamaManager(modelPath: modelPath, options: options, repoName: repoName)
            
            await self.prewarm()
        }
        
        internal func updateModelContext() async throws {
            let messages = try await getMessages()
            let preparedMessages = try messagePreparer.prepareMessages(messages)
            try await self.model.updateContext(messages: preparedMessages, runID: runID)
        }
        
        internal func saveSession() async throws {
            try await self.model.saveSession(fileName: "local_chat_\(runID).bin")
        }
        
        internal func kvTokenCount() async -> Int {
            return await self.model.templatedTokenCount
        }
        
        internal func generate(for runID: String) async throws -> AsyncThrowingStream<String, any Error> {
            return try await self.model.generate(runID: runID)
        }
        
        internal func getLastGenerationMetrics() async -> LlamaManager.GenerationMetrics? {
            return await self.model.getLastGenerationMetrics()
        }
        
        
    }
    
}
