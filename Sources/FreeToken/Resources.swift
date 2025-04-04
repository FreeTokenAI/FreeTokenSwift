//
//  Resources.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/16/24.
//

import Foundation

extension FreeToken {

    // MARK: - Coding Structs
    struct Codings {
        
        struct CreateDeviceSessionRequest: Encodable {
            struct DeviceSession: Encodable {
                let scope: String
                let clientType: String
                let clientVersion: String
                
                enum CodingKeys: String, CodingKey {
                    case scope
                    case clientType = "client_type"
                    case clientVersion = "client_version"
                }
            }
            
            let deviceSession: DeviceSession
            
            enum CodingKeys: String, CodingKey {
                case deviceSession = "device_session"
            }
        }
        
        struct ShowDeviceSessionResponse: Decodable {
            let token: String
            let scope: String
            let mode: String
            let availableCloudToolCalls: [String]
            let documentsConfig: DocumentsConfigResponse
            let aiModel: AiModelResponse
            let embeddingModel: EmbeddingModelResponse
            let precache: [DownloadableFile]?
            let createdAt: Date
            let updatedAt: Date
            
            enum CodingKeys: String, CodingKey {
                case token
                case scope
                case mode
                case availableCloudToolCalls = "available_cloud_tool_calls"
                case documentsConfig = "documents_config"
                case aiModel = "ai_model"
                case embeddingModel = "embedding_model"
                case precache = "precache"
                case createdAt = "created_at"
                case updatedAt = "updated_at"
            }
        }
        
        struct DocumentsConfigResponse: Decodable {
            let documentChunkSize: Int
            let documentChunkOverlapSize: Int
            
            enum CodingKeys: String, CodingKey {
                case documentChunkSize = "document_chunk_size"
                case documentChunkOverlapSize = "document_chunk_overlap_size"
            }
        }
        
        struct ShowClientConfig: Decodable {
            let max: String
            let min: String
            let modelId: String
            let requiredMemoryBytes: Int
            
            enum CodingKeys: String, CodingKey {
                case max
                case min
                case modelId = "model_id"
                case requiredMemoryBytes = "required_memory_bytes"
            }
        }
         
        struct AiModelConfigResponse: Decodable {
            struct ModelOptions: Decodable {
                let topK: Int
                let topP: Float
                let contextWindowSize: Int
                let temperature: Float
                let batchSize: Int
                let maxTokenCount: Int
                let toolRole: String
                let stopTokens: [String]
                let codeTag: String
                
                enum CodingKeys: String, CodingKey {
                    case topK = "top_k"
                    case topP = "top_p"
                    case contextWindowSize = "context_window_size"
                    case temperature
                    case batchSize = "batch_size"
                    case maxTokenCount = "max_token_count"
                    case toolRole = "tool_role"
                    case stopTokens = "stop_tokens"
                    case codeTag = "code_tag"
                }
            }
            
            struct SpecialTokens: Decodable {
                let beginningOfText: String
                let endOfText: String
                let startHeaderId: String
                let endHeaderId: String
                let endOfMessageId: String
                let endOfTurnId: String
                
                enum CodingKeys: String, CodingKey {
                    case beginningOfText = "beginning_of_text"
                    case endOfText = "end_of_text"
                    case startHeaderId = "start_header_id"
                    case endHeaderId = "end_header_id"
                    case endOfMessageId = "end_of_message_id"
                    case endOfTurnId = "end_of_turn_id"
                }
            }
            
            let defaultSettings: ModelOptions
            let specialTokens: SpecialTokens
            
            enum CodingKeys: String, CodingKey {
                case defaultSettings = "default_settings"
                case specialTokens = "special_tokens"
            }
        }
        
        struct AiModelResponse: Decodable {
            let code: String
            let name: String
            let sizeBytes: Int
            let files: FileDownloadPartResponse
            let config: AiModelConfigResponse
            let clientsConfig: [String: ShowClientConfig]
            
            enum CodingKeys: String, CodingKey {
                case code
                case name
                case sizeBytes = "size_bytes"
                case files
                case config
                case clientsConfig = "clients_config"
            }
        }
        
