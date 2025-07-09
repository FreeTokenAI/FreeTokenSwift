//
//  FreeTokenError.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/21/25.
//
import Foundation

extension FreeToken {
    
    public enum FreeTokenError: Error, Equatable {
        // MARK: - Main FreeToken Class Errors
        case deviceNotRegistered
        case clientDeallocated
        case aiModelDownload
        case clientNotConfigured
        case clientAIVersionMismatch
        case deviceReset
        case cacheReset
        case invalidURL
        case aiNotSupportedNoCompatibility
        case responseTypeInvalid
        case handlingToolCallsFailed
        case encryptionEnabledInCompatibilityMode
        case encryptedMessageLoadedInCompatibilityMode
        case cloudCompletionPrivacyMode
        case cloudCompletionFailed(message: String? = nil)
        case encryptedDocumentReceivedWithoutWayToDecrypt
        case encryptedMessageThreadLoadedWithoutWayToDecrypt
        case privateDocumentStoreNotFound
        case privateDocumentStoreCreationFailed
        case privateDocumentStoreDeletionFailed
        case invalidPrivateDocumentStoreId
        case privateDocumentCreationFailed
        case noEncryptOrDecryptDefinedInPrivacyMode
        case encryptOrDecryptDefinedInCompatibilityMode
        case deviceIncapableOfAiInPrivacyMode
        case cloudRunInPrivacyMode
        case modelMustBeLoadedBeforeAddingMessage
        case cloudCompletionInvalidResponse
        case encoding(message: String? = nil)
        
        // MARK: - AIModelManager Class Errors:
        case unsupportedVersion
        case aiModelNotDownloaded
        case modelAlreadyLoading
        case failedToLoadModel
        case aiModelNotLoaded
        case noMessagesToSend
        case messagesMustAlternate
        case aiRunFailed(message: String? = nil)
        case unsupportedModelType(message: String? = nil)
        case failedToRunAIWithError(message: String? = nil)
        case aiQueueTimeout
        
        // MARK: - EmbeddingManager Class Errors:
        case embeddingFailed
        case modelAlreadyDownloading
        case modelDownload
        case unableToInitializeModel
        case unableToGenerateEmbedding
        case managerNotConfigured
        case couldNotRemoveModel
        case modelDoesNotExistAtPath(message: String? = nil)
        case noOutputsFoundInResult
    
        // MARK: - HTTPClient Errors:
        case requestFailed
        case noResponse
        case decodingError(message: String? = nil)
        case noCachedDataAvailable
        case httpFailureResponse(message: String, code: Int? = nil)
        case unableToParseServerError(code: Int? = nil)
        case noDataError(code: Int? = nil)
        case streamError(message: String? = nil)
        case httpError(message: String, code: Int? = nil)
        case clientError(message: String)
        
        // MARK: - LlamaCppMultiContextRun Errors:
        case contextCreateFailed
        case selfDeallocated
        case decodingFailed(message: String? = nil)
        
        // MARK: - MessagesManager Errors:
        case clientNotInitialized
        
        // MARK: - ToolCallsManager Errors:
        case unhandledInternalToolCall
        
        // MARK: - Custom Error:
        case error(message: String, code: Int? = nil)
    }
    
}

extension FreeToken.FreeTokenError {
    
