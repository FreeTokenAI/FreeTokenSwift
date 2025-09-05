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
            let url: String?
            let type: String
            let snippet: String
            let description: String
            let age: String
            let thumbnail: String?
            let metadata: String
        }
        
        struct CreateDeviceSessionRequest: Encodable {
            struct DeviceSession: Encodable {
                let scope: String
                let clientType: String
                let clientVersion: String
                let deviceModelIdentifier: String?
                let deviceModelName: String?
                
                enum CodingKeys: String, CodingKey {
                    case scope
                    case clientType = "client_type"
                    case clientVersion = "client_version"
                    case deviceModelIdentifier = "device_model_identifier"
                    case deviceModelName = "device_model_name"
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
            let documentsConfig: DocumentsConfigResponse
            let aiModel: AiModelResponse
            let embeddingModel: EmbeddingModelResponse
            let systemInstructions: String
            let builtInToolDefinitions: [ToolDefinition]
            let cloudToolDefinitions: [ToolDefinition]
            let toolInstructions: String
            let precache: [DownloadableFile]
            let forceCloudRun: Bool
            let createdAt: Date
            let updatedAt: Date
            
            enum CodingKeys: String, CodingKey {
                case token
                case scope
                case documentsConfig = "documents_config"
                case aiModel = "ai_model"
                case embeddingModel = "embedding_model"
                case systemInstructions = "system_instructions"
                case builtInToolDefinitions = "built_in_tool_definitions"
                case cloudToolDefinitions = "cloud_tool_definitions"
                case toolInstructions = "tool_instructions"
                case precache = "precache"
                case forceCloudRun = "force_cloud_run"
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
                let batchSize: Int
                // DRY sampler parameters
                let dryMultiplier: Float?
                let dryBase: Float?
                let dryAllowedLength: Int32?
                let dryPenaltyLastN: Int32?
                // XTC sampler parameters
                let xtcProbability: Float?
                let xtcThreshold: Float?
                
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
                    case batchSize = "batch_size"
                    // DRY sampler
                    case dryMultiplier = "dry_multiplier"
                    case dryBase = "dry_base"
                    case dryAllowedLength = "dry_allowed_length"
                    case dryPenaltyLastN = "dry_penalty_last_n"
                    // XTC sampler
                    case xtcProbability = "xtc_probability"
                    case xtcThreshold = "xtc_threshold"
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
            let repo: String
            let modelFileName: String? // MLX models download the entire repo
            let mmproj: String? // Not supported for MLX
            
            enum CodingKeys: String, CodingKey {
                case repo
                case modelFileName = "model_file_name"
                case mmproj
            }
        }
        
        struct AiModelResponse: Decodable {
            let code: String
            let name: String
            let modelTypes: AvailableModelTypesResponse?
            let config: AiModelConfigResponse
            let clientsConfig: [String: ShowClientConfig]
            let trainingCutoffDate: String
            let cloudOnly: Bool
            let jsonToolCalls: Bool?
            
            enum CodingKeys: String, CodingKey {
                case code
                case name
                case modelTypes = "model_types"
                case config
                case clientsConfig = "clients_config"
                case trainingCutoffDate = "training_cutoff_date"
                case cloudOnly = "cloud_only"
                case jsonToolCalls = "json_tool_calls"
            }
        }
        
        struct AvailableModelTypesResponse: Decodable {
            let llamaCpp: HuggingfaceModelResponse
            let mlx: HuggingfaceModelResponse?
            
            enum CodingKeys: String, CodingKey {
                case llamaCpp = "llama_cpp"
                case mlx
            }
        }
        
        struct AIModelsResponse: Decodable {
            let aiModels: [AiModelResponse]
            
            enum CodingKeys: String, CodingKey {
                case aiModels = "ai_models"
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
            let modelTypes: AvailableModelTypesResponse
            let config: EmbeddingModelConfig
            let memoryRequirement: Int
            
            enum CodingKeys: String, CodingKey {
                case name
                case modelTypes = "model_types"
                case config
                case memoryRequirement = "memory_requirement"
            }
        }
        
        struct EmbeddingModelConfig: Decodable {
            let contextSize: Int
            let batchSize: Int
            let poolingType: EmbeddingPoolingTypes
            
            enum CodingKeys: String, CodingKey {
                case contextSize = "context_size"
                case batchSize = "batch_size"
                case poolingType = "pooling_type"
            }
        }
        
        enum EmbeddingPoolingTypes: String, Equatable, Decodable {
            case cls
            case last
            case mean
            case none
            case rank
            case unspecified
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
            let messages: [CreateMessageRequest]?
            
            enum CodingKeys: String, CodingKey {
                case messages
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
        
        struct CreatePrivateDocumentStoreRequest: Encodable {
            let name: String
        }
        
        struct CreatePrivateDocumentStoreResponse: Decodable {
            let id: String
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
            let privateDocumentStoreID: String?
            
            enum CodingKeys: String, CodingKey {
                case content
                case metadata
                case searchScope = "search_scope"
                case encryptionEnabled = "encryption_enabled"
                case documentChunks = "document_chunks"
                case privateDocumentStoreID = "private_document_store_id"
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
            let documentType: String
            let searchScope: String
            let metadata: String?
            let content: String
            let encryptionEnabled: Bool
            let createdAt: Date
            
            enum CodingKeys: String, CodingKey {
                case id
                case documentType = "document_type"
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
            let privateDocumentStoreIds: [String]?
            let resultCount: Int?
            let useAgentDocumentScope: Bool
            
            enum CodingKeys: String, CodingKey {
                case embedding = "embedding"
                case embeddingModel = "embedding_model"
                case documentScope = "document_scope"
                case privateDocumentStoreIds = "private_document_store_ids"
                case resultCount = "result_count"
                case useAgentDocumentScope = "use_agent_document_scope"
            }
        }
        
        struct SearchDocumentsResponse: Decodable {
            struct DocumentChunkResult: Decodable {
                let documentID: String
                let documentType: String
                let documentMetadata: String?
                let contentChunk: String
                let encryptionEnabled: Bool
                
                enum CodingKeys: String, CodingKey {
                    case documentID = "document_id"
                    case documentType = "document_type"
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
            var attachments: [CodableAttachment]? = nil
            
            enum CodingKeys: String, CodingKey {
                case role
                case content
                case attachments
            }
        }
        
        struct CodableAttachment: Codable {
            let imageUrl: String
            
            enum CodingKeys: String, CodingKey {
                case imageUrl = "image_url"
            }
        }
        
        struct CreateMessageRequest: Encodable {
            let messageThreadID: String?
            let role: String
            let content: String
            let encryptionEnabled: Bool
            let lastMessageID: String?
            let encryptedImages: [EncryptedImageData]?
            
            enum CodingKeys: String, CodingKey {
                case messageThreadID = "message_thread_id"
                case role
                case content
                case encryptionEnabled = "encryption_enabled"
                case lastMessageID = "last_message_id"
                case encryptedImages = "encrypted_images"
            }
        }
        
        struct EncryptedImageData: Encodable {
            let data: String // Base64 encoded encrypted image data
            let filename: String?
            let contentType: String
            
            enum CodingKeys: String, CodingKey {
                case data
                case filename
                case contentType = "content_type"
            }
        }
        
        struct ShowMessageResponse: Decodable, Sendable {
            let id: String?
            let role: String
            let content: String
            let encryptionEnabled: Bool
            let createdAt: Date
            let images: [ImageAttachmentResponse]?
            
            enum CodingKeys: String, CodingKey {
                case id
                case role
                case content
                case encryptionEnabled = "encryption_enabled"
                case createdAt = "created_at"
                case images
            }
        }
        
        struct ImageAttachmentResponse: Decodable, Sendable {
            let id: String
            let filename: String?
            let contentType: String
            let byteSize: Int
            let url: String?
            let data: String? // Base64 encoded data for encrypted images
            let encrypted: Bool
            
            enum CodingKeys: String, CodingKey {
                case id
                case filename
                case contentType = "content_type"
                case byteSize = "byte_size"
                case url
                case data
                case encrypted
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
            let inputTokens: Int
            let outputTokens: Int
            let modelCode: String
            
            enum CodingKeys: String, CodingKey {
                case totalTokens = "total_tokens"
                case tokensPerSecond = "tokens_per_second"
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case modelCode = "model_code"
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
            let tokenStats: Optional<TokenUsageRequest>
            let telemetryDataVersion: Int
            
            enum CodingKeys: String, CodingKey {
                case eventDurationInMilliseconds = "event_duration_in_milliseconds"
                case eventTypeId = "event_type_id"
                case eventObjectType = "event_object_type"
                case isSuccess = "is_success"
                case errorMessage = "error_message"
                case tokenStats = "token_stats"
                case telemetryDataVersion = "telemetry_data_version"
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
    
    public class PrivateDocumentStore {
        public let id: String
        
        internal init(from response: Codings.CreatePrivateDocumentStoreResponse) {
            self.id = response.id
        }
    }
    
    public class WebSearchResult {
        public let url: String?
        public let title: String
        public let snippet: String
        public let description: String
        public let age: String
        public let thumbnail: String?
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
        
        
        internal static func fromServerResponse(_ messageThreadResponse: Codings.ShowMessageThreadResponse) async throws -> MessageThread {
            // Fetch all message images concurrently
            let messages = try await withThrowingTaskGroup(of: Message.self) { group in
                for showMessageResponse in messageThreadResponse.messages {
                    group.addTask {
                        return try await Message.fromServerResponse(showMessageResponse)
                    }
                }
                
                var fetchedMessages: [Message] = []
                for try await message in group {
                    fetchedMessages.append(message)
                }
                
                // Sort messages to maintain original order (since tasks complete in arbitrary order)
                return fetchedMessages.sorted { msg1, msg2 in
                    guard let id1 = msg1.id, let id2 = msg2.id else { return false }
                    return messageThreadResponse.messages.firstIndex { $0.id == id1 } ?? 0 < 
                           messageThreadResponse.messages.firstIndex { $0.id == id2 } ?? 0
                }
            }
            
            return MessageThread(
                id: messageThreadResponse.id,
                messages: messages,
                createdAt: messageThreadResponse.createdAt,
                updatedAt: messageThreadResponse.updatedAt
            )
        }
    }
        
    public class Document {
        public let id: String
        public let documentType: DocumentType
        public let searchScope: String
        public let metadata: String?
        public let content: String
        public let createdAt: Date
        internal let encryptionManager = FreeToken.shared.encryptionManager
        
        internal init(from documentResponse: Codings.ShowDocumentResponse) throws {
            self.id = documentResponse.id
            self.documentType = documentResponse.documentType == "private_document" ? .privateDocument : .publicDocument
            self.searchScope = documentResponse.searchScope
            if documentResponse.encryptionEnabled {
                let scope: EncryptionScope = documentType == .privateDocument ? .userPrivate : .sharedPublic
                
                self.metadata = documentResponse.metadata != nil ? try encryptionManager.decrypt(documentResponse.metadata!, scope) : nil
                self.content = try encryptionManager.decrypt(documentResponse.content, scope)
            } else {
                self.metadata = documentResponse.metadata
                self.content = documentResponse.content
            }
            
            self.createdAt = documentResponse.createdAt
        }
    }
    
    public class DocumentSearchResults {
        public let documentChunks: [DocumentChunk]
        
        internal init(from searchResults: Codings.SearchDocumentsResponse) throws {
            self.documentChunks = try searchResults.documentChunks.map { documentChunkResult in
                try DocumentChunk(from: documentChunkResult)
            }
        }
    }
    
    public class DocumentChunk {
        public let documentID: String
        public let documentType: DocumentType
        public let documentMetadata: String?
        public let contentChunk: String
        internal let encryptionManager = FreeToken.shared.encryptionManager
        
        internal init(from documentChunkResponse: Codings.SearchDocumentsResponse.DocumentChunkResult) throws {
            self.documentID = documentChunkResponse.documentID
            
            self.documentType = documentChunkResponse.documentType == "private_document" ? .privateDocument : .publicDocument
            let scope: EncryptionScope = documentType == .privateDocument ? .userPrivate : .sharedPublic
            
            if documentChunkResponse.encryptionEnabled {
                self.documentMetadata = documentChunkResponse.documentMetadata != nil ? try encryptionManager.decrypt(documentChunkResponse.documentMetadata!, scope) : nil
                self.contentChunk = try encryptionManager.decrypt(documentChunkResponse.contentChunk, scope)
            } else {
                self.documentMetadata = documentChunkResponse.documentMetadata
                self.contentChunk = documentChunkResponse.contentChunk
            }
        }
    }
    
    public enum DocumentType: Equatable, Sendable {
        case privateDocument
        case publicDocument
    }
        
    public enum MessageRole: String, Codable {
        case user
        case assistant
        case system
        case tool
    }
    
    public enum AIModelLoadingState: String, Equatable, Sendable {
        case unloaded
        case loading
        case loaded
        case failed
        case notAICapable
        case cloudOnly
    }
    
    public enum RunLocation: String, Equatable, Sendable {
        case automatic
        case cloudRun
        case localRun
    }
    
    public class MessageAttachment: @unchecked Sendable {
        public let id: String?
        public let type: AttachmentType
        public let data: Data
        public let filename: String?
        public let contentType: String
        public let encryptedMetadata: String?
        
        public enum AttachmentType: String, CaseIterable {
            case image
        }
        
        public init(type: AttachmentType, data: Data, filename: String? = nil, contentType: String) {
            self.id = nil
            self.type = type
            self.data = data
            self.filename = filename
            self.contentType = contentType
            self.encryptedMetadata = nil
        }
        
        internal init(id: String?, type: AttachmentType, data: Data, filename: String?, contentType: String, encryptedMetadata: String?) {
            self.id = id
            self.type = type
            self.data = data
            self.filename = filename
            self.contentType = contentType
            self.encryptedMetadata = encryptedMetadata
        }
        
        public static func image(_ imageData: Data, filename: String? = nil, contentType: String = "image/png") -> MessageAttachment {
            return MessageAttachment(type: .image, data: imageData, filename: filename, contentType: contentType)
        }
    }
    
    public class Message: @unchecked Sendable {
        public let id: String?
        public let role: MessageRole
        public let content: String
        public let attachments: [MessageAttachment]?
        public let createdAt: Date?
        public let tokenUsage: TokenUsage?
        internal let encryptionManager = FreeToken.shared.encryptionManager
        
        public init(role: MessageRole, content: String, attachments: [MessageAttachment]? = nil) {
            self.role = role
            self.content = content
            self.attachments = attachments
            
            self.tokenUsage = nil
            self.id = nil
            self.createdAt = nil
        }
        
        internal init(role: MessageRole, content: String, attachments: [MessageAttachment]? = nil, tokenUsage: TokenUsage? = nil) {
            self.role = role
            self.content = content
            self.attachments = attachments
            self.tokenUsage = tokenUsage
            
            self.id = nil
            self.createdAt = nil
        }
        
        internal init(id: String?, role: MessageRole, content: String, attachments: [MessageAttachment]? = nil, createdAt: Date?, tokenUsage: TokenUsage? = nil) {
            self.id = id
            self.role = role
            self.content = content
            self.attachments = attachments
            self.createdAt = createdAt
            self.tokenUsage = tokenUsage
        }
        
        
        /// Creates a Message from server response, fetching any image URLs asynchronously
        internal static func fromServerResponse(_ showMessageResponse: Codings.ShowMessageResponse) async throws -> Message {
            let encryptionManager = FreeToken.shared.encryptionManager
            
            // Process attachments, fetching URLs if needed
            let processedAttachments: [MessageAttachment]?
            if let images = showMessageResponse.images {
                // Pre-process encrypted images - no longer need to decrypt here since we'll fetch from URLs
                let imageProcessingData: [(imageResponse: Codings.ImageAttachmentResponse, decryptedData: Data?)] = images.map { imageResponse in
                    // All images (encrypted and unencrypted) will be fetched from URLs
                    return (imageResponse, nil)
                }
                
                processedAttachments = try await withThrowingTaskGroup(of: MessageAttachment?.self) { group in
                    for (imageResponse, _) in imageProcessingData {
                        group.addTask { @Sendable () -> MessageAttachment? in
                            if let urlString = imageResponse.url, let url = URL(string: urlString) {
                                // Fetch image from URL (both encrypted and unencrypted)
                                do {
                                    let (data, response) = try await URLSession.shared.data(from: url)
                                    
                                    // Validate response
                                    guard let httpResponse = response as? HTTPURLResponse,
                                          (200...299).contains(httpResponse.statusCode) else {
                                        FreeToken.shared.logger("Failed to fetch image from URL: \(urlString)", .error)
                                        return nil
                                    }
                                    
                                    // If encrypted, decrypt the data
                                    let finalImageData: Data
                                    if imageResponse.encrypted {
                                        // Convert downloaded data to string, decrypt it, then convert back to image data
                                        guard let encryptedString = String(data: data, encoding: .utf8) else {
                                            FreeToken.shared.logger("Failed to convert encrypted data to string", .error)
                                            return nil
                                        }
                                        
                                        let decryptedBase64 = try FreeToken.shared.encryptionManager.decrypt(encryptedString, .userPrivate)
                                        guard let imageData = Data(base64Encoded: decryptedBase64) else {
                                            FreeToken.shared.logger("Failed to decode decrypted base64 data", .error)
                                            return nil
                                        }
                                        finalImageData = imageData
                                    } else {
                                        finalImageData = data
                                    }
                                    
                                    return MessageAttachment(
                                        id: imageResponse.id,
                                        type: .image,
                                        data: finalImageData,
                                        filename: imageResponse.filename,
                                        contentType: imageResponse.contentType,
                                        encryptedMetadata: imageResponse.encrypted ? "encrypted" : nil
                                    )
                                } catch {
                                    FreeToken.shared.logger("Error fetching image from URL \(urlString): \(error)", .error)
                                    return nil
                                }
                            }
                            return nil
                        }
                    }
                    
                    // Collect results
                    var attachments: [MessageAttachment] = []
                    for try await attachment in group {
                        if let attachment = attachment {
                            attachments.append(attachment)
                        }
                    }
                    return attachments.isEmpty ? nil : attachments
                }
            } else {
                processedAttachments = nil
            }
            
            // Create and return the message with all properties
            return Message(
                id: showMessageResponse.id,
                role: MessageRole(rawValue: showMessageResponse.role) ?? .user,
                content: showMessageResponse.encryptionEnabled ? 
                try encryptionManager.decrypt(showMessageResponse.content, .userPrivate) :
                    showMessageResponse.content,
                attachments: processedAttachments,
                createdAt: showMessageResponse.createdAt,
                tokenUsage: nil
            )
        }
        
        /// Creates a Message from cloud completion response, fetching any image URLs asynchronously
        internal static func fromCloudResponse(_ codableMessage: Codings.CodableMessage, tokenUsage: TokenUsage? = nil) async throws -> Message {
            FreeToken.shared.logger("🔍 CLOUD RESPONSE DEBUG: Processing message with \(codableMessage.attachments?.count ?? 0) attachments", .info)
            
            // Process attachments, fetching URLs if needed
            let processedAttachments: [MessageAttachment]?
            if let attachments = codableMessage.attachments {
                processedAttachments = try await withThrowingTaskGroup(of: MessageAttachment?.self) { group in
                    for attachment in attachments {
                        group.addTask { () -> MessageAttachment? in
                            guard let url = URL(string: attachment.imageUrl) else {
                                FreeToken.shared.logger("🔴 Invalid image URL: \(attachment.imageUrl)", .error)
                                return nil
                            }
                            
                            do {
                                let (data, response) = try await URLSession.shared.data(from: url)
                                
                                // Validate response
                                guard let httpResponse = response as? HTTPURLResponse,
                                      (200...299).contains(httpResponse.statusCode) else {
                                    FreeToken.shared.logger("🔴 Failed to fetch image from URL: \(attachment.imageUrl)", .error)
                                    return nil
                                }
                                
                                FreeToken.shared.logger("✅ Successfully fetched image from URL: \(attachment.imageUrl)", .info)
                                
                                return MessageAttachment(
                                    id: nil,
                                    type: .image,
                                    data: data,
                                    filename: "cloud_image.png",
                                    contentType: "image/png",
                                    encryptedMetadata: nil
                                )
                            } catch {
                                FreeToken.shared.logger("🔴 Error fetching image from URL \(attachment.imageUrl): \(error)", .error)
                                return nil
                            }
                        }
                    }
                    
                    var fetchedAttachments: [MessageAttachment] = []
                    for try await attachment in group {
                        if let attachment = attachment {
                            fetchedAttachments.append(attachment)
                        }
                    }
                    
                    return fetchedAttachments.isEmpty ? nil : fetchedAttachments
                }
            } else {
                processedAttachments = nil
            }
            
            // Create and return the message
            return Message(
                id: nil,
                role: MessageRole(rawValue: codableMessage.role) ?? .user,
                content: codableMessage.content,
                attachments: processedAttachments,
                createdAt: nil,
                tokenUsage: tokenUsage
            )
        }
        
        // MARK: - Encryption/Decryption Methods
        
        /// Converts message to encrypted request format for server
        internal func toEncryptedRequest(messageThreadID: String, lastMessageID: String?, encryptionManager: EncryptionManager) throws -> Codings.CreateMessageRequest {
            let encryptedContent = try encryptionManager.encrypt(self.content, .userPrivate)
            
            var encryptedImages: [Codings.EncryptedImageData]? = nil
            if let attachments = self.attachments {
                let imageAttachments = attachments.filter { $0.type == .image }
                if !imageAttachments.isEmpty {
                    encryptedImages = try imageAttachments.map { attachment in
                        let base64String = attachment.data.base64EncodedString()
                        let encryptedBase64 = try encryptionManager.encrypt(base64String, .userPrivate)
                        return Codings.EncryptedImageData(
                            data: encryptedBase64,
                            filename: attachment.filename,
                            contentType: attachment.contentType
                        )
                    }
                }
            }
            
            return Codings.CreateMessageRequest(
                messageThreadID: messageThreadID,
                role: self.role.rawValue,
                content: encryptedContent,
                encryptionEnabled: true,
                lastMessageID: lastMessageID,
                encryptedImages: encryptedImages
            )
        }
        
        /// Converts message to unencrypted request format for server (JSON data for multipart)
        internal func toUnencryptedMultipartData(messageThreadID: String, lastMessageID: String?) -> ([String: Any], [MessageAttachment]) {
            var jsonData: [String: Any] = [
                "message_thread_id": messageThreadID,
                "role": self.role.rawValue,
                "content": self.content,
                "encryption_enabled": false
            ]
            
            if let lastMessageID = lastMessageID {
                jsonData["last_message_id"] = lastMessageID
            }
            
            let imageAttachments = self.attachments?.filter { $0.type == .image } ?? []
            
            return (jsonData, imageAttachments)
        }
        
        /// Converts message to unencrypted request format for server (regular JSON)
        internal func toUnencryptedRequest(messageThreadID: String, lastMessageID: String?) -> Codings.CreateMessageRequest {
            return Codings.CreateMessageRequest(
                messageThreadID: messageThreadID,
                role: self.role.rawValue,
                content: self.content,
                encryptionEnabled: false,
                lastMessageID: lastMessageID,
                encryptedImages: nil
            )
        }
    }
    
    public struct TokenUsage: @unchecked Sendable {
        let totalTokens: Int
        let inputTokens: Int
        let outputTokens: Int
        let modelCode: String
        let tokensPerSecond: Float

        internal init(totalTokens: Int, tokensPerSecond: Float, inputTokens: Int, outputTokens: Int, modelCode: String) {
            self.totalTokens = totalTokens
            self.tokensPerSecond = tokensPerSecond
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.modelCode = modelCode
        }
        
        internal init(from tokenUsageReponse: Codings.TokenUsageResponse) {
            self.totalTokens = tokenUsageReponse.totalTokens
            self.tokensPerSecond = tokenUsageReponse.tokensPerSecond
            self.inputTokens = 0
            self.outputTokens = 0
            self.modelCode = ""
        }
                
        func asCodable() -> Codings.TokenUsageRequest {
            return Codings.TokenUsageRequest(totalTokens: self.totalTokens, tokensPerSecond: self.tokensPerSecond, inputTokens: self.inputTokens, outputTokens: self.outputTokens, modelCode: self.modelCode)
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
    
    public class ToolDefinition: @unchecked Sendable {
        public let name: String
        public let definition: String
        
        internal init(from toolDefinition: Codings.ToolDefinition) {
            self.name = toolDefinition.name
            self.definition = toolDefinition.definition
        }
        
        public init(name: String, definition: String) {
            self.name = name
            self.definition = definition
        }
    }
    
    enum ToolDefinitionType: Equatable, Sendable {
        case builtIn
        case application
        case cloud
    }
    
    public enum ToolRunMask: Equatable, Sendable {
        case denyAll
        case allowAll
        case allow(_ toolName: String)
        case deny(_ toolName: String)
    }
    
    public struct AIRunConfig: Sendable {
        let maxGenerationTokens: Int?
        let contextWindowSize: Int?
        let topK: Int?
        let topP: Float?
        let temperature: Float?
        
        public init(maxGenerationTokens: Int? = nil, contentWindowSize: Int? = nil, topK: Int? = nil, topP: Float? = nil, temperature: Float? = nil) {
            self.maxGenerationTokens = maxGenerationTokens
            self.contextWindowSize = contentWindowSize
            self.topK = topK
            self.topP = topP
            self.temperature = temperature
        }
    }
    
    struct AIModelConfiguration {
        var topK: Int
        var topP: Float
        var nCTX: Int
        var temperature: Float
        var maxTokenCount: Int
        var penaltyLastN: Int32
        var penaltyRepeat: Float
        var penaltyFrequency: Float
        var penaltyPresence: Float
        var batchSize: Int
        // DRY sampler parameters
        var dryMultiplier: Float
        var dryBase: Float
        var dryAllowedLength: Int32
        var dryPenaltyLastN: Int32
        // XTC sampler parameters
        var xtcProbability: Float
        var xtcThreshold: Float
        
        
        internal init(from modelOptions: Codings.AiModelConfigResponse.ModelOptions) {
            self.topK = modelOptions.topK
            self.topP = modelOptions.topP
            self.nCTX = modelOptions.contextWindowSize
            self.temperature = modelOptions.temperature
            self.maxTokenCount = modelOptions.maxTokenCount
            self.penaltyLastN = modelOptions.penaltyLastN
            self.penaltyRepeat = modelOptions.penaltyRepeat
            self.penaltyFrequency = modelOptions.penaltyFrequency
            self.penaltyPresence = modelOptions.penaltyPresence
            self.batchSize = modelOptions.batchSize
            // DRY sampler (default disabled if not provided)
            self.dryMultiplier = modelOptions.dryMultiplier ?? 0.0
            self.dryBase = modelOptions.dryBase ?? 1.75
            self.dryAllowedLength = modelOptions.dryAllowedLength ?? 2
            self.dryPenaltyLastN = modelOptions.dryPenaltyLastN ?? 256
            // XTC sampler (default disabled if not provided)
            self.xtcProbability = modelOptions.xtcProbability ?? 0.0
            self.xtcThreshold = modelOptions.xtcThreshold ?? 0.5
        }
        
        func equals(_ other: AIModelConfiguration) -> Bool {
            // Test if they are the same attribute by attribute
            return self.topK == other.topK &&
                   self.topP == other.topP &&
                   self.nCTX == other.nCTX &&
                   self.temperature == other.temperature &&
                   self.maxTokenCount == other.maxTokenCount &&
                   self.penaltyLastN == other.penaltyLastN &&
                   self.penaltyRepeat == other.penaltyRepeat &&
                   self.penaltyFrequency == other.penaltyFrequency &&
                   self.penaltyPresence == other.penaltyPresence &&
                   self.batchSize == other.batchSize &&
                   self.dryMultiplier == other.dryMultiplier &&
                   self.dryBase == other.dryBase &&
                   self.dryAllowedLength == other.dryAllowedLength &&
                   self.dryPenaltyLastN == other.dryPenaltyLastN &&
                   self.xtcProbability == other.xtcProbability &&
                   self.xtcThreshold == other.xtcThreshold
        }
            
    }
    
    public struct AIModel: Sendable {
        public let code: String
        public let name: String
        public let trainingCutoffDate: String
        public let cloudOnly: Bool
        public let jsonToolCalls: Bool
        internal let coding: Codings.AiModelResponse
        
        init(from: Codings.AiModelResponse) {
            self.code = from.code
            self.name = from.name
            self.trainingCutoffDate = from.trainingCutoffDate
            self.cloudOnly = from.cloudOnly
            self.jsonToolCalls = from.jsonToolCalls ?? false
            self.coding = from
        }
    }
    
    public enum DownloadedState: String, Equatable {
        case aiNotSupported = "AI not supported, skipping download"
        case cloudOnly = "Cloud only model, skipping download"
        case downloaded = "AI model downloaded"
    }
    
    public enum ModelDownloadState: Equatable, Sendable {
        case notDownloaded
        case downloading
        case downloaded
        case failed(error: String)
    }
    
    public enum EncryptionScope: Equatable, Sendable {
        case sharedPublic
        case userPrivate
    }
    
}
