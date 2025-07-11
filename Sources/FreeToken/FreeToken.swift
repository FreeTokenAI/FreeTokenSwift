import Foundation

/// FreeToken Client
public class FreeToken: @unchecked Sendable {
    static public let shared = FreeToken()
    

    public var isConfigured: Bool {
        get {
            return isClientConfigured()
        }
    }
    
    let clientVersion = "1.0.0"
    #if os(iOS)
    let clientType = "iOS"
    #elseif os(macOS)
    let clientType = "macOS"
    #endif
    let telemetryDataVersion = 1
    let httpClient = HTTPClient()
    let messagesManager: MessagesManager
    var baseURL: URL? = nil
    var appToken: String? = nil
    var deviceSessionToken: String? = nil
    var deviceDetails: Codings.ShowDeviceSessionResponse? = nil
    var aiModelManager: AIModelManager? {
        get {
            if _aiModelManager != nil { return self._aiModelManager } // Memoized
            if isDeviceRegistered() == false { return nil } // Device not registered
            self._aiModelManager = AIModelManager(modelConfig: deviceDetails!.aiModel, clientVersion: clientVersion, deviceMode: deviceMode!)
            return self._aiModelManager
        }
        set(manager) {
            self._aiModelManager = manager
        }
    }
    
    private var _aiModelManager: AIModelManager? = nil
    var documentChunkSize: Int? = nil
    var documentChunkOverlapSize: Int? = nil
    var deviceManager: DeviceManager? = nil
    var documentManager: DocumentManager? = nil
    
    let encryptionManager = EncryptionManager()
    
    var deviceMode: DeviceMode? = nil
    
    enum DeviceMode: String {
        case privacyMode = "privacy"
        case compatibilityMode = "compatibility"
        case compatibilityQuickStartMode = "compatibility_quick_start"

        var isCompatibilityMode: Bool {
            switch self {
            case .compatibilityMode, .compatibilityQuickStartMode:
                return true
            case .privacyMode:
                return false
            }
        }
        
        var isPrivacyMode: Bool {
            switch self {
            case .compatibilityMode, .compatibilityQuickStartMode:
                return false
            case .privacyMode:
                return true
            }
        }
        
        var isQuickStartMode: Bool {
            switch self {
            case .compatibilityQuickStartMode:
                return true
            case .privacyMode, .compatibilityMode:
                return false
            }
        }
        
        init?(from string: String) {
            self.init(rawValue: string)
        }
    }
    
    public enum ChatStreamStatus: String, @unchecked Sendable {
        case starting = "starting"
        case failed = "failed"
        case streaming_tokens = "streaming_tokens"
        case stream_ended = "stream_ended"
        case sending_to_local_ai = "sending_to_local_ai"
        case sending_to_cloud_ai = "sending_to_cloud_ai"
        case evaluating_tool_calls = "evaluating_tool_calls"
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
    public func configure(appToken: String, baseURL: Optional<URL> = nil, logLevel: FreeTokenLogger.LogLevel = .info) -> FreeToken {
        self.appToken = appToken
        
        if let baseURL = baseURL {
            self.baseURL = baseURL
        }

        FreeTokenLogger.shared.configure(logLevel: logLevel)
        
        return self
    }
    
    /// Enables privacy mode encryption by providing encryption and decryption callbacks.
    ///
    /// ```
    ///     try client.privacyModeEncryption(encrypt: { text in
    ///         // Your encryption logic here
    ///         return encryptedText
    ///     }, decrypt: { text in
    ///         // Your decryption logic here
    ///         return decryptedText
    ///     })
    /// ```
    ///
    /// > Note: This method sets the encryption and decryption callbacks to be used in privacy mode.
    /// > These callbacks are required for handling encrypted data when privacy mode is enabled.
    ///
    /// - Parameters:
    ///     - encryptCallback: A closure that takes a `String` to be encrypted and returns the encrypted `String`.
    ///     - decryptCallback: A closure that takes a `String` to be decrypted and returns the decrypted `String`.
    ///
    /// - Throws: An error if the encryption or decryption process fails.
    public func privacyModeEncryption(encrypt encryptCallback: @escaping (_ encrypt: String) -> String, decrypt decryptCallback: @escaping (_ decrypt: String) -> String) throws {

        self.encryptionManager.enableEncryption(encryptor: encryptCallback, decryptor: decryptCallback)
    }
    