    public var error: String {
        switch self {
        case .deviceNotRegistered: return "deviceNotRegistered"
        case .clientDeallocated: return "invalidState"
        case .aiModelDownload: return "downloadError"
        case .clientNotConfigured: return "clientNotConfigured"
        case .clientAIVersionMismatch: return "clientAIVersionMissmatch"
        case .deviceReset: return "deviceReset"
        case .cacheReset: return "cacheReset"
        case .invalidURL: return "InvalidURL"
        case .aiNotSupportedNoCompatibility: return "aiNotSupportedNoCompitability"
        case .responseTypeInvalid: return "responseTypeInvalid"
        case .handlingToolCallsFailed: return "handlingToolCallsFailed"
        case .encryptionEnabledInCompatibilityMode: return "encryptionEnabledInCompatabilityMode"
        case .encryptedMessageLoadedInCompatibilityMode: return "encryptedMessageLoadedInCompatabilityMode"
        case .cloudCompletionPrivacyMode: return "cloudCompletionPrivacyModeError"
        case .cloudCompletionFailed(_): return "cloudCompletionFailed"
        case .encryptedDocumentReceivedWithoutWayToDecrypt: return "encryptedDocumentRecievedWithoutWayToDecrypt"
        case .encryptedMessageThreadLoadedWithoutWayToDecrypt: return "encryptedMessageThreadLoadedWithoutWayToDecrypt"
        case .privateDocumentStoreNotFound: return "privateDocumentStoreNotFound"
        case .privateDocumentStoreCreationFailed: return "privateDocumentStoreCreationFailed"
        case .privateDocumentStoreDeletionFailed: return "privateDocumentStoreDeletionFailed"
        case .invalidPrivateDocumentStoreId: return "invalidPrivateDocumentStoreId"
        case .privateDocumentCreationFailed: return "privateDocumentCreationFailed"
        case .noEncryptOrDecryptDefinedInPrivacyMode: return "noEncryptOrDecryptDefinedInPrivacyMode"
        case .encryptOrDecryptDefinedInCompatibilityMode: return "encryptOrDecryptDefinedInCompatibilityMode"
        case .deviceIncapableOfAiInPrivacyMode: return "deviceIncapableOfAiInPrivacyMode"
        case .cloudRunInPrivacyMode: return "cannotCloudRunAiInPrivacyMode"
        case .modelMustBeLoadedBeforeAddingMessage: return "modelMustBeLoadedBeforeAddingMessage"
        case .cloudCompletionInvalidResponse: return "cloudCompletionInvalidResponse"
        case .encoding(_): return "encodingError"

        case .unsupportedVersion: return "unsupportedVersion"
        case .aiModelNotDownloaded: return "aiModelNotDownloaded"
        case .modelAlreadyLoading: return "aiModelAlreadyLoading"
        case .failedToLoadModel: return "failedToLoadModel"
        case .aiModelNotLoaded: return "aiModelNotLoaded"
        case .noMessagesToSend: return "noMessagesToSend"
        case .messagesMustAlternate: return "messagesMustAlternate"
        case .aiRunFailed(_): return "aiRunFailed"
        case .unsupportedModelType(_): return "unsupportedModelType"
        case .failedToRunAIWithError(_): return "failedToRunAIWithError"
        case .aiQueueTimeout: return "aiQueueTimeout"
        
        case .embeddingFailed: return "embeddingFailed"
        case .modelAlreadyDownloading: return "modelDownloadingError"
        case .modelDownload: return "modelDownloadError"
        case .unableToInitializeModel: return "unableToInitializeModel"
        case .unableToGenerateEmbedding: return "unableToGenerateEmbedding"
        case .managerNotConfigured: return "managerNotConfigured"
        case .couldNotRemoveModel: return "couldNotRemoveModelError"
        case .modelDoesNotExistAtPath(_): return "modelDoesNotExistAtPath"
        case .noOutputsFoundInResult: return "noOutputsFoundInResult"
            
            
        case .requestFailed: return "requestFailed"
        case .noResponse: return "noResponse"
        case .decodingError(_): return "decodingError"
        case .noCachedDataAvailable: return "noCachedDataAvailable"
        case .httpFailureResponse(_, _): return "httpFailureResponse"
        case .unableToParseServerError(_): return "unableToParseServerError"
        case .noDataError(_): return "noDataError"
        case .streamError(_): return "streamError"
        case .httpError(_, _): return "httpError"
        case .clientError(_): return "clientError"
            
        case .contextCreateFailed: return "contextCreateFailed"
        case .selfDeallocated: return "selfDeallocated"
        case .decodingFailed(_): return "decodingFailed"
            
        case .clientNotInitialized: return "clientNotInitialized"
            
        case .unhandledInternalToolCall: return "unhandledInternalToolCall"
        
        case .error(_, _):
            return "error"
        }
    }
    
