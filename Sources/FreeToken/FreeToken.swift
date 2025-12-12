import Foundation
import CryptoKit

/// FreeToken Client
public class FreeToken: @unchecked Sendable {
    /// Shared instance of FreeToken client
    ///
    /// Use this singleton instance to access all FreeToken functionality:
    /// ```
    /// let client = FreeToken.shared
    /// ```
    static public let shared = FreeToken()
    
    /// Indicates whether the client has been configured
    ///
    /// Returns `true` if the client has been configured with an API key, `false` otherwise.
    /// Check this before making API calls to ensure the client is ready:
    /// ```
    /// if FreeToken.shared.isConfigured {
    ///     // Client is ready to use
    /// }
    /// ```
    public var isConfigured: Bool {
        get {
            return clientConfigStatus == .configured
        }
    }
    
    let clientVersion = "1.1.0"
#if os(iOS)
    let clientType = "iOS"
#elseif os(macOS)
    let clientType = "macOS"
#endif
    let httpClient = HTTPClient()
    let messagesManager: MessagesManager
    let toolDefinitionsManager = ToolDefinitionsManager()
    
    // Captured device model details (identifier like iPhone16,1 or Mac15,7, plus a friendly name when available)
    public let deviceModelIdentifier: String
    public let deviceModelName: String
    
    var clientConfigStatus: ClientConfigStatus = .notConfigured
    var baseURL: URL? = nil
    var appToken: String? = nil
    var deviceSessionToken: String? = nil
    var deviceDetails: Codings.ShowDeviceSessionResponse? = nil
            
    var documentChunkSize: Int? = nil
    var documentChunkOverlapSize: Int? = nil
    var documentManager: DocumentManager? = nil
    
    let encryptionManager = EncryptionManager()
    
    var deviceSession: Codings.ShowDeviceSessionResponse? = nil
    
    var aiModels: [AIModel] = []
    
    /// Status updates for AI chat stream operations
    ///
    /// Provides real-time status updates during message thread execution. Used with the `chatStatusStream` callback
    /// in `runMessageThread` to monitor the progress of AI operations:
    /// ```
    /// await client.runMessageThread(
    ///     id: threadId,
    ///     chatStatusStream: { status in
    ///         switch status {
    ///         case .starting:
    ///             print("Starting AI operation...")
    ///         case .streaming_tokens:
    ///             print("Receiving response tokens...")
    ///         case .stream_ended:
    ///             print("Response complete!")
    ///         default:
    ///             print("Status: \(status.rawValue)")
    ///         }
    ///     }
    /// )
    /// ```
    public enum ChatStreamStatus: String, @unchecked Sendable {
        /// Initial status when the operation begins
        case starting = "starting"
        /// Indicates the operation has failed
        case failed = "failed"
        /// AI is actively streaming response tokens
        case streaming_tokens = "streaming_tokens"
        /// The response stream has completed
        case stream_ended = "stream_ended"
        /// Request is being sent to local on-device AI
        case sending_to_local_ai = "sending_to_local_ai"
        /// Request is being sent to cloud AI
        case sending_to_cloud_ai = "sending_to_cloud_ai"
        /// AI is evaluating function/tool calls
        case evaluating_tool_calls = "evaluating_tool_calls"
        /// A new message has been created and saved
        case new_message_created = "new_message_created"
        /// Local Run Failed - Falling back to cloud
        case cloud_fallback = "cloud_fallback"
    }
    
    enum ClientConfigStatus: Equatable {
        case notConfigured
        case configured
    }
    
    // Methods:
    
    private init() {
        self.baseURL = URL(string: "https://api.freetoken.ai/api/v1/")!
        let provider = DeviceModelProvider()
        self.deviceModelIdentifier = provider.modelIdentifier
        self.deviceModelName = provider.modelName
        self.messagesManager = MessagesManager(encryptionManager: self.encryptionManager)
        self.messagesManager.client = self
    }
    
    /// Configures the `FreeToken` client with the provided API key and base URL.
    ///
    /// ```
    ///  let client = FreeToken.shared.configure(appToken: "key-12345", baseURL: URL(string: "https://api.example.com/"))
    /// ```
    ///
    /// - Parameters:
    ///     - appToken: A `String` representing the API key used for authentication of your client.
    ///     - baseURL: Optional base URL for the API (e.g., `https://api.example.com/`). Defaults to `nil`.
    ///     - sharedPublicEncryptionKey: Optional shared public encryption key for encrypting and decrypting public documents. Defaults to `nil`.
    ///     - userPrivateEncryptionKey: Optional user private encryption key for encrypting and decrypting messages and private documents. Defaults to `nil`.
    ///     - logLevel: Optional log level for the client. Default is `.info`
    /// - Returns: A configured `FreeToken` instance.
    public func configure(
        appToken: String,
        baseURL: Optional<URL> = nil,
        sharedPublicEncryptionKey: String? = nil,
        userPrivateEncryptionKey: String? = nil,
        logLevel: FreeTokenLogger.LogLevel = .info
    ) throws -> FreeToken {
        self.appToken = appToken
        FreeTokenLogger.shared.configure(logLevel: logLevel)
        
        if let baseURL = baseURL {
            self.baseURL = baseURL
        }
        
        if let sharedPublicEncryptionKey = sharedPublicEncryptionKey {
            try self.encryptionManager.setEncryptionKey(sharedPublicEncryptionKey, scope: .sharedPublic)
        } else {
            FreeToken.shared.logger("⚠️ No Shared Public Encryption Key provided. Public Documents will not be encrypted/decrypted.", .warning)
        }
        
        if let userPrivateEncryptionKey = userPrivateEncryptionKey {
            try self.encryptionManager.setEncryptionKey(userPrivateEncryptionKey, scope: .userPrivate)
        } else {
            FreeToken.shared.logger("⚠️ No User Private Encryption Key provided. Messages and Private Document Store Documents will not be encrypted/decrypted.", .warning)
        }
        
        if userPrivateEncryptionKey == nil || sharedPublicEncryptionKey == nil {
            FreeToken.shared.logger("⚠️ Enable encryption by calling the `enableEncryption` method.", .warning)
        }
        
        self.clientConfigStatus = .configured
        
        return self
    }
    
    /// Enable Encryption for a scope using built-in encryption management system
    ///
    /// ```
    ///   let encryptionKey = client.enableEncryption(scope: .sharedPublic)
    /// ```
    ///
    /// > Note: After this method is run, all messages and documents will be encrypted using the built-in encryption system and the key returned.
    ///
    /// > Warning: This will be the only time you have access to this key, so ensure you persist it securely.
    ///
    /// > Tip: The next time the FreeToken client is initialized, pass this key into the `configure` method to the appropriately scoped attribute.
    ///
    /// - Parameters:
    ///   - scope: The `EncryptionScope` to enable encryption for. This determines the scope of the encryption key.
    /// - Returns: A `String` representing the generated encryption key for the specified scope.
    public func enableEncryption(scope: EncryptionScope) -> String {
        return self.encryptionManager.generateEncryptionKey(for: scope)
    }
    
    /// Enables encryption by providing encryption and decryption callbacks.
    ///
    /// ```
    ///     try client.enableCustomEncryption(encrypt: { text in
    ///         // Your encryption logic here
    ///         return encryptedText
    ///     }, decrypt: { text in
    ///         // Your decryption logic here
    ///         return decryptedText
    ///     })
    /// ```
    ///
    /// > Note: This enables encryption for all messages and documents from this point forward. Any incoming message or document will be decrypted using this callback. Similarly, any outgoing message or document will be encrypted using the provided encryption callback.
    ///
    /// - Parameters:
    ///     - encryptCallback: A closure that takes a `String` to be encrypted and returns the encrypted `String`.
    ///     - decryptCallback: A closure that takes a `String` to be decrypted and returns the decrypted `String`.
    /// - Throws: An error if the encryption or decryption process fails.
    public func enableCustomEncryption(
        encrypt encryptCallback: @escaping @Sendable (_ toEncrypt: String, _ scope: EncryptionScope) throws -> String,
        decrypt decryptCallback: @escaping @Sendable (_ toDecrypt: String, _ scope: EncryptionScope) throws -> String
    ) throws {
        self.encryptionManager.enableCustomEncryption(encryptor: encryptCallback, decryptor: decryptCallback)
    }
    
