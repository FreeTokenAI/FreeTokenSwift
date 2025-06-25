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
        
        struct WebSearchRequest: Encodable {
            let query: String
            let resultCount: Int?
            
            enum CodingKeys: String, CodingKey {
                case query
                case resultCount = "result_count"
            }
        }

        struct WebSearchResults: Decodable {
            let results: [WebSearchResult]
        }
        
        struct WebSearchResult: Decodable {
            let title: String
            let url: URL?
            let type: String
            let snippet: String
            let description: String
            let age: String
            let thumbnail: URL?
            let metadata: String
        }
        
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
            let toolNames: [String]
            let documentsConfig: DocumentsConfigResponse
            let aiModel: AiModelResponse
            let embeddingModel: EmbeddingModelResponse
            let systemInstructions: String
            let precache: [DownloadableFile]
            let createdAt: Date
            let updatedAt: Date
            
            enum CodingKeys: String, CodingKey {
                case token
                case scope
                case mode
                case toolNames = "tool_names"
                case documentsConfig = "documents_config"
                case aiModel = "ai_model"
                case embeddingModel = "embedding_model"
                case systemInstructions = "system_instructions"
                case precache = "precache"
                case createdAt = "created_at"
                case updatedAt = "updated_at"
            }
        }
        
        struct ToolDefinition: Decodable {
            let name: String
            let definition: String
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
                let maxTokenCount: Int
                let penaltyLastN: Int32
                let penaltyRepeat: Float
                let penaltyFrequency: Float
                let penaltyPresence: Float
                let stopTokens: [String]
                
                enum CodingKeys: String, CodingKey {
                    case topK = "top_k"
                    case topP = "top_p"
                    case contextWindowSize = "context_window_size"
                    case temperature
                    case maxTokenCount = "max_token_count"
                    case penaltyLastN = "penalty_last_n"
                    case penaltyRepeat = "penalty_repeat"
                    case penaltyFrequency = "penalty_frequency"
                    case penaltyPresence = "penalty_presence"
                    case stopTokens = "stop_tokens"
                }
            }
            
            struct PromptTemplateConfig: Decodable {
                let toolRole: String
                let userRole: String
                let assistantRole: String
                let systemRole: String
                let appendSystemToUserPrompt: Bool
                let jsonToolResults: Bool
                let messagesMustAlternate: Bool
                
                enum CodingKeys: String, CodingKey {
                    case toolRole = "tool_role"
                    case userRole = "user_role"
                    case assistantRole = "assistant_role"
                    case systemRole = "system_role"
                    case appendSystemToUserPrompt = "append_system_to_user_prompt"
                    case jsonToolResults = "json_tool_results"
                    case messagesMustAlternate = "messages_must_alternate"
                }
            }
            
            let defaultSettings: ModelOptions
            let promptTemplateConfig: PromptTemplateConfig
            
            enum CodingKeys: String, CodingKey {
                case defaultSettings = "default_settings"
                case promptTemplateConfig = "prompt_template_config"
            }
        }
        
        struct HuggingfaceModelResponse: Decodable {
            let id: String
            let modelFileName: String
            let mmproj: String?
            
            enum CodingKeys: String, CodingKey {
                case id
                case modelFileName = "model_file_name"
                case mmproj
            }
        }
        
        struct AiModelResponse: Decodable {
            let code: String
            let name: String
            let huggingface: HuggingfaceModelResponse
            let config: AiModelConfigResponse
            let clientsConfig: [String: ShowClientConfig]
            let trainingCutoffDate: String
            
            enum CodingKeys: String, CodingKey {
                case code
                case name
                case huggingface = "huggingface"
                case config
                case clientsConfig = "clients_config"
                case trainingCutoffDate = "training_cutoff_date"
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
            let encryptionEnabled: Bool
            
            enum CodingKeys: String, CodingKey {
                case agentScope = "agent_scope"
                case encryptionEnabled = "encryption_enabled"
            }
        }
        
        struct ShowMessageThreadResponse: Decodable {
            let id: String
            let pinnedContext: String?
            let encryptionEnabled: Bool
            let messages: [ShowMessageResponse]
            let createdAt: Date
            let updatedAt: Date
            
            enum CodingKeys: String, CodingKey {
                case id
                case pinnedContext = "pinned_context"
                case encryptionEnabled = "encryption_enabled"
                case messages
                case createdAt = "created_at"
                case updatedAt = "updated_at"
            }
        }
        
        struct CreateCompletionRequest: Encodable {
            let prompt: String
            let model: String?
            let maxTokens: Int?
            
            enum CodingKeys: String, CodingKey {
                case prompt
                case model
                case maxTokens = "max_tokens"
            }
        }
        
        struct CreateCompletionResponse: Decodable {
            let completion: String
        }
        
        struct CreateCloudChatCompletion: Encodable {
            let messages: [CodableMessage]
            let model: String?
            let topK: Int?
            let topP: Float?
            let temperature: Float?
            let maxTokens: Int?
            
            enum CodingKeys: String, CodingKey {
                case messages
                case model
                case topK = "top_k"
                case topP = "top_p"
                case temperature
                case maxTokens = "max_tokens"
            }
        }
        
        struct CloudChatResponse: Decodable {
            let message: CodableMessage?
            let messageChunks: [MessageContentChunk]?
            let tokenUsage: TokenUsageResponse?
            let error: RawErrorResponse?
            
            enum CodingKeys: String, CodingKey {
                case message
                case messageChunks = "message_chunks"
                case tokenUsage = "token_usage"
                case error
            }
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
                
        struct MessageContentChunk: Decodable, Sendable {
            let messageChunk: String
            
            enum CodingKeys: String, CodingKey {
                case messageChunk = "message_chunk"
            }
        }
        
        struct MessageChunkStream: Decodable, Sendable {
            let messageChunks: [MessageContentChunk]
            
            enum CodingKeys: String, CodingKey {
                case messageChunks = "message_chunks"
            }
        }
        
        struct CodableMessage: Codable {
            let role: String
            let content: String
            
            enum CodingKeys: String, CodingKey {
                case role
                case content
            }
        }
        
        struct CreateMessageRequest: Encodable {
            let messageThreadID: String
            let role: String
            let content: String
            let encryptionEnabled: Bool
            let lastMessageID: String?
            
            enum CodingKeys: String, CodingKey {
                case messageThreadID = "message_thread_id"
                case role
                case content
                case encryptionEnabled = "encryption_enabled"
                case lastMessageID = "last_message_id"
            }
        }
        
        struct ShowMessageResponse: Decodable, Sendable {
            let id: String?
            let role: String
            let content: String
            let encryptionEnabled: Bool
            let createdAt: Date
            
            enum CodingKeys: String, CodingKey {
                case id
                case role
                case content
                case encryptionEnabled = "encryption_enabled"
                case createdAt = "created_at"
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
        
        struct TokenUsageRequest: Encodable {
            let totalTokens: Int
            let tokensPerSecond: Float
        }
        
        struct TelemetryDataRequest: Encodable, Sendable {
            // Fill this with different types of optional data that should
            // go in a telemetry request
            let eventDurationInMilliseconds: Optional<Double>
            let eventTypeId: Optional<String>
            let eventObjectType: Optional<String>
            let isSuccess: Optional<Bool>
            let errorMessage: Optional<String>
            let tokenStats: Optional<TokenUsageRequest>
            
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
        
        struct TokenUsageResponse: Codable, Sendable {
            let totalTokens: Int
            let tokensPerSecond: Float
            
            enum CodingKeys: String, CodingKey {

                case totalTokens = "total_tokens"
                case tokensPerSecond = "tokens_per_second"
            }
        }
        
    }
    
    //MARK: - Public Classes
    
    public class WebSearchResult {
        public let url: URL?
        public let title: String
        public let snippet: String
        public let description: String
        public let age: String
        public let thumbnail: URL?
        public let metadata: String
        
        internal init(from webSearchResultResponse: Codings.WebSearchResult) {
            self.url = webSearchResultResponse.url
            self.title = webSearchResultResponse.title
            self.snippet = webSearchResultResponse.snippet
            self.description = webSearchResultResponse.description
            self.age = webSearchResultResponse.age
            self.thumbnail = webSearchResultResponse.thumbnail
            self.metadata = webSearchResultResponse.metadata
        }

    }
    
    public class Completion {
        public let response: String
        
        internal init(response: String) {
            self.response = response
        }
        
        internal init(from createCompletionResponse: Codings.CreateCompletionResponse) {
            self.response = createCompletionResponse.completion
        }
    }
    
    public class ChatCompletion {
        public let responseMessage: Message
        
        internal init(from createCloudChatCompletionResponse: Codings.CreateCloudChatCompletion) {
            let message = createCloudChatCompletionResponse.messages.first
            self.responseMessage = Message(role: MessageRole(rawValue: message?.role ?? "user") ?? .user, content: message?.content ?? "")
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
        public let createdAt: Date
        public let updatedAt: Date
        
        internal init(id: String, messages: [Message], createdAt: Date, updatedAt: Date) {
            self.id = id
            self.messages = messages
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
        
        internal init(from messageThreadResponse: Codings.ShowMessageThreadResponse) {
            self.id = messageThreadResponse.id
            let messages: [Message] = messageThreadResponse.messages.map { showMessageResponse in
                Message(from: showMessageResponse)
            }
            
            self.messages = messages
            self.createdAt = messageThreadResponse.createdAt
            self.updatedAt = messageThreadResponse.updatedAt
        }
    }
        
    public class Document {
        public let id: String
        public let searchScope: String
        public let metadata: String?
        public let content: String
        public let createdAt: Date
        internal let encryptionManager = FreeToken.shared.encryptionManager
        
        internal init(from documentResponse: Codings.ShowDocumentResponse) {
            self.id = documentResponse.id
            self.searchScope = documentResponse.searchScope
            if documentResponse.encryptionEnabled {
                self.metadata = documentResponse.metadata != nil ? encryptionManager.decrypt(documentResponse.metadata!) : nil
                self.content = encryptionManager.decrypt(documentResponse.content)
            } else {
                self.metadata = documentResponse.metadata
                self.content = documentResponse.content
            }
            
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
        internal let encryptionManager = FreeToken.shared.encryptionManager
        
        internal init(from documentChunkResponse: Codings.SearchDocumentsResponse.DocumentChunkResult) {
            self.documentID = documentChunkResponse.documentID
            
            if documentChunkResponse.encryptionEnabled {
                self.documentMetadata = documentChunkResponse.documentMetadata != nil ? encryptionManager.decrypt(documentChunkResponse.documentMetadata!) : nil
                self.contentChunk = encryptionManager.decrypt(documentChunkResponse.contentChunk)
            } else {
                self.documentMetadata = documentChunkResponse.documentMetadata
                self.contentChunk = documentChunkResponse.contentChunk
            }
        }
    }
        
    public enum MessageRole: String, Codable {
        case user
        case assistant
        case system
        case tool
    }
    
    public class Message: @unchecked Sendable {
        public let id: String?
        public let role: MessageRole
        public let content: String
        public let createdAt: Date?
        public let tokenUsage: TokenUsage?
        internal let encryptionManager = FreeToken.shared.encryptionManager
        
        public init(role: MessageRole, content: String) {
            self.role = role
            self.content = content
            
            self.tokenUsage = nil
            self.id = nil
            self.createdAt = nil
        }
        
        internal init(role: MessageRole, content: String, tokenUsage: TokenUsage? = nil) {
            self.role = role
            self.content = content
            self.tokenUsage = tokenUsage
            
            self.id = nil
            self.createdAt = nil
        }
        
        internal init(from showMessageResponse: Codings.ShowMessageResponse) {
            self.id = showMessageResponse.id
            self.role = MessageRole(rawValue: showMessageResponse.role) ?? .user
            
            if showMessageResponse.encryptionEnabled {
                self.content = encryptionManager.decrypt(showMessageResponse.content)
            } else {
                self.content = showMessageResponse.content
            }
            self.createdAt = showMessageResponse.createdAt

            self.tokenUsage = nil
        }
        
        internal init(from codableMessage: Codings.CodableMessage, tokenUsage: TokenUsage? = nil) {
            self.id = nil
            self.role = MessageRole(rawValue: codableMessage.role) ?? .user
            self.content = codableMessage.content
            
            self.tokenUsage = tokenUsage
            self.createdAt = nil
        }
    }
    
    public struct TokenUsage: @unchecked Sendable {
        let totalTokens: Int
        let tokensPerSecond: Float

        internal init(totalTokens: Int, tokensPerSecond: Float) {
            self.totalTokens = totalTokens
            self.tokensPerSecond = tokensPerSecond
        }
        
        internal init(from tokenUsageReponse: Codings.TokenUsageResponse) {
            self.totalTokens = tokenUsageReponse.totalTokens
            self.tokensPerSecond = tokenUsageReponse.tokensPerSecond
        }
                
        func asCodable() -> Codings.TokenUsageRequest {
            return Codings.TokenUsageRequest(totalTokens: self.totalTokens, tokensPerSecond: self.tokensPerSecond)
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
    
    public struct AIRunConfig: Sendable {
        let maxGenerationTokens: Int?
        let contentWindowSize: Int?
        let topK: Int?
        let topP: Float?
        let temperature: Float?
        
        public init(maxGenerationTokens: Int? = nil, contentWindowSize: Int? = nil, topK: Int? = nil, topP: Float? = nil, temperature: Float? = nil) {
            self.maxGenerationTokens = maxGenerationTokens
            self.contentWindowSize = contentWindowSize
            self.topK = topK
            self.topP = topP
            self.temperature = temperature
        }
    }
    
}
