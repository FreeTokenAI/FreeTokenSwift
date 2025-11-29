//
//  ChatSessionRunWorkflow.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/5/25.
//

extension FreeToken {
    
    protocol ChatSessionContextProtocol: WorkflowContext {
        var toolMask: [ToolRunMask] { get }
        var toolDefinitionsManager: ToolDefinitionsManager { get }
        var lastGeneratedMessage: Message? { get set }
        var documentSearchScope: String? { get }
        var privateDocumentStoreIDs: [String]? { get }
        var toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> { get }
        var chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> { get }
        var jsonToolResults: Bool { get  }
        var chatSession: ChatSessionInternalProtocol { get  }
        var runLocation: RunLocation { get }
    }
    
    final class ChatSessionRunWorkflowContext: ChatSessionContextProtocol, @unchecked Sendable {
        var stopExecution: Bool = false
        var lastGeneratedMessage: Message? = nil
        
        // Parent session
        let chatSession: ChatSessionInternalProtocol
        
        // Documents
        let documentSearchScope: String?
        let privateDocumentStoreIDs: [String]?
        
        // Status
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>
        
        // Tools
        var toolMask: [ToolRunMask]
        let toolDefinitionsManager: ToolDefinitionsManager
        let toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String>
        let jsonToolResults: Bool
        let runLocation: RunLocation = .localRun
        
        init(
            chatSession: ChatSessionInternalProtocol,
            documentSearchScope: String? = nil,
            privateDocumentStoreIDs: [String]? = nil,
            toolMask: [ToolRunMask] = [.allowAll],
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil,
            jsonToolResults: Bool = false,
            toolDefinitionsManager: ToolDefinitionsManager
        ) {
            self.stopExecution = false
            self.chatSession = chatSession
            self.documentSearchScope = documentSearchScope
            self.privateDocumentStoreIDs = privateDocumentStoreIDs
            self.toolMask = toolMask
            self.chatStatusStream = chatStatusStream
            self.toolUseHandler = toolUseHandler
            self.toolDefinitionsManager = toolDefinitionsManager
            self.jsonToolResults = jsonToolResults
        }
    }
    
    final class CloudChatSessionRunWorklowContext: ChatSessionContextProtocol, @unchecked Sendable {
        var stopExecution: Bool = false
        var lastGeneratedMessage: Message? = nil
        
        // Parent session
        let chatSession: ChatSessionInternalProtocol
        
        // Documents
        let documentSearchScope: String?
        let privateDocumentStoreIDs: [String]?
        
        // Cloud Model Config
        let modelCode: String
        let aiRunConfig: AIRunConfig
        
        // Status
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>
        
        // Tools
        let toolMask: [ToolRunMask]
        let toolDefinitionsManager: ToolDefinitionsManager
        let toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String>
        let jsonToolResults: Bool
        let runLocation: RunLocation = .cloudRun
        
        init(
            chatSession: CloudChatSession,
            documentSearchScope: String? = nil,
            privateDocumentStoreIDs: [String]? = nil,
            modelCode: String,
            aiRunConfig: AIRunConfig,
            toolMask: [ToolRunMask] = [.allowAll],
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void> = nil,
            toolUseHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil,
            jsonToolResults: Bool = false,
            toolDefinitionsManager: ToolDefinitionsManager
        ) {
            self.chatSession = chatSession
            self.documentSearchScope = documentSearchScope
            self.privateDocumentStoreIDs = privateDocumentStoreIDs
            self.modelCode = modelCode
            self.aiRunConfig = aiRunConfig
            self.toolMask = toolMask
            self.chatStatusStream = chatStatusStream
            self.toolUseHandler = toolUseHandler
            self.toolDefinitionsManager = toolDefinitionsManager
            self.jsonToolResults = jsonToolResults
        }
    }
    
    final class RunLocalChatSession: WorkflowStep, @unchecked Sendable {
        var context: ChatSessionContextProtocol
        
        init(context: any FreeToken.WorkflowContext) {
            self.context = context as! ChatSessionContextProtocol
        }
        
