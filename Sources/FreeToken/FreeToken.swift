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
    let clientType = "iOS"
    let telemetryDataVersion = 1
    let httpClient = HTTPClient()
    var baseURL: URL? = nil
    var appToken: String? = nil
    var deviceSessionToken: String? = nil
    var deviceDetails: Codings.ShowDeviceSessionResponse? = nil
    var aiModelManager: AIModelManager? {
        get {
            if _aiModelManager != nil { return self._aiModelManager } // Memoized
            if isDeviceRegistered() == false { return nil } // Device not registered
            self._aiModelManager = AIModelManager(modelConfig: deviceDetails!.aiModel, clientVersion: clientVersion, overrideModelPath: overrideModelPath)
            return self._aiModelManager
        }
        set(manager) {
            self._aiModelManager = manager
        }
    }
    
    private var _aiModelManager: AIModelManager? = nil
    var overrideModelPath: URL? = nil
    var documentChunkSize: Int? = nil
    var documentChunkOverlapSize: Int? = nil
    
    var deviceManager: DeviceManager? = nil
    var documentManager: DocumentManager? = nil
    
    var encrypt: Optional<(_ encrypt: String) -> String> = nil
    var decrypt: Optional<(_ decrypt: String) -> String> = nil
    
    var encryptionEnabled: Bool {
        get {
            return encrypt != nil
        }
    }
    var deviceMode: DeviceMode? = nil
    
    // Error Messages:
    private let deviceNotRegisteredError = Codings.ErrorResponse(error: "deviceNotRegistered", message: "This device has not been registered. Try .registerDevice.", code: 1000)
    private let clientDeallocatedError = Codings.ErrorResponse(error: "invalidState", message: "Client was deallocated", code: 1002)
    private let aiModelDownloadError = Codings.ErrorResponse(error: "downloadError", message: "Model did not download successfully", code: 1003)
    private let clientNotConfiguredError = Codings.ErrorResponse(error: "clientNotConfigured", message: "Client has not been configured. Try .configure()", code: 1004)
    private let clientAIVersionMissmatchError = Codings.ErrorResponse(error: "clientAIVersionMissmatch", message: "This client version is not capable of running the AI model sent by the server. Please upgrade the client.", code: 1005)
    private let deviceResetError = Codings.ErrorResponse(error: "deviceReset", message: "Could not reset the device", code: 1006)
    private let cacheResetError = Codings.ErrorResponse(error: "cacheReset", message: "Could not reset the AI model cache", code: 1007)
    private let invalidURLError = Codings.ErrorResponse(error: "InvalidURL", message: "Failed to construct URL with query parameters.", code: nil)
    private let aiNotSupportedNoCompatibilityError = Codings.ErrorResponse(error: "aiNotSupportedNoCompitability", message: "AI is not supported on this device and compatibility mode is off", code: 1008)
    private let responseTypeInvalidError = Codings.ErrorResponse(error: "responseTypeInvalid", message: "The response from the server was invalid", code: 1009)
    private let handlingToolCallsFailedError = Codings.ErrorResponse(error: "handlingToolCallsFailed", message: "Failed to handle tool calls", code: 1010)
    private let encryptionEnabledInCompatabilityModeError = Codings.ErrorResponse(error: "encryptionEnabledInCompatabilityMode", message: "Encryption is not available in compatability mode, for encryption turn on privacy mode in the admin.", code: 1011)
    private let encryptedMessageLoadedInCompatabilityModeError = Codings.ErrorResponse(error: "encryptedMessageLoadedInCompatabilityMode", message: "An encrypted message was loaded from the server in compatability mode where no decryption method is defined.", code: 1012)
    private let cloudCompletionPrivacyModeError = Codings.ErrorResponse(error: "cloudCompletionPrivacyModeError", message: "Application tried to run a completion in the cloud with Privacy Mode enabled. Likely cause is that the AI model is not downloaded yet.", code: 1013)
    private let encryptedDocumentRecievedWithoutWayToDecryptError = Codings.ErrorResponse(error: "encryptedDocumentRecievedWithoutWayToDecrypt", message: "Recieved an encrypted document from the cloud, but no decryption method defined", code: 1014)
    private let encryptedMessageThreadLoadedWithoutWayToDecryptError = Codings.ErrorResponse(error: "encryptedMessageThreadLoadedWithoutWayToDecrypt", message: "Recieved a message thread from the cloud, but no decryption method defined ", code: 1015)
    private let noEncryptOrDecryptDefinedInPrivacyModeError = Codings.ErrorResponse(error: "noEncryptOrDecryptDefinedInPrivacyMode", message: "Encrypt & Decrypt must be added via the configure method in Privacy Mode", code: 1016)
    private let encryptOrDecryptDefinedInCompatibilityModeError = Codings.ErrorResponse(error: "encryptOrDecryptDefinedInCompatibilityMode", message: "Encrypt & Decrypt must not be added via configure in Compatibility Mode", code: 1017)
    private let deviceIncapableOfAiInPrivacyModeError = Codings.ErrorResponse(error: "deviceIncapableOfAiInPrivacyMode", message: "This device is not capable of AI and the App is configured for Privacy Mode (on-device AI only)", code: 1018)
    private let cloudRunInPrivacyModeError = Codings.ErrorResponse(error: "cannotCloudRunAiInPrivacyMode", message: "Cloud run of a is not supported in Privacy Mode", code: 1019)
    private let modelMustBeLoadedBeforeAddingMessageError = Codings.ErrorResponse(error: "modelMustBeLoadedBeforeAddingMessage", message: "Model must be loaded before adding a message", code: 1020)
    private let cloudCompletionInvalidResponseError = Codings.ErrorResponse(error: "cloudCompletionInvalidResponse", message: "The response from the cloud completion was invalid", code: 1022)
    
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
    }
    
    /// Configures the `FreeToken` client with the provided API key and base URL.
    ///
    /// ```
    ///  let client = FreeToken.shared.configure(appToken: "key-12345", baseURL: URL(string: "https://api.example.com/"), overrideModelPath: URL(string: "path/to/model"))
    /// ```
    ///
    /// - Parameters:
    ///     - appToken: A `String` representing the API key used for authentication of your client.
    ///     - baseURL: Optional base URL for the API (e.g., `https://api.example.com/`). Defaults to `nil`.
    ///     - overrideModelPath: An optional `URL` for the override model path. Defaults to `nil`.
    ///     - logLevel: Optional log level for the client. Default is `.info`
    ///
    /// - Returns: A configured `FreeToken` instance.
    public func configure(appToken: String, baseURL: Optional<URL> = nil, overrideModelPath: Optional<URL> = nil, logLevel: FreeTokenLogger.LogLevel = .info) -> FreeToken {
        self.appToken = appToken
        
        if let baseURL = baseURL {
            self.baseURL = baseURL
        }
        
        if let overrideModelPath = overrideModelPath {
            self.overrideModelPath = overrideModelPath
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

        self.encrypt = encryptCallback
        self.decrypt = decryptCallback
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
    public func registerDeviceSession(scope: String, success: @escaping @Sendable () -> Void, error: @escaping @Sendable (FreeTokenError) -> Void) {
        let profiler = Profiler()
        
        // Determine Device Capabilities
        let createDeviceSessionRequest = Codings.CreateDeviceSessionRequest(deviceSession: .init(scope: scope, clientType: clientType, clientVersion: clientVersion))
        
        postData(path: "device_sessions", data: createDeviceSessionRequest, responseType: Codings.ShowDeviceSessionResponse.self) { result in
            switch result {
            case .success(let response):
                self.deviceMode = DeviceMode(from: response.mode)
                
                if self.deviceMode?.isPrivacyMode == true {
                    if self.encrypt == nil || self.decrypt == nil {
                        // Require these to be set before moving forward.
                        error(FreeTokenError.convertErrorResponse(errorResponse: self.noEncryptOrDecryptDefinedInPrivacyModeError))
                        return
                    }
                }
                if self.deviceMode?.isCompatibilityMode == true {
                    if self.encrypt != nil || self.decrypt != nil {
                        error(FreeTokenError.convertErrorResponse(errorResponse: self.encryptOrDecryptDefinedInCompatibilityModeError))
                        return
                    }
                }
                
                self.deviceSessionToken = response.token
                self.deviceDetails = response
                
                self.deviceManager = DeviceManager(memoryRequirement: response.aiModel.clientsConfig["iOS"]!.requiredMemoryBytes)
                
                if self.deviceManager?.isAICapable == false, self.deviceMode?.isPrivacyMode == true {
                    error(FreeTokenError.convertErrorResponse(errorResponse: self.deviceIncapableOfAiInPrivacyModeError))
                    return
                }
                
                EmbeddingManager.shared.config(modelConfig: response.embeddingModel)
                
                self.documentManager = DocumentManager(chunkSize: response.documentsConfig.documentChunkSize, overlapSize: response.documentsConfig.documentChunkOverlapSize, encrypt: self.encrypt, decrypt: self.decrypt)
                
                FreeToken.shared.logger("Device registered successfully", .info)
                
                profiler.end(eventType: Profiler.EventType.registerDeviceSession, isSuccess: true)
                success()
            case .failure(let errorResponse):
                FreeToken.shared.logger("Failed to register device: \(errorResponse.message ?? errorResponse.localizedDescription)", .error)
                profiler.end(eventType: .registerDeviceSession, isSuccess: false, errorMessage: errorResponse.message ?? errorResponse.localizedDescription)
                error(FreeTokenError.convertErrorResponse(errorResponse: errorResponse))
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
        do {
            try resetAIModelCache()
            try resetEmbeddingModelCache()
        } catch {
            throw self.deviceResetError
        }
        deviceDetails = nil
        deviceSessionToken = nil
        aiModelManager = nil
        deviceMode = nil
        encrypt = nil
        decrypt = nil
    }
    
    /// Removes the AI Model cache from the local device
    ///
    /// > Note: This is useful if the user will no longer be using the AI portion of your application
    /// > or if there are any problems running the AI.  The system does it's best to ensure that all files
    /// > are correct upon device registration, but if there are any app crashes this would be a good
    /// > place to begin.
    ///
    /// ```
    /// client.resetAIModelCache()
    /// ```
    ///
    /// - Returns: Void
    /// - Throws: FreeToken Device Not Registered Error
    public func resetAIModelCache() throws {
        guard isDeviceRegistered() else {
            throw self.deviceNotRegisteredError
        }
        
        guard aiModelManager!.resetCache() else {
            throw self.cacheResetError
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
    public func resetEmbeddingModelCache() throws {
        try EmbeddingManager.shared.resetCache()
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
    public func downloadAIModel(success successCallback: @escaping @Sendable (Bool) -> Void, error errorCallback: @escaping @Sendable (FreeTokenError) -> Void, progressPercent: Optional<@Sendable (_ progressPercent: Double) -> Void> = nil) async {
        guard isDeviceRegistered() else {
            errorCallback(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        let aiModelManager = self.aiModelManager!
        let deviceManager = self.deviceManager!
        
        progressPercent?(0.0)
        
        await EmbeddingManager.shared.downloadModel(progress: progressPercent) {
            // Success -> Download AI model
            Task {
                if await aiModelManager.stateManager.getState() == .downloaded {
                    FreeToken.shared.logger("Model already downloded", .info)
                    successCallback(true)
                    return
                }
                
                if deviceManager.isAICapable == false {
                    FreeToken.shared.logger("Cannot download AI model as AI is not supported on this device.", .error)
                    successCallback(false)
                    return
                }

            
                if await aiModelManager.downloadIfNeeded(progress: progressPercent) {
                    FreeToken.shared.logger("Model downloaded successfully", .info)
                    successCallback(true)
                } else {
                    FreeToken.shared.logger("Model did not download successfully", .error)
                    errorCallback(FreeTokenError.convertErrorResponse(errorResponse: self.aiModelDownloadError))
                }
            }
        } failureCallback: { error in
            // Error
            errorCallback(error)
        }
    }
    
    /// Create Message Thread in FreeToken Cloud
    ///
    /// ```
    ///     client.createMessageThread(pinnedContext: "Initial context", agentScope: "agent-scope", success: { messageThread in
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
    /// > Tip: If you plan on supporting many devices in your application this ID should be
    /// > stored in a database to ensure accessibility across devices.
    ///
    /// - Parameters:
    ///     - pinnedContext: Optional parameter to attach a specific context to the message thread.
    ///     - agentScope: Optional parameter to attach the message thread to a specific agent.
    ///     - success: A closure that is executed when the message thread is successfully created.
    ///     - error: A closure that is executed if there is an error during the creation of the message thread.
    ///
    /// - Returns: Void
    public func createMessageThread(pinnedContext: Optional<String> = nil, agentScope: Optional<String> = nil, success: @escaping @Sendable (MessageThread) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        let originalPinnedContext = pinnedContext
        var pinnedContext = pinnedContext
        var encryptionEnabled = false
        
        if let encrypt = self.encrypt, pinnedContext != nil {
            pinnedContext = encrypt(pinnedContext!)
            encryptionEnabled = true
        }
        
        let request = Codings.CreateMessageThreadRequest(agentScope: agentScope, pinnedContext: pinnedContext, encryptionEnabled: encryptionEnabled)
        
        let profiler = Profiler()
        postData(path: "message_threads", data: request, responseType: Codings.ShowMessageThreadResponse.self) { result in
            switch result {
            case .success(var response):
                if originalPinnedContext != nil {
                    response = Codings.ShowMessageThreadResponse(id: response.id, pinnedContext: originalPinnedContext, encryptionEnabled: response.encryptionEnabled, messages: response.messages)
                }
                
                profiler.end(eventType: Profiler.EventType.createMessageThread, eventTypeID: response.id, isSuccess: true)
                FreeToken.shared.logger("Message thread created successfully: \(response.id)", .info)
                success(MessageThread(from: response))
            case .failure(let error):
                profiler.end(eventType: .createMessageThread, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
                FreeToken.shared.logger("Failed to create message thread: \(error)", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
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
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
    public func getMessageThread(id: String, success successCompletion: @escaping @Sendable (MessageThread) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        let path = "message_threads/\(id)"
        fetchResource(path: path, responseType: Codings.ShowMessageThreadResponse.self) { result in
            switch result {
            case .success(var response):
                if response.encryptionEnabled == true, response.pinnedContext != nil {
                    if let decrypt = self.decrypt {
                        response = Codings.ShowMessageThreadResponse(id: response.id, pinnedContext: decrypt(response.pinnedContext!), encryptionEnabled: response.encryptionEnabled, messages: response.messages)
                    } else {
                        errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.encryptedMessageThreadLoadedWithoutWayToDecryptError))
                    }
                }
                
                successCompletion(MessageThread(from: response))
            case .failure(let error):
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
            }
            
        }
    }
    
    /// Add a message to a message thread
    ///
    /// ```
    ///     client.addMessageToThread(messageThreadID: "msgthr-id", role: "user", content: "What is a nova?", success: { message in
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
    ///     - messageThreadID: ID of the message thread to add the message
    ///     - message: The `Message` object to add to the thread
    ///     - success: A closure to capture the results of the call to add the message to the thread
    ///     - toolCalls: This parameter is used when creating Role calls from the AI - it can be used when importing existing threads from other systems.
    ///     - success: A closure to capture the results of the call to add the message to the thread
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func addMessageToThread(messageThreadID: String, message: Message, toolCalls: Optional<String> = nil, success successCompletion: @escaping @Sendable (Message) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        let originalContent = message.content
        let originalToolCalls = toolCalls
        
        // Generate token count for message (if it doesn't exist or if possible)
        let tokenCount: Int?
        do {
            // Will throw if the model is not loaded
            if let completionTokens = message.tokenUsage?.completionTokens {
                tokenCount = completionTokens
            } else {
                tokenCount = try await aiModelManager?.tokenCount(originalContent)
            }
        } catch {
            if deviceMode! == .privacyMode {
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.modelMustBeLoadedBeforeAddingMessageError))
                return
            } else {
                // In compatibility mode, let's leave token count nil (let the cloud handle it)
                tokenCount = nil
            }
        }
        
        var content = message.content
        var toolCalls = toolCalls
        var encryptionEnabled = false
        
        if let encrypt = encrypt {
            encryptionEnabled = true
            content = encrypt(content)
            toolCalls = toolCalls != nil ? encrypt(toolCalls!) : nil
        }
        
        var vectors: [Float]?
                
        do {
            vectors = try EmbeddingManager.shared.generate(text: content)
        } catch (let error) {
            errorCompletion(error as! FreeTokenError)
            return
        }
                
        let request = Codings.CreateMessageRequest(messageThreadID: messageThreadID, role: message.role.rawValue, content: content, toolCalls: toolCalls, embedding: vectors, embeddingModel: EmbeddingManager.shared.embeddingModelName, encryptionEnabled: encryptionEnabled, tokenCount: tokenCount)
        
        let profiler = Profiler()
        postData(path: "messages", data: request, responseType: Codings.ShowMessageResponse.self) { result in
            switch result {
            case .success(var response):
                if response.encryptionEnabled == true {
                    response = Codings.ShowMessageResponse(id: response.id, role: response.role, content: originalContent, toolCalls: originalToolCalls, encryptionEnabled: response.encryptionEnabled, tokenCount: tokenCount!, createdAt: response.createdAt, updatedAt: response.updatedAt)
                }
                
                profiler.end(eventType: Profiler.EventType.addMessageToThread, eventTypeID: response.id, isSuccess: true)
                FreeToken.shared.logger("Added message to thread. Message ID: \(response.id!)", .info)
                successCompletion(Message(from: response))
            case .failure(let error):
                profiler.end(eventType: .addMessageToThread, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
                FreeToken.shared.logger("Message could not be added to thread: \(error)", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
    public func getMessage(id: String, success successCompletion: @escaping @Sendable (Message) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        let path = "messages/\(id)"
        
        fetchResource(path: path, responseType: Codings.ShowMessageResponse.self) { result in
            switch result {
            case .success(var response):
                if response.encryptionEnabled == true {
                    if let decrypt = self.decrypt {
                        let toolCalls = response.toolCalls != nil ? decrypt(response.toolCalls!) : nil
                        
                        response = Codings.ShowMessageResponse(id: response.id, role: response.role, content: decrypt(response.content), toolCalls: toolCalls, encryptionEnabled: response.encryptionEnabled, tokenCount: response.tokenCount, createdAt: response.createdAt, updatedAt: response.updatedAt)
                    } else {
                        errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.encryptedMessageLoadedInCompatabilityModeError))
                    }
                }
                
                successCompletion(Message(from: response))
                return
            case .failure(let error):
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
                return
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
    public func generateCompletion(prompt: String, modelCode: Optional<String> = nil, maxTokens: Int? = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        if await aiModelManager?.stateManager.getState() == .downloaded, (modelCode == nil || self.deviceDetails?.aiModel.code == modelCode)  {
            // Generate local completion
            await generateLocalCompletion(prompt: prompt, maxTokens: maxTokens) { completion in
                successCompletion(completion)
            } error: { error in
                errorCompletion(error)
            }
            return
        } else {
            // Generate cloud completion
            if self.deviceMode?.isPrivacyMode == false {
                generateCloudCompletion(prompt: prompt, maxTokens: maxTokens, success: successCompletion, error: errorCompletion)
            } else {
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: cloudCompletionPrivacyModeError))
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
    public func generateCloudCompletion(prompt: String, modelCode: Optional<String> = nil, maxTokens: Int? = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }

        let request = Codings.CreateCompletionRequest(prompt: prompt, model: modelCode, maxTokens: maxTokens)
        let profiler = Profiler()
        postData(path: "completions", data: request, responseType: Codings.CreateCompletionResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: Profiler.EventType.generateCloudCompletion, isSuccess: true)
                FreeToken.shared.logger("Completion generated succesfully", .info)
                successCompletion(Completion(from: response))
            case .failure(let error):
                profiler.end(eventType: .generateCloudCompletion, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
                FreeToken.shared.logger("Completion failed to generate", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
    public func generateLocalCompletion(prompt: String, maxTokens: Int? = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        guard await self.aiModelManager?.stateManager.getState() == .downloaded else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError))
            return
        }

        let profiler = Profiler()
        var result: (response: String, usage: TokenUsage)? = nil
        
        let aiModelManager = self.aiModelManager!
        let prompt = "\(aiModelManager.specialTokens.beginningOfText)\(prompt)"
        
        do {
            let uuid = UUID().uuidString
            result = try await aiModelManager.runEngine(prompt: prompt, maxTokens: maxTokens, runIdentifier: uuid, noContextCache: true)
            let completion = Completion(response: result!.response)

            profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: true, tokenStats: result!.usage)
            successCompletion(completion)
        } catch {
            var codingError = error as? Codings.ErrorResponse
            
            if codingError == nil {
                codingError = Codings.ErrorResponse(error: "unknownCompletionError", message: error.localizedDescription, code: nil)
            }
            
            profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: false, errorMessage: codingError!.message ?? error.localizedDescription)
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: codingError!))
        }
    }
    
    /// Generate a chat completion in the cloud
    ///
    ///
    func generateCloudChatCompletion(messages: [Message], model: String? = nil, maxTokens: Int? = nil, topK: Int? = nil, topP: Float? = nil, temperature: Float? = nil, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) -> Void> = nil, success successCallback: @escaping @Sendable (Message) -> Void, error errorCallback: @escaping @Sendable (FreeTokenError) -> Void) {
        
        // Filter out empty assistant message (not required for a cloud completion)
        let messages = messages.filter { message in
            !(message.role == .assistant && message.content == "")
        }
        
        let requestMessages = messages.map { message in
            return Codings.CodableMessage(role: message.role.rawValue, content: message.content)
        }
        
        let request: Codings.CreateCloudChatCompletion = Codings.CreateCloudChatCompletion(messages: requestMessages, model: model, topK: topK, topP: topP, temperature: temperature, maxTokens: maxTokens)
        
        let messageChunkPattern = #"(\{\s*"message_chunk"\s*:\s*".*?"\s*\}),"#
        let messageChunkRegex = try! NSRegularExpression(pattern: messageChunkPattern, options: [])
        let profiler = Profiler()
        
        streamPostData(path: "completions/chat", data: request, responseType: Codings.CloudChatResponse.self) { chunk in
            if let chatStatusStream = chatStatusStream {
                
                // The entire response will be streamed not just message chunks - so we need to filter it out
                if chunk.range(of: "message_chunk") != nil, messageChunkRegex.firstMatch(in: chunk, options: [], range: NSRange(location: 0, length: chunk.utf16.count)) != nil {
                    // Decode the chunk with MessageContentChunk
                    // If the last character is a comma, remove it
                    var chunk = chunk
                    if chunk.last == "," {
                        chunk.removeLast()
                    }
                    
                    // I'm getting some double chunks back - I could wrap it an []
                    chunk = "{ \"message_chunks\": [\(chunk)] }"
                    
                    if let data = chunk.data(using: .utf8) {
                        do {
                            let decoder = JSONDecoder()
                            let messageContentChunk = try decoder.decode(Codings.MessageChunkStream.self, from: data)
                            
                            // Check if the chunk is a message chunk
                            messageContentChunk.messageChunks.forEach { messageChunk in
                                // If the content is empty, we skip it
                                if !messageChunk.messageChunk.isEmpty {
                                    // Send the message chunk to the chat status stream
                                    chatStatusStream(messageChunk.messageChunk, .streaming_tokens)
                                }
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
                    chatStatusStream?(nil, .failed)
                    FreeToken.shared.logger("🔴 Error in cloud chat completion: \(errorResponse.message)", .error)

                    profiler.end(eventType: Profiler.EventType.generateCloudChatCompletion, isSuccess: false, errorMessage: errorResponse.message)
                    
                    // Hit an error while processing
                    let error = Codings.ErrorResponse(error: "cloudChatCompletionFailed", message: errorResponse.message, code: 1021)
                    
                    errorCallback(FreeTokenError.convertErrorResponse(errorResponse: error))
                    return
                }
                
                // Process the response
                if let tokenUsage = response.tokenUsage, let responseMessage = response.message {
                    let usage = TokenUsage(from: tokenUsage)
                    let message = Message(from: responseMessage, tokenUsage: usage)
                    profiler.end(eventType: Profiler.EventType.generateCloudChatCompletion, isSuccess: true, tokenStats: usage)
                    chatStatusStream?(nil, .stream_ended)
                    
                    // Call the success callback
                    successCallback(message)
                } else {
                    // Error that there wasn't the right response
                    chatStatusStream?(nil, .failed)
                    FreeToken.shared.logger("🔴 Invalid response from cloud chat completion", .error)
                    errorCallback(FreeTokenError.convertErrorResponse(errorResponse: self.cloudCompletionInvalidResponseError))
                }
            case .failure(let error):
                // Handle the error
                chatStatusStream?(nil, .failed)
                FreeToken.shared.logger("🔴 Failed to generate chat completion: \(error)", .error)
                
                // Call the error callback
                errorCallback(FreeTokenError.convertErrorResponse(errorResponse: error))
            }
        }

    }
    
    
    /// Create a document to be searched in your App's vector store
    ///
    /// ```
    ///     client.createDocument(content: blogPost.body, metadata: ["title": blogPost.title], searchScope: "blog-posts", success: { document in
    ///         // Created Successfully!
    ///     }, error: { error in
    ///         // Failed to create - retry?
    ///     })
    /// ```
    ///
    /// > Warning: Any document stored in your app's vector store should be public data. It is not secure or protected from other users access.
    ///
    /// > Note: It is not recommended that you use the document store as a persistence store in your app. Only use it for context to be provided to an AI.
    ///
    /// > Tip: For large documents, break them into chunks.  Large documents may hit an upload error.
    ///
    /// - Parameters:
    ///     - content: content of the document
    ///     - metadata: User defined metadata to attach to the document
    ///     - searchScope: String scope to use when looking up documents in Agents or via the API
    ///     - success: A closure to capture the result of the document being created
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func createDocument(content: String, metadata: Optional<String> = nil, searchScope: String, success successCompletion: @escaping @Sendable (Document) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
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
            let content = encryptionEnabled ? chunk.encryptedContent : chunk.chunkContent
            return Codings.CreateDocumentChunkRequest(content: content!, embedding: chunk.embedding!, embeddingModel: chunk.embeddingModelName)
        }
        
        let request = Codings.CreateDocumentRequest(content: document.sendableContent()!, metadata: document.sendableMetadata(), searchScope: searchScope, documentChunks: chunks, encryptionEnabled: encryptionEnabled)
        
        let wrapper = Codings.CreateDocumentRequestWrapper(document: request)
        
        let profiler = Profiler()
        postData(path: "documents", data: wrapper, responseType: Codings.ShowDocumentResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: Profiler.EventType.createDocument, isSuccess: true)
                FreeToken.shared.logger("Document created successfully", .info)
                successCompletion(Document(from: response))
            case .failure(let error):
                profiler.end(eventType: .createDocument, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
                FreeToken.shared.logger("Document failed to create with error: \(error)", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
    public func getDocument(id: String, success successCompletion: @escaping @Sendable (Document) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        let path = "documents/\(id)"
        fetchResource(path: path, responseType: Codings.ShowDocumentResponse.self) { result in
            switch result {
            case .success(var response):
                if response.encryptionEnabled {
                    let document = self.documentManager!.processEncryptedDocument(encryptedContent: response.content, encryptedMetdata: response.metadata)
                    response = Codings.ShowDocumentResponse(id: response.id, searchScope: response.searchScope, metadata: document.metadata, content: document.content!, encryptionEnabled: response.encryptionEnabled, createdAt: response.createdAt)
                }
                
                successCompletion(Document(from: response))
            case .failure(let error):
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
    ///     - maxResults: Max number of results to return
    ///     - success: A closure to capture the result of searching for documents
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func searchDocuments(query: String, searchScope: Optional<String> = nil, maxResults: Optional<Int> = nil, success successCompletion: @escaping @Sendable (DocumentSearchResults) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        // EmbeddingManager
        var embedding: [Float]
        do {
            embedding = try EmbeddingManager.shared.generate(text: query)
        } catch (_) {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: EmbeddingManager.embeddingFailedError))
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
        let data = Codings.SearchDocumentsRequest(embedding: embedding, embeddingModel: EmbeddingManager.shared.embeddingModelName, documentScope: searchScope, resultCount: resultCount, useAgentDocumentScope: useAgentDocumentScope)
        
        let profiler = Profiler()
        postData(path: path, data: data, responseType: Codings.SearchDocumentsResponse.self) { result in
            switch result {
            case .success(var response):
                let documentChunks: [Codings.SearchDocumentsResponse.DocumentChunkResult] = response.documentChunks.map({ documentChunkResult in
                    if documentChunkResult.encryptionEnabled == true {
                        let documentChunk = self.documentManager!.processEncryptedDocumentChunk(encryptedContent: documentChunkResult.contentChunk, documentMetadata: documentChunkResult.documentMetadata)
                        
                        return Codings.SearchDocumentsResponse.DocumentChunkResult(documentID: documentChunkResult.documentID, documentMetadata: documentChunk.documentMetadata, contentChunk: documentChunk.chunkContent!, encryptionEnabled: documentChunkResult.encryptionEnabled)
                    } else {
                        return documentChunkResult
                    }
                })
                
                profiler.end(eventType: Profiler.EventType.searchDocuments, isSuccess: true)

                response = Codings.SearchDocumentsResponse(documentChunks: documentChunks)

                successCompletion(DocumentSearchResults(from: response))
            case .failure(let error):
                profiler.end(eventType: .searchDocuments, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
                FreeToken.shared.logger("Document search failed with error \(error.message ?? error.localizedDescription)", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
            }
        }
    }
    
    func webSearch(query: String, resultCount: Int? = nil, success successCompletion: @escaping @Sendable ([WebSearchResult]) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        let path = "tool_calls/web_search"
        let data = Codings.WebSearchRequest(query: query, resultCount: resultCount)
        
        let profiler = Profiler()
        postData(path: path, data: data, responseType: Codings.WebSearchResults.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: Profiler.EventType.webSearch, isSuccess: true)
                let results = response.results.map { WebSearchResult(from: $0) }
                successCompletion(results)
            case .failure(let error):
                profiler.end(eventType: .webSearch, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
                FreeToken.shared.logger("Web search failed with error \(error.message ?? error.localizedDescription)", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
        success successCompletion: @escaping @Sendable (Message) -> Void,
        error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void,
        chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) -> Void> = nil,
        toolCallback: Optional<@Sendable ([ToolCall]) -> String> = nil,
        toolRunOnly: Bool = true,
        maxTokens: Int? = nil
    ) async {
        
            chatStatusStream?(nil, .starting)
        guard isDeviceRegistered() else {
            chatStatusStream?(nil, .failed)
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        // Determine AI Run Locations:
        let cloudRun: Bool
        
        if forceCloudRun == nil {
            // Automatically determine if this should be a cloud run or not
            do {
                cloudRun = try await shouldCloudRun()
            } catch {
                chatStatusStream?(nil, .failed)
                errorCompletion(error as! FreeTokenError)
                return
            }
        } else {
            FreeToken.shared.logger("☁️ Force cloud run set to: \(forceCloudRun!)", .info)
            cloudRun = forceCloudRun!
            
            if cloudRun == false, await aiModelManager?.stateManager.getState() != .downloaded {
                chatStatusStream?(nil, .failed)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError))
                return
            }
            
            if cloudRun == true, deviceMode?.isPrivacyMode == true {
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.cloudRunInPrivacyModeError))
                return
            }
        }
        
        FreeToken.shared.logger("🏁 Running message thread with ID: \(messageThreadID) - Cloud Run: \(cloudRun)", .info)
            
        let profiler = Profiler()
        
        let request = Codings.CreateMessageThreadRunRequest(messageThreadId: messageThreadID, forceCloudRun: cloudRun)
        postData(path: "message_thread_runs", data: request, responseType: Codings.ShowMessageThreadRunResponse.self) { result in
            switch result {
            case .success(let response):
                FreeToken.shared.logger("📩 Message thread run created successfully", .info)
                
                Task {
                    FreeToken.shared.logger("🏁 Prepping message context for AI", .info)
                    
                    var messages: [Message] = []
                    
                    // Assemble the system prompt
                    let systemPromptManager = SystemPromptManager(decrypt: self.decrypt, systemPromptParts: response.systemPromptParts, threadSearchResults: response.threadSearchResults)
                    
                    let systemPrompt: Message
                    
                    
                    if toolRunOnly == true {
                        // The system prompt will only contain tool definitions
                        systemPrompt = systemPromptManager.generateTool()
                    } else {
                        // The system prompt will not have tool definitions
                        systemPrompt = systemPromptManager.generateWithoutTools()
                    }
                    
                    messages.append(systemPrompt)
                    
                    // Add prompt messages to the messages array
                    let promptMessages = response.promptMessages.map { message in
                        let content: String
                        if let decrypt = self.decrypt {
                            if message.encryptionEnabled == true {
                                content = decrypt(message.content)
                            } else {
                                content = message.content
                            }
                        } else {
                            content = message.content
                        }
                        
                        return Message(role: MessageRole(rawValue: message.role)!, content: content, tokenCount: message.tokenCount)
                    }
                    
                    messages.append(contentsOf: promptMessages)
                    
                    let contextWindowManager = ContextWindowManager(modelManager: self.aiModelManager!)

                    // Cloud run & local Run success Handler
                    let successResult: @Sendable (Message) -> Void = { resultMessage in
                        FreeToken.shared.logger("🧠 AI Run was successful, adding message to thread", .info)
                        
                        // Add the result message to the thread
                        Task {
                            await self.addMessageToThread(messageThreadID: messageThreadID, message: resultMessage) { message in
                                do {
                                    // If tools are defined on the server (in the system prompt) then try to process them.
                                    if let toolDefinitions = response.systemPromptParts.toolDefinitions {
                                        FreeToken.shared.logger("🛠️ Checking for tool calls", .info)
                                        try self.runToolCall(messageThreadID: messageThreadID, aiMessage: resultMessage, toolNames: toolDefinitions.toolNames, profiler: profiler, isCloudRun: cloudRun, documentSearchScope: documentSearchScope, toolCallback: toolCallback, chatStatusStream: chatStatusStream, success: successCompletion, error: errorCompletion)
                                    } else {
                                        // No tools were defined on the server, just call the success callback
                                        chatStatusStream?(nil, .stream_ended)
                                        successCompletion(message)
                                    }
                                } catch {
                                    FreeToken.shared.logger("🔴 Failed to process tool calls: \(error)", .error)
                                    chatStatusStream?(nil, .failed)
                                }
                            } error: { error in
                                errorCompletion(error)
                                FreeToken.shared.logger("🔴 Failed to add result message to thread: \(error)", .error)
                            }
                        }
                    }
                    
                    let errorResult: @Sendable (FreeTokenError) -> Void = { error in
                        chatStatusStream?(nil, .failed)
                        errorCompletion(error)
                    }
                    
                    // Run the messages with either the local AI completion or the Cloud AI completion
                    if cloudRun {
                        // Run in the cloud
                        chatStatusStream?(nil, .sending_to_cloud_ai)
                        
                        // Run the cloud context window manager (as the local AI will not have a tokenizer)
                        let contextWindowMessages = try await contextWindowManager.filterMessages(messages: messages)
                        
                        FreeToken.shared.logger("🧠 Sending messages to the cloud for chat completion", .info)
                        // Send messages to the cloud for completion
                        self.generateCloudChatCompletion(messages: contextWindowMessages, maxTokens: maxTokens, chatStatusStream: chatStatusStream, success: successResult, error: errorResult)
                    } else {
                        // Run locally
                        chatStatusStream?(nil, .sending_to_local_ai)
                        let tokenString = try await contextWindowManager.generate(messages: messages)
                        
                        // Send the token string to the AI for completion
                        let resultContent: String
                        let usage: TokenUsage
                        
                        do {
                            (resultContent, usage) = try await self.aiModelManager!.sendPromptToAI(prompt: tokenString,  runIdentifier: messageThreadID, maxTokens: maxTokens) { token in
                                chatStatusStream?(token, .streaming_tokens)
                                // TODO: Try to start handling tool calls before the AI completes
                            }
                            FreeToken.shared.logger("🧠 Local AI run completed successfully", .info)
                            let resultMessage = Message(role: .assistant, content: resultContent, tokenUsage: usage)
                            successResult(resultMessage)
                        } catch {
                            let errorResponse = error as! FreeTokenError
                            FreeToken.shared.logger("🔴 Local AI run failed with error: \(errorResponse.message ?? errorResponse.localizedDescription)", .error)
                            errorCompletion(error as! FreeTokenError)
                        }
                    }
                }
                
            case .failure(let error):
                FreeToken.shared.logger("Message thread run failed with error \(error.message ?? error.localizedDescription)", .error)
                chatStatusStream?(nil, .failed)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
            }
        }
    }
    
    private func runToolCall(
            messageThreadID: String,
            aiMessage resultMessage: Message,
            toolNames: [String] = [],
            profiler: Profiler,
            isCloudRun cloudRun: Bool = false,
            documentSearchScope: String? = nil,
            toolCallback: Optional<@Sendable ([ToolCall]) -> String> = nil,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) -> Void> = nil,
            success successCompletion: @escaping @Sendable (Message) -> Void,
            error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void
    ) throws {
        let toolCallManager = ToolCallsManager(messageContent: resultMessage.content, availableCloudToolCalls: self.deviceDetails!.availableCloudToolCalls, toolNames: toolNames, documentSearchScope: documentSearchScope)
        
        try toolCallManager.process(externalToolCallHandler: toolCallback) { toolCalls in
            // TODO: Future Feature: Handle Cloud Tool Calls
            return ""
        } success: { result in
            if result != "" {
                // Tool result was returned
                // Create a tool message
                FreeToken.shared.logger("🔧 Tool calls processed successfully", .info)
                
                let toolResult: String
                if self.deviceDetails?.aiModel.config.promptTemplateConfig.jsonToolResults == true {
                    toolResult = "{\"toolResults\": \"\(result)\"}"
                } else {
                    toolResult = result
                }

                let toolMessage = Message(role: .tool, content: toolResult)
                Task {
                    await self.addMessageToThread(messageThreadID: messageThreadID, message: toolMessage) { toolResultMessage in
                        // Run message thread again with tool result
                        Task {
                            await self.runMessageThread(id: messageThreadID, forceCloudRun: cloudRun, documentSearchScope: documentSearchScope, success: successCompletion, error: errorCompletion, chatStatusStream: chatStatusStream, toolCallback: toolCallback, toolRunOnly: false)
                        }
                    } error: { error in
                        FreeToken.shared.logger("🔴 Failed to add tool result message: \(error)", .error)
                        errorCompletion(error)
                    }
                }
            } else {
                // No tool result, just call the success callback
                if cloudRun == true {
                    profiler.end(eventType: Profiler.EventType.runMessageThreadCloud, isSuccess: true, tokenStats: resultMessage.tokenUsage)
                } else {
                    profiler.end(eventType: Profiler.EventType.runMessageThreadLocal, isSuccess: true, tokenStats: resultMessage.tokenUsage)
                }
                
                FreeToken.shared.logger("✅ Message thread run completed successfully", .info)
                
                chatStatusStream?(nil, .stream_ended)
                successCompletion(resultMessage)
            }
        }
    }
        
    private func shouldCloudRun() async throws -> Bool {
        if deviceManager?.isAICapable == true {
            if await aiModelManager?.stateManager.getState() != .downloaded {
                if self.deviceMode?.isQuickStartMode == true {
                    FreeToken.shared.logger("Quick Start Activated!", .info)
                    // Quick start mode activated
                    return true
                } else {
                    throw FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError)
                }
            } else {
                // Downloaded
                FreeToken.shared.logger("🧠 Model downloaded and AI supported - Should run locally", .info)
                return false
            }
        } else {
            if  self.deviceMode?.isCompatibilityMode == true {
                // Compatibility Mode activated
                FreeToken.shared.logger("☁️ Compatibility Mode Activated!", .info)
                return true
            } else {
                if deviceManager?.isAICapable == true {
                    if aiModelManager != nil {
                        throw FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError)
                    } else {
                        throw FreeTokenError(domain: "modelNotDownloadedError", code: 900)
                    }
                } else {
                    throw FreeTokenError.convertErrorResponse(errorResponse: aiNotSupportedNoCompatibilityError)
                }
            }
        }
    }
    
    /// Get a Message Thread Run by ID
    ///
    /// ```
    ///     client.getMessageThreadRun(id: "msgthr-id", success: { messageThreadRun in
    ///         // Check the status
    ///     }, error: { error in
    ///         // Handle error - retry?
    ///     })
    /// ```
    ///
    /// - Parameters:
    ///     - id: String of the message thread run ID
    ///     - success: A closure to capture the result of fetching the message thread run
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func getMessageThreadRun(id: String, success successCompletion: @escaping @Sendable (MessageThreadRun) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        if !isDeviceRegistered() {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }

        let path = "message_thread_runs/\(id)"
        
        fetchResource(path: path, responseType: Codings.ShowMessageThreadRunResponse.self) { result in
            switch result {
            case .success(let response):
                FreeToken.shared.logger("Get Message Thread Run was successful by ID \(id)", .info)
                successCompletion(MessageThreadRun(from: response))
                return
            case .failure(let error):
                FreeToken.shared.logger("Get Message Thread Run failed with error \(error.message ?? error.localizedDescription)", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
                return
            }
        }
    }
    
    /// Load the AI Model into the device memory
    ///
    /// ```
    ///     client.loadModel(success: {
    ///         // Model is loaded and ready for use
    ///     }, error: { error in
    ///         // Handle the error - Retry?
    ///     })
    /// ```
    ///
    /// > Note: You must run ``downloadAIModel(completion:)`` prior to using this method.
    ///
    ///- Parameters:
    ///     - success: A closure to capture the result of loading the AI model
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: A generic enumeration result of Bool, ErrorResponse
    public func loadModel(success successCompletion: @escaping (Bool) -> Void, error errorCompletion: @escaping (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        if deviceManager?.isAICapable == false {
            FreeToken.shared.logger("Load Model: Device not capable of AI, nothing to do here", .info)
            successCompletion(false)
            return
        }
        
        let response = await aiModelManager!.loadModel()
        switch response {
        case .success(let isSuccess):
            successCompletion(isSuccess)
        case .failure(let error):
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
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
    public func unloadModel() {
        aiModelManager?.unloadModel()
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
    public func localChat(messages: [Message], uniqueID: String? = nil) async throws -> Message {
        if !isDeviceRegistered() {
            throw FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError)
        }
        
        let runIdentifier: String
        
        if uniqueID == nil {
            runIdentifier = UUID().uuidString
        } else {
            runIdentifier = uniqueID!
        }
            
        
        do {
            return try await aiModelManager!.localChat(messages: messages, runIdentifier: runIdentifier)
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
            
            self.postData(path: "telemetries", data: request, responseType: Codings.TelemetryCreateResponse.self) { result in
                switch result {
                case .success(_):
//                    print("[FreeToken] Created telemetry successfully: \(response.message)")
                    break
                case .failure(let error):
                    FreeToken.shared.logger("[FreeToken] Telemetry Creation Error: \(error.message ?? error.localizedDescription)", .error)
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
    private func fetchResource<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        responseType: T.Type,
        completion: @escaping @Sendable (Result<T, Codings.ErrorResponse>) -> Void
    ) {
        guard isClientConfigured() else {
            completion(.failure(self.clientNotConfiguredError))
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
            completion(.failure(self.invalidURLError))
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
        httpClient.get(from: endpoint, headers: headers, responseType: responseType, completion: completion)
    }

    /// Posts data to the server.
    /// - Parameters:
    ///   - data: The object to send, encoded as JSON.
    ///   - responseType: The type of the expected response.
    ///   - completion: Completion handler with the decoded response or an error.
    private func postData<T: Decodable, U: Encodable>(
        path: String,
        data: U,
        responseType: T.Type,
        completion: @escaping @Sendable (Result<T, Codings.ErrorResponse>) -> Void
    ) {
        guard isClientConfigured() else {
            completion(.failure(self.clientNotConfiguredError))
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
            
            httpClient.post(to: endpoint, headers: headers, body: body, responseType: responseType, completion: completion)
        } catch {
            completion(.failure(error as! Codings.ErrorResponse))
        }
    }
    
    /// Posts data to the server.
    /// - Parameters:
    ///   - data: The object to send, encoded as JSON.
    ///   - responseType: The type of the expected response.
    ///   - completion: Completion handler with the decoded response or an error.
    private func streamPostData<T: Decodable, U: Encodable>(
        path: String,
        data: U,
        responseType: T.Type,
        streamCallback: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (Result<T, Codings.ErrorResponse>) -> Void
    ) {
        guard isClientConfigured() else {
            completion(.failure(self.clientNotConfiguredError))
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
            completion(.failure(error as! Codings.ErrorResponse))
        }
    }
    
    /// Delete a resource
    private func deleteResource(
        path: String,
        completion: @escaping @Sendable (Result<Void, Codings.ErrorResponse>) -> Void
    ) {
        guard isClientConfigured() else {
            completion(.failure(self.clientNotConfiguredError))
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