    /// Determine Device Capabilities and Register with FreeToken Cloud
    ///
    /// ```
    ///     client.registerDevice(scope: "my-app-v1") {
    ///         // Successfully registered
    ///     } error: { error in
    ///         // Failed to register device
    ///     }
    /// ```
    ///
    /// > Warning: If you are changing the `scope` of a device after it has been previously registered,
    /// > you must use ``resetDevice()`` prior to registering the device.
    /// > This function is asynchronous and may throw an error if the reset operation fails.
    ///
    /// - Parameters:
    ///   - scope: The Device Scope used in routing to agents and keeping in cohorts
    ///   - success: A closure that is executed if the call was successful
    ///   - error: A closure that is executed if the call failed.
    ///
    /// - Returns: Void
    public func registerDeviceSession(scope: String, success: @escaping @Sendable () async -> Void, error: @escaping @Sendable (FreeTokenError) async -> Void) async {
        let profiler = Profiler()
        
        // Determine Device Capabilities
        let createDeviceSessionRequest = Codings.CreateDeviceSessionRequest(deviceSession: .init(scope: scope, clientType: clientType, clientVersion: clientVersion))
        
        await postData(path: "device_sessions", data: createDeviceSessionRequest, responseType: Codings.ShowDeviceSessionResponse.self) { result in
            switch result {
            case .success(let response):
                self.deviceMode = DeviceMode(from: response.mode)
                
                if self.deviceMode?.isPrivacyMode == true, self.encryptionManager.isEncryptionEnabled == false {
                    // Require these to be set before moving forward.
                    await error(FreeTokenError.noEncryptOrDecryptDefinedInPrivacyMode)
                    return
                }
                if self.deviceMode?.isCompatibilityMode == true, self.encryptionManager.isEncryptionEnabled == true {
                    await error(FreeTokenError.encryptOrDecryptDefinedInCompatibilityMode)
                    return
                }
                
                self.deviceSessionToken = response.token
                self.deviceDetails = response
                
                self.deviceManager = DeviceManager(memoryRequirement: response.aiModel.clientsConfig["iOS"]!.requiredMemoryBytes)
                
                if self.deviceManager?.isAICapable == false, self.deviceMode?.isPrivacyMode == true {
                    await error(FreeTokenError.deviceIncapableOfAiInPrivacyMode)
                    return
                }
                
                EmbeddingManager.shared.config(modelConfig: response.embeddingModel)
                
                self.documentManager = DocumentManager(chunkSize: response.documentsConfig.documentChunkSize, overlapSize: response.documentsConfig.documentChunkOverlapSize)
                
                FreeToken.shared.logger("Device registered successfully", .info)
                
                profiler.end(eventType: Profiler.EventType.registerDeviceSession, isSuccess: true)
                await success()
            case .failure(let errorResponse):
                FreeToken.shared.logger("Failed to register device: \(errorResponse.message)", .error)
                profiler.end(eventType: .registerDeviceSession, isSuccess: false, errorMessage: errorResponse.message)
                await error(errorResponse)
            }
        }
    }
    
    /// Reset the persisted device details
    ///
    /// ```
    ///   client.resetDevice()
    /// ```
    ///
    /// Performs two major functions:
    /// 1. Deletes any persisted references to the device
    /// 2. Deletes the AI model cache
    ///
    /// - Returns: Void
    public func resetDevice() throws {
        deviceDetails = nil
        deviceSessionToken = nil
        aiModelManager = nil
        deviceMode = nil
        encryptionManager.reset()
    }
    
