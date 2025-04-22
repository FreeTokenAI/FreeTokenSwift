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
    
    // Methods:
    
    private init() {
        self.baseURL = URL(string: "https://project-nova.fractionallab.com/api/v1/")!
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
                
                profiler.end(eventType: Profiler.EventType.createDevice, isSuccess: true)
                success()
            case .failure(let errorResponse):
                FreeToken.shared.logger("Failed to register device: \(errorResponse.message ?? errorResponse.localizedDescription)", .error)
                profiler.end(eventType: .createDevice, isSuccess: false, errorMessage: errorResponse.message ?? errorResponse.localizedDescription)
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
            
            if aiModelManager.state == .downloaded {
                FreeToken.shared.logger("Model already downloded", .info)
                successCallback(true)
                return
            }
            
            if deviceManager.isAICapable == false {
                FreeToken.shared.logger("Cannot download AI model as AI is not supported on this device.", .error)
                successCallback(false)
                return
            }

            Task {
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
    ///     - role: Message role. Examples: 'user', 'assistant', 'system'
    ///     - content: Content of the message
    ///     - toolResult: Use this optional value to respond to Tool Calls from the AI
    ///     - success: A closure to capture the results of the call to add the message to the thread
    ///     - toolCalls: This parameter is used when creating Role calls from the AI - it can be used when importing existing threads from other systems.    
    ///     - success: A closure to capture the results of the call to add the message to the thread
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func addMessageToThread(messageThreadID: String, role: String, content: String, toolResult: Optional<String> = nil, toolCalls: Optional<String> = nil, success successCompletion: @escaping @Sendable (Message) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        let originalContent = content
        let originalToolCalls = toolCalls
        let originalToolResult = toolResult
        
        var content = content
        var toolCalls = toolCalls
        var toolResult = toolResult
        var encryptionEnabled = false
        
        if let encrypt = encrypt {
            encryptionEnabled = true
            content = encrypt(content)
            toolCalls = toolCalls != nil ? encrypt(toolCalls!) : nil
            toolResult = toolResult != nil ? encrypt(toolResult!) : nil
        }
        
        var vectors: [Float]?
                
        if toolCalls == nil, toolResult == nil {
            do {
                vectors = try EmbeddingManager.shared.generate(text: content)
            } catch (let error) {
                errorCompletion(error as! FreeTokenError)
                return
            }
        }
                
        let request = Codings.CreateMessageRequest(messageThreadID: messageThreadID, role: role, content: content, toolResult: toolResult, toolCalls: toolCalls, embedding: vectors, embeddingModel: EmbeddingManager.shared.embeddingModelName, encryptionEnabled: encryptionEnabled)
        
        let profiler = Profiler()
        postData(path: "messages", data: request, responseType: Codings.ShowMessageResponse.self) { result in
            switch result {
            case .success(var response):
                if response.encryptionEnabled == true {
                    response = Codings.ShowMessageResponse(id: response.id, role: response.role, content: originalContent, toolCalls: originalToolCalls, toolResult: originalToolResult, isToolMessage: response.isToolMessage, encryptionEnabled: response.encryptionEnabled, createdAt: response.createdAt, updatedAt: response.updatedAt, tokenUsage: response.tokenUsage)
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
                        let toolResult = response.toolResult != nil ? decrypt(response.toolResult!) : nil
                        
                        response = Codings.ShowMessageResponse(id: response.id, role: response.role, content: decrypt(response.content), toolCalls: toolCalls, toolResult: toolResult, isToolMessage: response.isToolMessage, encryptionEnabled: response.encryptionEnabled, createdAt: response.createdAt, updatedAt: response.updatedAt, tokenUsage: response.tokenUsage)
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
    ///     - success: A closure to capture the results of the call to generate the completion
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func generateCompletion(prompt: String, modelCode: Optional<String> = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        if aiModelManager?.state == .downloaded, (modelCode == nil || self.deviceDetails?.aiModel.code == modelCode)  {
            // Generate local completion
            await generateLocalCompletion(prompt: prompt) { completion in
                successCompletion(completion)
            } error: { error in
                errorCompletion(error)
            }
            return
        } else {
            // Generate cloud completion
            if self.deviceMode?.isPrivacyMode == false {
                generateCloudCompletion(prompt: prompt, success: successCompletion, error: errorCompletion)
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
    ///     - success: A closure to capture the results of the AI completion
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func generateCloudCompletion(prompt: String, modelCode: Optional<String> = nil, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }

        let request = Codings.CreateCompletionRequest(prompt: prompt, model: modelCode)
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
    ///     - success: A closure that is called after the successful call to the AI
    ///     - error: A closure to capture any errors that occur during the call
    ///
    /// - Returns: Void
    public func generateLocalCompletion(prompt: String, success successCompletion: @escaping @Sendable (Completion) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) async {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        guard case .downloaded = aiModelManager!.state else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError))
            return
        }

        let profiler = Profiler()
        var result: (response: [String : String], usage: FreeToken.Codings.TokenUsageResponse)? = nil
        
        let aiModelManager = self.aiModelManager!
        let prompt = "\(aiModelManager.specialTokens.beginningOfText)\(prompt)"
        
        do {
            result = try aiModelManager.runEngine(prompt: prompt)
            let response = result!.response
            let output = response["content"]!
            let completion = Completion(response: output)

            profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: true, tokenStats: result!.usage)
            successCompletion(completion)
        } catch {
            let error = error as! FreeTokenError
            profiler.end(eventType: Profiler.EventType.generateLocalCompletion, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
            errorCompletion(error)
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
    ///
    /// - Returns: Void
    public func runMessageThread(id: String, forceCloudRun: Optional<Bool> = nil, documentSearchScope: Optional<String> = nil, success successCompletion: @escaping @Sendable (MessageThreadRun) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: String) -> Void> = nil, toolCallback: Optional<@Sendable ([ToolCall]) -> String> = nil) {
        
        chatStatusStream?(nil, "starting_run")
        guard isDeviceRegistered() else {
            chatStatusStream?(nil, "failed")
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        // Determine AI Run Locations:
        let cloudRun: Bool
        
        if forceCloudRun == nil {
            if deviceManager?.isAICapable == true {
                if aiModelManager?.state != .downloaded {
                    if self.deviceMode?.isQuickStartMode == true {
                        FreeToken.shared.logger("Quick Start Activated!", .info)
                        // Quick start mode activated
                        cloudRun = true
                    } else {
                        chatStatusStream?(nil, "failed")
                        errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError))
                        return
                    }
                } else {
                    // Downloaded
                    FreeToken.shared.logger("Model downloaded and AI supported - cloud run False", .info)
                    cloudRun = false
                }
            } else {
                if  self.deviceMode?.isCompatibilityMode == true {
                    // Compatibility Mode activated
                    FreeToken.shared.logger("Compatibility Mode Activated!", .info)
                    cloudRun = true
                } else {
                    chatStatusStream?(nil, "failed")
                    
                    if deviceManager?.isAICapable == true {
                        if aiModelManager != nil {
                            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError))
                        } else {
                            errorCompletion(FreeTokenError(domain: "modelNotDownloadedError", code: 900))
                        }
                    } else {
                        errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: aiNotSupportedNoCompatibilityError))
                    }
                    
                    return
                }
            }
        } else {
            FreeToken.shared.logger("Force cloud run set to: \(forceCloudRun!)", .info)
            cloudRun = forceCloudRun!
            
            if cloudRun == false, aiModelManager?.state != .downloaded {
                chatStatusStream?(nil, "failed")
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: aiModelManager!.aiModelNotDownloadedError))
                return
            }
            
            if cloudRun == true, deviceMode?.isPrivacyMode == true {
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.cloudRunInPrivacyModeError))
                return
            }
        }
        
        FreeToken.shared.logger("Running Tool Call Agent", .info)
        // Run tool calls prior to running the message thread
        chatStatusStream?(nil, "checking_for_tool_calls")
        self.runFunctionCallAgent(cloudRun: cloudRun, messageThreadID: id) { toolMessage, agentMessages, forceCloudRun, skip in
            if skip {
                FreeToken.shared.logger("No tool calls, running message thread", .info)
                self._runMessageThread(messageThreadID: id, cloudRun: forceCloudRun, chatStatusStream: chatStatusStream, success: successCompletion, error: errorCompletion)
                return
            }
            
            // Have the prompt or the agent message
            if let toolMessage = toolMessage {
                // Ran in the cloud & has at least one tool call - handle the tool results now
                FreeToken.shared.logger("Handing off tool calls", .info)
                chatStatusStream?(nil, "handing_off_tool_calls")
                self.handleToolCalls(toolCalls: toolMessage.toolCalls!, messageThreadID: id, documentSearchScope: documentSearchScope, externalToolCallback: toolCallback, chatStatusStream: chatStatusStream) { toolResult in
                    // Successful tool call
                    FreeToken.shared.logger("Successfull tool calls, adding tool result to thread: \(toolResult)", .info)
                    // Add Message to Thread
                    self.addMessageToThread(messageThreadID: id, role: "tool", content: "", toolResult: toolResult) { message in
                        // Continue with message thread run
                        FreeToken.shared.logger("Running the message thread with tool result message added", .info)
                        self._runMessageThread(messageThreadID: id, cloudRun: forceCloudRun, chatStatusStream: chatStatusStream, success: successCompletion, error: errorCompletion)
                    } error: { error in
                        errorCompletion(error)
                    }
                } error: { error in
                    errorCompletion(error)
                }
            } else if let agentMessages = agentMessages {
                // Need to run on local AI
                do {
                    // Decrypt any of the agent messages
                    let messages = agentMessages.map { agentMessage in
                        var message: Codings.ShowMessageResponse
                        
                        if agentMessage.encryptionEnabled == true {
                            var toolCalls = agentMessage.toolCalls
                            var content = agentMessage.content
                            var toolResult = agentMessage.toolResult
                            
                            if toolCalls != nil {
                                toolCalls = self.decrypt!(agentMessage.toolCalls!)
                            } else if toolResult != nil {
                                toolResult = self.decrypt!(agentMessage.toolResult!)
                            } else if content != "" {
                                content = self.decrypt!(agentMessage.content)
                            }
                            
                            message = Codings.ShowMessageResponse(id: agentMessage.id, role: agentMessage.role, content: content, toolCalls: toolCalls, toolResult: toolResult, isToolMessage: agentMessage.isToolMessage, encryptionEnabled: agentMessage.encryptionEnabled, createdAt: agentMessage.createdAt, updatedAt: agentMessage.updatedAt, tokenUsage: agentMessage.tokenUsage)
                        } else {
                            message = agentMessage
                        }
                        
                        return message
                    }
                    
                    // Run on local AI
                    let resultMessage = try self.aiModelManager!.sendMessagesToAISync(messages: messages)
                    
                    if resultMessage.toolCalls != nil {
                        
                        chatStatusStream?(nil, "handing_off_tool_calls")
                        // Add the tool call message to the thread
                        self.addMessageToThread(messageThreadID: id, role: resultMessage.role, content: "", toolCalls: resultMessage.toolCalls) { message in
                            
                            // Handle the tool calls
                            self.handleToolCalls(toolCalls: resultMessage.toolCalls!, messageThreadID: id, documentSearchScope: documentSearchScope, externalToolCallback: toolCallback, chatStatusStream: chatStatusStream) { toolResult in
                                
                                FreeToken.shared.logger("Successfull tool calls, adding tool result to thread", .info)

                                // Add the tool result to the message thread
                                self.addMessageToThread(messageThreadID: id, role: "tool", content: "", toolResult: toolResult) { message in
                                    
                                    FreeToken.shared.logger("Running the message thread with tool result message added", .info)
                                    // Run the message thread
                                    self._runMessageThread(messageThreadID: id, cloudRun: forceCloudRun, chatStatusStream: chatStatusStream, success: successCompletion, error: errorCompletion)
                                } error: { error in
                                    errorCompletion(error)
                                }

                            } error: { error in
                                errorCompletion(error)
                            }
                        } error: { error in
                            errorCompletion(error)
                        }

                    } else {
                        // Tool result was just nil, move on to running the message thread
                        self._runMessageThread(messageThreadID: id, cloudRun: forceCloudRun, chatStatusStream: chatStatusStream, success: successCompletion, error: errorCompletion)
                    }
                } catch (let error) {
                    errorCompletion(error as! FreeTokenError)
                }
            } else {
                // You shouldn't get here, but if you do assume that we should run the message thread?
                errorCompletion(FreeTokenError(domain: "whoops", code: 001))
            }
        } error: { error in
            errorCompletion(error)
        }
    }
    
    private func _runMessageThread(messageThreadID id: String, cloudRun: Bool, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: String) -> Void> = nil, success successCompletion: @escaping @Sendable (MessageThreadRun) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        let profiler = Profiler()
        let messageChunkPattern = #"(\{\s*"message_chunk"\s*:\s*".*?"\s*\}),"#
        let messageChunkRegex = try! NSRegularExpression(pattern: messageChunkPattern, options: [])
        let request = Codings.CreateMessageThreadRunRequest(messageThreadId: id, forceCloudRun: cloudRun)
        
        streamPostData(path: "message_thread_runs", data: request, responseType: Codings.ShowMessageThreadRunResponse.self) { chunk in
            let range = NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)
            let matches = messageChunkRegex.matches(in: chunk, options: [], range: range)
            
            for match in matches {
                let range = Range(match.range(at: 1), in: chunk)
                let jsonMatch = String(chunk[range!])
                
                let decodedResponse = try! JSONDecoder().decode(Codings.MessageContentChunk.self, from: jsonMatch.data(using: .utf8)!)
                chatStatusStream?(decodedResponse.messageChunk, "streaming_tokens")
            }
        } completion: { result in
            switch result {
            case .success(let response):
                // If it's a cloud run, return the response immediately
                // Note: cloud runs can be forced by the Agent definition
                if response.cloudRun {
                    successCompletion(MessageThreadRun(from: response))
                } else {
                    let systemPromptContext = self.generateSystemPrompt(parts: response.systemPromptParts, threadSearchResults: response.threadSearchResults)
                    let systemPrompt = Codings.ShowMessageResponse(id: nil, role: "system", content: systemPromptContext, toolCalls: nil, toolResult: nil, isToolMessage: nil, encryptionEnabled: nil, createdAt: nil, updatedAt: nil, tokenUsage: nil)
                    var promptMessages: [Codings.ShowMessageResponse] = [systemPrompt]
                    if self.decrypt != nil {
                        let decrypted = response.promptMessages.map { message in
                            if message.encryptionEnabled == true {
                                if message.toolResult != nil {
                                    return Codings.ShowMessageResponse(id: message.id, role: message.role, content: message.content, toolCalls: message.toolCalls, toolResult: self.decrypt!(message.toolResult!), isToolMessage: message.isToolMessage, encryptionEnabled: message.encryptionEnabled, createdAt: message.createdAt, updatedAt: message.updatedAt, tokenUsage: message.tokenUsage)
                                } else if message.toolCalls != nil {
                                    return Codings.ShowMessageResponse(id: message.id, role: message.role, content: message.content, toolCalls: self.decrypt!(message.toolCalls!), toolResult: message.toolResult, isToolMessage: message.isToolMessage, encryptionEnabled: message.encryptionEnabled, createdAt: message.createdAt, updatedAt: message.updatedAt, tokenUsage: message.tokenUsage)
                                } else {
                                    return Codings.ShowMessageResponse(id: message.id, role: message.role, content: self.decrypt!(message.content), toolCalls: message.toolCalls, toolResult: message.toolResult, isToolMessage: message.isToolMessage, encryptionEnabled: message.encryptionEnabled, createdAt: message.createdAt, updatedAt: message.updatedAt, tokenUsage: message.tokenUsage)
                                }
                            } else {
                                return message
                            }
                        }
                        promptMessages.append(contentsOf: decrypted)
                    } else {
                        promptMessages.append(contentsOf: response.promptMessages)
                    }
                    
                    self.runMessageThreadLocally(messageThreadRunResponse: response, messageThreadID: id, messages: promptMessages, profiler: profiler, chatStatusStream: chatStatusStream, success: successCompletion, error: errorCompletion)
                }
                chatStatusStream?(nil, "stream_ended")
            case .failure(let error):
                let profilerEventType = cloudRun ? Profiler.EventType.runMessageThreadCloud : Profiler.EventType.runMessageThreadLocal
                profiler.end(eventType: profilerEventType, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
                FreeToken.shared.logger("Message thread failed to run with error \(error.message ?? error.localizedDescription)", .error)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
            }
        }
    }
    
    private func generateSystemPrompt(parts: [[String: String?]], threadSearchResults: [[String: String]]) -> String {
        var systemContext = ""
        
        for part in parts {
            for key in part.keys {
                if let value = part[key]! {
                    if key == "thread_search_results_context" {
                        systemContext += value
                        systemContext += "\n\n"
                        for message in threadSearchResults {
                            var content: String
                            if decrypt != nil {
                                content = decrypt!(message["content"]!)
                            } else {
                                content = message["content"]!
                            }
                            
                            systemContext += "\(message["role"]!): \(content)\n"
                        }
                    } else if key == "pinned_context", decrypt != nil {
                        systemContext += decrypt!(value)
                    } else {
                        systemContext += value
                    }
                    systemContext += "\n\n"
                }
            }
        }
        
        return systemContext
    }
    
    private func runMessageThreadLocally(messageThreadRunResponse response: Codings.ShowMessageThreadRunResponse, messageThreadID: String, messages: [Codings.ShowMessageResponse], profiler: Profiler, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: String) -> Void> = nil, success successCompletion: @escaping @Sendable (MessageThreadRun) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {

        // Process messages synchronously
        var responseMessage: Codings.ShowMessageResponse
        
        // Send off to the AI
        do {
            chatStatusStream?(nil, "sending_to_local_ai")
            responseMessage = try aiModelManager!.sendMessagesToAISync(messages: messages, tokenStream: { newTokens in
                chatStatusStream?(newTokens, "streaming_tokens")
            })
        } catch {
            let error = error as! Codings.ErrorResponse
            profiler.end(eventType: .runMessageThreadLocal, isSuccess: false, errorMessage: error.message ?? error.localizedDescription)
            chatStatusStream?(nil, "failed")
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
            return
        }
        
        // Process the Results
        let tokenUsage = responseMessage.tokenUsage
        
        self.addMessageToThread(messageThreadID: messageThreadID, role: responseMessage.role, content: responseMessage.content, toolCalls: responseMessage.toolCalls) { message in
            let newResponse = Codings.ShowMessageThreadRunResponse(
                id: response.id,
                status: response.status,
                createdAt: response.createdAt,
                startedAt: response.startedAt,
                endedAt: response.endedAt,
                cloudRun: response.cloudRun,
                promptMessages: response.promptMessages,
                systemPromptParts: [],
                threadSearchResults: [],
                resultMessage: Codings.ShowMessageResponse(id: message.id, role: message.role, content: message.content, toolCalls: message.toolCalls, toolResult: message.toolResult, isToolMessage: message.isToolMessage, encryptionEnabled: nil, createdAt: message.createdAt, updatedAt: message.updatedAt, tokenUsage: tokenUsage)
            )
            profiler.end(eventType: .runMessageThreadLocal, eventTypeID: response.id, isSuccess: true, tokenStats: tokenUsage)
            chatStatusStream?(nil, "stream_ended")
            successCompletion(MessageThreadRun(from: newResponse))
        } error: { error in
            profiler.end(eventType: .runMessageThreadLocal, eventTypeID: response.id, isSuccess: false, errorMessage: error.message ?? error.localizedDescription, tokenStats: tokenUsage)
            chatStatusStream?(nil, "failed")
            errorCompletion(error)
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
    public func loadModel(success successCompletion: @escaping (Bool) -> Void, error errorCompletion: @escaping (FreeTokenError) -> Void) {
        guard isDeviceRegistered() else {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError))
            return
        }
        
        if deviceManager?.isAICapable == false {
            FreeToken.shared.logger("Load Model: Device not capable of AI, nothing to do here", .info)
            successCompletion(false)
            return
        }
        
        let response = aiModelManager!.loadModel()
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
        Task {
            await aiModelManager?.unloadModel()
        }
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
    /// > Warning: You must run ``downloadAIModel(completion:)`` prior to using this method. This will not work on devices
    /// > that do not support AI.
    ///
    /// - Parameters:
    ///     - content: String of the message content
    ///     - role: String of the role. Examples: 'user', 'assistant', 'system'
    ///
    /// - Returns: Dictionary of message result including role & content keys
    /// - Throws: FreeTokenError if the device is not registered or if there is an error during the local chat
        public func localChat(content: String, role: String) throws -> [String: String] {
        if !isDeviceRegistered() {
            throw FreeTokenError.convertErrorResponse(errorResponse: self.deviceNotRegisteredError)
        }
        
        do {
            return try aiModelManager!.localChat(content: content, role: role)
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
        let eventData = Codings.TelemetryDataRequest(eventDurationInMilliseconds: profiler.msDuration(), eventTypeId: profiler.eventTypeID, eventObjectType: profiler.eventObjectType, isSuccess: profiler.isSuccess, errorMessage: profiler.errorMessage, tokenStats: profiler.tokenStats)
        
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
    
    private func runFunctionCallAgent(cloudRun: Bool, messageThreadID: String, success successCompletion: @escaping @Sendable (_ functionMessage: Codings.ShowMessageResponse?, _ agentMessages: [Codings.ShowMessageResponse]?, _ forceCloudRun: Bool, _ skip: Bool) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) {
        
        let request = Codings.ToolCallAgentRequest(messageThreadID: messageThreadID, cloudRun: cloudRun)
        
        let profiler = Profiler()
        self.postData(path: "tool_calls/agent", data: request, responseType: Codings.ToolCallAgentResponse.self) { result in
            switch result {
            case .success(let response):
                profiler.end(eventType: .toolCallAgentRun, isSuccess: true)
                if response.cloudRun {
                    if let toolMessage = response.toolMessage {
                        // Return the resulting tool call
                        successCompletion(toolMessage, nil, response.cloudRun, false)
                    } else {
                        // Cloud run was activated - likely no tools defined
                        successCompletion(nil, nil, response.cloudRun, true)
                    }
                } else {
                    // Return messages to be parsed
                    if let agentMessages = response.agentMessages {
                        successCompletion(nil, agentMessages, response.cloudRun, false)
                    } else {
                        // Likely no tools defined
                        successCompletion(nil, nil, response.cloudRun, true)
                    }
                }
            case .failure(let error):
                profiler.end(eventType: .toolCallAgentRun, isSuccess: false, errorMessage: error.message)
                errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: error))
            }
        }
    }
    
    private func handleToolCalls(toolCalls: String, messageThreadID: String, documentSearchScope: Optional<String> = nil, externalToolCallback: Optional<@Sendable ([ToolCall]) -> String> = nil, chatStatusStream: Optional<@Sendable (_ token: String?, _ status: String) -> Void> = nil, success successCompletion: @escaping @Sendable (String) -> Void, error errorCompletion: @escaping @Sendable (FreeTokenError) -> Void) -> Void {
        // Send tool calls off to cloud for handling
        
        let cloudToolCalls = deviceDetails!.availableCloudToolCalls
        
        let toolCallManager = ToolCallsManager(toolCalls: toolCalls, availableCloudToolCalls: cloudToolCalls, documentSearchScope: documentSearchScope)
                
        do {
            try toolCallManager.process(externalToolCallHandler: externalToolCallback) { cloudCalls in
                // Handle internal cloud call tools
                let toolCalls = cloudCalls.map { toolCall in
                    Codings.ToolCall(name: toolCall.name, arguments: toolCall.arguments)
                }
                
                let request = Codings.ToolCallsRequest(messageThreadID: messageThreadID, toolCalls: toolCalls)
                var finalResponse = ""
                let resultsQueue = DispatchQueue(label: "com.FreeToken.toolCallResponseQueue")

                self.postData(path: "tool_calls", data: request, responseType: Codings.ToolCallsResponse.self) { result in
                    switch result {
                    case .success(let response):
                        resultsQueue.sync {
                            finalResponse = response.toolResults
                        }
                    case .failure(_):
                        // NoOp
                        errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.handlingToolCallsFailedError))
                    }
                }
                
                return finalResponse
            } success: { result in
                successCompletion(result)
            }
        } catch (_) {
            errorCompletion(FreeTokenError.convertErrorResponse(errorResponse: self.handlingToolCallsFailedError))
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
    internal func postData<T: Decodable, U: Encodable>(
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

}