        struct FileVerify: Decodable {
            let file: String
            let md5: String
        }
        
        struct FileDownloadPartResponse: Decodable {
            let toDownload: [DownloadableFile]
            let toVerify: [FileVerify]
            
            enum CodingKeys: String, CodingKey {
                case toDownload = "to_download"
                case toVerify = "to_verify"
            }
        }
        
        struct EmbeddingModelResponse: Decodable {
            let name: String
            let sizeBytes: Int
            let files: FileDownloadPartResponse
            
            enum CodingKeys: String, CodingKey {
                case name
                case sizeBytes = "size_bytes"
                case files
            }
        }
        
        struct DownloadableFile: Decodable {
            let file: String
            let md5: String
            let sizeBytes: Int
            let isFilePart: Bool
            
            enum CodingKeys: String, CodingKey {
                case file
                case md5
                case sizeBytes = "size_bytes"
                case isFilePart = "is_file_part"
            }
        }
        
        struct CreateMessageThreadRequest: Encodable {
            let agentScope: String?
            let pinnedContext: String?
            let encryptionEnabled: Bool
            
            enum CodingKeys: String, CodingKey {
                case agentScope = "agent_scope"
                case pinnedContext = "pinned_context"
                case encryptionEnabled = "encryption_enabled"
            }
        }
        
        struct ShowMessageThreadResponse: Decodable {
            let id: String
            let pinnedContext: String?
            let encryptionEnabled: Bool
            let messages: [ShowMessageResponse]
            
            enum CodingKeys: String, CodingKey {
                case id
                case pinnedContext = "pinned_context"
                case encryptionEnabled = "encryption_enabled"
                case messages
            }
        }
        
        struct CreateCompletionRequest: Encodable {
            let prompt: String
            let model: String?
        }
        
        struct CreateCompletionResponse: Decodable {
            let completion: String
        }
        
        struct CreateDocumentRequestWrapper: Encodable {
            let document: CreateDocumentRequest
        }
        
        struct CreateDocumentRequest: Encodable {
            let content: String
            let metadata: String?
            let searchScope: String
            let documentChunks: [CreateDocumentChunkRequest]
            let encryptionEnabled: Bool
            
            enum CodingKeys: String, CodingKey {
                case content
                case metadata
                case searchScope = "search_scope"
                case encryptionEnabled = "encryption_enabled"
                case documentChunks = "document_chunks"
            }
        }
        
        struct CreateDocumentChunkRequest: Encodable {
            let content: String
            let embedding: [Float]
            let embeddingModel: String
            
            enum CodingKeys: String, CodingKey {
                case content
                case embedding
                case embeddingModel = "embedding_model"
            }
        }

        struct ShowDocumentResponse: Decodable {
            let id: String
            let searchScope: String
            let metadata: String?
            let content: String
            let encryptionEnabled: Bool
            let createdAt: Date
            
            enum CodingKeys: String, CodingKey {
                case id
                case searchScope = "search_scope"
                case metadata
                case content
                case encryptionEnabled = "encryption_enabled"
                case createdAt = "created_at"
            }
        }
        
        struct SearchDocumentsRequest: Encodable {
            let embedding: [Float]
            let embeddingModel: String
            let documentScope: String?
            let resultCount: Int?
            let useAgentDocumentScope: Bool
            
            enum CodingKeys: String, CodingKey {
                case embedding = "embedding"
                case embeddingModel = "embedding_model"
                case documentScope = "document_scope"
                case resultCount = "result_count"
                case useAgentDocumentScope = "use_agent_document_scope"
            }
        }
        
        struct SearchDocumentsResponse: Decodable {
            struct DocumentChunkResult: Decodable {
                let documentID: String
                let documentMetadata: String?
                let contentChunk: String
                let encryptionEnabled: Bool
                
                enum CodingKeys: String, CodingKey {
                    case documentID = "document_id"
                    case documentMetadata = "document_metadata"
                    case contentChunk = "content_chunk"
                    case encryptionEnabled = "encryption_enabled"
                }
            }
            
            let documentChunks: [DocumentChunkResult]
            