    /// Reset Model Caches
    ///
    public func resetModelCaches() async throws {
        try resetEmbeddingModelCache()
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
    public func resetEmbeddingModelCache() throws {
        do {
            try EmbeddingManager.shared.resetCache()
        } catch {
            throw FreeTokenError.deviceReset
        }
    }
    
    public func deleteAIModelCache() async {
        #if os(macOS) || os(Linux)
            let defaultRootDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".localllmclient")
        #else
            let defaultRootDirectory = URL.documentsDirectory.appending(path: ".localllmclient")
        #endif

        await aiModelManager?.unloadModel()
        await aiModelManager?.stateManager.setDownloadState(.notDownloaded)
        
        // Delete the whole directory
        do {
            try FileManager.default.removeItem(at: defaultRootDirectory)
            FreeToken.shared.logger("❌ AI model cache reset successfully", .info)
        } catch {
            FreeToken.shared.logger("Failed to reset LLM model cache: \(error.localizedDescription)", .error)
        }
    }
    
    /// Download the AI model for this specific device
    ///
    /// ```
    ///     client.downloadAIModel(success: { isModelDownloaded in
    ///         // Model is ready for use
    ///     }, error: { error in
    ///         // Failure - retry downloading.
    ///     })
    /// ```
    ///
    /// > Note: There are scenarios where the a successful result will mean that the model was not downloaded.
    /// > An example is that the device is not capable of supporting AI.  This returns a successful result but in the
    /// > above example, isModelDownloaded will be false.  There will let your program know
    /// > that no model that can run locally. If you allow cloud fallbacks via the admin console this is seamless and can be ignored;
    /// > but if not, all calls to the AI will fail going forward.
    ///
    /// - Parameters:
    ///   - success: Closure that is executed after the result of whether the model is downloaded is returned.
    ///   - error: Closure that is executed if there is an error during the AI model download.
    ///   - progressPercent: Optional closure that is executed to report the progress of the AI model download.
    ///
    /// - Returns: Void
    public func downloadAIModel(
        success successCallback: @escaping @Sendable (_ isLocalAI: Bool) -> Void,
        error errorCallback: @escaping @Sendable (FreeTokenError) -> Void,
        progressPercent: Optional<@Sendable (_ progressPercent: Double) -> Void> = nil
    ) async {
        guard isDeviceRegistered() else {
            errorCallback(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let aiModelManager = self.aiModelManager!
        let deviceManager = self.deviceManager!
        
        progressPercent?(0.0)
        
        if await aiModelManager.stateManager.getDownloadState() == .downloaded {
            FreeToken.shared.logger("Model already downloded", .info)
            successCallback(true)
            return
        }
        
        if deviceManager.isAICapable == false {
            FreeToken.shared.logger("Cannot download AI model as AI is not supported on this device.", .error)
            successCallback(false)
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
        
        // Download the AI model
        do {
            let result = try await aiModelManager.downloadIfNeeded(progress: progressPercent)
            if result == true {
                FreeToken.shared.logger("Model downloaded successfully", .info)
                successCallback(true)
            } else {
                FreeToken.shared.logger("Model did not download successfully", .error)
                errorCallback(FreeTokenError.aiModelDownload)
            }
        } catch {
            FreeToken.shared.logger("Failed to download AI model: \(error.localizedDescription)", .error)
            errorCallback(FreeTokenError.aiModelDownload)
        }
    }
    
    /// Create Message Thread in FreeToken Cloud
    ///
    /// ```
    ///     client.createMessageThread(agentScope: "agent-scope", success: { messageThread in
    ///         // Persist the message thread ID in your application
    ///         yourMethodToPersist(messageThreadID: messageThread.id)
    ///     }, error: { error in
    ///         // Retry?
    ///     })
    /// ```
    ///
    /// > Note: This process is the only time you will have access to the Message Thread ID.
    /// > If it's not persisted, it will be lost and you will have no way of adding messages to the thread.
    ///
    /// - Parameters:
    ///     - agentScope: Optional parameter to attach the message thread to a specific agent that matches this scope.
    ///     - success: A closure that is executed when the message thread is successfully created.
    ///     - error: A closure that is executed if there is an error during the creation of the message thread.
    ///
    /// - Returns: Void
    public func createMessageThread(agentScope: Optional<String> = nil, success successCompletion: @escaping @Sendable (MessageThread) async -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        // Use Message Manager
        await messagesManager.createMessageThread(agentScope: agentScope) { result in
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
    ///    client.deleteMessageThread(id: "[message-thread-id]", success: {
    ///     // Message thread deleted successfully
    ///     }, error: { error in
    ///     // Failed to delete message thread
    ///     })
    /// ```
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
    ///        // Can be retried
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
    public func getMessageThread(id: String, success successCompletion: @escaping @Sendable (MessageThread) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        await messagesManager.getMessageThread(id: id) { messageThread, _ in
            successCompletion(messageThread)
        } failure: { error in
            errorCompletion(error)
        }
    }
    
    /// Add a message to a message thread
    ///
    /// ```
    ///     client.addMessageToThread(id: "msg_thr-id", message: Message(role: .user, content: "Hello!"), success: { message in
    ///         // Message was created successfully
    ///         // Display message in your UI
    ///     }, error: { error in
    ///         // Message could not be created. Retry?
    ///     })
    /// ```
    ///
    /// > Note: Created messages are not immediately sent to the AI. You must call ``runMessageThread(id:documentSearchScope:forceCloudRun:completion:)``
    /// > to run this on the AI.
    ///
    /// > Note: Messages are automatically indexed for reference in large message threads that will not fit in the AI's context window.
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
    public func generateCompletion(prompt: String, modelCode: Optional<String> = nil, aiRunConfig: AIRunConfig? = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        if await aiModelManager?.stateManager.getDownloadState() == .downloaded, await aiModelManager?.stateManager.getLoadedState() == .loaded, deviceManager?.isTooHot() == false, (modelCode == nil || self.deviceDetails?.aiModel.code == modelCode)  {
            // Generate local completion
            await generateLocalCompletion(prompt: prompt, aiRunConfig: aiRunConfig) { completion in
                successCompletion(completion)
            } error: { error in
                errorCompletion(error)
            }
            return
        } else {
            // Generate cloud completion
            if self.deviceMode?.isPrivacyMode == false {
                await generateCloudCompletion(prompt: prompt, aiRunConfig: aiRunConfig, success: successCompletion, error: errorCompletion)
            } else {
                errorCompletion(FreeTokenError.cloudCompletionPrivacyMode)
            }
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
    public func generateCloudCompletion(prompt: String, modelCode: Optional<String> = nil, aiRunConfig: AIRunConfig? = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
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
                successCompletion(Completion(from: response))
            case .failure(let error):
                profiler.end(eventType: .generateCloudCompletion, isSuccess: false, errorMessage: error.message)
                FreeToken.shared.logger("Completion failed to generate", .error)
                errorCompletion(error)
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
    ///     - maxTokens: Optional maximum number of tokens to generate in the completion
    ///     - success: A closure that is called after the successful call to the AI
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func generateLocalCompletion(prompt: String, aiRunConfig: AIRunConfig? = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        guard await self.aiModelManager?.stateManager.getDownloadState() == .downloaded else {
            errorCompletion(FreeTokenError.aiModelNotDownloaded)
            return
        }

        let profiler = Profiler()
        
        let aiModelManager = self.aiModelManager!
        
        do {
            let uuid = UUID().uuidString
            let message = Message(role: .user, content: "Complete the following: \(prompt)")
            let response: String
            let usage: TokenUsage?
            
            (response, usage) = try await aiModelManager.sendMessagesToAI(messages: [message], runIdentifier: uuid, noContextCache: true)
            let completion = Completion(response: response)

            profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: true, tokenStats: usage)
            successCompletion(completion)
        } catch {
            if error as? FreeTokenError == .aiQueueTimeout, self.deviceMode?.isQuickStartMode == true {
                // Queue is taking too long, send this to the cloud
                await generateCloudCompletion(prompt: prompt, modelCode: nil, aiRunConfig: aiRunConfig, success: successCompletion, error: errorCompletion)
            } else {
                let error = FreeTokenError.encoding(message: error.localizedDescription)
                profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: false, errorMessage: error.message)
                errorCompletion(error)
            }
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
        let requestMessages = preparedMessages.map { Codings.CodableMessage(role: $0.role.rawValue, content: $0.content) }
        
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
                    let message = Message(from: responseMessage, tokenUsage: usage)
                    profiler.end(eventType: Profiler.EventType.generateCloudChatCompletion, isSuccess: true, tokenStats: usage)
                    if let chatStatusStream = chatStatusStream {
                        await chatStatusStream(nil, .stream_ended)
                    }
                    
                    // Call the success callback
                    await successCallback(message)
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
    public func createDocument(content: String, metadata: Optional<String> = nil, searchScope: String, privateDocumentStoreID: Optional<String> = nil, success successCompletion: @escaping @Sendable (Document) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        let document: FreeToken.DocumentManager.Document
        do {
            document = try self.documentManager!.processDocument(content: content, metadata: metadata)
        } catch (let error) {
            errorCompletion(error as! FreeTokenError)
            return
        }
        
        let chunks = document.chunks.map { chunk in
            let content = encryptionManager.encrypt(chunk.chunkContent)
            return Codings.CreateDocumentChunkRequest(content: content, embedding: chunk.embedding!, embeddingModel: chunk.embeddingModelName)
        }
        
        let request = Codings.CreateDocumentRequest(content: encryptionManager.encrypt(content), metadata: (metadata != nil ? encryptionManager.encrypt(metadata!) : nil), searchScope: searchScope, documentChunks: chunks, encryptionEnabled: encryptionManager.isEncryptionEnabled, privateDocumentStoreID: privateDocumentStoreID)
        
        let wrapper = Codings.CreateDocumentRequestWrapper(document: request)
        
        let profiler = Profiler()
        await postData(path: "documents", data: wrapper, responseType: Codings.ShowDocumentResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: .createDocument, isSuccess: true)
                FreeToken.shared.logger("📄 Document created successfully", .info)
                successCompletion(Document(from: response))
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
                successCompletion(Document(from: response))
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
            embedding = try EmbeddingManager.shared.generate(text: query)
        } catch (let error) {
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

                await successCompletion(DocumentSearchResults(from: response))
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
    
    func webSearch(query: String, resultCount: Int? = nil, success successCompletion: @escaping @Sendable ([WebSearchResult]) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
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
    /// > Tip: You can force a cloud run with the `forceCloudRun` flag.  This will run the AI in the cloud without using your local AI.
    ///
    /// > Tip: Use `documentSearchScope` to change the context that the AI uses for RAG.  If left unset, the AI will use the document scope set in the Agent in the FreeToken Admin console.
    ///
    /// > Warning: The AI model must be downloaded prior to using this method. It's recommended that you ensure that ``downloadAIModel(completion:)`` is called prior to use.
    ///
    /// - Parameters:
    ///     - id: String of the message thread ID
    ///     - forceCloudRun: Optional Boolean to force the AI to run in the cloud rather than on device
    ///     - documentSearchScope: Optional document search scope. Used for context for the AI
    ///     - privateDocumentStoreIds: Optional array of private document store IDs for RAG context
    ///     - success: A closure to capture the result of the run of the message thread
    ///     - error: A closure to capture any errors that occur during the call
    ///     - chatStatusStream: Optional closure to capture the status of the chat stream
    ///     - toolCallback: Optional closure to handle tool calls
    ///     - toolRunOnly: Boolean to indicate if this run is only to generate tool calls, not for a user response
    ///
    /// - Returns: Void
    public func runMessageThread(
        id messageThreadID: String,
        forceCloudRun: Optional<Bool> = nil,
        documentSearchScope: Optional<String> = nil,
        privateDocumentStoreIds: Optional<[String]> = nil,
        aiRunConfig: Optional<AIRunConfig> = nil,
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
        
        // Workflow Context
        let context = RunMessageThreadContext(messageThreadID: messageThreadID, forceCloudRun: forceCloudRun, documentSearchScope: documentSearchScope, privateDocumentStoreIds: privateDocumentStoreIds, toolRunOnly: true, deviceDetails: deviceDetails, aiModelManager: aiModelManager, deviceMode: deviceMode, deviceManager: deviceManager, messagesManager: messagesManager, jsonToolResults: deviceDetails?.aiModel.config.promptTemplateConfig.jsonToolResults ?? false, aiRunConfig: aiRunConfig, chatStatusStream: chatStatusStream)
        
        // Workflow Steps
        let workflowSteps: [WorkflowStep.Type] = [
            LoadAIModel.self,
            DetermineAIRunLocation.self,
            GetMessageThread.self,
            RunAIModelInCloud.self,
            RunAIModelLocally.self,
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
                profiler.end(eventType: profilerEventType, eventTypeID: context.messageThreadID, isSuccess: true)
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
    /// > Note: Any success callback means that your system is ready to run AI.
    ///
    ///- Parameters:
    ///     - success: A closure to capture the result of loading the AI model
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: A generic enumeration result of Bool, ErrorResponse
    public func loadModel(success successCompletion: @escaping (_ loadedState: AIModelLoadingState) async -> Void, error errorCompletion: @escaping (FreeTokenError) async -> Void) async {
        guard isDeviceRegistered() else {
            await errorCompletion(FreeTokenError.deviceNotRegistered)
            return
        }
        
        guard deviceManager?.isAICapable == true else {
            FreeToken.shared.logger("💾 Load Model: Device not capable of AI, nothing to do here", .info)
            await successCompletion(.notAICapable)
            return
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
    
    /// Unload the AI Model from the device memory
    ///
    /// ```
    ///     client.unloadModel()
    /// ```
    ///
    /// > Note: This method will unload the AI model from the device memory, freeing up resources.
    /// > It is useful when the AI model is no longer needed or when you want to switch to a different model.
    ///
    /// - Returns: Void
    public func unloadModel() async {
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
    public func localChat(messages: [Message], uniqueID: String? = nil, aiRunConfig: AIRunConfig? = nil) async throws -> Message {
        if !isDeviceRegistered() {
            throw FreeTokenError.deviceNotRegistered
        }
        
        let runIdentifier: String
        
        if uniqueID == nil {
            runIdentifier = UUID().uuidString
        } else {
            runIdentifier = uniqueID!
        }
        
        do {
            let response: String
            let usage: TokenUsage?
            (response, usage) = try await aiModelManager!.sendMessagesToAI(messages: messages, runIdentifier: runIdentifier, aiRunConfig: aiRunConfig)
            
            let message = Message(role: .assistant, content: response, tokenUsage: usage)
            
            return message
        } catch {
            throw error
        }
    }

    // MARK: Private Methods
    
    private func isClientConfigured() -> Bool {
        if baseURL != nil && appToken != nil {
            return true
        } else {
            return false
        }
    }
    
    // Internal Method
    func sendTelemetry(profiler: Profiler) {
        let eventData = Codings.TelemetryDataRequest(eventDurationInMilliseconds: profiler.msDuration(), eventTypeId: profiler.eventTypeID, eventObjectType: profiler.eventObjectType, isSuccess: profiler.isSuccess, errorMessage: profiler.errorMessage, tokenStats: profiler.tokenStats?.asCodable())
        
        let eventType = profiler.eventType!.rawValue
        
        FreeToken.shared.logger("Telemetry Stats - Event: \(eventType): Time: \(profiler.msDuration()!)ms", .info)
        
        Task.detached(priority: .background) {
            guard self.isDeviceRegistered() else {
                FreeToken.shared.logger("Telemetry: Device not registered", .warning)
                return
            }
            
            let request = Codings.TelemetryCreateRequest(eventType: eventType, eventData: eventData, version: self.telemetryDataVersion)
            
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
        guard isClientConfigured() else {
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
        guard isClientConfigured() else {
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
        guard isClientConfigured() else {
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
        guard isClientConfigured() else {
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