    public var message: String {
        switch self {
        case .deviceNotRegistered: return "This device has not been registered. Try .registerDevice."
        case .clientDeallocated: return "Client was deallocated"
        case .aiModelDownload: return "Model did not download successfully"
        case .clientNotConfigured: return "Client has not been configured. Try .configure()"
        case .clientAIVersionMismatch: return "This client version is not capable of running the AI model sent by the server. Please upgrade the client."
        case .deviceReset: return "Could not reset the device"
        case .cacheReset: return "Could not reset the AI model cache"
        case .invalidURL: return "Failed to construct URL with query parameters."
        case .aiNotSupportedNoCompatibility: return "AI is not supported on this device and compatibility mode is off"
        case .responseTypeInvalid: return "The response from the server was invalid"
        case .handlingToolCallsFailed: return "Failed to handle tool calls"
        case .encryptionEnabledInCompatibilityMode: return "Encryption is not available in compatability mode, for encryption turn on privacy mode in the admin."
        case .encryptedMessageLoadedInCompatibilityMode: return "An encrypted message was loaded from the server in compatability mode where no decryption method is defined."
        case .cloudCompletionPrivacyMode: return "Application tried to run a completion in the cloud with Privacy Mode enabled. Likely cause is that the AI model is not downloaded yet."
        case .cloudCompletionFailed(let message):
            var response = "Cloud completion failed"
            response += (message != nil) ? (":\n \(message!)") : ""
            return response
        case .encryptedDocumentReceivedWithoutWayToDecrypt: return "Recieved an encrypted document from the cloud, but no decryption method defined"
        case .encryptedMessageThreadLoadedWithoutWayToDecrypt: return "Recieved a message thread from the cloud, but no decryption method defined "
        case .privateDocumentStoreNotFound: return "The specified private document store was not found"
        case .privateDocumentStoreCreationFailed: return "Failed to create private document store"
        case .privateDocumentStoreDeletionFailed: return "Failed to delete private document store"
        case .invalidPrivateDocumentStoreId: return "The private document store ID is invalid"
        case .privateDocumentCreationFailed: return "Failed to create document in private document store"
        case .noEncryptOrDecryptDefinedInPrivacyMode: return "Encrypt & Decrypt must be added via the configure method in Privacy Mode"
        case .encryptOrDecryptDefinedInCompatibilityMode: return "Encrypt & Decrypt must not be added via configure in Compatibility Mode"
        case .deviceIncapableOfAiInPrivacyMode: return "This device is not capable of AI and the App is configured for Privacy Mode (on-device AI only)"
        case .cloudRunInPrivacyMode: return "Cloud run of a is not supported in Privacy Mode"
        case .modelMustBeLoadedBeforeAddingMessage: return "Model must be loaded before adding a message"
        case .cloudCompletionInvalidResponse: return "The response from the cloud completion was invalid"
        case .encoding(let message):
            var response = "Failed to encode the request to the server"
            response += (message != nil) ? (":\n \(message!)") : ""
            return response
        
        case .unsupportedVersion: return "The AI model sent by the server is not supported by this client"
        case .aiModelNotDownloaded: return "AI model has not yet been downloded. Try .downloadAIModel() first"
        case .modelAlreadyLoading: return "Model already loading. Wait until AI Model is loaded and try again"
        case .failedToLoadModel: return "Failed to load model"
        case .aiModelNotLoaded: return "AI model is not loaded. Try .loadModel() first"
        case .noMessagesToSend: return "No messages to send to the AI model"
        case .messagesMustAlternate: return "Messages must alternate between user and assistant."
        case .aiRunFailed(let message): return "AI run failed" + ((message != nil) ? (": \(message!)") : "")
        case .unsupportedModelType(let message): return "Unsupported model type" + ((message != nil) ? (": \(message!)") : "")
        case .failedToRunAIWithError(let message): return "Failed to run AI with error" + ((message != nil) ? (": \(message!)") : "")
        case .aiQueueTimeout: return "AI queue timed out waiting for execution"
        
        case .embeddingFailed: return "The embedding model failed on the device."
        case .modelAlreadyDownloading: return "The embedding model is downloading. Multiple download calls prohibited."
        case .modelDownload: return "The embedding model failed to download."
        case .unableToInitializeModel: return "The embedding model failed to initialize."
        case .unableToGenerateEmbedding: return "The embedding model failed to generate an embedding."
        case .managerNotConfigured: return "The embedding manager is not configured."
        case .couldNotRemoveModel: return "Failed to remove model with error: Failed to remove model directory."
        case .modelDoesNotExistAtPath(let message):
            var response = "The model does not exist at the specified path"
            response += (message != nil) ? (":\n \(message!)") : ""
            return response
        case .noOutputsFoundInResult: return "No outputs found in the inference result of the embedding model"
            
        case .requestFailed: return "The request to the server failed"
        case .noResponse: return "No response from the server"
        case .decodingError(let message):
            var response = "Failed to decode the response from the server"
            response += (message != nil) ? (":\n \(message!)") : ""
            return response
        case .noCachedDataAvailable: return "HTTP 304 recieved but, no cached data available"
        case .httpFailureResponse(let message, _): return message
        case .unableToParseServerError(_): return "Unable to parse server error response"
        case .noDataError(_): return "No data received from the server"
        case .streamError(let message):
            var response = "Error receving streaming response from the server"
            response += (message != nil) ? (":\n \(message!)") : ""
            return response
        case .httpError(let message, _):
            let response = "HTTP error: \(message)"
            return response
        case .clientError(let message): return "Client Error: \(message)"
            
        case .contextCreateFailed: return "Failed to create context for LlamaCppMultiContextRun"
        case .selfDeallocated: return "Self was deallocated during generation"
        case .decodingFailed(let message): return message ?? "Decoding failed during generation"
            
        case .clientNotInitialized: return "MessagesManager not initialized with a FreeToken client"
            
        case .unhandledInternalToolCall: return "An internal tool call was not handled by the client code"
            
        case .error(let message, _):
            return message
        }
    }
    