            enum CodingKeys: String, CodingKey {
                case documentChunks = "document_chunks"
            }
        }
        
        struct DocumentIndexingStatusResponse: Decodable {
            let id: String
            let status: String
        }
        
        struct CreateMessageThreadRunRequest: Encodable {
            let messageThreadId: String
            let forceCloudRun: Bool?
            
            enum CodingKeys: String, CodingKey {
                case messageThreadId = "message_thread_id"
                case forceCloudRun = "force_cloud_run"
            }
        }
        
        struct ShowMessageThreadRunResponse: Decodable, Sendable {
            let id: String
            let status: String
            let createdAt: Date
            let startedAt: Date?
            let endedAt: Date?
            let cloudRun: Bool
            let promptMessages: [ShowMessageResponse]
            let systemPromptParts: [[String: String?]]
            let threadSearchResults: [[String: String]]
            var resultMessage: ShowMessageResponse?
            var messageChunks: [MessageContentChunk]?
            
            enum CodingKeys: String, CodingKey {
                case id
                case status
                case createdAt = "created_at"
                case startedAt = "started_at"
                case endedAt = "ended_at"
                case cloudRun = "cloud_run"
                case promptMessages = "prompt_messages"
                case systemPromptParts = "system_prompt_parts"
                case threadSearchResults = "thread_search_results"
                case resultMessage = "result_message"
                case messageChunks = "message_chunks"
            }
        }
        
        struct MessageContentChunk: Decodable, Sendable {
            let messageChunk: String
            
            enum CodingKeys: String, CodingKey {
                case messageChunk = "message_chunk"
            }
        }
        
        struct CreateMessageRequest: Encodable {
            let messageThreadID: String
            let role: String
            let content: String
            let toolResult: String?
            let toolCalls: String?
            let embedding: [Float]?
            let embeddingModel: String?
            let encryptionEnabled: Bool
            
            enum CodingKeys: String, CodingKey {
                case messageThreadID = "message_thread_id"
                case role
                case content
                case toolResult = "tool_result"
                case toolCalls = "tool_calls"
                case embedding
                case embeddingModel = "embedding_model"
                case encryptionEnabled = "encryption_enabled"
            }
        }
        
        struct ShowMessageResponse: Decodable, Sendable {
            let id: String?
            let role: String
            let content: String
            let toolCalls: String?
            let toolResult: String?
            let isToolMessage: Bool?
            let encryptionEnabled: Bool?
            let createdAt: Date?
            let updatedAt: Date?
            let tokenUsage: TokenUsageResponse?
            
            enum CodingKeys: String, CodingKey {
                case id
                case role
                case content
                case toolCalls = "tool_calls"
                case toolResult = "tool_result"
                case isToolMessage = "is_tool_message"
                case encryptionEnabled = "encryption_enabled"
                case createdAt = "created_at"
                case updatedAt = "updated_at"
                case tokenUsage = "token_usage"
            }
        }
        
        struct ErrorResponse: Decodable, Error {
            let error: String
            let message: String?
            let code: Int?
        }
        
        struct RawErrorResponse: Decodable {
            let message: String
        }
        
        struct TelemetryCreateRequest: Encodable {
            let eventType: String
            let eventData: TelemetryDataRequest
            let version: Int
            
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
                case eventData = "event_data"
                case version
            }
        }
        
        struct TelemetryDataRequest: Encodable, Sendable {
            // Fill this with different types of optional data that should
            // go in a telemetry request
            let eventDurationInMilliseconds: Optional<Double>
            let eventTypeId: Optional<String>
            let eventObjectType: Optional<String>
            let isSuccess: Optional<Bool>
            let errorMessage: Optional<String>
            let tokenStats: Optional<TokenUsageResponse>
            
            enum CodingKeys: String, CodingKey {
                case eventDurationInMilliseconds = "event_duration_in_milliseconds"
                case eventTypeId = "event_type_id"
                case eventObjectType = "event_object_type"
                case isSuccess = "is_success"
                case errorMessage = "error_message"
                case tokenStats = "token_stats"
            }
        }
        
        struct TelemetryCreateResponse: Decodable {
            let message: String
        }
        
