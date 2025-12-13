//
//  AISession.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/5/25.
//

import Foundation

extension FreeToken {
    
    /// Protocol defining the interface for chat sessions in FreeToken.
    /// Chat sessions provide persistent conversation threads with message history and AI generation.
    ///
    /// You obtain chat sessions via `FreeToken.shared.getChatSession()` or related factory methods.
    /// Do not instantiate these classes directly.
    public protocol ChatSessionProtocol {
        /// Preloads the AI model into memory for faster response times on the first message.
        /// This is automatically called when creating a session, but can be called manually if needed.
        func prewarm() async

        /// Creates a new message thread for this chat session.
        /// The thread will be persisted to the cloud with local caching.
        ///
        /// - Returns: The newly created `MessageThread` object.
        /// - Throws: `FreeTokenError` if a thread already exists on this session or if creation fails.
        func createMessageThread() async throws -> MessageThread

        /// Adds a message to the current chat session's thread.
        ///
        /// - Parameter message: The `Message` to add to the conversation thread.
        /// - Returns: The added `Message` with its server-assigned ID.
        /// - Throws: `FreeTokenError` if no thread exists on this session.
        func addMessage(message: Message) async throws -> Message

        /// Retrieves all messages in the current chat session's thread.
        ///
        /// - Returns: An array of `Message` objects in chronological order.
        /// - Throws: `FreeTokenError` if no thread exists on this session.
        func getMessages() async throws -> [Message]

        /// Generates a new AI response message based on the conversation history.
        /// This method automatically handles tool calls, document search (RAG), and streaming.
        ///
        /// - Parameters:
        ///   - documentSearchScope: Optional search scope for document retrieval (RAG).
        ///   - privateDocumentStoreIDs: Optional array of private document store IDs to search.
        ///   - chatStatusStream: Optional closure for receiving status updates during generation.
        ///   - toolUseHandler: Optional closure for handling tool/function calls from the AI.
        /// - Returns: The generated assistant `Message`.
        /// - Throws: `FreeTokenError` if generation fails or no thread exists.
        func generateNewMessage(
            documentSearchScope: String?,
            privateDocumentStoreIDs: [String]?,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String>
        ) async throws -> Message

        /// Counts the number of tokens in the given text using the session's AI model.
        /// Useful for estimating context usage.
        ///
        /// - Parameter text: The text to tokenize.
        /// - Returns: The number of tokens in the text.
        /// - Throws: `FreeTokenError` if tokenization fails.
        func countTokens(for text: String) async throws -> Int

        /// Unloads the AI model from memory, freeing system resources.
        /// Call this when you're done with the session to free memory.
        func unload() async

        /// Reloads the AI model into memory after it has been unloaded.
        /// This is called automatically when needed, but can be called manually.
        ///
        /// - Throws: `FreeTokenError` if model loading fails.
        func load() async throws
    }
    
    internal protocol ChatSessionInternalProtocol: ChatSessionProtocol {
        var modelCode: String { get }

        func updateModelContext() async throws
        func kvTokenCount() async -> Int
        func generate() async throws -> AsyncThrowingStream<String, Error>
        func getLastGenerationMetrics() async -> LlamaManager.GenerationMetrics?
        func saveSession() async throws
        func cancelGeneration() async

        func addMessage(message: Message, updateKVCache: Bool) async throws -> Message
    }
    
    
    /// Protocol defining the interface for completion sessions in FreeToken.
    /// Completion sessions provide stateless text generation without persistent message threads.
    ///
    /// You obtain completion sessions via `FreeToken.shared.getCompletionSession()`.
    /// Do not instantiate these classes directly.
    public protocol CompletionSessionProtocol {
        /// Generates a text completion from the given prompt.
        /// This is a stateless operation - each call is independent.
        ///
        /// - Parameters:
        ///   - text: The prompt text to generate a completion for.
        ///   - chatStatusStream: Optional closure for receiving status updates during generation.
        /// - Returns: A `Completion` object containing the response and token usage.
        /// - Throws: `FreeTokenError` if generation fails.
        func generateCompletion(from text: String, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>) async throws -> Completion

        /// Unloads the AI model from memory, freeing system resources.
        /// Call this when you're done with the session to free memory.
        func unload() async

        /// Reloads the AI model into memory after it has been unloaded.
        /// This is called automatically when needed, but can be called manually.
        ///
        /// - Throws: `FreeTokenError` if model loading fails.
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
    
    /// Local chat session with automatic cloud fallback.
    /// Manages persistent conversation threads with on-device AI inference, automatically falling back
    /// to cloud inference when device resources are insufficient or when explicitly configured.
    ///
    /// **Usage:**
    /// ```swift
    /// // Get a chat session (automatically determines local vs cloud)
    /// let session = try await FreeToken.shared.getChatSession()
    ///
    /// // Create a thread
    /// let thread = try await session.createMessageThread()
    ///
    /// // Add user message
    /// let userMsg = FreeToken.Message(role: .user, content: "Hello!")
    /// try await session.addMessage(message: userMsg)
    ///
    /// // Generate AI response
    /// let response = try await session.generateNewMessage()
    /// print(response.content)
    /// ```
    ///
    /// - Note: Obtain instances via `FreeToken.shared.getChatSession()`. Do not instantiate directly.
    public class ChatSession: ChatSessionInternalProtocol, @unchecked Sendable {
        // MARK: - Properties

        let client: FreeToken
        let aiModel: AIModel
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
        let modelCode: String
        let modelPath: String
        let repoName: String
        var aiRunConfig: AIRunConfig? = nil

        // MARK: - Initialization