    /// Determine Device Capabilities and Register with FreeToken Cloud
    ///
    /// ```
    ///     await client.registerDevice(scope: "my-app-v1") {
    ///         // Successfully registered
    ///     } error: { error in
    ///         // Failed to register device
    ///     }
    /// ```
    ///
    /// > Warning: If you are changing the `scope` of a device after it has been previously registered,
    /// > you must use ``resetDevice()`` prior to registering the device.
    ///
    /// > Tip: Add a random recognizable letter or number to the end of your scope to perform A/B testing on your users with different Agents.  Agent routing is defined in the server console.
    ///
    /// - Parameters:
    ///   - scope: The Device Scope used in routing to an app agent
    ///   - success: A closure that is executed if the call was successful
    ///   - error: A closure that is executed if the call failed.
    ///
    /// - Returns: Void
    public func registerDeviceSession(scope: String, success successCallback: @escaping @Sendable () async -> Void, error errorCallback: @escaping @Sendable (FreeTokenError) async -> Void) async {
        let profiler = Profiler()
        
        // Determine Device Capabilities
        // Only include model fields if we have a non-Unknown identifier
        let modelIdentifier = deviceModelIdentifier == "Unknown" ? nil : deviceModelIdentifier
        let modelName = deviceModelName == "Unknown" ? nil : deviceModelName
        let createDeviceSessionRequest = Codings.CreateDeviceSessionRequest(
            deviceSession: .init(
                scope: scope,
                clientType: clientType,
                clientVersion: clientVersion,
                deviceModelIdentifier: modelIdentifier,
                deviceModelName: modelName
            )
        )
        
        await postData(path: "device_sessions", data: createDeviceSessionRequest, responseType: Codings.ShowDeviceSessionResponse.self) { result in
            switch result {
            case .success(let response):
                self.deviceSessionToken = response.token
                self.deviceDetails = response
                
                // Initialize Embedding Manager
                let embeddingDeviceManager = DeviceManager(memoryRequirement: response.embeddingModel.memoryRequirement)
                EmbeddingManager.shared.config(modelConfig: response.embeddingModel, deviceAICapable: embeddingDeviceManager.isAICapable)
                
                // Initialize Document Manager
                self.documentManager = DocumentManager(chunkSize: response.documentsConfig.documentChunkSize, overlapSize: response.documentsConfig.documentChunkOverlapSize)
                
                // Capture Tool Call Instructions
                await self.toolDefinitionsManager.setToolInstructions(response.toolInstructions)
                
                // Capture Built In Tool and Cloud Tool Calls
                let builtInTools = response.builtInToolDefinitions.map { ToolDefinition(from: $0) }
                await self.toolDefinitionsManager.addToolDefinitions(builtInTools, type: .builtIn)
                
                let cloudTools = response.cloudToolDefinitions.map { ToolDefinition(from: $0) }
                await self.toolDefinitionsManager.addToolDefinitions(cloudTools, type: .cloud)
                
                let defaultAIModel = try? AIModel(from: response.aiModel)
                self.aiModels.append(defaultAIModel!)
                
                FreeToken.shared.logger("📋 Device registered successfully", .info)
                
                profiler.end(eventType: Profiler.EventType.registerDeviceSession, isSuccess: true)
                self.deviceSession = response
                await successCallback()
            case .failure(let errorResponse):
                FreeToken.shared.logger("Failed to register device: \(errorResponse.message)", .error)
                profiler.end(eventType: .registerDeviceSession, isSuccess: false, errorMessage: errorResponse.message)
                await errorCallback(errorResponse)
            }
        }
    }
    
    /// Reset the persisted device details
    ///
    /// ```
    ///   client.resetDevice()
    /// ```
    ///
    /// > Note: This method is used to reset the client to original state to begin registering again.
    ///
    /// - Returns: Void
    public func resetDevice() async throws {
        deviceDetails = nil
        deviceSessionToken = nil
        documentManager = nil
        deviceSession = nil
        self.aiModels = []
        encryptionManager.reset()
        await toolDefinitionsManager.removeAllToolDefinitions()
    }
    
    /// Reset Model Caches
    ///
    public func resetModelCaches() async throws {
        try? await resetEmbeddingModelCache()
        try? await resetChatCache()
        DownloadManager.shared.cancelAllDownloads()
        DownloadManager.shared.removeAllPersistedDownloadSessions()
        await deleteAIModelCache()
    }

    /// Clears all cached chat session states
    ///
    /// This removes all saved llama.cpp sequence caches that are used to speed up
    /// chat session initialization. These caches will be recreated as needed.
    ///
    /// - Throws: `FreeTokenError.fileOperationFailed` if unable to clear the cache
    public func resetChatCache() async throws {
        // Clear the entire cache directory for all models
        let cacheBaseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FreeToken").appendingPathComponent("chats")

        if FileManager.default.fileExists(atPath: cacheBaseURL.path) {
            do {
                try FileManager.default.removeItem(at: cacheBaseURL)
                logger("✅ Cleared chat cache directory at: \(cacheBaseURL.path)", .info)
            } catch {
                logger("🔴 Failed to clear chat cache directory: \(error)", .error)
                throw FreeTokenError.fileOperationFailed(message: "Failed to clear chat cache: \(error.localizedDescription)")
            }
        } else {
            logger("ℹ️ Chat cache directory does not exist, nothing to clear", .debug)
        }
    }

    /// Removes the Embedding Model Cache from the local device
    ///
    /// > Note: Use this if you get embedding model errors.  This will remove the model from the device.
    ///
    /// ```
    ///   try client.resetEmbeddingModelCache()
    /// ```
    /// - Returns: Void
    /// - Throws: Error if failed to reset the cache
    public func resetEmbeddingModelCache() async throws {
        do {
            try await EmbeddingManager.shared.resetCache()
        } catch {
            throw FreeTokenError.deviceReset
        }
    }
    
    
    /// Delete AI Model Cache
    ///
    /// Deletes AI model cache from disk. Can delete a specific model or all models.
    ///
    /// - Parameter modelCode: Optional model code to delete a specific model. If nil, deletes all models.
    /// - Returns: Void
    ///
    /// > Warning: When modelCode is nil, this method deletes the entire AI model cache directory, including all downloaded models.
    public func deleteAIModelCache(modelCode: String? = nil) async {

        let defaultRootDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FreeToken")
            .appendingPathComponent("Models")
        
        if let modelCode = modelCode, let aiModel = try? await self.getAIModel(modelCode: modelCode) {
            // Delete specific model
            try? aiModel.deleteModelFiles()
            
        } else {
            // Delete the whole directory
            do {
                try FileManager.default.removeItem(at: defaultRootDirectory)
                FreeToken.shared.logger("🗑️ AI model cache reset successfully", .info)
            } catch {
                FreeToken.shared.logger("🔴 Failed to reset AI model cache: \(error.localizedDescription)", .error)
            }
        }
    }
    
    /// Get download state of any AI model by code
    ///
    /// - Parameters:
    ///  - modelCode: Optional String that represents the AI model code to check. If not provided, uses the default AI model for the Agent.
    /// - Returns: A `Bool` indicating whether the AI model is downloaded.
    /// - Throws: `FreeTokenError` if the device is not registered.
    public func getAIModelDownloadState(modelCode: String? = nil) async throws -> ModelDownloadState {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModel = try await self.getAIModel(modelCode: modelCode)
        
        return try await aiModel.downloadStatus()
    }
    
    /// Download the AI model for this specific device
    ///
    /// ```
    ///     await client.downloadAIModel(success: { modelState in
    ///        // Model is ready for use
    ///        // Check the modelState to determine if the model was downloaded, and if AI is supported.
    ///     }, error: { error in
    ///         // Failure - retry downloading.
    ///     })
    /// ```
    ///
    /// > Note: There are scenarios where the a successful result will mean that the model was not downloaded.
    /// > Use `modelState` to determine the state of the download.
    ///
    /// - Parameters:
    ///   - success: Closure that is executed after the result of whether the model is downloaded is returned.
    ///   - error: Closure that is executed if there is an error during the AI model download.
    ///   - progressPercent: Optional closure that is executed to report the progress of the AI model download.
    ///
    /// - Returns: Void
    public func downloadAIModel(
        modelCode: String? = nil,
        success successCallback: @escaping @Sendable (_ state: DownloadedState) async -> Void,
        error errorCallback: @escaping @Sendable (FreeTokenError) async -> Void,
        progressPercent: Optional<@Sendable (_ progressPercent: Double) -> Void> = nil
    ) async {
        guard isDeviceRegistered() else {
            await errorCallback(FreeTokenError.deviceNotRegistered)
            return
        }
        
        Task {
            do {
                let aiModel = try await getAIModel(modelCode: modelCode)
                let result = try await aiModel.download(progress: progressPercent)
                await successCallback(result)
            } catch {
                await errorCallback(error as! FreeTokenError)
            }
            await downloadEmbeddingModel()
        }
    }
    
    
    /// Check if a model is capable of running on this device
    ///
    /// - Parameters:
    ///    - modelCode: Optional model code you can pass if not the default agent model
    /// - Returns: Bool
    public func isModelAvailableForDevice(modelCode: String?) async throws -> Bool {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModel: AIModel = try await self.getAIModel(modelCode: modelCode)
        
        return aiModel.canInitializeOnDevice()
    }
    
    /// Get models that are capable of running on this device
    ///
    /// - Returns: An Array of AIModel objects that are capable of running on this device
    public func availableAIModelsForDevice() async throws -> [AIModel] {
        
        let aiModels = try await listAIModels()
        
        return aiModels.compactMap { aiModel in
            if aiModel.canInitializeOnDevice() {
                return aiModel
            } else {
                return nil
            }
        }
    }
    
