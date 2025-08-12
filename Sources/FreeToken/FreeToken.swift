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
    
    let clientVersion = "1.0.0"
#if os(iOS)
    let clientType = "iOS"
#elseif os(macOS)
    let clientType = "macOS"
#endif
    let httpClient = HTTPClient()
    let messagesManager: MessagesManager
    let aiModelsManager: AIModelsManager = AIModelsManager()
    let toolDefinitionsManager = ToolDefinitionsManager()
    
    var clientConfigStatus: ClientConfigStatus = .notConfigured
    var baseURL: URL? = nil
    var appToken: String? = nil
    var deviceSessionToken: String? = nil
    var deviceDetails: Codings.ShowDeviceSessionResponse? = nil
    var aiModelManager: AIModelManager? {
        get {
            return aiModelsManager.defaultManager
        }
    }
    var deviceManager: DeviceManager? {
        get {
            return aiModelsManager.defaultDeviceManager
        }
    }
            
    var documentChunkSize: Int? = nil
    var documentChunkOverlapSize: Int? = nil
    var documentManager: DocumentManager? = nil
    
    let encryptionManager = EncryptionManager()
    
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
    }
    
    enum ClientConfigStatus: Equatable {
        case notConfigured
        case configured
    }
    
    // Methods:
    
    private init() {
        self.baseURL = URL(string: "https://api.freetoken.ai/api/v1/")!
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
    ///     - logLevel: Optional log level for the client. Default is `.info`
    ///
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
        let createDeviceSessionRequest = Codings.CreateDeviceSessionRequest(deviceSession: .init(scope: scope, clientType: clientType, clientVersion: clientVersion))
        
        await postData(path: "device_sessions", data: createDeviceSessionRequest, responseType: Codings.ShowDeviceSessionResponse.self) { result in
            switch result {
            case .success(let response):
                self.deviceSessionToken = response.token
                self.deviceDetails = response
                
                let embeddingDeviceManager = DeviceManager(memoryRequirement: response.embeddingModel.memoryRequirement)
                EmbeddingManager.shared.config(modelConfig: response.embeddingModel, deviceAICapable: embeddingDeviceManager.isAICapable)
                
                self.documentManager = DocumentManager(chunkSize: response.documentsConfig.documentChunkSize, overlapSize: response.documentsConfig.documentChunkOverlapSize)
                
                if response.aiModel.cloudOnly == false {
                    // Initialize the AI Model Manager
                    do {
                        _ = try self.aiModelsManager.addManager(modelConfig: response.aiModel, clientVersion: self.clientVersion, isDefault: true)
                    } catch {
                        FreeToken.shared.logger("🔴 Failed to initialize AI Model Manager: \(error.localizedDescription)", .error)
                        await errorCallback(error as! FreeToken.FreeTokenError)
                        profiler.end(eventType: Profiler.EventType.registerDeviceSession, isSuccess: false, errorMessage: error.localizedDescription)
                        return
                    }
                    
                    _ = self.aiModelsManager.getDeviceManager(for: response.aiModel.code)
                } else {
                    FreeToken.shared.logger("⏭️ AI Model is cloud-only, skipping local model initialization.", .info)
                }
                
                // Capture Tool Call Instructions
                await self.toolDefinitionsManager.setToolInstructions(response.toolInstructions)
                
                // Capture Built in and Cloud Tool Calls
                let builtInTools = response.builtInToolDefinitions.map { ToolDefinition(from: $0) }
                await self.toolDefinitionsManager.addToolDefinitions(builtInTools, type: .builtIn)
                
                let cloudTools = response.cloudToolDefinitions.map { ToolDefinition(from: $0) }
                await self.toolDefinitionsManager.addToolDefinitions(cloudTools, type: .cloud)
                
                FreeToken.shared.logger("📋 Device registered successfully", .info)
                
                profiler.end(eventType: Profiler.EventType.registerDeviceSession, isSuccess: true)
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
        aiModelsManager.reset()
        encryptionManager.reset()
        await toolDefinitionsManager.removeAllToolDefinitions()
    }
    
    /// Reset Model Caches
    ///
    public func resetModelCaches() async throws {
        try? await resetEmbeddingModelCache()
        await deleteAIModelCache()
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
    /// > Warning: This method deletes the entire AI model cache directory, including all downloaded models.
    ///
    /// - Returns: Void
    public func deleteAIModelCache() async {
#if os(macOS) || os(Linux)
        let defaultRootDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".localllmclient")
#else
        let defaultRootDirectory = URL.documentsDirectory.appending(path: ".localllmclient")
#endif
        
        await aiModelManager?.unloadModel()
        await aiModelManager?.stateManager.reset()
        
        // Delete the whole directory
        do {
            try FileManager.default.removeItem(at: defaultRootDirectory)
            FreeToken.shared.logger("🗑️ AI model cache reset successfully", .info)
        } catch {
            FreeToken.shared.logger("🔴 Failed to reset LLM model cache: \(error.localizedDescription)", .error)
        }
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
        
        var modelCode = modelCode
        
        if modelCode == nil {
            // Use the default model code if nothing is passed in
            modelCode = deviceDetails?.aiModel.code
        }
        
        let isDefaultModelCode = (modelCode == deviceDetails?.aiModel.code)
        progressPercent?(0.0)

        // Download a specific model by initializing a new AIModelManager
        if let modelManager = aiModelsManager.getManager(for: modelCode!), let deviceManager = aiModelsManager.getDeviceManager(for: modelCode!) {
            if await modelManager.stateManager.getDownloadState() == .downloaded {
                FreeToken.shared.logger("⏭️ Model \(modelCode!) already downloded, skipping download", .info)
                progressPercent?(1.0)
                await successCallback(.downloaded)
                return
            }
            
            guard deviceManager.isAICapable else {
                FreeToken.shared.logger("⏭️ Device does not meet AI model requirements for model \(modelCode!), skipping AI model download", .info)
                await successCallback(.aiNotSupported)
                return
            }
            
            do {
                let wasSuccess = try await modelManager.downloadIfNeeded(progress: progressPercent)
                if wasSuccess {
                    FreeToken.shared.logger("⬇️ Model \(modelManager.modelCode) downloaded successfully", .info)
                    await successCallback(.downloaded)
                } else {
                    FreeToken.shared.logger("🔴 Model \(modelManager.modelCode) did not download successfully", .error)
                    await errorCallback(FreeTokenError.aiModelDownload)
                }
            } catch {
                FreeToken.shared.logger("🔴 Failed to download AI model for code \(modelCode!): \(error.localizedDescription)", .error)
                await errorCallback(error as! FreeTokenError)
            }
        } else {
            // Initialize a new AIModelManager for the specific model code
            // Get model details by code
            await getAIModel(modelCode: modelCode!) { aiModel in
                if aiModel.cloudOnly {
                    FreeToken.shared.logger("🔴 AI model \(aiModel.code) is cloud-only skipping download.", .error)
                    await errorCallback(FreeTokenError.isCloudOnlyModel)
                    return
                }
                
                do {
                    let modelManager = try self.aiModelsManager.addManager(modelConfig: aiModel.coding, clientVersion: self.clientVersion, isDefault: isDefaultModelCode)
                    
                    let deviceManager = self.aiModelsManager.getDeviceManager(for: aiModel.code)! // Should always have a device manager since it was just added
                    
                    // Check if the device is capable of running AI models
                    guard deviceManager.isAICapable else {
                        FreeToken.shared.logger("⏭️ Device does not meet AI model requirements for model \(aiModel.code), skipping AI model download", .info)
                        await successCallback(.aiNotSupported)
                        return
                    }
                    
                    let wasSuccess = try await modelManager.downloadIfNeeded { percentage in
                        let newPercent = Double(percentage) * 100.0
                        progressPercent?(newPercent)
                    }
                    
                    if wasSuccess {
                        FreeToken.shared.logger("⬇️ Model \(aiModel.code) downloaded successfully", .info)
                        await successCallback(.downloaded)
                    } else {
                        FreeToken.shared.logger("🔴 Model \(aiModel.code) did not download successfully", .error)
                        await errorCallback(FreeTokenError.aiModelDownload)
                    }
                } catch {
                    // Failed to add AI model manager
                    FreeToken.shared.logger("🔴 Failed to initialize AI Model Manager for model code \(aiModel.code): \(error.localizedDescription)", .error)
                    await errorCallback(error as! FreeTokenError)
                }
            } error: { error in
                await errorCallback(error)
            }
        }
        await downloadEmbeddingModel()
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
    public func listAIModels(success successCompletion: @escaping @Sendable (_ aiModels: [AIModel]) async -> Void, error errorCompletion: @escaping @Sendable (_ error: FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        
        let path = "ai_models"
        await fetchResource(path: path, responseType: Codings.AIModelsResponse.self) { result in
            switch result {
            case .success(let response):
                let aiModels = response.aiModels.map { AIModel(from: $0) }
                await successCompletion(aiModels)
            case .failure(let error):
                await errorCompletion(error)
            }
        }
    }
    
    /// Get AI Model by Code
    ///
    /// ```
    ///   await client.getAIModel(modelCode: "model-code") { aiModel in
    ///   // aiModel is an AIModel object
    ///   }, error: { error in
    ///   // Failed to get AI model
    ///   })
    /// ```
    ///
    /// - Parameters:
    ///  - modelCode: The code of the AI model to retrieve.
    ///  - success: A closure that is executed when the AI model is successfully retrieved.
    ///  - error: A closure that is executed if there is an error during the retrieval of the AI model.
    /// - Returns: Void
    public func getAIModel(modelCode: String, success successCompletion: @escaping @Sendable (_ aiModel: AIModel) async -> Void, error errorCompletion: @escaping @Sendable (_ error: FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            FreeToken.shared.logger("Device not registered. Cannot fetch AI model.", .error)
            return
        }
        
        
        // URL escape the model code to handle special characters
        let path = "ai_models/\(modelCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelCode)"
        await fetchResource(path: path, responseType: Codings.AiModelResponse.self) { result in
            switch result {
            case .success(let response):
                let aiModel = AIModel(from: response)
                await successCompletion(aiModel)
            case .failure(let error):
                FreeToken.shared.logger("Failed to fetch AI Model: \(error.message)", .error)
                await errorCompletion(error)
            }
        }
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
        let deviceDetails = self.deviceDetails!
        
        var systemMessageContent = deviceDetails.systemInstructions
        
        let toolDefinitions = await toolDefinitionsManager.processToolMask(toolAccess)
        if toolDefinitions.isEmpty == false {
            let toolDefinitionJSON = toolDefinitions.map { $0.definition }.joined(separator: ",\n")
            systemMessageContent += "\n\n\(await toolDefinitionsManager.getToolInstructions())\n\nAvailable Tools:\n[\n\(toolDefinitionJSON)\n]"
        }
        
        let systemMessage = Message(role: .system, content: systemMessageContent)
        
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
    
    /// Token Counter
    ///
    ///
    /// - Parameters:
    ///    - text: The text to count tokens for
    ///    - modelCode: Optional AI Model Code to use for token counting. If not provided, the default model will be used.
    /// - Returns: The number of tokens in the provided text
    public func countTokens(text: String, modelCode: Optional<String> = nil) async throws -> Int {
        guard isDeviceRegistered() else {
            FreeToken.shared.logger("🔴 Device not registered. Cannot count tokens.", .error)
            return 0
        }
        
        // Use the AI Model Manager to count tokens
        let aiModelManager: AIModelManager?
        
        if let modelCode = modelCode {
            if let modelManager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = modelManager
            } else {
                FreeToken.shared.logger("⏭️ Token counting called for model code \(modelCode) - model not loaded", .warning)
                throw FreeTokenError.aiModelNotLoaded
            }
        } else {
            // Use Default AI Model Manager
            aiModelManager = self.aiModelManager
        }
        let message = Message(role: .user, content: text)
        
        return try await aiModelManager!.tokensCount(for: nil, messages: [message])
    }
    
    
    /// Generate an AI Completion
    ///
    /// ```
    ///     client.generateCompletion(prompt: "A supernova is") { response in
    ///         // Use the response to the completion how you would like:
    ///         // response.completion
    ///      } error: { error in
    ///         // Handle any errors
    ///     }
    /// ```
    ///
    /// > Note: This method will automatically determine whether to route the completion to the cloud or locally depending on
    /// > the state of the local device and device capabilities.  For more control on whether this runs in the cloud or locally,
    /// > use ``generateLocalCompletion(prompt:completion:)``
    /// > or ``generateCloudCompletion(prompt:modelCode:completion:)`` respectively.
    ///
    /// > Note: Completion outputs are not persisted in the cloud or on device. Any output is ephemiral.
    ///
    /// > Tip: Use this for data processing or background AI work.
    ///
    /// - Parameters:
    ///     - prompt: The prompt you want to send to the AI for completion
    ///     - modelCode: AI Model Code defined by FreeToken in the Admin interface. (Think of this like a model ID, unique to the individual AI model)
    ///     - maxTokens: Optional maximum number of tokens to generate in the completion
    ///     - success: A closure to capture the results of the call to generate the completion
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func generateCompletion(prompt: String, modelCode: Optional<String> = nil, aiRunConfig: AIRunConfig? = nil, success successCompletion: @escaping @Sendable (Completion) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        // Check if server forces cloud execution
        if deviceDetails?.forceCloudRun == true {
            await generateCloudCompletion(prompt: prompt, modelCode: modelCode, aiRunConfig: aiRunConfig, success: successCompletion, error: errorCompletion)
            return
        }
        
        let aiModelManager: AIModelManager?
        let deviceManager: DeviceManager?
        
        // Try to use the AI Model Manager for the specified model code
        if let modelCode = modelCode {
            if let modelManager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = modelManager
                deviceManager = aiModelsManager.getDeviceManager(for: modelCode)
            } else {
                FreeToken.shared.logger("⏭️ Completion called for model code \(modelCode) - model not loaded, running in cloud.", .warning)
                // Cloud Completion with model code
                await generateCloudCompletion(prompt: prompt, modelCode: modelCode, aiRunConfig: aiRunConfig, success: successCompletion, error: errorCompletion)
                return
            }
        } else {
            // Run with Default AI Model Manager
            aiModelManager = self.aiModelManager
            deviceManager = self.deviceManager
        }
        
        if await aiModelManager?.stateManager.getDownloadState() == .downloaded, deviceManager?.isTooHot() == false  {
            // Generate local completion
            await generateLocalCompletion(prompt: prompt, modelCode: modelCode, aiRunConfig: aiRunConfig, success: successCompletion, error: errorCompletion)
            return
        } else {
            // Generate cloud completion
            await generateCloudCompletion(prompt: prompt, modelCode: modelCode, aiRunConfig: aiRunConfig, success: successCompletion, error: errorCompletion)
        }
    }
    
    /// Generate an AI Completion in the FreeToken Cloud
    ///
    /// ```
    ///     client.generateCloudCompletion(prompt: "Complete the following phrase. My favorite star is") { response in
    ///         // Process the resulting text
    ///         // response.completion
    ///      } error: { error in
    ///         // Handle error response
    ///     }
    /// ```
    ///
    /// Warning: This will not function if you have Cloud completion disabled in the FreeToken Admin interface.
    ///
    /// Tip: Specify a larger model with `modelCode` in order to get access to more compute in the cloud for complex processing.
    ///
    /// - Parameters:
    ///     - prompt: Prompt to have the AI complete
    ///     - modelCode: AI Model Code defined by FreeToken in the Admin interface. (Think of this like a model ID, unique to the individual AI model)
    ///     - maxTokens: Optional maximum number of tokens to generate in the completion
    ///     - success: A closure to capture the results of the AI completion
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func generateCloudCompletion(prompt: String, modelCode: Optional<String> = nil, aiRunConfig: AIRunConfig? = nil, success successCompletion: @escaping @Sendable (Completion) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
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
        await postData(path: "completions", data: request, responseType: Codings.CreateCompletionResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: Profiler.EventType.generateCloudCompletion, isSuccess: true)
                FreeToken.shared.logger("Completion generated succesfully", .info)
                await successCompletion(Completion(from: response))
            case .failure(let error):
                profiler.end(eventType: .generateCloudCompletion, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("Completion failed to generate", .error)
                await errorCompletion(error)
            }
        }
    }
    
    /// Generate AI completion locally on device
    ///
    /// ```
    ///     client.generateLocalCompletion(prompt: "Message to summarize: \(message). MESSAGE SUMMARY:") { response in
    ///         // Process the resulting text
    ///         // response.completion
    ///     } error: { error in
    ///         // Handle error response
    ///     }
    /// ```
    ///
    /// > Warning: This will not function if the AI Model has not been downloaded. Ensure you call ``downloadAIModel(completion:)`` prior
    /// > to execution of this method.
    ///
    /// - Parameters:
    ///     - prompt: Prompt to have the AI complete
    ///     - modelCode: AI Model Code defined by FreeToken in the Admin interface
    ///     - maxTokens: Optional maximum number of tokens to generate in the completion
    ///     - success: A closure that is called after the successful call to the AI
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func generateLocalCompletion(prompt: String, modelCode: String? = nil, aiRunConfig: AIRunConfig? = nil, success successCompletion: @escaping @Sendable (Completion) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        guard self.deviceDetails?.aiModel.cloudOnly == false else {
            await errorCompletion(FreeTokenError.isCloudOnlyModel)
            return
        }
        
        let aiModelManager: AIModelManager
        
        if let modelCode = modelCode {
            if let modelManager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = modelManager
            } else {
                // Model not loaded
                await errorCompletion(FreeTokenError.aiModelNotDownloaded)
                return
            }
        } else {
            // Use the default AI Model Manager
            aiModelManager = self.aiModelManager!
        }
        
        guard await aiModelManager.stateManager.getDownloadState() == .downloaded else {
            await errorCompletion(FreeTokenError.aiModelNotDownloaded)
            return
        }
        
        guard deviceManager?.isTooHot() == false else {
            await errorCompletion(FreeTokenError.isTooHot)
            return
        }

        let profiler = Profiler()
        
        do {
            let response: String
            let usage: TokenUsage?
            
            (response, usage) = try await aiModelManager.sendTextToAI(text: prompt, runLocation: .localRun)
            let completion = Completion(response: response)

            profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: true, tokenStats: usage)
            await successCompletion(completion)
        } catch {
            let error = FreeTokenError.encoding(message: error.localizedDescription)
            profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: false, errorMessage: error.message)
            await errorCompletion(error)
        }
    }
    
    /// Generate a chat completion in the cloud
    ///
    ///
    func generateCloudChatCompletion(messages: [Message], model: String? = nil, aiRunConfig: AIRunConfig? = nil, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async -> Void> = nil, success successCallback: @escaping @Sendable (Message) async -> Void, error errorCallback: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCallback(FreeTokenError.deviceNotRegistered)
            return
        }

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
        
        await streamPostData(path: "completions/chat", data: request, responseType: Codings.CloudChatResponse.self) { chunk in
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
                                await chatStatusStream(messageContentChunk.messageChunk, .streaming_tokens)
                            }
                        } catch {
                            FreeToken.shared.logger("🔴 Error decoding message content chunk: \(chunk) - ERROR: \(error)", .error)
                        }
                    }
                }
            }
        } completion: { result in
            switch result {
            case .success(let response):
                if let errorResponse = response.error {
                    await chatStatusStream?(nil, .failed)
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
                            await chatStatusStream(nil, .stream_ended)
                        }
                        
                        // Call the success callback
                        await successCallback(message)
                    } catch {
                        await chatStatusStream?(nil, .failed)
                        FreeToken.shared.logger("🔴 Failed to parse cloud response message with images: \(error)", .error)
                        await errorCallback(FreeTokenError.cloudCompletionInvalidResponse)
                    }
                } else {
                    // Error that there wasn't the right response
                    await chatStatusStream?(nil, .failed)
                    FreeToken.shared.logger("🔴 Invalid response from cloud chat completion", .error)
                    await errorCallback(FreeTokenError.cloudCompletionInvalidResponse)
                }
            case .failure(let error):
                // Handle the error
                await chatStatusStream?(nil, .failed)
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
                successCompletion(results)
            case .failure(let error):
                profiler.end(eventType: .webSearch, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("Web search failed with error \(error.message)", .error)
                errorCompletion(error)
            }
        }
    }
    
    /// Stop a running generation of the local AI
    ///
    /// ```
    ///    client.stopLocalGeneration()
    /// ```
    ///  > Tip: Use this method to stop generation as your app goes into the background. This will help prevent crashes.
    ///
    /// - Returns: Void
    public func stopLocalGeneration() async {
        guard isDeviceRegistered() else {
            FreeToken.shared.logger("Device not registered, cannot stop generation", .error)
            return
        }
        
        await aiModelManager?.stopGeneration()
    }

    
    /// Run a message thread through the AI
    ///
    /// ```
    ///     client.runMessageThread(id: "msgthr-id", success: { response in
    ///         // The thread has run successfully
    ///         // Use the result message in your UI immediately (without fetching the thread)
    ///         // response.resultMessage
    ///     }, error: { error in
    ///         // Handle the error - Retry?
    ///     })
    /// ```
    ///
    /// > Tip: You can control where the AI runs with the `runLocation` parameter. Use `.cloudRun` to force cloud execution, `.localRun` to force local execution, or `.automatic` (default) to let the system decide.
    ///
    /// > Tip: Use `documentSearchScope` to change the context that the AI uses for RAG.  If left unset, the AI will use the document scope set in the Agent in the FreeToken Admin console.
    ///
    /// > Tip: Use `toolAccess` to control which tools can be run during the message thread.  This allows you to limit the tools that can be used during the message thread execution. Order matters, so if you want to allow only one tool you can use `[.denyAll, .allow("my_tool")]`. This would deny all tools except "my_tool".
    ///
    /// > Warning: The AI model must be downloaded prior to using this method. It's recommended that you ensure that ``downloadAIModel(completion:)`` is called prior to use.
    ///
    /// - Parameters:
    ///     - id: String of the message thread ID
    ///     - runLocation: Specifies where to run the AI - `.automatic` (default), `.cloudRun`, or `.localRun`
    ///     - documentSearchScope: Optional document search scope. Used for context for the AI
    ///     - privateDocumentStoreIds: Optional array of private document store IDs for RAG context
    ///     - aiRunConfig: Optional AI run configuration to override default AI model settings
    ///     - modelCode: Optional AI Model Code to use a different model than provided by the device session (will force to cloud)
    ///     - toolAccess: Optional ToolRunMask to control which tools can be run during the message thread
    ///     - success: A closure to capture the result of the run of the message thread
    ///     - error: A closure to capture any errors that occur during the call
    ///     - chatStatusStream: Optional closure to capture the status of the chat stream
    ///     - toolCallback: Optional closure to handle tool calls
    ///
    /// - Returns: Void
    public func runMessageThread(
        id messageThreadID: String,
        runLocation: RunLocation = .automatic,
        runIdentifier: Optional<String> = nil,
        documentSearchScope: Optional<String> = nil,
        privateDocumentStoreIds: Optional<[String]> = nil,
        aiRunConfig: Optional<AIRunConfig> = nil,
        modelCode: Optional<String> = nil,
        toolAccess: [ToolRunMask] = [.allowAll],
        success successCompletion: @escaping @Sendable (Message) async -> Void,
        error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void,
        chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async -> Void> = nil,
        toolCallback: Optional<@Sendable ([ToolCall]) async -> String> = nil
    ) async {
        await chatStatusStream?(nil, .starting)
        guard isDeviceRegistered() else {
            await chatStatusStream?(nil, .failed)
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let effectiveRunLocation: RunLocation
        
        // Determine effective run location based on priority:
        // 1. Explicit runLocation parameter (if not automatic)
        // 2. Device session forceCloudRun setting
        // 3. Default to automatic
        if runLocation != .automatic {
            effectiveRunLocation = runLocation
        } else if let deviceDetails = deviceDetails, deviceDetails.forceCloudRun == true {
            effectiveRunLocation = .cloudRun
        } else {
            effectiveRunLocation = .automatic
        }
        
        var aiModelManager: AIModelManager? = nil
        
        // Only load AI model manager if we might run locally
        if effectiveRunLocation != .cloudRun {
            if let modelCode = modelCode {
                if let manager = aiModelsManager.getManager(for: modelCode) {
                    // Found a manager!
                    aiModelManager = manager
                } else {
                    // Return an error since the model code is not loaded
                    await errorCompletion(FreeTokenError.aiModelNotDownloaded)
                    return
                }
            } else {
                // No model code provided - use default AIModelManager
                aiModelManager = self.aiModelManager
            }
        }
        
        // Workflow Context
        let context = RunMessageThreadContext(
            messageThreadID: messageThreadID,
            runLocation: effectiveRunLocation,
            runIdentifier: runIdentifier,
            documentSearchScope: documentSearchScope,
            privateDocumentStoreIds: privateDocumentStoreIds,
            deviceDetails: deviceDetails,
            aiModelManager: aiModelManager,
            deviceManager: deviceManager,
            messagesManager: messagesManager,
            jsonToolResults: deviceDetails?.aiModel.config.promptTemplateConfig.jsonToolResults ?? false,
            aiRunConfig: aiRunConfig,
            modelCode: modelCode,
            toolRunMasks: toolAccess,
            allToolDefinitions: await toolDefinitionsManager.allToolDefinitions(),
            toolDefinitionsManager: toolDefinitionsManager,
            chatStatusStream: chatStatusStream,
            toolCallback: toolCallback
        )
        
        // Workflow Steps
        let workflowSteps: [WorkflowStep.Type] = [
            GetMessageThread.self,
            ToolCallMasking.self,
            DetermineAIRunLocation.self,
            LoadAIModel.self,
            RunAIModelLocally.self, // Order of these two steps is important!
            RunAIModelInCloud.self, // <---
            AddMessageToThread.self,
            RunToolCalls.self
        ]
        
        let workflow = WorkflowManager(context: context, steps: workflowSteps)
        
        let profiler = Profiler()
        await workflow.execute { context in
            let context = context as! RunMessageThreadContext
            let profilerEventType: Profiler.EventType
            if context.cloudRun! {
                profilerEventType = .runMessageThreadCloud
            } else {
                profilerEventType = .runMessageThreadLocal
            }
            profiler.end(eventType: profilerEventType, eventTypeID: context.messageThreadID, isSuccess: true)

            await successCompletion(context.resultMessage!)
        } failure: { error, context in
            let context = context as! RunMessageThreadContext
            let profilerEventType: Profiler.EventType
            if let cloudRun = context.cloudRun {
                if cloudRun {
                    profilerEventType = .runMessageThreadCloud
                } else {
                    profilerEventType = .runMessageThreadLocal
                }
                profiler.end(eventType: profilerEventType, eventTypeID: context.messageThreadID, isSuccess: true, errorMessage: error.message)
            } else {
                // Couldn't determine run location - use local as default
                profiler.end(eventType: .runMessageThreadLocal, eventTypeID: context.messageThreadID, isSuccess: false, errorMessage: error.message)
            }
            
            await errorCompletion(error)
        }
    }
        
    /// Load the AI Model into the device memory
    ///
    /// ```
    ///     client.loadModel(success: { loadedState in
    ///         // Model is loaded and ready for use
    ///         if loadedState == .loaded {
    ///             // Use the AI model for local completions
    ///         }
    ///     }, error: { error in
    ///         // Handle the error - Retry?
    ///     })
    /// ```
    ///
    /// > Note: You must run ``downloadAIModel`` prior to using this method.
    ///
    /// > Note: Any success callback means that your system is ready to run AI (regardless of passed state as it may be cloud-only).
    ///
    ///- Parameters:
    ///    - modelCode: Optional AI Model Code to load a specific model, if not provided the default AI Model will be loaded
    ///    - success: A closure to capture the result of loading the AI model
    ///    - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func loadModel(modelCode: String? = nil, success successCompletion: @escaping (_ loadedState: AIModelLoadingState) async -> Void, error errorCompletion: @escaping (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        guard deviceManager?.isAICapable == true else {
            FreeToken.shared.logger("💾 Load Model: Device not capable of AI, nothing to do here", .info)
            await successCompletion(.notAICapable)
            return
        }
        
        // Get the AI Model Manager
        let aiModelManager: AIModelManager?
        if let modelCode = modelCode {
            if let manager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = manager
            } else {
                // Model not downloaded
                await errorCompletion(FreeTokenError.aiModelNotDownloaded)
                return
            }
        } else {
            // Use the default AI Model Manager
            aiModelManager = self.aiModelManager
            
            guard deviceDetails?.aiModel.cloudOnly == false else {
                await successCompletion(.cloudOnly)
                return
            }
        }
        
        // Check if the AI Model is downloaded
        guard await aiModelManager?.stateManager.getDownloadState() == .downloaded else {
            await errorCompletion(FreeTokenError.aiModelNotDownloaded)
            return
        }
        
        
        let response = await aiModelManager!.loadModel()
        switch response {
        case .success(let isSuccess):
            await successCompletion(isSuccess)
        case .failure(let error):
            await errorCompletion(error)
        }
    }
    
    /// Prewarm AI Cache for a specific run identifier, useful for preparing the AI model for a specific task or run.
    ///
    /// ```
    ///    await client.prewarmAIFor(runIdentifier: "run-id") {
    ///        // Successfully prewarmed AI for run identifier
    ///    } error: {
    ///        // Handle error during prewarming
    ///    }
    /// ```
    ///
    /// Tip: Use this to prewarm a cache when convienient, then use this same run identifier when calling any run methods like `runMessageThread`.
    ///
    /// - Parameters:
    ///   - runIdentifier: The identifier for the run to prewarm the AI model for
    ///   - modelCode: Optional AI Model Code to prewarm a specific model, if not provided the default AI Model will be used
    ///   - runConfig: Optional configuration for the AI run
    ///   - success: A closure to capture the result of the prewarming operation
    ///   - error: A closure to capture any errors that occur during the call
    public func prewarmAIFor(runIdentifier: String, modelCode: String? = nil, runConfig: AIRunConfig? = nil, success successCallback: (@Sendable () async -> Void)? = nil, error errorCallback: (@Sendable (FreeTokenError) async -> Void)? = nil) async {
        guard isDeviceRegistered() else {
            FreeToken.shared.logger("🔴 Device not registered, cannot prewarm AI for run identifier", .error)
            return
        }
        
        // Get the AI Model Manager by Model Code
        let aiModelManager: AIModelManager?
        if let modelCode = modelCode {
            if let manager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = manager
            } else {
                // Model not downloaded
                await errorCallback?(FreeTokenError.aiModelNotDownloaded)
                return
            }
        } else {
            // Use the default AI Model Manager
            aiModelManager = self.aiModelManager
            
            guard deviceDetails?.aiModel.cloudOnly == false else {
                await errorCallback?(FreeTokenError.isCloudOnlyModel)
                return
            }
        }
        
        do {
            let session = try await aiModelManager?.stateManager.loadSession(for: runIdentifier, runConfig: runConfig)
            _ = try await session?.load()
            await successCallback?()
        } catch {
            await errorCallback?(FreeTokenError.failedToLoadModel)
        }
    }
        
    
    
    /// Prewarm AI Cache for MessageThread
    ///
    /// ```
    ///    await client.prewarmAIForMessageThread(messageThreadID: "msgthr-id")
    /// ```
    ///
    /// Tip: Use this method when the initial hit of downloading the messages for a thread and loading the AI model is too slow and could be done at a more convienient time for the user.
    ///
    /// - Parameters:
    ///    - messageThreadID: The ID of the message thread to prewarm the AI
    /// - Returns: Void
    public func prewarmAIForMessageThread(
        messageThreadID: String,
        modelCode: String? = nil,
        runConfig: AIRunConfig? = nil,
        success successCallback: (@Sendable () async -> Void)? = nil,
        error errorCallback: (@Sendable (FreeTokenError) async -> Void)? = nil
    ) async {
        guard isDeviceRegistered() else {
            FreeToken.shared.logger("🔴 Device not registered, cannot prewarm AI for message thread", .error)
            return
        }
        
        // Get the AI Model Manager by Model Code
        let aiModelManager: AIModelManager?
        if let modelCode = modelCode {
            if let manager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = manager
            } else {
                // Model not downloaded
                await errorCallback?(FreeTokenError.aiModelNotDownloaded)
                return
            }
        } else {
            // Use the default AI Model Manager
            aiModelManager = self.aiModelManager
            
            guard deviceDetails?.aiModel.cloudOnly == false else {
                await errorCallback?(FreeTokenError.isCloudOnlyModel)
                return
            }
        }
        
        await self.getMessageThread(id: messageThreadID) { thread in
            do {
                let session = try await aiModelManager?.stateManager.loadSession(for: messageThreadID, with: thread.messages, runConfig: runConfig)
                _ = try await session?.load()
                await successCallback?()
            } catch {
                await errorCallback?(FreeTokenError.failedToLoadModel)
            }
        } error: { error in
            await errorCallback?(error)
        }
    }
    
    /// Unload the AI Model from the device memory
    ///
    /// ```
    ///     client.unloadModel()
    /// ```
    ///
    /// > Note: This method will unload the AI model from the device memory, freeing up resources.
    /// > It is useful when the AI model is no longer needed or when you want to switch to a different model.
    ///
    /// - Parameters:
    ///    - modelCode: Optional AI Model Code to unload a specific model, if not provided the default AI Model will be unloaded
    /// - Returns: Void
    public func unloadModel(modelCode: String? = nil) async {
        
        FreeToken.shared.logger("Unloading model\(modelCode != nil ? " with code (\(modelCode!))" : "")", .info)
        // Get the AI Model Manager
        let aiModelManager: AIModelManager?
        if let modelCode = modelCode {
            if let manager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = manager
            } else {
                // Model not downloaded
                FreeToken.shared.logger("⚠️ AI Model with code \(modelCode) not loaded", .warning)
                return
            }
        } else {
            // Use the default AI Model Manager
            aiModelManager = self.aiModelManager
            
            guard deviceDetails?.aiModel.cloudOnly == false else {
                FreeToken.shared.logger("⚠️ AI Model is cloud-only, nothing to unload", .warning)
                return
            }
        }
        
        await aiModelManager?.unloadModel()
    }
    
    /// Send one message directly to the AI without going to the cloud
    ///
    /// ```
    ///     do {
    ///         let message = try await client.localChat(content: "Tell me about a supernova", role: "user")
    ///         // Do what you will with the response.
    ///     } catch {
    ///         // Handle error
    ///         print(error.message ?? error.localizedDescription)
    ///     }
    /// ```
    ///
    /// > Note: This is ephemerial and does not run via the cloud at all. This call does not include RAG or any context injection.
    ///
    /// > Note: This method does not manage context window size, be careful when using this method with large messages or many messages.
    ///
    /// > Warning: You must run ``downloadAIModel(completion:)`` prior to using this method. This will not work on devices
    /// > that do not support AI.
    ///
    /// - Parameters:
    ///     - messages: An array of Message objects to send to the AI
    ///     - uniqueID: Optional unique ID for the chat session. This ID helps keep the chat persistent in the device memory between runs.
    ///
    /// - Returns: FreeToken.Message object
    /// - Throws: FreeTokenError if the device is not registered or if there is an error during the local chat
    public func localChat(modelCode: String? = nil, messages: [Message], runIdentifier: String? = nil, aiRunConfig: AIRunConfig? = nil) async throws -> Message {
        guard isDeviceRegistered() else {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let aiModelManager: AIModelManager?
        if let modelCode = modelCode {
            if let manager = aiModelsManager.getManager(for: modelCode) {
                aiModelManager = manager
            } else {
                throw FreeTokenError.aiModelNotDownloaded
            }
        } else {
            // Use the default AI Model Manager
            aiModelManager = self.aiModelManager
            
            guard deviceDetails?.aiModel.cloudOnly == false else {
                throw FreeTokenError.isCloudOnlyModel
            }
        }
                
        let runId: String
        
        if runIdentifier == nil {
            runId = UUID().uuidString
        } else {
            runId = runIdentifier!
        }
        
        let profiler = Profiler()
        do {
            let response: String
            let usage: TokenUsage?
            (response, usage) = try await aiModelManager!.sendMessagesToAI(messages: messages, runIdentifier: runId, runLocation: .localRun, aiRunConfig: aiRunConfig)
            profiler.end(eventType: .generateLocalChatCompletion, isSuccess: true, tokenStats: usage)
            let message = Message(role: .assistant, content: response, tokenUsage: usage)
            
            return message
        } catch {
            profiler.end(eventType: .generateLocalChatCompletion, isSuccess: false, errorMessage: "Failed to generate local chat with error: \(error.localizedDescription)")
            throw error
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
        return deviceDetails != nil
    }
    
    /// Fetches a specific resource by ID with optional query parameters.
    /// - Parameters:
    ///   - path: The API path to append to the base URL.
    ///   - queryParameters: A dictionary of query parameters to include in the URL.
    ///   - responseType: The expected type of the response.
    ///   - completion: Completion handler with the decoded response or an error.
    internal func fetchResource<T: Decodable>(
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
    internal func postData<T: Decodable, U: Encodable>(
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
    
    internal func postMultipartData<T: Decodable>(
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

}