        internal init(
            client: FreeToken,
            aiModel: AIModel,
            systemMessage: Message,
            runLocation: RunLocation,
            messagesManager: MessagesManager,
            toolDefinitionsManager: ToolDefinitionsManager,
            toolAccess: [ToolRunMask] = [.allowAll],
            queue: AITaskQueue,
            messageThreadID: String? = nil,
            aiRunConfig: AIRunConfig? = nil
        ) async throws {
            self.client = client
            self.messagePreparer = aiModel.messagePreparer()
            self.deviceManager = aiModel.deviceManager!
            self.queue = queue
            self.messageThreadID = messageThreadID
            self.runLocation = runLocation
            self.systemMessage = systemMessage
            self.messagesManager = messagesManager
            self.toolDefinitionsManager = toolDefinitionsManager
            self.toolAccess = toolAccess
            self.jsonToolResults = aiModel.jsonToolResults
            self.modelCode = aiModel.code
            self.modelPath = aiModel.getRootModelPath().path
            self.repoName = aiModel.repo!
            self.aiModel = aiModel
            self.aiRunConfig = aiRunConfig
            
            self.model = try aiModel.llamaManager(aiRunConfig: aiRunConfig)
            
            await self.prewarm()
        }

        // MARK: - Public Methods

        /// Preloads the AI model into memory for faster response times.
        /// This method is automatically called during session initialization but can be called manually.
        /// If a message thread ID exists, it will restore the session state from disk and update the model context.
        ///
        /// The prewarming process:
        /// - Checks available memory
        /// - Loads existing session from disk (if thread ID exists)
        /// - Updates model context with conversation history
        /// - Generates prewarm buffer for new sessions
        ///
        /// - Note: This is a no-op if the session is already prewarmed.
        public func prewarm() async {
            if isPrewarmed {
                return
            }

            if let messageThreadID = self.messageThreadID {
                // There is a thread - prewarm with existing messages
                
                await messagesManager.getMessageThread(id: messageThreadID) { messageThread, _ in
                    do {
                        try await self.model.loadSession(fileName: "\(messageThreadID).bin", systemMessage: self.systemMessage)
                        self.client.logger("✅ Loaded existing session from disk for prewarming.", .info)
                        return
                    } catch {
                        self.client.logger("Failed to load session from disk. Likely does not exist. Proceeding with new creation.", .info)
                    }
                    
                    do {
                        try await self.model.updateContext(messages: messageThread.messages)
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
                    try await model.prewarmSession(systemMessage: self.systemMessage)
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

        /// Signals the AI generation loop to stop as soon as possible.
        /// This is called internally when the user throws an error from the `chatStatusStream` callback.
        public func cancelGeneration() async {
            await model.cancelGeneration()
        }

        /// Creates a new message thread for this chat session.
        /// The thread will be persisted to the cloud with local caching.
        ///
        /// **Important:** Each chat session can only have one thread. If you need multiple threads,
        /// create separate chat session instances.
        ///
        /// - Returns: The newly created `MessageThread` object with a unique ID.
        /// - Throws: `FreeTokenError` if a thread already exists on this session or if creation fails.
        ///
        /// - Note: Save the returned `thread.id` for future operations. This is the only time you'll receive it.
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

        /// Adds a message to the current chat session's thread.
        /// The message will be persisted to the cloud and included in future AI generations.
        ///
        /// - Parameter message: The `Message` to add to the conversation thread. Typically a user message with role `.user`.
        /// - Returns: The added `Message` with its server-assigned ID and timestamp.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists on this session.
        ///
        /// **Example:**
        /// ```swift
        /// let userMsg = Message(role: .user, content: "What is quantum computing?")
        /// let addedMsg = try await session.addMessage(message: userMsg)
        /// print("Message ID: \(addedMsg.id)")
        /// ```
        ///
        /// - Note: You must call `createMessageThread()` before adding messages to a new session.
        public func addMessage(message: Message) async throws -> Message {
            if let messageThreadID = messageThreadID {
                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await client.addMessageToThread(id: messageThreadID, message: message) { message in
                            do {
                                try await self.model.addMessage(message: message)
                                continuation.resume(returning: message)
                            } catch {
                                continuation.resume(throwing: error)
                            }

                        } error: { error in
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }

        internal func addMessage(message: Message, updateKVCache: Bool = true) async throws -> Message {
            if let messageThreadID = messageThreadID {
                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await client.addMessageToThread(id: messageThreadID, message: message) { message in
                            do {
                                if updateKVCache {
                                    try await self.model.addMessage(message: message)
                                }
                                continuation.resume(returning: message)
                            } catch {
                                continuation.resume(throwing: error)
                            }

                        } error: { error in
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }

        /// Retrieves all messages in the current chat session's thread.
        /// Messages are returned in chronological order from oldest to newest.
        ///
        /// - Returns: An array of `Message` objects representing the complete conversation history.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists on this session.
        ///
        /// **Example:**
        /// ```swift
        /// let messages = try await session.getMessages()
        /// for msg in messages {
        ///     print("\(msg.role): \(msg.content)")
        /// }
        /// ```
        ///
        /// - Note: This fetches messages from the server, so it reflects the current state including messages added by other clients.
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

        /// Generates a new AI response message based on the conversation history.
        /// This method automatically handles local/cloud execution, tool calls, document search (RAG), and streaming.
        ///
        /// The generation process:
        /// 1. Determines optimal run location (local vs cloud) based on device capabilities
        /// 2. Updates model context with conversation history
        /// 3. Executes AI generation with optional streaming
        /// 4. Handles tool/function calls if the AI requests them
        /// 5. Performs document search (RAG) if specified
        /// 6. Saves the generated message to the thread
        ///
        /// - Parameters:
        ///   - documentSearchScope: Optional search scope for document retrieval (RAG). Documents matching this scope will be used as context.
        ///   - privateDocumentStoreIDs: Optional array of private document store IDs to search within.
        ///   - chatStatusStream: Optional closure for receiving real-time status updates and tokens during generation. Throw an error from this closure to cancel generation.
        ///   - toolUseHandler: Optional closure for handling tool/function calls from the AI. Return the tool results as a string.
        /// - Returns: The generated assistant `Message` with content, token usage, and metadata.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists, or other errors if generation fails.
        ///
        /// **Example with streaming:**
        /// ```swift
        /// let response = try await session.generateNewMessage(
        ///     chatStatusStream: { token, status in
        ///         if let token = token {
        ///             print(token, terminator: "")
        ///         }
        ///     }
        /// )
        /// ```
        ///
        /// - Note: If configured with `.automatic` run location, this will fallback to cloud if local execution fails.
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


            let cloudSession = CloudChatSession(
                client: client,
                aiModel: aiModel,
                toolDefinitionsManager: toolDefinitionsManager,
                toolAccess: toolAccess,
                messageThreadID: messageThreadID
            )

            let workflowSteps: [WorkflowStep.Type] = [
                RunLocalChatSession.self, // Run Generation
                ChatSessionRunToolCalls.self // Handle Tool Calls
            ]
            
            let workflowContext = ChatSessionRunWorkflowContext(
                chatSession: self,
                documentSearchScope: documentSearchScope,
                privateDocumentStoreIDs: privateDocumentStoreIDs,
                toolMask: self.toolAccess,
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
                if error is FreeTokenError && (error as! FreeTokenError) == .generationCancelled {
                    client.logger("⚠️ Generation cancelled by user.", .warning)
                    self.isPrewarmed = false
                    await self.prewarm() // We need to re-prewarm because when generation is cancelled the context window is flushed to prevent a bad state.
                    
                    throw error
                }
                
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

        /// Counts the number of tokens in the given text using this session's AI model.
        /// This is useful for estimating context usage before adding messages or generating responses.
        ///
        /// - Parameter text: The text to tokenize and count.
        /// - Returns: The number of tokens in the text according to the model's tokenizer.
        /// - Throws: An error if tokenization fails.
        ///
        /// - Note: Token counts may vary between different models. Always use the same session to count tokens that you'll use for generation.
        public func countTokens(for text: String) async throws -> Int {
            return try await self.model.tokenize(text).count
        }

        /// Unloads the AI model from memory, freeing system resources.
        /// This sets `isPrewarmed` to false, requiring the model to be reloaded on next use.
        ///
        /// Call this method when you're done with the session to free memory, especially on memory-constrained devices.
        /// The model will be automatically reloaded if you call `load()` or if needed for generation.
        ///
        /// - Note: This is a synchronous operation that completes when the model is fully unloaded.
        public func unload() async {
            await model.unload()
            isPrewarmed = false
        }

        /// Reloads the AI model into memory after it has been unloaded.
        /// This method first unloads any existing model, then initializes a new model instance with the same configuration.
        /// After loading, the model is automatically prewarmed for optimal performance.
        ///
        /// - Throws: An error if model initialization or prewarming fails.
        ///
        /// - Note: This is typically called automatically when needed. Manual calls are only necessary if you've explicitly unloaded the model.
        public func load() async throws {
            await unload()
            self.model = try aiModel.llamaManager(aiRunConfig: self.aiRunConfig)

            await self.prewarm()
        }

        // MARK: - Internal Methods

        internal func updateModelContext() async throws {
            let messages = try await getMessages()
            let preparedMessages = try messagePreparer.prepareMessages(messages)
            try await self.model.updateContext(messages: preparedMessages)
        }

        internal func saveSession() async throws {
            if let messageThreadID {
                try await self.model.saveSession(fileName: "\(messageThreadID).bin")
            } else {
                throw FreeTokenError.messageThreadNotCreated
            }
        }

        internal func kvTokenCount() async -> Int {
            return await self.model.kvCachePosition
        }

        internal func generate() async throws -> AsyncThrowingStream<String, any Error> {
            return try await self.model.generate()
        }

        internal func getLastGenerationMetrics() async -> LlamaManager.GenerationMetrics? {
            return await self.model.getLastGenerationMetrics()
        }
        
    }
    
    /// Cloud-only chat session.
    /// Manages persistent conversation threads using cloud-based AI inference only.
    /// This session type does not use local device resources for inference.
    ///
    /// **Usage:**
    /// ```swift
    /// // Get a cloud-only chat session
    /// let session = try await FreeToken.shared.getChatSession(runLocation: .cloudRun)
    ///
    /// // Create a thread
    /// let thread = try await session.createMessageThread()
    ///
    /// // Add user message
    /// let userMsg = FreeToken.Message(role: .user, content: "Hello!")
    /// try await session.addMessage(message: userMsg)
    ///
    /// // Generate AI response (always uses cloud)
    /// let response = try await session.generateNewMessage()
    /// ```
    ///
    /// - Note: Obtain instances via `FreeToken.shared.getChatSession(runLocation: .cloudRun)`. Do not instantiate directly.
    public class CloudChatSession: ChatSessionInternalProtocol, @unchecked Sendable {
        let client: FreeToken
        let messagePreparer: MessagePreparer
        var messageThreadID: String?
        var config: AIModelConfiguration

        let toolDefinitionsManager: ToolDefinitionsManager
        let jsonToolResults: Bool
        let toolAccess: [ToolRunMask]
        let modelCode: String
        var aiRunConfig: AIRunConfig? = nil
        
        internal init(
            client: FreeToken,
            aiModel: AIModel,

            toolDefinitionsManager: ToolDefinitionsManager,
            toolAccess: [ToolRunMask] = [.allowAll],
            messageThreadID: String? = nil,
            aiRunConfig: AIRunConfig? = nil
        ) {
            self.client = client
            self.messagePreparer = aiModel.messagePreparer()
            self.config = aiModel.aiModelConfiguration
            self.toolDefinitionsManager = toolDefinitionsManager
            self.jsonToolResults = aiModel.jsonToolResults
            self.modelCode = aiModel.code
            self.messageThreadID = messageThreadID
            self.toolAccess = toolAccess
            self.aiRunConfig = aiRunConfig
        }

        // MARK: - Public Methods

        /// Prewarming is not required for cloud sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need prewarming since they don't load models into device memory.
        public func prewarm() async {
            // No-op for cloud session
            client.logger("ℹ️ Prewarm not required for Cloud Sessions.", .info)
        }

        /// Loading is not required for cloud sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need to load models since inference happens remotely.
        public func load() async throws {
            client.logger("ℹ️ Loading is not required for Cloud Sessions.", .info)
        }

        /// Unloading is not required for cloud sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need to unload models since they don't use local device memory.
        public func unload() async {
            client.logger("ℹ️ Unloading is not required for Cloud Sessions.", .info)
        }

        /// Cancellation is handled differently for cloud sessions.
        /// This method is a no-op since cloud sessions use a different cancellation mechanism.
        public func cancelGeneration() async {
            // No-op for cloud session - cancellation is handled via the API
        }

        /// Creates a new message thread for this cloud chat session.
        /// The thread will be persisted to the cloud.
        ///
        /// **Important:** Each chat session can only have one thread. If you need multiple threads,
        /// create separate chat session instances.
        ///
        /// - Returns: The newly created `MessageThread` object with a unique ID.
        /// - Throws: `FreeTokenError` if a thread already exists on this session or if creation fails.
        ///
        /// - Note: Save the returned `thread.id` for future operations. This is the only time you'll receive it.
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

        /// Adds a message to the current cloud chat session's thread.
        /// The message will be persisted to the cloud and included in future AI generations.
        ///
        /// - Parameter message: The `Message` to add to the conversation thread. Typically a user message with role `.user`.
        /// - Returns: The added `Message` with its server-assigned ID and timestamp.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists on this session.
        ///
        /// - Note: You must call `createMessageThread()` before adding messages to a new session.
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
        
        internal func addMessage(message: Message, updateKVCache: Bool = true) async throws -> Message {
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

        /// Retrieves all messages in the current cloud chat session's thread.
        /// Messages are returned in chronological order from oldest to newest.
        ///
        /// - Returns: An array of `Message` objects representing the complete conversation history.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists on this session.
        ///
        /// - Note: This fetches messages from the server, reflecting the current state including messages added by other clients.
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

        /// Generates a new AI response message using cloud-based inference.
        /// This method automatically handles tool calls, document search (RAG), and streaming.
        ///
        /// All generation is performed using cloud AI infrastructure - no local device resources are used.
        ///
        /// - Parameters:
        ///   - documentSearchScope: Optional search scope for document retrieval (RAG). Documents matching this scope will be used as context.
        ///   - privateDocumentStoreIDs: Optional array of private document store IDs to search within.
        ///   - chatStatusStream: Optional closure for receiving real-time status updates and tokens during generation.
        ///   - toolUseHandler: Optional closure for handling tool/function calls from the AI. Return the tool results as a string.
        /// - Returns: The generated assistant `Message` with content, token usage, and metadata.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists, or other errors if generation fails.
        ///
        /// - Note: This always uses cloud AI. There is no local fallback.
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
            
            let workflowContext = CloudChatSessionRunWorklowContext(
                chatSession: self,
                documentSearchScope: documentSearchScope,
                privateDocumentStoreIDs: privateDocumentStoreIDs,
                modelCode: self.modelCode,
                aiRunConfig: self.aiRunConfig,
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

        /// Token counting is not supported for cloud chat sessions.
        /// Use a local chat session if you need to count tokens.
        ///
        /// - Parameter text: The text to count tokens for (ignored).
        /// - Throws: `FreeTokenError` indicating that token counting is not supported on cloud models.
        ///
        /// - Note: Cloud models don't provide local tokenization. Use a `ChatSession` with local model for token counting.
        public func countTokens(for text: String) async throws -> Int {
            throw FreeTokenError.error(message: "Counting tokens is not supported on cloud models", code: 10002)
        }

        // MARK: - Internal Methods

        internal func updateModelContext() async throws {
            // No-op for cloud session
            client.logger("ℹ️ Updating model context is not required for Cloud Sessions.", .info)
        }
        
        internal func kvTokenCount() async -> Int {
            return 0
        }
        
        internal func generate() async throws -> AsyncThrowingStream<String, any Error> {
            throw FreeTokenError.error(message: "Direct generation is not supported on cloud models", code: 10003)
        }
        
        internal func getLastGenerationMetrics() async -> FreeToken.LlamaManager.GenerationMetrics? {
            return nil
        }
        
        internal func saveSession() async throws {
            // No-op for cloud session
            client.logger("ℹ️ Saving session is not required for Cloud Sessions.", .info)
        }
    }
    
    /// Local completion session with automatic cloud fallback.
    /// Provides stateless text generation using on-device AI, automatically falling back
    /// to cloud inference when device resources are insufficient or when explicitly configured.
    ///
    /// **Usage:**
    /// ```swift
    /// // Get a completion session
    /// let session = try await FreeToken.shared.getCompletionSession()
    ///
    /// // Generate completion
    /// let completion = try await session.generateCompletion(from: "Write a poem about coding")
    /// print(completion.response)
    ///
    /// // Free memory when done
    /// await session.unload()
    /// ```
    ///
    /// - Note: Obtain instances via `FreeToken.shared.getCompletionSession()`. Do not instantiate directly.
    public class CompletionSession: CompletionSessionProtocol, @unchecked Sendable {
        let client: FreeToken
        let aiModel: AIModel
        let runLocation: RunLocation
        
        let deviceManager: DeviceManager
        let queue: AITaskQueue
        var model: LlamaManager
        let modelCode: String
        var aiRunConfig: AIRunConfig? = nil
        
        internal init(
            client: FreeToken,
            aiModel: AIModel,
            runLocation: RunLocation,
            queue: AITaskQueue,
            aiRunConfig: AIRunConfig? = nil
        ) throws {
            self.client = client
            self.aiModel = aiModel
            self.deviceManager = aiModel.deviceManager!
            self.queue = queue
            self.runLocation = runLocation
            self.modelCode = aiModel.code
            self.aiRunConfig = aiRunConfig
            
            // Initialize Model
            self.model = try aiModel.llamaManager(aiRunConfig: aiRunConfig)
        }

        // MARK: - Public Methods

        /// Generates a text completion from the given prompt.
        /// This is a stateless operation - each call is independent with no conversation history.
        ///
        /// The generation process:
        /// 1. Determines optimal run location (local vs cloud) based on device capabilities
        /// 2. Executes AI generation with optional streaming
        /// 3. Falls back to cloud if local execution fails (when using `.automatic`)
        ///
        /// - Parameters:
        ///   - text: The prompt text to generate a completion for.
        ///   - chatStatusStream: Optional closure for receiving real-time status updates and tokens during generation.
        /// - Returns: A `Completion` object containing the response text and token usage information.
        /// - Throws: `FreeTokenError` if generation fails.
        ///
        /// **Example with streaming:**
        /// ```swift
        /// let completion = try await session.generateCompletion(
        ///     from: "Explain quantum computing",
        ///     chatStatusStream: { token, status in
        ///         if let token = token {
        ///             print(token, terminator: "")
        ///         }
        ///     }
        /// )
        /// print("\nTokens used: \(completion.tokenUsage?.totalTokens ?? 0)")
        /// ```
        ///
        /// - Note: If configured with `.automatic` run location, this will fallback to cloud if local execution fails.
        public func generateCompletion(from text: String, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil) async throws -> Completion {
            let message = Message(role: .user, content: text, attachments: nil)
            
            try await self.model.addMessage(message: message)

            do {
                let (result, tokenUsage) = try await queue.enqueue(name: "Completion Session", runLocation: .localRun) {
                    var resultContent = ""
                    let inputTokensCount = await self.model.kvCachePosition
                    var tokenCount = 0
                    for try await nextChunk in try await self.model.generate() {
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
                    
                    let cloudSession = CloudCompletionSession(client: client, aiModel: aiModel)
                    
                    return try await cloudSession.generateCompletion(from: text, chatStatusStream: chatStatusStream)
                } else {
                    self.client.logger(error.localizedDescription, .error)
                    throw error
                }
            }
        }

        /// Unloads the AI model from memory, freeing system resources.
        /// Call this method when you're done with the session to free memory, especially on memory-constrained devices.
        ///
        /// - Note: The model will be automatically reloaded if you call `load()` or if needed for generation.
        public func unload() async {
            await model.unload()
        }

        /// Reloads the AI model into memory after it has been unloaded.
        /// This method first unloads any existing model, then initializes a new model instance with the same configuration.
        ///
        /// - Throws: An error if model initialization fails.
        ///
        /// - Note: This is typically called automatically when needed. Manual calls are only necessary if you've explicitly unloaded the model.
        public func load() async throws {
            await unload()
            
            self.model = try aiModel.llamaManager(aiRunConfig: self.aiRunConfig)
        }
    }

    /// Cloud-only completion session.
    /// Provides stateless text generation using cloud-based AI inference only.
    /// This session type does not use local device resources for inference.
    ///
    /// **Usage:**
    /// ```swift
    /// // Get a cloud-only completion session
    /// let session = try await FreeToken.shared.getCompletionSession(runLocation: .cloudRun)
    ///
    /// // Generate completion (always uses cloud)
    /// let completion = try await session.generateCompletion(from: "Explain quantum computing")
    /// print(completion.response)
    /// ```
    ///
    /// - Note: Obtain instances via `FreeToken.shared.getCompletionSession(runLocation: .cloudRun)`. Do not instantiate directly.
    public class CloudCompletionSession: CompletionSessionProtocol, @unchecked Sendable {
        let client: FreeToken
        let aiModel: AIModel
        let modelCode: String
        var aiRunConfig: AIRunConfig? = nil
        
        internal init(
            client: FreeToken,
            aiModel: AIModel,
            aiRunConfig: AIRunConfig? = nil
        ) {
            self.client = client
            self.aiModel = aiModel
            self.modelCode = aiModel.code
            self.aiRunConfig = aiRunConfig
        }

        // MARK: - Public Methods

        /// Generates a text completion using cloud-based AI inference.
        /// This is a stateless operation - each call is independent with no conversation history.
        ///
        /// All generation is performed using cloud AI infrastructure - no local device resources are used.
        ///
        /// - Parameters:
        ///   - text: The prompt text to generate a completion for.
        ///   - chatStatusStream: Optional closure for receiving real-time status updates and tokens during generation.
        /// - Returns: A `Completion` object containing the response text and token usage information.
        /// - Throws: `FreeTokenError` if generation fails.
        ///
        /// **Example:**
        /// ```swift
        /// let completion = try await session.generateCompletion(from: "Summarize quantum physics")
        /// print(completion.response)
        /// ```
        ///
        /// - Note: This always uses cloud AI. There is no local execution option.
        public func generateCompletion(from text: String, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil) async throws -> Completion {

            let message = Message(role: .user, content: text)
            let messages = [message]

            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    await client.generateCloudChatCompletion(messages: messages, model: modelCode, aiRunConfig: self.aiRunConfig, chatStatusStream: chatStatusStream) { message in
                        let result = Completion(response: message.content, tokenUsage: message.tokenUsage)
                        continuation.resume(returning: result)
                    } error: { error in
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        /// Unloading is not required for cloud completion sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need to unload models since they don't use local device memory.
        public func unload() async {
            client.logger("ℹ️ Unloading is not required for Cloud Completion Sessions.", .info)
        }

        /// Loading is not required for cloud completion sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need to load models since inference happens remotely.
        public func load() async throws {
            client.logger("ℹ️ Loading is not required for Cloud Completion Sessions.", .info)
        }

    }

    /// In-memory chat session for local-only conversations.
    /// Manages conversation threads entirely in memory without persistent cloud storage.
    /// Ideal for temporary conversations or privacy-sensitive use cases.
    ///
    /// **Usage:**
    /// ```swift
    /// // Get an in-memory chat session
    /// let session = try await FreeToken.shared.getMemoryChatSession()
    ///
    /// // Add user message (stored in memory only)
    /// let userMsg = FreeToken.Message(role: .user, content: "Hello!")
    /// try await session.addMessage(message: userMsg)
    ///
    /// // Generate AI response
    /// let response = try await session.generateNewMessage()
    /// print(response.content)
    ///
    /// // Note: Messages are not persisted to cloud
    /// ```
    ///
    /// - Note: Obtain instances via `FreeToken.shared.getMemoryChatSession()`. Do not instantiate directly.
    /// - Important: This session does not support `createMessageThread()` as messages are memory-only.
    public class MemoryChatSession: ChatSessionInternalProtocol, @unchecked Sendable {
        let sessionID: String
        var messages: [Message]
        var isPrewarmed: Bool = false
        var model: LlamaManager
        let aiModel: AIModel

        let client: FreeToken
        let messagePreparer: MessagePreparer
        let modelPath: String
        let repoName: String
        let deviceManager: DeviceManager
        let toolDefinitionsManager: ToolDefinitionsManager
        let toolAccess: [ToolRunMask]
        let jsonToolResults: Bool
        let modelCode: String
        let queue: AITaskQueue
        let systemMessage: Message
        var aiRunConfig: AIRunConfig? = nil

        internal init(
            client: FreeToken,
            aiModel: AIModel,
            systemMessage: Message,
            toolDefinitionsManager: ToolDefinitionsManager,
            toolAccess: [ToolRunMask] = [.allowAll],
            queue: AITaskQueue,
            sessionID: String = UUID().uuidString,
            messages: [Message] = [],
            aiRunConfig: AIRunConfig? = nil
        ) async {
            self.client = client
            self.aiModel = aiModel
            self.messagePreparer = aiModel.messagePreparer()
            self.modelPath = aiModel.getRootModelPath().path
            self.repoName = aiModel.repo!
            self.deviceManager = aiModel.deviceManager!
            self.toolDefinitionsManager = toolDefinitionsManager
            self.toolAccess = toolAccess
            self.jsonToolResults = aiModel.jsonToolResults
            self.modelCode = aiModel.code
            self.queue = queue
            self.systemMessage = systemMessage
            self.sessionID = sessionID
            self.messages = messages
            self.aiRunConfig = aiRunConfig

            self.model = try! aiModel.llamaManager(aiRunConfig: aiRunConfig)

            self.messages.insert(systemMessage, at: 0)

            await self.prewarm()
        }

        // MARK: - Public Methods

        /// Preloads the AI model into memory for faster response times.
        /// This method is automatically called during session initialization but can be called manually.
        /// If messages exist, it will restore the session state from disk and update the model context.
        ///
        /// The prewarming process:
        /// - Checks available memory
        /// - Loads existing session from disk (if messages exist)
        /// - Updates model context with message history
        /// - Generates prewarm buffer for new sessions
        ///
        /// - Note: This is a no-op if the session is already prewarmed.
        public func prewarm() async {
            if isPrewarmed {
                return
            }
            
            if messages.count > 0 {
                do {
                    try await self.model.loadSession(fileName: "local_chat_\(sessionID).bin", systemMessage: self.systemMessage)
                    self.client.logger("✅ Loaded existing session from disk for prewarming.", .info)
                } catch {
                    self.client.logger("Failed to load session from disk. Likely does not exist. Proceeding with new creation.", .info)
                }

                do {
                    try await self.model.updateContext(messages: messages)
                    self.client.logger("✅ Updated model context with existing messages for prewarming.", .info)
                } catch {
                    // Failed to prewarm
                    self.client.logger("❌ Failed to update model session context: \(error.localizedDescription)", .error)
                    return
                }

                self.isPrewarmed = true

                self.client.logger("✅ Successfully prewarmed model session with existing message thread.", .info)

                // Update the session after loading / updating context
                try? await self.model.saveSession(fileName: "local_chat_\(sessionID).bin")
            } else {
                // There is no thread - just prewarm an empty session
                do {
                    try await model.prewarmSession(systemMessage: self.systemMessage)
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

        /// Signals the AI generation loop to stop as soon as possible.
        /// This is called internally when the user throws an error from the `chatStatusStream` callback.
        public func cancelGeneration() async {
            await model.cancelGeneration()
        }

        /// Creating message threads is not supported for in-memory chat sessions.
        /// Messages are stored only in memory and are not persisted to the cloud.
        ///
        /// - Throws: `FreeTokenError` indicating that message threads cannot be created for memory-only sessions.
        ///
        /// - Note: Use `ChatSession` if you need persistent cloud-backed threads.
        public func createMessageThread() async throws -> MessageThread {
            throw FreeTokenError.error(message: "Creating message threads is not supported in MemoryChatSession", code: 10004)
        }

        /// Adds a message to the in-memory conversation.
        /// The message is stored only in memory and will be lost when the session is deallocated.
        ///
        /// - Parameter message: The `Message` to add to the in-memory conversation. Typically a user message with role `.user`.
        /// - Returns: The added `Message` (same instance as provided).
        ///
        /// **Example:**
        /// ```swift
        /// let userMsg = Message(role: .user, content: "What is machine learning?")
        /// try await session.addMessage(message: userMsg)
        /// ```
        ///
        /// - Note: Messages are not persisted and will be lost when the session ends.
        public func addMessage(message: Message) async throws -> Message {
            self.messages.append(message)
            try await self.model.addMessage(message: message)
            return message
        }

        internal func addMessage(message: Message, updateKVCache: Bool = true) async throws -> Message {
            self.messages.append(message)
            if updateKVCache {
                try await self.model.addMessage(message: message)
            }
            return message
        }

        /// Retrieves all messages in the in-memory conversation.
        /// Messages are returned in chronological order from oldest to newest.
        ///
        /// - Returns: An array of `Message` objects representing the conversation history stored in memory.
        ///
        /// - Note: This returns only messages stored in memory during this session. No cloud synchronization occurs.
        public func getMessages() async throws -> [Message] {
            return self.messages
        }

        /// Generates a new AI response message based on the in-memory conversation history.
        /// This method handles local AI generation, tool calls, and document search (RAG).
        ///
        /// All generation is performed locally on-device. The generated message is added to the in-memory conversation.
        ///
        /// - Parameters:
        ///   - documentSearchScope: Optional search scope for document retrieval (RAG). Documents matching this scope will be used as context.
        ///   - privateDocumentStoreIDs: Optional array of private document store IDs to search within.
        ///   - chatStatusStream: Optional closure for receiving real-time status updates and tokens during generation.
        ///   - toolUseHandler: Optional closure for handling tool/function calls from the AI. Return the tool results as a string.
        /// - Returns: The generated assistant `Message` with content and metadata.
        /// - Throws: `FreeTokenError` if generation fails.
        ///
        /// - Note: Generated messages are stored in memory only and are not persisted to the cloud.
        public func generateNewMessage(
            documentSearchScope: String? = nil,
            privateDocumentStoreIDs: [String]? = nil,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil
        ) async throws -> Message {
            try await chatStatusStream?(nil, .starting)
            
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
                            if error.code == FreeTokenError.generationCancelled.code {
                                self.client.logger("⚠️ Generation cancelled by user.", .warning)
                                self.isPrewarmed = false
                                await self.prewarm() // We need to re-prewarm because when generation is cancelled the context window is flushed to prevent a bad state.
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
        }

        /// Counts the number of tokens in the given text using this session's AI model.
        /// This is useful for estimating context usage before adding messages or generating responses.
        ///
        /// - Parameter text: The text to tokenize and count.
        /// - Returns: The number of tokens in the text according to the model's tokenizer.
        /// - Throws: An error if tokenization fails.
        ///
        /// - Note: Token counts may vary between different models. Always use the same session to count tokens that you'll use for generation.
        public func countTokens(for text: String) async throws -> Int {
            return try await self.model.tokenize(text).count
        }

        /// Unloads the AI model from memory, freeing system resources.
        /// This sets `isPrewarmed` to false, requiring the model to be reloaded on next use.
        ///
        /// Call this method when you're done with the session to free memory, especially on memory-constrained devices.
        /// The model will be automatically reloaded if you call `load()` or if needed for generation.
        ///
        /// - Note: This is a synchronous operation that completes when the model is fully unloaded.
        public func unload() async {
            await model.unload()
            isPrewarmed = false
        }

        /// Reloads the AI model into memory after it has been unloaded.
        /// This method first unloads any existing model, then initializes a new model instance with the same configuration.
        /// After loading, the model is automatically prewarmed for optimal performance.
        ///
        /// - Throws: An error if model initialization or prewarming fails.
        ///
        /// - Note: This is typically called automatically when needed. Manual calls are only necessary if you've explicitly unloaded the model.
        public func load() async throws {
            await unload()

            self.model = try aiModel.llamaManager(aiRunConfig: self.aiRunConfig)

            await self.prewarm()
        }

        // MARK: - Internal Methods

        internal func updateModelContext() async throws {
            let messages = try await getMessages()
            let preparedMessages = try messagePreparer.prepareMessages(messages)
            try await self.model.updateContext(messages: preparedMessages)
        }

        internal func saveSession() async throws {
            try await self.model.saveSession(fileName: "local_chat_\(sessionID).bin")
        }

        internal func kvTokenCount() async -> Int {
            return await self.model.kvCachePosition
        }

        internal func generate() async throws -> AsyncThrowingStream<String, any Error> {
            return try await self.model.generate()
        }

        internal func getLastGenerationMetrics() async -> LlamaManager.GenerationMetrics? {
            return await self.model.getLastGenerationMetrics()
        }

    }
    
    public class CloudMemoryChatSession: ChatSessionInternalProtocol, @unchecked Sendable {
        let client: FreeToken
        let messagePreparer: MessagePreparer
        var messages: [Message] = []
        var config: AIModelConfiguration

        let toolDefinitionsManager: ToolDefinitionsManager
        let jsonToolResults: Bool
        let toolAccess: [ToolRunMask]
        let modelCode: String
        var aiRunConfig: AIRunConfig? = nil
        
        internal init(
            client: FreeToken,
            aiModel: AIModel,
            toolDefinitionsManager: ToolDefinitionsManager,
            toolAccess: [ToolRunMask] = [.allowAll],
            messages: [Message] = [],
            aiRunConfig: AIRunConfig? = nil
        ) {
            self.client = client
            self.messagePreparer = aiModel.messagePreparer()
            self.config = aiModel.aiModelConfiguration
            self.toolDefinitionsManager = toolDefinitionsManager
            self.jsonToolResults = aiModel.jsonToolResults
            self.modelCode = aiModel.code
            self.messages = messages
            self.toolAccess = toolAccess
            self.aiRunConfig = aiRunConfig
        }

        // MARK: - Public Methods

        /// Prewarming is not required for cloud sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need prewarming since they don't load models into device memory.
        public func prewarm() async {
            // No-op for cloud session
            client.logger("ℹ️ Prewarm not required for Cloud Sessions.", .info)
        }

        /// Loading is not required for cloud sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need to load models since inference happens remotely.
        public func load() async throws {
            client.logger("ℹ️ Loading is not required for Cloud Sessions.", .info)
        }

        /// Unloading is not required for cloud sessions.
        /// This method does nothing but logs an informational message.
        ///
        /// - Note: Cloud sessions don't need to unload models since they don't use local device memory.
        public func unload() async {
            client.logger("ℹ️ Unloading is not required for Cloud Sessions.", .info)
        }

        /// Cancellation is handled differently for cloud sessions.
        /// This method is a no-op since cloud sessions use a different cancellation mechanism.
        public func cancelGeneration() async {
            // No-op for cloud session - cancellation is handled via the API
        }

        /// Creates a new message thread for this cloud chat session.
        /// The thread will be persisted to the cloud.
        ///
        /// **Important:** Each chat session can only have one thread. If you need multiple threads,
        /// create separate chat session instances.
        ///
        /// - Returns: The newly created `MessageThread` object with a unique ID.
        /// - Throws: `FreeTokenError` if a thread already exists on this session or if creation fails.
        ///
        /// - Note: Save the returned `thread.id` for future operations. This is the only time you'll receive it.
        public func createMessageThread() async throws -> MessageThread {
            throw FreeTokenError.error(message: "Creating message threads is not supported in CloudMemoryChatSession", code: 10004)
        }

        /// Adds a message to the current cloud chat session's thread.
        /// The message will be persisted to the cloud and included in future AI generations.
        ///
        /// - Parameter message: The `Message` to add to the conversation thread. Typically a user message with role `.user`.
        /// - Returns: The added `Message` with its server-assigned ID and timestamp.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists on this session.
        ///
        /// - Note: You must call `createMessageThread()` before adding messages to a new session.
        public func addMessage(message: Message) async throws -> Message {
            self.messages.append(message)
            
            return message
        }
        
        internal func addMessage(message: Message, updateKVCache: Bool = true) async throws -> Message {
            self.messages.append(message)
            return message
        }

        /// Retrieves all messages in the current cloud chat session's thread.
        /// Messages are returned in chronological order from oldest to newest.
        ///
        /// - Returns: An array of `Message` objects representing the complete conversation history.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists on this session.
        ///
        /// - Note: This fetches messages from the server, reflecting the current state including messages added by other clients.
        public func getMessages() async throws -> [Message] {
            return self.messages
        }

        /// Generates a new AI response message using cloud-based inference.
        /// This method automatically handles tool calls, document search (RAG), and streaming.
        ///
        /// All generation is performed using cloud AI infrastructure - no local device resources are used.
        ///
        /// - Parameters:
        ///   - documentSearchScope: Optional search scope for document retrieval (RAG). Documents matching this scope will be used as context.
        ///   - privateDocumentStoreIDs: Optional array of private document store IDs to search within.
        ///   - chatStatusStream: Optional closure for receiving real-time status updates and tokens during generation.
        ///   - toolUseHandler: Optional closure for handling tool/function calls from the AI. Return the tool results as a string.
        /// - Returns: The generated assistant `Message` with content, token usage, and metadata.
        /// - Throws: `FreeTokenError.messageThreadNotCreated` if no thread exists, or other errors if generation fails.
        ///
        /// - Note: This always uses cloud AI. There is no local fallback.
        public func generateNewMessage(
            documentSearchScope: String? = nil,
            privateDocumentStoreIDs: [String]? = nil,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil
        ) async throws -> Message {
            guard self.messages.count > 0 else {
                client.logger("No messages for context for generation.", .error)
                throw FreeTokenError.noMessagesToSend
            }

            try await chatStatusStream?(nil, .starting)
            
            
            let workflowSteps: [WorkflowStep.Type] = [
                RunCloudChatSession.self, // Run Generation
                ChatSessionRunToolCalls.self // Handle Tool Calls
            ]
            
            let workflowContext = CloudChatSessionRunWorklowContext(
                chatSession: self,
                documentSearchScope: documentSearchScope,
                privateDocumentStoreIDs: privateDocumentStoreIDs,
                modelCode: self.modelCode,
                aiRunConfig: self.aiRunConfig,
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

        /// Token counting is not supported for cloud chat sessions.
        /// Use a local chat session if you need to count tokens.
        ///
        /// - Parameter text: The text to count tokens for (ignored).
        /// - Throws: `FreeTokenError` indicating that token counting is not supported on cloud models.
        ///
        /// - Note: Cloud models don't provide local tokenization. Use a `ChatSession` with local model for token counting.
        public func countTokens(for text: String) async throws -> Int {
            throw FreeTokenError.error(message: "Counting tokens is not supported on cloud models", code: 10002)
        }

        // MARK: - Internal Methods

        internal func updateModelContext() async throws {
            // No-op for cloud session
            client.logger("ℹ️ Updating model context is not required for Cloud Sessions.", .info)
        }
        
        internal func kvTokenCount() async -> Int {
            return 0
        }
        
        internal func generate() async throws -> AsyncThrowingStream<String, any Error> {
            throw FreeTokenError.error(message: "Direct generation is not supported on cloud models", code: 10003)
        }
        
        internal func getLastGenerationMetrics() async -> FreeToken.LlamaManager.GenerationMetrics? {
            return nil
        }
        
        internal func saveSession() async throws {
            // No-op for cloud session
            client.logger("ℹ️ Saving session is not required for Cloud Sessions.", .info)
        }
    }
    
}