    private func downloadEmbeddingModel() async {
        let embeddingModelState = await EmbeddingManager.shared.modelStateActor.modelState
        
        guard embeddingModelState != .ready && embeddingModelState != .downloading else {
            FreeToken.shared.logger("⏭️ Skipping downloading of embedding model as it's in state: \(embeddingModelState)", .info)
            return
        }
        
        // Download Embedding Model - Detached from main download.
        Task.detached {
            @Sendable func attempt(_ remainingTries: Int) async {
                await withCheckedContinuation { continuation in
                    Task {
                        await EmbeddingManager.shared.downloadModel(progress: nil) {
                            FreeToken.shared.logger("📃 Embedding model downloaded successfully", .info)
                            continuation.resume()
                        } failureCallback: { error in
                            FreeToken.shared.logger("🔴 Failed to download embedding model: \(error)", .error)
                            if remainingTries > 0 {
                                FreeToken.shared.logger("↩️ Retrying embedding model download... (\(remainingTries) left)", .info)
                                Task {
                                    await attempt(remainingTries - 1)
                                    continuation.resume() // Resume after the final retry
                                }
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
            
            await attempt(3)
        }
    }
    
    /// List all available AI models
    ///
    /// ```
    ///    await client.listAIModels(success: { AIModels in
    ///       // Successfully listed AI models
    ///     }, error: { error in
    ///       // Failed to list AI models
    ///     })
    /// ```
    ///
    /// > Note: This method retrieves all AI models available in the FreeToken, both cloud and local supported models.
    ///
    /// > Tip: Use this to retrieve model codes for use in other methods or to present to the user for model selection.
    ///
    /// - Parameters:
    ///   - success: A closure that is executed when the AI models are successfully listed.
    ///   - error: A closure that is executed if there is an error during the listing of AI models.
    /// - Returns: Void
    public func listAIModels() async throws -> [AIModel]  {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModels: [AIModel] = try await withCheckedThrowingContinuation { continuation in
            Task {
                let path = "ai_models"
                await fetchResource(path: path, responseType: Codings.AIModelsResponse.self) { result in
                    switch result {
                    case .success(let response):
                        do {
                            var allModels: [AIModel] = []
                            for aiModelCoding in response.aiModels {
                                if let existingModel = self.aiModels.first(where: { $0.code == aiModelCoding.code }) {
                                    allModels.append(existingModel)
                                } else {
                                    let newModel = try AIModel(from: aiModelCoding)
                                    allModels.append(newModel)
                                    self.aiModels.append(newModel)
                                }
                            }
                            continuation.resume(returning: allModels)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        return aiModels
    }
    
    /// Get AI Model by Code
    ///
    /// ```
    ///   let aiModel = await client.getAIModel()
    /// ```
    ///
    /// - Parameters:
    ///  - modelCode: The code of the AI model to retrieve.
    /// - Returns: Void
    public func getAIModel(modelCode: String? = nil) async throws -> AIModel {
        guard isDeviceRegistered() else {
            FreeToken.shared.logger("Device not registered. Cannot fetch AI model.", .error)
            throw FreeTokenError.deviceNotRegistered
        }
        
        var modelCode = modelCode
        
        if modelCode == nil {
            modelCode = deviceSession!.aiModel.code
        }
        
        if let cachedModel = aiModels.first(where: { $0.code == modelCode }) {
            return cachedModel
        }
        
        if modelCode == deviceSession!.aiModel.code {
            let aiModel = try AIModel(from: deviceSession!.aiModel)
            self.aiModels.append(aiModel)
            return aiModel
        }
        
        // URL escape the model code to handle special characters
        let path = "ai_models/\(modelCode!.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelCode!)"
        
        let aiModel = try await withCheckedThrowingContinuation { continuation in
            Task {
                await fetchResource(path: path, responseType: Codings.AiModelResponse.self) { result in
                    switch result {
                    case .success(let response):
                        do {
                            let aiModel = try AIModel(from: response)
                            continuation.resume(returning: aiModel)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                        
                    case .failure(let error):
                        FreeToken.shared.logger("Failed to fetch AI Model: \(error.message)", .error)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        self.aiModels.append(aiModel)
        return aiModel
    }
    
    /// Register tool definitions with the client
    ///
    /// > Tip: Use OpenAI JSON Tool Definitions to register tools.
    ///
    /// - Parameters:
    ///  - toolDefinitions: An array of `ToolDefinition` objects to register.
    /// - Returns: Void
    public func registerToolDefinitions(_ toolDefinitions: [ToolDefinition]) async {
        
        for toolDefinition in toolDefinitions {
            await toolDefinitionsManager.addToolDefinition(toolDefinition, type: .application)
        }
    }
    
    /// Add a tool definition globally to the client
    ///
    /// ```
    ///   await client.addToolDefinition(name: "myTool", definitionJSON: "{...}")
    /// ```
    ///
    /// > Tip: Use OpenAI JSON Tool Definitions to register tools.
    ///
    /// - Parameters:
    ///   - name: Name of the tool function to add
    ///   - definitionJSON: OpenAI Tool Definition JSON string
    /// - Returns: Void
    public func addToolDefinition(name: String, definitionJSON: String) async {
        let toolDefinition = ToolDefinition(name: name, definition: definitionJSON)
        await toolDefinitionsManager.addToolDefinition(toolDefinition, type: .application)
    }
    
    /// Remove all tool definitions
    ///
    /// - Returns: Void
    public func removeAllToolDefinitions() async {
        await toolDefinitionsManager.removeAllToolDefinitions()
        
        // Add back default tool definitions
        if let deviceDetails = deviceDetails {
            let builtInTools = deviceDetails.builtInToolDefinitions.map { ToolDefinition(from: $0) }
            await toolDefinitionsManager.addToolDefinitions(builtInTools, type: .builtIn)
            
            let cloudTools = deviceDetails.cloudToolDefinitions.map { ToolDefinition(from: $0) }
            await toolDefinitionsManager.addToolDefinitions(cloudTools, type: .cloud)
        }
    }
    
    /// Create Message Thread in FreeToken Cloud
    ///
    /// ```
    ///     await client.createMessageThread(success: { messageThread in
    ///         // Persist the message thread ID in your application
    ///         yourMethodToPersist(messageThreadID: messageThread.id)
    ///     }, error: { error in
    ///         // Retry?
    ///     })
    /// ```
    ///
    /// > Warning: This process is the only time you will have access to the Message Thread ID.
    /// > If it's not persisted, it will be lost and you will have no way of adding messages to the thread.
    ///
    /// > Tip: Use `toolAccess` to selectively define tools that will be availble to this thread.  You can then use `toolAccess` on ``runMessageThread`` to allow certain tools for a specific run.
    ///
    /// - Parameters:
    ///     - toolAccess: An array of `ToolRunMask` to define which tools will be available in this message thread. Defaults to `.allowAll`.
    ///     - success: A closure that is executed when the message thread is successfully created.
    ///     - error: A closure that is executed if there is an error during the creation of the message thread.
    /// - Returns: Void
    public func createMessageThread(toolAccess: [ToolRunMask] = [.allowAll], success successCompletion: @escaping @Sendable (MessageThread) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        // Assemble the system message
        let systemMessage = await buildSystemMessage(toolAccess: toolAccess)
        
        // Use Message Manager
        await messagesManager.createMessageThread(systemMessage: systemMessage) { result in
            switch result {
            case .success(let messageThread):
                FreeToken.shared.logger("📝 Message thread created successfully: \(messageThread.id)", .info)
                await successCompletion(messageThread)
            case .failure(let error):
                FreeToken.shared.logger("🔴 Failed to create message thread: \(error.message)", .error)
                await errorCompletion(error)
            }
        }
    }
    
    private func buildSystemMessage(toolAccess: [ToolRunMask] = [.allowAll]) async -> Message {
        let deviceDetails = self.deviceDetails!
        
        var systemMessageContent = deviceDetails.systemInstructions
        
        let toolDefinitions = await toolDefinitionsManager.processToolMask(toolAccess)
        if toolDefinitions.isEmpty == false {
            let toolDefinitionJSON = toolDefinitions.map { $0.definition }.joined(separator: ",\n")
            systemMessageContent += "\n\n\(await toolDefinitionsManager.getToolInstructions())\n\nAvailable Tools:\n[\n\(toolDefinitionJSON)\n]"
        }
        
        return Message(role: .system, content: systemMessageContent)
    }
    
    /// Delete a message thread
    ///
    /// ```
    ///    await client.deleteMessageThread(id: "[message-thread-id]", success: {
    ///         // Message thread deleted successfully
    ///     }, error: { error in
    ///         // Failed to delete message thread
    ///     })
    /// ```
    ///
    /// > Tip: If your account is billed for storage, deleting message threads will reduce your storage costs.
    ///
    /// - Parameters:
    ///   - id: ID of the message thread to delete
    ///   - success: A closure that is executed when the message thread is successfully deleted
    ///   - error: A closure that is executed if there is an error during the deletion of the message thread
    /// - Returns: Void
    public func deleteMessageThread(id: String, success successCompletion: @escaping @Sendable (_ id: String) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let path = "message_threads/\(id)"
        deleteResource(path: path) { result in
            switch result {
            case .success:
                FreeToken.shared.logger("🚮 Message thread deleted successfully: \(id)", .info)
                successCompletion(id)
            case .failure(let error):
                FreeToken.shared.logger("🔴 Failed to delete message thread: \(error)", .error)
                errorCompletion(error)
            }
        }
    }
    
    /// Load a message thread from FreeToken Cloud
    ///
    /// ```
    ///     client.getMessageThread(id: "[message-thread-id]") { messageThread in
    ///         // Show your messages in the UI
    ///         // Array of messages: messageThread.messages
    ///     } error: { error in
    ///        // Can retry for connection issues.
    ///        print(error.localizedDescription)
    ///     }
    /// ```
    ///
    /// > Note: This returns all messages from a message thread, and can be used as the
    /// > source of truth for the message thread.
    ///
    /// - Parameters:
    ///     - id: Message Thread ID
    ///     - success: A closure for capturing the results of the call to load the message thread
    ///     - error: A closure for capturing any errors that occur during the call.
    ///
    ///     - Returns: Void
    public func getMessageThread(id: String, success successCompletion: @escaping @Sendable (MessageThread) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        await messagesManager.getMessageThread(id: id) { messageThread, _ in
            await successCompletion(messageThread)
        } failure: { error in
            await errorCompletion(error)
        }
    }
    
    /// Add a message to a message thread
    ///
    /// ```
    ///     await client.addMessageToThread(id: "msg_thr-id", message: FreeToken.Message(role: .user, content: "Hello!"), success: { message in
    ///         // Message was created successfully
    ///         // Display message in your UI
    ///     }, error: { error in
    ///         // Message could not be created. Retry?
    ///     })
    /// ```
    ///
    /// > Note: Created messages are not immediately sent to the AI. You must call ``runMessageThread``
    /// > to run this on the AI.
    ///
    /// - Parameters:
    ///     - id: ID of the message thread to add the message
    ///     - message: The `Message` object to add to the thread
    ///     - success: A closure to capture the results of the call to add the message to the thread
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func addMessageToThread(id messageThreadID: String, message: Message, success successCompletion: @escaping @Sendable (Message) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let profiler = Profiler()
        await messagesManager.addMessage(message: message, messageThreadID: messageThreadID) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: Profiler.EventType.addMessageToThread, eventTypeID: response.id, isSuccess: true)
                response.tokenUsage = message.tokenUsage
                await successCompletion(response)
            case .failure(let error):
                profiler.end(eventType: .addMessageToThread, isSuccess: false, errorMessage: error.message)
                await errorCompletion(error)
            }
        }
    }
    
    /// Get Message by ID
    ///
    /// ```
    ///     client.getMessage(id: "msg-id") { message in
    ///         // Do what you want with the message
    ///     } error: { error in
    ///         // Could not get the message - retry?
    ///     }
    /// ```
    ///
    /// > Note: Messages cannot be deleted or edited, so the ID should always exist as long as
    /// > you have access to the App the messages were created in.
    ///
    /// - Parameters:
    ///     - id: ID of the message
    ///     - success: A closure to capture the results of getting the message
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func getMessage(id: String, success successCompletion: @escaping @Sendable (Message) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        await messagesManager.getMessage(id: id) { result in
            switch result {
            case .success(let message):
                successCompletion(message)
            case .failure(let error):
                errorCompletion(error)
            }
        }
    }
    
    // MARK: New Session Based System
    
    /// Create a New Chat Session
    ///
    /// ```
    ///    let chatSession = try? await client.getChatSession(messageThreadID: "thread-id", modelCode: "model-code", runLocation: .automatic, toolAccess: [.allowAll])
    ///
    ///    let message = try? async chatSession?.generateNewMessage()
    ///
    ///    print("AI Response: \(message?.content ?? "No response")")
    /// ```
    ///
    /// > Tip: Don't provide a `messageThreadID` to create a completely new thread.
    ///
    /// > Tip: Use `toolAccess` to selectively define include tools that you have defined.
    ///
    /// > Tip: Use `runLocation` to define where you want the AI model to run.  If the model is not downloaded or the device is not capable, it will automatically fall back to cloud execution.
    ///
    /// - Parameters:
    ///  - messageThreadID: Optional messageThreadID
    ///  - modelCode: Optional model code to use for this session. If not provided, uses the default AI model for the Agent.
    ///  - runLocation: RunLocation enum to specify where to run the AI model. Defaults to `.automatic`.
    ///  - toolAccess: An array of `ToolRunMask` to define which tools will be available in this chat session. Defaults to `.allowAll`.
    /// - Returns: A `ChatSessionProtocol` object representing the chat session.
    public func getChatSession(
        messageThreadID: String? = nil,
        modelCode: String? = nil,
        runLocation: RunLocation = .automatic,
        toolAccess: [ToolRunMask] = [.allowAll],
        aiRunConfig: AIRunConfig? = nil
    ) async throws -> ChatSessionProtocol {
        let downloadStatus = try await getAIModelDownloadState(modelCode: modelCode)
        let aiModel = try await getAIModel(modelCode: modelCode)
        let availableMemoryToLoad = aiModel.availableMemoryToLoad()
        
        switch runLocation {
        case .cloudRun:
            return try await getCloudChatSession(messageThreadID: messageThreadID, modelCode: modelCode, toolAccess: toolAccess, aiRunConfig: aiRunConfig)
        case .automatic:
            if !aiModel.cloudOnly && downloadStatus == .downloaded && availableMemoryToLoad {
                return try await getLocalChatSession(messageThreadID: messageThreadID, modelCode: modelCode, runLocation: runLocation, toolAccess: toolAccess, aiRunConfig: aiRunConfig)
            } else {
                return try await getCloudChatSession(messageThreadID: messageThreadID, modelCode: modelCode, toolAccess: toolAccess, aiRunConfig: aiRunConfig)
            }
        case .localRun:
            guard !aiModel.cloudOnly else {
                throw FreeTokenError.isCloudOnlyModel
            }
            
            if downloadStatus == .downloaded && availableMemoryToLoad {
                return try await getLocalChatSession(messageThreadID: messageThreadID, modelCode: modelCode, runLocation: runLocation, toolAccess: toolAccess, aiRunConfig: aiRunConfig)
            } else {
                if downloadStatus != .downloaded {
                    throw FreeTokenError.aiModelNotDownloaded
                } else {
                    throw FreeTokenError.deviceNotCapable
                }
            }
        }
    }
    
    internal func getLocalChatSession(
        messageThreadID: String? = nil,
        modelCode: String? = nil,
        runLocation: RunLocation = .automatic,
        toolAccess: [ToolRunMask] = [.allowAll],
        aiRunConfig: AIRunConfig? = nil
    ) async throws -> ChatSessionProtocol {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModel = try await self.getAIModel(modelCode: modelCode)
        
        guard runLocation != .cloudRun else {
            self.logger("🚫 Tried to generate a local chat session when the run location is cloud.", .error)
            throw FreeTokenError.error(message: "Invalid run location - Tried to run on cloud with a local call. Try `getCloudChatSession` instead.", code: 10003)
        }
        
        // Is Model Downloaded?
        guard try await getAIModelDownloadState(modelCode: modelCode) == .downloaded else {
            self.logger("🚫 Tried to generate a local chat session when the model is not downloaded.", .error)
            throw FreeTokenError.aiModelNotDownloaded
        }
        
        // Is Device Capable?
        guard aiModel.canInitializeOnDevice() == true else {
            self.logger("🚫 Tried to generate a local chat session when the device is not AI capable.", .error)
            throw FreeTokenError.deviceNotCapable
        }
        
        if aiModel.availableMemoryToLoad() {
            let systemMessage = await buildSystemMessage(toolAccess: toolAccess)
            
            return try await ChatSession(client: self, aiModel: aiModel, systemMessage: systemMessage, runLocation: runLocation, messagesManager: messagesManager, toolDefinitionsManager: toolDefinitionsManager, queue: AITaskQueue.shared, messageThreadID: messageThreadID, aiRunConfig: aiRunConfig)
        } else if runLocation == .automatic {
            // Go to cloud
            return try await self.getCloudChatSession(messageThreadID: messageThreadID, modelCode: aiModel.code, toolAccess: toolAccess)
        } else {
            // Throw
            throw FreeTokenError.notEnoughMemoryForModel(message: "Not enough memory to initialize model - try .automatic mode for cloud fallback")
        }
    }
    
    internal func getCloudChatSession(
        messageThreadID: String? = nil,
        modelCode: String? = nil,
        toolAccess: [ToolRunMask] = [.allowAll],
        aiRunConfig: AIRunConfig? = nil
    ) async throws -> CloudChatSession {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModel = try await self.getAIModel(modelCode: modelCode)
                    
        return CloudChatSession(client: self, aiModel: aiModel, messagesManager: messagesManager, toolDefinitionsManager: toolDefinitionsManager,toolAccess: toolAccess, messageThreadID: messageThreadID, aiRunConfig: aiRunConfig)
    }
    
    public func getMemoryChatSession(
        modelCode: String? = nil,
        runLocation: RunLocation = .automatic,
        toolAccess: [ToolRunMask] = [.allowAll],
        messages: [Message] = [],
        systemInstructions: String = "",
        sessionID: String = UUID().uuidString,
        aiRunConfig: AIRunConfig? = nil
    ) async throws -> MemoryChatSession {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }

        let aiModel = try await self.getAIModel(modelCode: modelCode)

        guard runLocation != .cloudRun else {
            self.logger("🚫 Tried to generate a local chat session when the run location is cloud.", .error)
            throw FreeTokenError.error(message: "Invalid run location - Tried to run on cloud with a local call. Try `getCloudChatSession` instead.", code: 10003)
        }

        // Is Model Downloaded?
        guard try await getAIModelDownloadState(modelCode: modelCode) == .downloaded else {
            self.logger("🚫 Tried to generate a local chat session when the model is not downloaded.", .error)
            throw FreeTokenError.aiModelNotDownloaded
        }

        // Is Device Capable?
        guard aiModel.canInitializeOnDevice() else {
            self.logger("🚫 Tried to generate a local chat session when the device is not AI capable.", .error)
            throw FreeTokenError.deviceNotCapable
        }

        // Generate System Message
        let systemMessage = await buildSystemMessage(toolAccess: toolAccess)

        return await MemoryChatSession(client: self, aiModel: aiModel, systemMessage: systemMessage, toolDefinitionsManager: toolDefinitionsManager, toolAccess: toolAccess, queue: AITaskQueue.shared, sessionID: sessionID, messages: messages, aiRunConfig: aiRunConfig)
    }
    
    /// Create a New Completion Session
    ///
    /// ```
    ///   let completionSession = try? await client.getCompletionSession()
    ///   let response = try? await completionSession?.generateCompletion(prompt: "Hello, world!")
    ///   print("AI Completion: \(response?.text ?? "No response")")
    /// ```
    ///
    ///  > Tip: Use `runLocation` to define where you want the AI model to run.  If the model is not downloaded or the device is not capable, it will automatically fall back to cloud execution.
    ///
    ///  > Tip: Use `modelCode` if you want to use a specific model for this completion session.  If not provided, the default AI model for the Agent will be used.
    ///
    ///  - Parameters:
    ///     - modelCode: Optional model code to use for this session. If not provided, uses the default AI model for the Agent.
    ///     - runLocation: RunLocation enum to specify where to run the AI model. Defaults to `.automatic`.
    ///  - Returns: A `CompletionSessionProtocol` object representing the completion session.
    public func getCompletionSession(
        modelCode: String? = nil,
        runLocation: RunLocation = .automatic,
        aiRunConfig: AIRunConfig? = nil
    ) async throws -> CompletionSessionProtocol {
        let downloadState = try await getAIModelDownloadState(modelCode: modelCode) == .downloaded
        let aiModel = try await self.getAIModel(modelCode: modelCode)
        
        if downloadState && aiModel.availableMemoryToLoad() && runLocation != .cloudRun {
            return try await getLocalCompletionSession(modelCode: modelCode, runLocation: runLocation, aiRunConfig: aiRunConfig)
        } else {
            return try await getCloudCompletionSession(modelCode: modelCode, aiRunConfig: aiRunConfig)
        }
    }
    
    internal func getLocalCompletionSession(
        modelCode: String? = nil,
        runLocation: RunLocation = .automatic,
        aiRunConfig: AIRunConfig? = nil
    ) async throws -> CompletionSession {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModel = try await getAIModel(modelCode: modelCode)
        
        // Is Model Downloaded?
        guard try await getAIModelDownloadState(modelCode: modelCode) == .downloaded else {
            self.logger("🚫 Tried to generate a local completion session when the model is not downloaded.", .error)
            throw FreeTokenError.aiModelNotDownloaded
        }
        
        // Is Device Capable?
        guard aiModel.canInitializeOnDevice() else {
            self.logger("🚫 Tried to generate a local completion session when the device is not AI capable.", .error)
            throw FreeTokenError.deviceNotCapable
        }
        
        return try CompletionSession(client: self, aiModel: aiModel, runLocation: runLocation, queue: AITaskQueue.shared, aiRunConfig: aiRunConfig)
    }
    
    internal func getCloudCompletionSession(
        modelCode: String? = nil,
        aiRunConfig: AIRunConfig? = nil
    ) async throws -> CloudCompletionSession {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModel = try await getAIModel(modelCode: modelCode)
        
        return CloudCompletionSession(client: self, aiModel: aiModel, aiRunConfig: aiRunConfig)
    }
    
    
    internal func generateCloudCompletion(prompt: String, modelCode: Optional<String> = nil, aiRunConfig: AIRunConfig? = nil, tokenStream: Optional<@Sendable (_ token: String) async throws -> Void> = nil, success successCompletion: @escaping @Sendable (Completion) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        var maxTokens: Int? = nil
        if let value = aiRunConfig?.maxGenerationTokens {
            maxTokens = value
        }

        let request = Codings.CreateCompletionRequest(prompt: prompt, model: modelCode, maxTokens: maxTokens)
        let profiler = Profiler()
        
        // Check if we need streaming support
        if let tokenStream = tokenStream {
            // Use streaming version - convert to chat format for streaming support
            let messages = [Codings.CodableMessage(role: "user", content: prompt, attachments: nil)]
            let chatRequest = Codings.CreateCloudChatCompletion(messages: messages, model: modelCode, topK: nil, topP: nil, temperature: nil, maxTokens: maxTokens)
            
            actor StreamingState {
                private var _isCancelled = false
                private var _completionText = ""
                
                var isCancelled: Bool {
                    return _isCancelled
                }
                
                var completionText: String {
                    return _completionText
                }
                
                func appendText(_ text: String) {
                    _completionText += text
                }
                
                func cancel() {
                    _isCancelled = true
                }
            }
            
            let streamingState = StreamingState()
            
            await streamPostData(path: "completions/chat", data: chatRequest, responseType: Codings.CloudChatResponse.self) { chunk in
                // Check if already cancelled
                if await streamingState.isCancelled {
                    return
                }
                
                // With SSE preprocessing, we get clean JSON chunks that can be parsed directly
                if chunk.range(of: "message_chunk") != nil && !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let data = chunk.data(using: .utf8) {
                        do {
                            let decoder = JSONDecoder()
                            let messageContentChunk = try decoder.decode(Codings.MessageContentChunk.self, from: data)
                            
                            if !messageContentChunk.messageChunk.isEmpty {
                                await streamingState.appendText(messageContentChunk.messageChunk)
                                do {
                                    try await tokenStream(messageContentChunk.messageChunk)
                                } catch {
                                    // User cancelled generation through tokenStream
                                    FreeToken.shared.logger("⚠️ Token stream threw error, cancelling generation: \(error)", .warning)
                                    await streamingState.cancel()
                                }
                            }
                        } catch {
                            FreeToken.shared.logger("🔴 Error decoding message content chunk: \(chunk) - ERROR: \(error)", .error)
                        }
                    }
                }
            } completion: { result in
                // Check if cancelled by user
                if await streamingState.isCancelled {
                    await errorCompletion(FreeTokenError.generationCancelled)
                    return
                }
                
                switch result {
                case .success(let response):
                    if let errorResponse = response.error {
                        FreeToken.shared.logger("🔴 Error in cloud completion: \(errorResponse.message)", .error)
                        profiler.end(eventType: .generateCloudCompletion, isSuccess: false, errorMessage: errorResponse.message)
                        await errorCompletion(FreeTokenError.cloudCompletionFailed(message: errorResponse.message))
                        return
                    }
                    
                    profiler.end(eventType: Profiler.EventType.generateCloudCompletion, isSuccess: true)
                    FreeToken.shared.logger("Completion generated successfully", .info)
                    
                    // Create completion from accumulated text
                    let completion = Completion(response: await streamingState.completionText)
                    await successCompletion(completion)
                    
                case .failure(let error):
                    profiler.end(eventType: .generateCloudCompletion, isSuccess: false, errorMessage: error.message)
                    FreeToken.shared.logger("Completion failed to generate", .error)
                    await errorCompletion(error)
                }
            }
        } else {
            // Non-streaming version
            await postData(path: "completions", data: request, responseType: Codings.CreateCompletionResponse.self) { result in
                switch result {
                case .success(let response):
                    profiler.end(eventType: Profiler.EventType.generateCloudCompletion, isSuccess: true)
                    FreeToken.shared.logger("Completion generated successfully", .info)
                    await successCompletion(Completion(from: response))
                case .failure(let error):
                    profiler.end(eventType: .generateCloudCompletion, isSuccess: false, errorMessage: error.message)
                    FreeToken.shared.logger("Completion failed to generate", .error)
                    await errorCompletion(error)
                }
            }
        }
    }
    
    /// Generate a chat completion in the cloud
    ///
    ///
    internal func generateCloudChatCompletion(
        messages: [Message],
        model: String? = nil,
        aiRunConfig: AIRunConfig? = nil,
        chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
        success successCallback: @escaping @Sendable (Message) async -> Void,
        error errorCallback: @escaping @Sendable (FreeTokenError) async -> Void
    ) async {
        guard isDeviceRegistered() else {
            await errorCallback(FreeTokenError.deviceNotRegistered)
            return
        }

        // Check if any messages contain image attachments
        let hasImageAttachments = messages.contains { message in
            guard let attachments = message.attachments else { return false }
            return !attachments.isEmpty
        }
        
        // If there are image attachments and no specific model is requested, check the default model's capabilities
        if hasImageAttachments && model == nil {
            let supportsImageToText = deviceDetails?.aiModel.capabilities.imageToText ?? false
            if !supportsImageToText {
                FreeToken.shared.logger("🔴 Default model does not support image-to-text capabilities", .error)
                await errorCallback(FreeTokenError.visionModelRequired)
                return
            }
        }
        // Note: When a specific model code is provided, we currently cannot validate its capabilities
        // without fetching model information from the server. This validation would need to be done
        // server-side or by implementing a model info API endpoint.

        let preparedMessages: [Message]
        do {
            let promptTemplateConfig = deviceDetails!.aiModel.config.promptTemplateConfig
            
            preparedMessages = try MessagePrep(messages: messages, promptTemplateConfig: promptTemplateConfig).prepareMessages()
        } catch {
            FreeToken.shared.logger("🔴 Error preparing messages for chat completion: \(error.localizedDescription)", .error)
            await errorCallback(error as! FreeTokenError)
            return
        }
        let config = deviceDetails!.aiModel.config.defaultSettings
        
        // Convert types
        let requestMessages = preparedMessages.map { message in
            let urls: [Codings.CodableAttachment]?
            
            if let attachments = message.attachments {
                urls = attachments.map { attachment in
                    let base64String = attachment.data.base64EncodedString()
                    let imageType = attachment.contentType
                    return Codings.CodableAttachment(imageUrl: "data:\(imageType);base64,\(base64String)")
                }
            } else {
                urls = nil
            }
            
            return Codings.CodableMessage(role: message.role.rawValue, content: message.content, attachments: urls)
        }
        
        let topK: Int = aiRunConfig?.topK ?? config.topK
        let topP: Float = aiRunConfig?.topP ?? config.topP
        let temperature: Float = aiRunConfig?.temperature ?? config.temperature
        let maxTokens: Int = aiRunConfig?.maxGenerationTokens ?? config.maxTokenCount
                
        let request: Codings.CreateCloudChatCompletion = Codings.CreateCloudChatCompletion(messages: requestMessages, model: model, topK: topK, topP: topP, temperature: temperature, maxTokens: maxTokens)
        
        let profiler = Profiler()
        
        actor CancellationState {
            private var _isCancelled = false
            
            var isCancelled: Bool {
                return _isCancelled
            }
            
            func cancel() {
                _isCancelled = true
            }
        }
        
        let cancellationState = CancellationState()
        
        await streamPostData(path: "completions/chat", data: request, responseType: Codings.CloudChatResponse.self) { chunk in
            // Check if already cancelled
            if await cancellationState.isCancelled {
                return
            }
            
            if let chatStatusStream = chatStatusStream {
                // With SSE preprocessing, we get clean JSON chunks that can be parsed directly
                if chunk.range(of: "message_chunk") != nil && !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let data = chunk.data(using: .utf8) {
                        do {
                            let decoder = JSONDecoder()
                            // Try to decode as a single message chunk directly
                            let messageContentChunk = try decoder.decode(Codings.MessageContentChunk.self, from: data)
                            
                            // Process the message chunk
                            // If the content is empty, we skip it
                            if !messageContentChunk.messageChunk.isEmpty {
                                // Send the message chunk to the chat status stream via actor for sequential delivery
                                do {
                                    try await chatStatusStream(messageContentChunk.messageChunk, .streaming_tokens)
                                } catch {
                                    // User threw an error in chatStatusStream, cancel generation
                                    FreeToken.shared.logger("⚠️ Chat status stream threw error, cancelling generation: \(error)", .warning)
                                    await cancellationState.cancel()
                                }
                            }
                        } catch {
                            FreeToken.shared.logger("🔴 Error decoding message content chunk: \(chunk) - ERROR: \(error)", .error)
                        }
                    }
                }
            }
        } completion: { result in
            // Check if cancelled by user
            if await cancellationState.isCancelled {
                await errorCallback(FreeTokenError.generationCancelled)
                return
            }
            switch result {
            case .success(let response):
                if let errorResponse = response.error {
                    do {
                        try await chatStatusStream?(nil, .failed)
                    } catch {
                        // Ignore errors in failed status
                    }
                    FreeToken.shared.logger("🔴 Error in cloud chat completion: \(errorResponse.message)", .error)

                    profiler.end(eventType: Profiler.EventType.generateCloudChatCompletion, isSuccess: false, errorMessage: errorResponse.message)
                    
                    // Hit an error while processing
                    let error = FreeTokenError.cloudCompletionFailed(message: errorResponse.message)
                    
                    await errorCallback(error)
                    return
                }
                
                // Process the response
                if let tokenUsage = response.tokenUsage, let responseMessage = response.message {
                    let usage = TokenUsage(from: tokenUsage)
                    do {
                        let message = try await Message.fromCloudResponse(responseMessage, tokenUsage: usage)
                        profiler.end(eventType: Profiler.EventType.generateCloudChatCompletion, isSuccess: true, tokenStats: usage)
                        if let chatStatusStream = chatStatusStream {
                            do {
                                try await chatStatusStream(nil, .stream_ended)
                            } catch {
                                // Ignore errors at the end
                            }
                        }
                        
                        // Call the success callback
                        await successCallback(message)
                    } catch {
                        do {
                            try await chatStatusStream?(nil, .failed)
                        } catch {
                            // Ignore errors in failed status
                        }
                        FreeToken.shared.logger("🔴 Failed to parse cloud response message with images: \(error)", .error)
                        await errorCallback(FreeTokenError.cloudCompletionInvalidResponse)
                    }
                } else {
                    // Error that there wasn't the right response
                    do {
                        try await chatStatusStream?(nil, .failed)
                    } catch {
                        // Ignore errors in failed status
                    }
                    FreeToken.shared.logger("🔴 Invalid response from cloud chat completion", .error)
                    await errorCallback(FreeTokenError.cloudCompletionInvalidResponse)
                }
            case .failure(let error):
                // Handle the error
                do {
                    try await chatStatusStream?(nil, .failed)
                } catch {
                    // Ignore errors in failed status
                }
                FreeToken.shared.logger("🔴 Failed to generate chat completion: \(error)", .error)
                
                // Call the error callback
                await errorCallback(error)
            }
        }

    }
    
    
    /// Create a document to be searched in your App's vector store
    ///
    /// ```
    ///     client.createDocument(content: blogPost.body, metadata: "TITLE: My blog post!\nDATE: Jan 1, 2025", searchScope: "blog-posts", success: { document in
    ///         // Created Successfully!
    ///     }, error: { error in
    ///         // Failed to create - retry?
    ///     })
    /// ```
    ///
    /// > Warning: Any document stored without a `privateDocumentStoreID` should be considered public data. It is not secure or protected from other users access.
    ///
    /// > Note: It is not recommended that you use the document store as a persistence store in your app. Only use it for context to be provided to an AI.
    ///
    /// > Tip: For large documents, break them into chunks.  Large documents may hit an upload error.
    ///
    /// - Parameters:
    ///     - content: content of the document
    ///     - metadata: User defined metadata to attach to the document in String format
    ///     - searchScope: String scope to use when looking up documents in Agents or via the API
    ///     - privateDocumentStoreID: Optional private document store ID, when added will create the document in the supplied private store (rather than in public space)
    ///     - success: A closure to capture the result of the document being created
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func createDocument(
        content: String,
        metadata: Optional<String> = nil,
        searchScope: String,
        privateDocumentStoreID: Optional<String> = nil,
        success successCompletion: @escaping @Sendable (Document) -> Void,
        error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void
    ) async throws {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let document: FreeToken.DocumentManager.Document
        do {
            document = try await self.documentManager!.processDocument(content: content, metadata: metadata)
        } catch {
            if let freeTokenError = error as? FreeTokenError {
                errorCompletion(freeTokenError)
            } else {
                errorCompletion(FreeTokenError.unableToGenerateEmbedding)
            }
            return
        }
        
        let encryptionScope: EncryptionScope
        if privateDocumentStoreID != nil {
            encryptionScope = .userPrivate
        } else {
            encryptionScope = .sharedPublic
        }
        
        let chunks = try document.chunks.map { chunk in
            let content = try encryptionManager.encrypt(chunk.chunkContent, encryptionScope)
            return Codings.CreateDocumentChunkRequest(content: content, embedding: chunk.embedding!, embeddingModel: chunk.embeddingModelName)
        }
        
        let request = Codings.CreateDocumentRequest(
            content: try encryptionManager.encrypt(content, encryptionScope),
            metadata: (metadata != nil ? try encryptionManager.encrypt(metadata!, encryptionScope) : nil),
            searchScope: searchScope,
            documentChunks: chunks,
            encryptionEnabled: encryptionManager.isEncryptionEnabled,
            privateDocumentStoreID: privateDocumentStoreID
        )
        
        let wrapper = Codings.CreateDocumentRequestWrapper(document: request)
        
        let profiler = Profiler()
        await postData(path: "documents", data: wrapper, responseType: Codings.ShowDocumentResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: .createDocument, isSuccess: true)
                FreeToken.shared.logger("📄 Document created successfully", .info)
                do {
                    let document = try Document(from: response)
                    successCompletion(document)
                } catch {
                    let error = FreeTokenError.encryptionError(message: "Initializing the document failed with error: \(error.localizedDescription)")
                    errorCompletion(error)
                }
            case .failure(let error):
                profiler.end(eventType: .createDocument, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("🔴 Document failed to create with error: \(error)", .error)
                errorCompletion(error)
            }
        }
    }

    /// Get a document by ID
    ///
    /// ```
    ///     client.getDocument(id: "doc-id") { result in
    ///         switch result {
    ///         case .success(let document):
    ///             // Do what you'd like with the doc.
    ///             // document.content
    ///         case .failure(let error):
    ///             // Handle the error or retry?
    ///     }
    /// ```
    ///
    /// - Parameters:
    ///     - id: String of the Document ID
    ///     - success: A closure to capture the result of fetching the document
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func getDocument(id: String, success successCompletion: @escaping @Sendable (Document) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let path = "documents/\(id)"
        await fetchResource(path: path, responseType: Codings.ShowDocumentResponse.self, useEtagCaching: true) { result in
            switch result {
            case .success(let response):
                do {
                    let document = try Document(from: response)
                    successCompletion(document)
                } catch {
                    let error = FreeTokenError.encryptionError(message: "Failed to initialize document with error: \(error.localizedDescription)")
                    errorCompletion(error)
                }
            case .failure(let error):
                errorCompletion(error)
            }
        }
    }
    
    /// Search for document chunks with a query
    ///
    /// ```
    ///     client.searchDocuments(query: "A nova is a special kind of space event", success: { results in
    ///         // Use the document chunks in your own AI requests
    ///         // results.documentChunks
    ///     }, error: { error in
    ///         // Handle the search error - retry?
    ///     })
    /// ```
    ///
    /// > Note: The search results do not result in documents but instead document chunks.  Document chunks contain
    /// > document IDs so if you'd like to fetch the entire document you can with the ID.
    ///
    /// > Tip: Use this method to perform your own RAG inside other AI queries or completions.
    ///
    /// - Parameters:
    ///     - query: String to query by vector and keywords
    ///     - searchScope: Find only documents that match this scope
    ///     - privateDocumentStoreIds: Array of private document store IDs to search within
    ///     - maxResults: Max number of results to return
    ///     - success: A closure to capture the result of searching for documents
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func searchDocuments(query: String, searchScope: Optional<String> = nil, privateDocumentStoreIds: Optional<[String]> = nil, maxResults: Optional<Int> = nil, success successCompletion: @escaping @Sendable (DocumentSearchResults) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        // EmbeddingManager
        var embedding: [Float]
        do {
            embedding = try await EmbeddingManager.shared.generate(text: query)
        } catch {
            FreeToken.shared.logger("🔴 Failed to generate embedding for search query: \(error.localizedDescription)", .error)
            let errorResponse = FreeTokenError.embeddingFailed
            await errorCompletion(errorResponse)
            return
        }
        
        var useAgentDocumentScope = true
        if searchScope != nil {
            useAgentDocumentScope = false
        }
        
        var resultCount: Int? = nil
        if maxResults != nil {
            resultCount = maxResults!
        }
        
        let path = "documents/search"
        let data = Codings.SearchDocumentsRequest(embedding: embedding, embeddingModel: EmbeddingManager.shared.embeddingModelName, documentScope: searchScope, privateDocumentStoreIds: privateDocumentStoreIds, resultCount: resultCount, useAgentDocumentScope: useAgentDocumentScope)
        
        let profiler = Profiler()
        await postData(path: path, data: data, responseType: Codings.SearchDocumentsResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: Profiler.EventType.searchDocuments, isSuccess: true)
                do {
                    let searchResults = try DocumentSearchResults(from: response)
                    await successCompletion(searchResults)
                } catch {
                    let error = FreeTokenError.encryptionError(message: "Failed to initialize document search results with error: \(error.localizedDescription)")
                    await errorCompletion(error)
                }
            case .failure(let error):
                profiler.end(eventType: .searchDocuments, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("🔴 Document search failed with error \(error.message)", .error)
                await errorCompletion(error)
            }
        }
    }
    
    /// Create a private document store
    ///
    /// ```
    ///     client.createPrivateDocumentStore(name: "My Documents", success: { store in
    ///         // Store created successfully, use store.id to create documents
    ///         let storeId = store.id
    ///     }, error: { error in
    ///         // Handle creation error
    ///     })
    /// ```
    ///
    /// > Note: Private document stores are identified by their server-generated ID.
    /// > The name is used server-side for identification but only the ID is returned.
    /// > Encryption is handled at the document level when creating individual documents.
    ///
    /// - Parameters:
    ///     - name: Optional name for identifying the store server-side
    ///     - success: A closure to capture the created private document store
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func createPrivateDocumentStore(name: String, success successCompletion: @escaping @Sendable (PrivateDocumentStore) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let path = "private_document_stores"
        let data = Codings.CreatePrivateDocumentStoreRequest(name: name)
        
        let profiler = Profiler()
        await postData(path: path, data: data, responseType: Codings.CreatePrivateDocumentStoreResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: .createDocument, isSuccess: true)
                successCompletion(PrivateDocumentStore(from: response))
            case .failure(let error):
                profiler.end(eventType: .createDocument, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("Private document store creation failed with error \(error.message)", .error)
                errorCompletion(error)
            }
        }
    }
        
    /// Delete a private document store
    ///
    /// ```
    ///     client.deletePrivateDocumentStore(id: "store-id", success: {
    ///         // Store deleted successfully
    ///     }, error: { error in
    ///         // Handle deletion error
    ///     })
    /// ```
    ///
    /// > Warning: This will permanently delete the private document store and all documents within it.
    /// > This action cannot be undone.
    ///
    /// - Parameters:
    ///     - id: The ID of the private document store to delete
    ///     - success: A closure called when the store is successfully deleted
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func deletePrivateDocumentStore(id: String, success successCompletion: @escaping @Sendable () -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let path = "private_document_stores/\(id)"
        let profiler = Profiler()
        deleteResource(path: path) { result in
            switch result {
            case .success():
                profiler.end(eventType: .createDocument, isSuccess: true) // Using createDocument event type for now
                FreeToken.shared.logger("🗑️ Private document store deleted successfully", .info)
                successCompletion()
            case .failure(let error):
                profiler.end(eventType: .createDocument, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("🔴 Private document store deletion failed with error \(error.message)", .error)
                errorCompletion(error)
            }
        }
    }
    
    /// Perform Web Search
    ///
    /// Perform web searches and retrieve results for use in AI or user-facing features. This is the same method that is used by the AI to search the web for relevant information when generating completions or responses.
    ///
    /// ```
    ///     await client.webSearch(
    ///         query: "latest AI news",
    ///         resultCount: 3,
    ///         success: { results in
    ///             for result in results {
    ///                 print("Web result: \(result.title) - \(result.url)")
    ///             }
    ///         },
    ///         error: { error in
    ///             print("Web search failed: \(error)")
    ///         }
    ///     )
    /// ```
    ///
    /// > Note: You must setup the web search with an API key in the FreeToken dashboard before using this feature.
    ///
    /// - Parameters:
    ///     - query: The search query string
    ///     - resultCount: Optional number of results to return
    ///     - success: A closure to capture the web search results
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func webSearch(query: String, resultCount: Int? = nil, success successCompletion: @escaping @Sendable ([WebSearchResult]) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let path = "tool_calls/web_search"
        let data = Codings.WebSearchRequest(query: query, resultCount: resultCount)
        
        let profiler = Profiler()
        await postData(path: path, data: data, responseType: Codings.WebSearchResults.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: Profiler.EventType.webSearch, isSuccess: true)
                let results = response.results.map { WebSearchResult(from: $0) }
                for result in results {
                    FreeToken.shared.logger("🌐 Web Search Result: \(result.title)", .info)
                }
                successCompletion(results)
            case .failure(let error):
                profiler.end(eventType: .webSearch, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("🔴 Web search failed with error \(error.message)", .error)
                errorCompletion(error)
            }
        }
    }
    
    // Internal Method
    func sendTelemetry(profiler: Profiler) {
        let eventData = Codings.TelemetryDataRequest(eventDurationInMilliseconds: profiler.msDuration(), eventTypeId: profiler.eventTypeID, eventObjectType: profiler.eventObjectType, isSuccess: profiler.isSuccess, errorMessage: profiler.errorMessage, tokenStats: profiler.tokenStats?.asCodable(), telemetryDataVersion: 1)
        
        let eventType = profiler.eventType!.rawValue
        
        FreeToken.shared.logger("🛰️ Telemetry Stats - Event: \(eventType): Time: \(profiler.msDuration()!)ms", .info)
        
        Task.detached(priority: .background) {
            guard self.isDeviceRegistered() else {
                FreeToken.shared.logger("Telemetry: Device not registered", .warning)
                return
            }
            
            let request = Codings.TelemetryCreateRequest(eventType: eventType, eventData: eventData, version: profiler.telemetryDataVersion)
            
            await self.postData(path: "telemetries", data: request, responseType: Codings.TelemetryCreateResponse.self) { result in
                switch result {
                case .success(_):
                    break
                case .failure(let error):
                    FreeToken.shared.logger("Telemetry Creation Error: \(error.message)", .error)
                }
            }
        }
    }
    
    private func isDeviceRegistered() -> Bool {
        return deviceSession != nil
    }
    
    /// Fetches a specific resource by ID with optional query parameters.
    /// - Parameters:
    ///   - path: The API path to append to the base URL.
    ///   - queryParameters: A dictionary of query parameters to include in the URL.
    ///   - responseType: The expected type of the response.
    ///   - completion: Completion handler with the decoded response or an error.
    internal func fetchResource<T: Decodable & Sendable>(
        path: String,
        queryParameters: [String: String]? = nil,
        responseType: T.Type,
        useEtagCaching: Bool = false,
        completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
    ) async {
        guard isConfigured else {
            await completion(.failure(FreeTokenError.clientNotConfigured))
            return
        }

        let baseURL = self.baseURL!
        let apiKey = self.appToken!
        
        // Build the URL with query parameters
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if let queryParameters = queryParameters {
            urlComponents?.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let endpoint = urlComponents?.url else {
            await completion(.failure(FreeTokenError.invalidURL))
            return
        }

        // Set headers
        var headers: [String: String] = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
            "Client-Type": clientType,
            "Client-Version": clientVersion
        ]
        if deviceSessionToken != nil {
            headers["Device-Session-Token"] = deviceSessionToken
        }

        // Send the GET request
        await httpClient.get(from: endpoint, headers: headers, responseType: responseType, useETagCaching: useEtagCaching, completion: completion)
    }

    /// Posts data to the server.
    /// - Parameters:
    ///   - data: The object to send, encoded as JSON.
    ///   - responseType: The type of the expected response.
    ///   - completion: Completion handler with the decoded response or an error.
    internal func postData<T: Decodable & Sendable, U: Encodable>(
        path: String,
        data: U,
        responseType: T.Type,
        completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
    ) async {
        guard isConfigured else {
            await completion(.failure(FreeTokenError.clientNotConfigured))
            return
        }

        let baseURL = self.baseURL!
        let apiKey = self.appToken!
        
        
        let endpoint = baseURL.appendingPathComponent(path)
        
        do {
            let body = try JSONEncoder().encode(data)
            var headers: [String: String] = [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Client-Version": clientVersion,
                "Client-Type": clientType
            ]
                        
            if self.deviceSessionToken != nil {
                headers["Device-Session-Token"] = deviceSessionToken
            }
            
            await httpClient.post(to: endpoint, headers: headers, body: body, responseType: responseType, completion: completion)
        } catch {
            await completion(.failure(FreeTokenError.encoding(message: error.localizedDescription)))
        }
    }
    
    internal func postMultipartData<T: Decodable & Sendable>(
        path: String,
        jsonData: [String: Any],
        attachments: [MessageAttachment],
        responseType: T.Type,
        completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
    ) async {
        guard isConfigured else {
            await completion(.failure(FreeTokenError.clientNotConfigured))
            return
        }

        let baseURL = self.baseURL!
        let apiKey = self.appToken!
        let endpoint = baseURL.appendingPathComponent(path)
        
        var headers: [String: String] = [
            "Authorization": "Bearer \(apiKey)",
            "Client-Version": clientVersion,
            "Client-Type": clientType
        ]
                    
        if self.deviceSessionToken != nil {
            headers["Device-Session-Token"] = deviceSessionToken
        }
        
        await httpClient.postMultipart(to: endpoint, headers: headers, jsonData: jsonData, attachments: attachments, responseType: responseType, completion: completion)
    }
    
    /// Posts data to the server.
    /// - Parameters:
    ///   - data: The object to send, encoded as JSON.
    ///   - responseType: The type of the expected response.
    ///   - completion: Completion handler with the decoded response or an error.
    private func streamPostData<T: Decodable & Sendable, U: Encodable>(
        path: String,
        data: U,
        responseType: T.Type,
        streamCallback: @escaping @Sendable (String) async -> Void,
        completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
    ) async {
        guard isConfigured else {
            await completion(.failure(FreeTokenError.clientNotConfigured))
            return
        }

        let baseURL = self.baseURL!
        let apiKey = self.appToken!
        
        
        let endpoint = baseURL.appendingPathComponent(path)
        do {
            let body = try JSONEncoder().encode(data)
            var headers: [String: String] = [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Client-Version": clientVersion,
                "Client-Type": clientType
            ]
                        
            if self.deviceSessionToken != nil {
                headers["Device-Session-Token"] = deviceSessionToken
            }
            
            httpClient.streamPost(to: endpoint, headers: headers, body: body, streamCallback: streamCallback, completion: completion)
        } catch {
            await completion(.failure(error as! FreeTokenError))
        }
    }
    
    /// Delete a resource
    private func deleteResource(
        path: String,
        completion: @escaping @Sendable (Result<Void, FreeTokenError>) -> Void
    ) {
        guard isConfigured else {
            completion(.failure(FreeTokenError.clientNotConfigured))
            return
        }

        let baseURL = self.baseURL!
        let apiKey = self.appToken!
        
        let endpoint = baseURL.appendingPathComponent(path)
        
        // Set headers
        var headers: [String: String] = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
            "Client-Type": clientType,
            "Client-Version": clientVersion
        ]
        
        if deviceSessionToken != nil {
            headers["Device-Session-Token"] = deviceSessionToken
        }

        // Send the DELETE request
        httpClient.delete(from: endpoint, headers: headers, completion: completion)
    }
    
    // MARK: - Background Download Integration
    
    /// Handle background download events from AppDelegate
    /// 
    /// Call this method from your AppDelegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)` 
    /// to properly handle background downloads managed by FreeToken.
    ///
    /// ## Usage (iOS only)
    /// Add this to your iOS AppDelegate.swift:
    /// ```swift
    /// func application(_ application: UIApplication,
    ///                 handleEventsForBackgroundURLSession identifier: String,
    ///                 completionHandler: @escaping () -> Void) {
    ///     FreeToken.handleBackgroundDownloads(
    ///         identifier: identifier,
    ///         completionHandler: completionHandler
    ///     )
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - identifier: The session identifier provided by the system
    ///   - completionHandler: The completion handler that must be called when processing is complete
    /// - Note: On macOS/other platforms, the completion handler is called immediately as background processing differs
    public static func handleBackgroundDownloads(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // iOS-family platforms support background URLSession completion handlers
        DownloadManager.shared.handleBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
        #else
        // macOS and other platforms: background sessions work differently
        // Just call the completion handler immediately to satisfy the contract
        FreeToken.shared.logger("🔄 Background downloads handled differently on this platform. Calling completion handler immediately.", .info)
        completionHandler()
        #endif
    }
    
    /// Attaches or reattaches the background download session
    /// 
    /// Call this method early in your app launch (AppDelegate.didFinishLaunching or SwiftUI App.init)
    /// to ensure background downloads can resume and pending delegate callbacks are received.
    /// 
    /// Example usage:
    /// ```swift
    /// // In AppDelegate
    /// func application(_ application: UIApplication, 
    ///                didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    ///     FreeToken.attachDownloadSession()
    ///     return true
    /// }
    /// 
    /// // In SwiftUI App
    /// @main
    /// struct MyApp: App {
    ///     init() {
    ///         FreeToken.attachDownloadSession()
    ///     }
    /// }
    /// ```
    public static func attachDownloadSession() {
        DownloadManager.shared.attachSession()
    }

}