        struct TokenUsageResponse: Codable, Sendable {
            let promptTokens: Optional<Int>
            let completionTokens: Optional<Int>
            let totalTokens: Optional<Int>
            let prefillTokensPerSecond: Optional<Float>
            let decodeTokensPerSecond: Optional<Float>
            let numPrefillTokens: Optional<Int>
            
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
                case prefillTokensPerSecond = "prefill_tokens_per_second"
                case decodeTokensPerSecond = "decode_tokens_per_second"
                case numPrefillTokens = "num_prefill_tokens"
            }
        }
        
        struct ToolCallsRequest: Encodable, Sendable {
            let messageThreadID: String
            let toolCalls: [ToolCall]
            
            enum CodingKeys: String, CodingKey {
                case messageThreadID = "message_thread_id"
                case toolCalls = "tool_calls"
            }
        }
        
        struct ToolCallsResponse: Decodable, Sendable {
            let remainingToolCalls: [ToolCall]
            let toolResults: String
            
            enum CodingKeys: String, CodingKey {
                case remainingToolCalls = "remaining_tool_calls"
                case toolResults = "tool_results"
            }
        }

        struct ToolCall: Codable, Sendable {
            let name: String
            let arguments: [String: String]
        }
        
        struct ToolCallAgentRequest: Encodable, Sendable {
            let messageThreadID: String
            let cloudRun: Bool
            
            enum CodingKeys: String, CodingKey {
                case messageThreadID = "message_thread_id"
                case cloudRun = "cloud_run"
            }
        }
        
        struct ToolCallAgentResponse: Decodable, Sendable {
            let cloudRun: Bool
            let agentMessages: [ShowMessageResponse]?
            let toolMessage: ShowMessageResponse?
            
            enum CodingKeys: String, CodingKey {
                case cloudRun = "cloud_run"
                case agentMessages = "agent_messages"
                case toolMessage = "tool_message"
            }
        }
        
    }
    
    //MARK: - Public Classes
    
    public class Completion {
        public let response: String
        
        internal init(response: String) {
            self.response = response
        }
        
        internal init(from createCompletionResponse: Codings.CreateCompletionResponse) {
            self.response = createCompletionResponse.completion
        }
    }
    
    public class Device {
        let token: String
        let scope: String
        
        internal init(from deviceResponse: Codings.ShowDeviceSessionResponse) {
            self.token = deviceResponse.token
            self.scope = deviceResponse.scope
        }
    }
    
    public class MessageThread: @unchecked Sendable {
        public let id: String
        public let messages: [Message]
        public let pinnedContext: String?
        
        internal init(from showMessageThreadResponse: Codings.ShowMessageThreadResponse) {
            self.id = showMessageThreadResponse.id
            self.pinnedContext = showMessageThreadResponse.pinnedContext
            let messages: [Message] = showMessageThreadResponse.messages.map { showMessageResponse in
                Message(from: showMessageResponse)
            }
            
            self.messages = messages
        }
    }
        
    public class Document {
        public let id: String
        public let searchScope: String
        public let metadata: String?
        public let content: String
        public let createdAt: Date
        
        internal init(from documentResponse: Codings.ShowDocumentResponse) {
            self.id = documentResponse.id
            self.searchScope = documentResponse.searchScope
            self.metadata = documentResponse.metadata
            self.content = documentResponse.content
            self.createdAt = documentResponse.createdAt
        }
    }
    
    public class DocumentSearchResults {
        public let documentChunks: [DocumentChunk]
        
        internal init(from searchResults: Codings.SearchDocumentsResponse) {
            self.documentChunks = searchResults.documentChunks.map { documentChunkResult in
                DocumentChunk(from: documentChunkResult)
            }
        }
    }
    
    public class DocumentChunk {
        public let documentID: String
        public let documentMetadata: String?
        public let contentChunk: String
        
        internal init(from documentChunkResponse: Codings.SearchDocumentsResponse.DocumentChunkResult) {
            self.documentID = documentChunkResponse.documentID
            self.documentMetadata = documentChunkResponse.documentMetadata
            self.contentChunk = documentChunkResponse.contentChunk
        }
    }
    
    public class DocumentIndexingStatus {
        public let id: String
        public let status: String
        
        internal init(from documentIndexingStatus: DocumentIndexingStatus) {
            self.id = documentIndexingStatus.id
            self.status = documentIndexingStatus.status
        }
    }
    
    
    
    public class MessageThreadRun {
        public let id: String
        public let status: String
        public let createdAt: Date
        public let startedAt: Date?
        public let endedAt: Date?
        public let cloudRun: Bool
        public var resultMessage: Message?
        
        internal init(from messageThreadRunResponse: Codings.ShowMessageThreadRunResponse) {
            self.id = messageThreadRunResponse.id
            self.status = messageThreadRunResponse.status
            self.createdAt = messageThreadRunResponse.createdAt
            self.startedAt = messageThreadRunResponse.startedAt
            self.endedAt = messageThreadRunResponse.endedAt
            self.cloudRun = messageThreadRunResponse.cloudRun
            if let resultMessage = messageThreadRunResponse.resultMessage {
                self.resultMessage = Message(from: resultMessage)
            }
        }
    }
    
    
    
    public class Message: @unchecked Sendable {
        public let id: String?
        public let role: String
        public let content: String
        public let toolCalls: String?
        public let toolResult: String?
        public let isToolMessage: Bool?
        public let createdAt: Date?
        public let updatedAt: Date?
        public let tokenUsage: TokenUsage?
        
        internal init(from showMessageResponse: Codings.ShowMessageResponse) {
            self.id = showMessageResponse.id
            self.role = showMessageResponse.role
            self.content = showMessageResponse.content
            self.toolCalls = showMessageResponse.toolCalls
            self.toolResult = showMessageResponse.toolResult
            self.isToolMessage  = showMessageResponse.isToolMessage
            self.createdAt = showMessageResponse.createdAt
            self.updatedAt = showMessageResponse.updatedAt
            if let tokenUsage = showMessageResponse.tokenUsage {
                self.tokenUsage = TokenUsage(from: tokenUsage)
            } else {
                self.tokenUsage = nil
            }
        }
    }
    
    
    
    public class FreeTokenError: NSError, @unchecked Sendable {
        public var message: String?
        
        static func convertErrorResponse(errorResponse: Codings.ErrorResponse) -> FreeTokenError {
            let underlyingError = errorResponse as NSError
            var customUserInfo: [String: Any] = [:]
            
            customUserInfo[NSLocalizedDescriptionKey] = underlyingError.localizedDescription
            customUserInfo[NSUnderlyingErrorKey] = underlyingError
            
            let novaError = FreeTokenError(domain: "com.example.errorresponse", code: errorResponse.code ?? 0, userInfo: customUserInfo)
            novaError.message = errorResponse.message
            
            return novaError
        }
        
    }
    
    
    
    public class TokenUsage: @unchecked Sendable {
        public let promptTokens: Optional<Int>
        public let completionTokens: Optional<Int>
        public let totalTokens: Optional<Int>
        public let prefillTokensPerSecond: Optional<Float>
        public let decodeTokensPerSecond: Optional<Float>
        public let numPrefillTokens: Optional<Int>
        
        internal init(from tokenUsageResponse: Codings.TokenUsageResponse) {
            self.promptTokens = tokenUsageResponse.promptTokens
            self.completionTokens = tokenUsageResponse.completionTokens
            self.totalTokens = tokenUsageResponse.totalTokens
            self.prefillTokensPerSecond = tokenUsageResponse.prefillTokensPerSecond
            self.decodeTokensPerSecond = tokenUsageResponse.decodeTokensPerSecond
            self.numPrefillTokens = tokenUsageResponse.numPrefillTokens
        }
    }
    
    public class ToolCall: @unchecked Sendable {
        public let name: String
        public let arguments: [String: String]
        
        internal init(from toolCall: Codings.ToolCall) {
            self.name = toolCall.name
            self.arguments = toolCall.arguments
        }
        
        internal init(name: String, arguments: [String: String]) {
            self.name = name
            self.arguments = arguments
        }
    }
    
}