        func execute(
            success: @escaping @Sendable (any FreeToken.WorkflowContext) async -> Void,
            failure: @escaping @Sendable (FreeToken.FreeTokenError, any FreeToken.WorkflowContext) async -> Void) async {
                
                var resultContent = ""
                do {
                    try await self.context.chatStatusStream?(nil, .sending_to_local_ai)
                    
                    let inputTokensCount = await context.chatSession.kvTokenCount()
                    var tokenCount = 0
                    for try await nextChunk in try await context.chatSession.generate(for: context.chatSession.runID) {
                        try await self.context.chatStatusStream?(nextChunk, .streaming_tokens)
                        resultContent += nextChunk
                        tokenCount += 1
                    }
                    
                    let generationMetrics = await self.context.chatSession.getLastGenerationMetrics()
                    
                    // Convert generationMetrics.tokensPersecond to Float from Double
                    let tokensPerSecond = Float(generationMetrics?.tokensPerSecond ?? 0.0)
                    
                    let tokenUsage = TokenUsage(totalTokens: (inputTokensCount + tokenCount), tokensPerSecond: tokensPerSecond, inputTokens: inputTokensCount, outputTokens: tokenCount, modelCode: self.context.chatSession.modelCode)
                    
                    
                    // Add New Assitant Message to Thread
                    let assistantMessage = Message(role: .assistant, content: resultContent, tokenUsage: tokenUsage)
                    _ = try await self.context.chatSession.addMessage(message: assistantMessage, updateKVCache: false)
                    _ = try await self.context.chatSession.saveSession()
                    try await self.context.chatStatusStream?(nil, .new_message_created)
                    self.context.lastGeneratedMessage = assistantMessage
                    await success(self.context)
                    return
                } catch {
                    if resultContent != "" {
                        let partialMessage = Message(role: .assistant, content: resultContent)
                        _ = try? await self.context.chatSession.addMessage(message: partialMessage, updateKVCache: false)
                    }
                    let err = FreeTokenError.failedToRunAIWithError(message: error.localizedDescription)
                    await failure(err, self.context)
                }
        }
    }
    
    final class RunCloudChatSession: WorkflowStep, @unchecked Sendable {
        let context: CloudChatSessionRunWorklowContext
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! CloudChatSessionRunWorklowContext
            self.context = context
        }
        