    public var code: Int? {
        switch self {
        case .deviceNotRegistered: return 1000
        case .clientDeallocated: return 1002
        case .aiModelDownload: return 1003
        case .clientNotConfigured: return 1004
        case .clientAIVersionMismatch: return 1005
        case .deviceReset: return 1006
        case .cacheReset: return 1007
        case .invalidURL: return nil
        case .aiNotSupportedNoCompatibility: return 1008
        case .responseTypeInvalid: return 1009
        case .handlingToolCallsFailed: return 1010
        case .encryptionEnabledInCompatibilityMode: return 1011
        case .encryptedMessageLoadedInCompatibilityMode: return 1012
        case .cloudCompletionPrivacyMode: return 1013
        case .encryptedDocumentReceivedWithoutWayToDecrypt: return 1014
        case .encryptedMessageThreadLoadedWithoutWayToDecrypt: return 1015
        case .privateDocumentStoreNotFound: return 1016
        case .privateDocumentStoreCreationFailed: return 1017
        case .privateDocumentStoreDeletionFailed: return 1018
        case .invalidPrivateDocumentStoreId: return 1019
        case .privateDocumentCreationFailed: return 1020
        case .noEncryptOrDecryptDefinedInPrivacyMode: return 1021
        case .encryptOrDecryptDefinedInCompatibilityMode: return 1022
        case .deviceIncapableOfAiInPrivacyMode: return 1023
        case .cloudRunInPrivacyMode: return 1024
        case .modelMustBeLoadedBeforeAddingMessage: return 1025
        case .cloudCompletionFailed(_): return 1026
        case .cloudCompletionInvalidResponse: return 1027
        case .encoding(_): return 1028
        case .unsupportedVersion: return 2000
        case .aiModelNotDownloaded: return 2001
        case .modelAlreadyLoading: return 2002
        case .failedToLoadModel: return 2003
        case .aiModelNotLoaded: return 2004
        case .noMessagesToSend: return 2005
        case .messagesMustAlternate: return 2006
        case .aiRunFailed(_): return 2007
        case .unsupportedModelType(_): return 2008
        case .failedToRunAIWithError(_): return 2009
        case .aiQueueTimeout: return 2010
        case .embeddingFailed: return 3000
        case .modelAlreadyDownloading: return 3001
        case .modelDownload: return 3002
        case .unableToInitializeModel: return 3003
        case .unableToGenerateEmbedding: return 3004
        case .managerNotConfigured: return 3005
        case .couldNotRemoveModel: return 3006
        case .modelDoesNotExistAtPath(_): return 3007
        case .noOutputsFoundInResult: return 3008
        case .requestFailed: return 9000
        case .noResponse: return 9001
        case .decodingError: return 9002
        case .noCachedDataAvailable: return 9003
        case .httpFailureResponse(_, let code): return code
        case .unableToParseServerError(let code): return code
        case .noDataError(let code): return code
        case .streamError(_): return 9004
        case .httpError(_, let code): return code
        case .clientError(_): return 9005
        case .contextCreateFailed: return 10000
        case .selfDeallocated: return 10001
        case .decodingFailed(_): return 10002
        case .clientNotInitialized: return 11000
        case .unhandledInternalToolCall: return 4000
            
        case .error(_, let code):
            return code
        }
    }
    
}

extension FreeToken.FreeTokenError: LocalizedError {
    public var errorDescription: String? {
        return self.message
    }
}

extension FreeToken.FreeTokenError {
    
