//
//  Profiler.swift
//  FreeToken
//
//  Created by Vince Francesi on 12/5/24.
//

import Foundation

extension FreeToken {
    class Profiler: @unchecked Sendable {
        private let startTime: DispatchTime
        private var endTime: DispatchTime?
        
        public var eventType: EventType?
        public var errorMessage: String?
        public var eventTypeID: String?
        public var isSuccess: Bool?
        public var tokenStats: Codings.TokenUsageResponse?
        
        public var eventObjectType: String {
            get {
                if eventType != nil {
                    switch eventType! {
                    case .getDevice: return "Device"
                    case .createDevice: return "Device"
                    case .unknown: return ""
                    case .downloadModel: return "AiModel"
                    case .createMessageThread: return "MessageThread"
                    case .addMessageToThread: return "MessageThread"
                    case .generateCloudCompletion: return ""
                    case .generateLocalCompletion: return ""
                    case .createDocument: return "Document"
                    case .searchDocuments: return "DocumentChunk"
                    case .runMessageThreadCloud: return "MessageThread"
                    case .runMessageThreadLocal: return "MessageThread"
                    case .loadModel: return "AiModel"
                    case .internalToolRun: return "InternalToolRun"
                    case .toolCallAgentRun: return "ToolCallAgentRun"
                    }
                } else {
                    return ""
                }
            }
        }
        
        public enum EventType: String {
            case unknown = "unknown"
            case getDevice = "get_device"
            case createDevice = "create_device"
            case downloadModel = "download_model"
            case createMessageThread = "create_message_thread"
            case addMessageToThread = "add_message_to_thread"
            case generateCloudCompletion = "generate_cloud_completion"
            case generateLocalCompletion = "generate_local_completion"
            case createDocument = "create_document"
            case searchDocuments = "search_documents"
            case runMessageThreadCloud = "run_message_thread_cloud"
            case runMessageThreadLocal = "run_message_thread_local"
            case loadModel = "load_model"
            case internalToolRun = "internal_tool_run"
            case toolCallAgentRun = "tool_call_agent_run"
        }
        
        init() {
            self.startTime = DispatchTime.now()
        }
        
        public func end(eventType: EventType, eventTypeID: Optional<String> = nil, isSuccess: Optional<Bool> = nil, errorMessage: Optional<String> = nil, tokenStats: Optional<Codings.TokenUsageResponse> = nil) {
            endTime = DispatchTime.now()
            self.eventType = eventType
            self.eventTypeID = eventTypeID
            self.isSuccess = isSuccess
            self.errorMessage = errorMessage
            self.tokenStats = tokenStats
            
            self.sendTelemtry()
        }
        
        public func msDuration() -> Double? {            
            if endTime != nil {
                let nanoTime = endTime!.uptimeNanoseconds - startTime.uptimeNanoseconds
                return Double(nanoTime) / 1_000_000
            } else {
                return nil
            }
        }
        
        private func sendTelemtry() {
            FreeToken.shared.sendTelemetry(profiler: self)
        }
        
    }
}