        func execute(success: @escaping @Sendable (any FreeToken.WorkflowContext) async -> Void, failure: @escaping @Sendable (FreeToken.FreeTokenError, any FreeToken.WorkflowContext) async -> Void) async {
            do {
                let messages = try await context.chatSession.getMessages()
                
                let assistantMessage = try await withCheckedThrowingContinuation { continuation in
                    Task {
                        try await self.context.chatStatusStream?(nil, .sending_to_cloud_ai)
                        await FreeToken.shared.generateCloudChatCompletion(messages: messages, model: context.modelCode, aiRunConfig: context.aiRunConfig, chatStatusStream: self.context.chatStatusStream) { message in
                            continuation.resume(returning: message)
                        } error: { error in
                            FreeToken.shared.logger("🔴 Cloud AI run failed with error: \(error)", .error)
                            continuation.resume(throwing: error)
                        }
                    }
                }
                
                let message = try await self.context.chatSession.addMessage(message: assistantMessage, updateKVCache: false)
                try await self.context.chatSession.saveSession()
                try await self.context.chatStatusStream?(nil, .new_message_created)
                self.context.lastGeneratedMessage = message
                
                FreeToken.shared.logger("🏁 Cloud AI run completed with message: \(assistantMessage.content)", .info)
                await success(self.context)
            } catch {
                await failure(error as! FreeTokenError, context)
            }
        }
    }
    
    final class ChatSessionRunToolCalls: WorkflowStep, @unchecked Sendable {
        let context: ChatSessionContextProtocol
        let resultMessage: Message
        let documentSearchScope: String?
        let privateDocumentStoreIds: [String]?
        let externalToolCallback: Optional<@Sendable ([FreeToken.ToolCall]) async -> String>
        let toolDefinitionsManager: ToolDefinitionsManager
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! ChatSessionContextProtocol
            self.context = context
            self.resultMessage = context.lastGeneratedMessage!
            self.documentSearchScope = context.documentSearchScope
            self.privateDocumentStoreIds = context.privateDocumentStoreIDs
            self.externalToolCallback = context.toolUseHandler
            self.toolDefinitionsManager = context.toolDefinitionsManager
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            let toolNames = await toolDefinitionsManager.processToolMask(context.toolMask)
            
            guard toolNames.count > 0 else {
                FreeToken.shared.logger("🛠️ No tool calls defined, skipping", .info)
                await success(context)
                return
            }
            
            FreeToken.shared.logger("🛠️ Checking for tool calls", .info)
            
            let builtInToolDefinitions = await toolDefinitionsManager.getToolDefinitions(for: .builtIn)
            let applicationToolDefinitions = await context.toolDefinitionsManager.getToolDefinitions(for: .application)
            let cloudToolDefinitions = await context.toolDefinitionsManager.getToolDefinitions(for: .cloud)
            
            let toolCallManager = ToolCallsManager(messageContent: resultMessage.content, builtInToolDefinitions: builtInToolDefinitions, applicationToolDefinitions: applicationToolDefinitions, cloudToolDefinitions: cloudToolDefinitions, documentSearchScope: context.documentSearchScope, privateDocumentStoreIds: context.privateDocumentStoreIDs)
                
            let profiler = Profiler()
            
            do {
                do {
                    try await self.context.chatStatusStream?(nil, .evaluating_tool_calls)
                } catch {
                    // User cancelled during tool evaluation
                    await failure(FreeTokenError.generationCancelled, self.context)
                    return
                }
                try await toolCallManager.process(externalToolCallHandler: externalToolCallback) { cloudToolCalls in
                    // TODO: Handle Cloud Tool Calls
                    return ""
                } success: { result in
                    FreeToken.shared.logger("✅ Tool calls processed successfully", .info)
                    profiler.end(eventType: .toolCallAgentRun, isSuccess: true)
                    if result == "" {
                        // No tool calls to handle, just continue
                        do {
                            try await self.context.chatStatusStream?(nil, .stream_ended)
                        } catch {
                            // Ignore errors at stream end
                        }
                        await success(self.context)
                        return
                    }
                    
                    var result = result
                    if self.context.jsonToolResults {
                        result = "{\"tool_results\": \"\(result)}\" }"
                    } else {
                        result = "Result of tool calls: \n \(result)"
                    }
                    
                    let toolMessage = Message(role: .tool, content: result)
                    _ = try await self.context.chatSession.addMessage(message: toolMessage)
                    try await self.context.chatSession.saveSession()
//                    try? await self.context.chatStatusStream?(nil, .new_message_created)
                    
                    let additionalSteps: [any WorkflowStep.Type]
                    
                    if self.context.runLocation == .localRun {
                        additionalSteps = [
                            RunLocalChatSession.self,
                            ChatSessionRunToolCalls.self
                        ]
                    } else {
                        additionalSteps = [
                            RunCloudChatSession.self,
                            ChatSessionRunToolCalls.self
                        ]
                    }
                    
                    if let context = self.context as? ChatSessionRunWorkflowContext {
                        let workflow = WorkflowManager(context: context, steps: additionalSteps)
                        await workflow.execute(success: success, failure: failure)
                        return
                    }
                    
                    if let context = self.context as? CloudChatSessionRunWorklowContext {
                        let workflow = WorkflowManager(context: context, steps: additionalSteps)
                        await workflow.execute(success: success, failure: failure)
                        return
                    }
                    
                    FreeToken.shared.logger("🔴 Unknown context type in tool call workflow", .error)
                    // Can't trigger failure here because it requires context object that
                    // we're not sure of it's type.
                }
            } catch {
                FreeToken.shared.logger("🔴 Error processing tool calls: \(error)", .error)
                profiler.end(eventType: .toolCallAgentRun, isSuccess: false, errorMessage: error.localizedDescription)
                await failure(error as! FreeTokenError, context)
                return
            }
        }
    }
}