    public static func == (lhs: FreeToken.FreeTokenError, rhs: FreeToken.FreeTokenError) -> Bool {
        switch (lhs, rhs) {
        // Cases without associated values
        case (.deviceNotRegistered, .deviceNotRegistered),
             (.clientDeallocated, .clientDeallocated),
             (.aiModelDownload, .aiModelDownload),
             (.clientNotConfigured, .clientNotConfigured),
             (.clientAIVersionMismatch, .clientAIVersionMismatch),
             (.deviceReset, .deviceReset),
             (.cacheReset, .cacheReset),
             (.invalidURL, .invalidURL),
             (.aiNotSupportedNoCompatibility, .aiNotSupportedNoCompatibility),
             (.responseTypeInvalid, .responseTypeInvalid),
             (.handlingToolCallsFailed, .handlingToolCallsFailed),
             (.encryptionEnabledInCompatibilityMode, .encryptionEnabledInCompatibilityMode),
             (.encryptedMessageLoadedInCompatibilityMode, .encryptedMessageLoadedInCompatibilityMode),
             (.cloudCompletionPrivacyMode, .cloudCompletionPrivacyMode),
             (.encryptedDocumentReceivedWithoutWayToDecrypt, .encryptedDocumentReceivedWithoutWayToDecrypt),
             (.encryptedMessageThreadLoadedWithoutWayToDecrypt, .encryptedMessageThreadLoadedWithoutWayToDecrypt),
             (.noEncryptOrDecryptDefinedInPrivacyMode, .noEncryptOrDecryptDefinedInPrivacyMode),
             (.encryptOrDecryptDefinedInCompatibilityMode, .encryptOrDecryptDefinedInCompatibilityMode),
             (.deviceIncapableOfAiInPrivacyMode, .deviceIncapableOfAiInPrivacyMode),
             (.cloudRunInPrivacyMode, .cloudRunInPrivacyMode),
             (.modelMustBeLoadedBeforeAddingMessage, .modelMustBeLoadedBeforeAddingMessage),
             (.cloudCompletionInvalidResponse, .cloudCompletionInvalidResponse),
             (.unsupportedVersion, .unsupportedVersion),
             (.aiModelNotDownloaded, .aiModelNotDownloaded),
             (.modelAlreadyLoading, .modelAlreadyLoading),
             (.failedToLoadModel, .failedToLoadModel),
             (.aiModelNotLoaded, .aiModelNotLoaded),
             (.noMessagesToSend, .noMessagesToSend),
             (.messagesMustAlternate, .messagesMustAlternate),
             (.embeddingFailed, .embeddingFailed),
             (.modelAlreadyDownloading, .modelAlreadyDownloading),
             (.modelDownload, .modelDownload),
             (.unableToInitializeModel, .unableToInitializeModel),
             (.unableToGenerateEmbedding, .unableToGenerateEmbedding),
             (.managerNotConfigured, .managerNotConfigured),
             (.couldNotRemoveModel, .couldNotRemoveModel),
             (.requestFailed, .requestFailed),
             (.noResponse, .noResponse),
             (.noCachedDataAvailable, .noCachedDataAvailable),
             (.contextCreateFailed, .contextCreateFailed),
             (.selfDeallocated, .selfDeallocated),
             (.clientNotInitialized, .clientNotInitialized),
             (.unhandledInternalToolCall, .unhandledInternalToolCall):
            return true
        
        // Cases with associated values
        case (.cloudCompletionFailed(let lhsMessage), .cloudCompletionFailed(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.encoding(let lhsMessage), .encoding(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.aiRunFailed(let lhsMessage), .aiRunFailed(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.modelDoesNotExistAtPath(let lhsMessage), .modelDoesNotExistAtPath(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.decodingError(let lhsMessage), .decodingError(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.httpFailureResponse(let lhsMessage, let lhsCode), .httpFailureResponse(let rhsMessage, let rhsCode)):
            return lhsMessage == rhsMessage && lhsCode == rhsCode
        case (.unableToParseServerError(let lhsCode), .unableToParseServerError(let rhsCode)):
            return lhsCode == rhsCode
        case (.noDataError(let lhsCode), .noDataError(let rhsCode)):
            return lhsCode == rhsCode
        case (.streamError(let lhsMessage), .streamError(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.httpError(let lhsMessage, let lhsCode), .httpError(let rhsMessage, let rhsCode)):
            return lhsMessage == rhsMessage && lhsCode == rhsCode
        case (.clientError(let lhsMessage), .clientError(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.decodingFailed(let lhsMessage), .decodingFailed(let rhsMessage)):
            return lhsMessage == rhsMessage
        case (.error(let lhsMessage, let lhsCode), .error(let rhsMessage, let rhsCode)):
            return lhsMessage == rhsMessage && lhsCode == rhsCode
        
        default:
            return false
        }
    }
}
