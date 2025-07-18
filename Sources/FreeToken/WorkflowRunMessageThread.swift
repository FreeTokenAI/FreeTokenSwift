//
//  WorkflowRunMessageThread.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/21/25.
//
import Foundation

extension FreeToken {

    // MARK: - Context Definition:
    
    final class RunMessageThreadContext: WorkflowContext, @unchecked Sendable {
        let messageThreadID: String
        let runLocation: FreeToken.RunLocation
        let deviceDetails: FreeToken.Codings.ShowDeviceSessionResponse?
        let aiModelManager: AIModelManager?
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async -> Void>
        let toolCallback: Optional<@Sendable ([FreeToken.ToolCall]) async -> String>
        let deviceMode: DeviceMode?
        let deviceManager: DeviceManager?
        let documentSearchScope: String?
        let privateDocumentStoreIds: [String]?
        let messagesManager: MessagesManager
        let aiRunConfig: AIRunConfig?
        let jsonToolResults: Bool
        let modelCode: String?

        var cloudRun: Bool? = nil
        var resultMessage: Message? = nil
        var messageThread: MessageThread? = nil
        var tokenUsage: TokenUsage? = nil // Not sure I'll use this, but keeping it for now
        var toolCallRecursiveRuns: Int = 0
        var stopExecution: Bool = false // Special flag to stop execution of the workflow after current step.
        
        
        init(
            messageThreadID: String,
            runLocation: FreeToken.RunLocation,
            documentSearchScope: String?,
            privateDocumentStoreIds: [String]?,
            deviceDetails: FreeToken.Codings.ShowDeviceSessionResponse?,
            aiModelManager: AIModelManager?,
            deviceMode: DeviceMode?,
            deviceManager: DeviceManager?,
            messagesManager: MessagesManager,
            jsonToolResults: Bool,
            aiRunConfig: AIRunConfig? = nil,
            modelCode: String? = nil,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async -> Void>,
            toolCallback: Optional<@Sendable ([FreeToken.ToolCall]) async -> String> = nil
        ) {
            self.messageThreadID = messageThreadID
            self.runLocation = runLocation
            self.documentSearchScope = documentSearchScope
            self.privateDocumentStoreIds = privateDocumentStoreIds
            self.deviceDetails = deviceDetails
            self.aiModelManager = aiModelManager
            self.chatStatusStream = chatStatusStream
            self.deviceMode = deviceMode
            self.deviceManager = deviceManager
            self.messagesManager = messagesManager
            self.aiRunConfig = aiRunConfig
            self.toolCallback = toolCallback
            self.jsonToolResults = jsonToolResults
            self.modelCode = modelCode
        }
    }
    
    // MARK: - Load model if not already loaded
    final class LoadAIModel: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let aiModelManager: AIModelManager?
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.aiModelManager = context.aiModelManager
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            // If we're forcing a cloud run, we don't need to load the model
            if context.runLocation == .cloudRun {
                await success(context)
                return
            }
            
            // If the model isn't downloaded, just move on.
            if await context.aiModelManager?.stateManager.getDownloadState() != .downloaded {
                await success(context)
                return
            }
            
            if await context.aiModelManager?.stateManager.getLoadedState() == .loaded {
                FreeToken.shared.logger("🧠 AI model already loaded, skipping load", .info)
                await success(context)
                return
            }

            // Kickoff async model load
            Task.detached(priority: .background) {
                _ = await FreeToken.shared.loadModel { loadedState in
                    // Nothing to do here, the model is loaded
                } error: { error in
                    // Failed to load the model, nothing to do here
                }
            }
            
            await success(context) // Continue execution without waiting for the model to load
        }
    }
    
    // MARK: - Determine AI Run Location:
    
    final class DetermineAIRunLocation: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let deviceDetails: FreeToken.Codings.ShowDeviceSessionResponse?
        let aiModelManager: AIModelManager?
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async -> Void>
        let deviceMode: DeviceMode?
        let runLocation: FreeToken.RunLocation
        let deviceManager: DeviceManager?
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.deviceDetails = context.deviceDetails
            self.aiModelManager = context.aiModelManager
            self.chatStatusStream = context.chatStatusStream
            self.deviceMode = context.deviceMode
            self.runLocation = context.runLocation
            self.deviceManager = context.deviceManager
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            switch runLocation {
            case .automatic:
                // Automatically determine if this should be a cloud run or not
                do {
                    context.cloudRun = try await shouldCloudRun()
                    await success(context)
                } catch {
                    await chatStatusStream?(nil, .failed)
                    await failure(error as! FreeTokenError, context)
                    return
                }
            case .cloudRun:
                FreeToken.shared.logger("☁️ Force cloud run requested", .info)
                context.cloudRun = true
                
                if deviceMode?.isPrivacyMode == true {
                    await failure(FreeTokenError.cloudRunInPrivacyMode, context)
                    return
                }
                
                await success(context)
            case .localRun:
                FreeToken.shared.logger("🧠 Force local run requested", .info)
                context.cloudRun = false
                
                // Check if device is overheating
                if deviceManager?.isTooHot() == true {
                    await chatStatusStream?(nil, .failed)
                    await failure(FreeTokenError.deviceOverheating, context)
                    return
                }
                
                // Check if AI model is downloaded
                if await aiModelManager?.stateManager.getDownloadState() != .downloaded {
                    await chatStatusStream?(nil, .failed)
                    await failure(FreeTokenError.aiModelNotDownloaded, context)
                    return
                }
                
                // Check if device is AI capable
                if deviceManager?.isAICapable != true {
                    await chatStatusStream?(nil, .failed)
                    await failure(FreeTokenError.deviceNotCapable, context)
                    return
                }
                
                // Check if model is cloud only
                if deviceDetails?.aiModel.cloudOnly == true {
                    await chatStatusStream?(nil, .failed)
                    await failure(FreeTokenError.isCloudOnlyModel, context)
                    return
                }
                
                await success(context)
            }
        }
        
        private func shouldCloudRun() async throws -> Bool {
            if deviceManager?.isAICapable == true {
                if await aiModelManager?.stateManager.getDownloadState() != .downloaded {
                    if self.deviceMode?.isQuickStartMode == true {
                        FreeToken.shared.logger("Quick Start Activated!", .info)
                        // Quick start mode activated
                        return true
                    } else {
                        throw FreeTokenError.aiModelNotDownloaded
                    }
                } else {
                    // Downloaded
                    
                    if self.deviceMode?.isQuickStartMode == true {
                        // If not loaded, run in cloud
                        if await aiModelManager?.stateManager.getLoadedState() != .loaded {
                            FreeToken.shared.logger("🧠 Model not loaded yet, running in cloud", .info)
                            return true
                        }
                        
                        if self.deviceManager?.isTooHot() == true {
                            FreeToken.shared.logger("😰 Device too hot, running in cloud", .warning)
                            return true
                        }
                    }
                    
                    FreeToken.shared.logger("🧠 Model downloaded and AI supported - Should run locally", .info)
                    return false
                }
            } else {
                if self.deviceMode?.isCompatibilityMode == true {
                    // Compatibility Mode activated
                    FreeToken.shared.logger("☁️🧠 Compatibility Mode Activated!", .info)
                    return true
                } else {
                    throw FreeTokenError.aiNotSupportedNoCompatibility
                }
            }
        }
    }
    
    // MARK: - Get Message Thread from MessageManager:
    
    final class GetMessageThread: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let messagesManager: MessagesManager
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.messagesManager = context.messagesManager
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            await messagesManager.getMessageThread(id: context.messageThreadID) { messageThread, _ in
                self.context.messageThread = messageThread
                await success(self.context)
            } failure: { error in
                await failure(error, self.context)
            }
        }
    }

    // MARK: - Run AI Model in the Cloud:
    
    final class RunAIModelInCloud: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async -> Void>
        let messageThread: MessageThread
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.chatStatusStream = context.chatStatusStream
            self.messageThread = context.messageThread!
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            guard let cloudRun = context.cloudRun, cloudRun else {
                // Not a cloud run, so just call success and move on
                FreeToken.shared.logger("☁️ Not a cloud run, skipping cloud AI execution", .info)
                await success(context)
                return
            }
            
            FreeToken.shared.logger("🏁 Running message thread in the cloud with ID: \(context.messageThreadID)", .info)
            
            await chatStatusStream?(nil, .sending_to_cloud_ai)
            
            await FreeToken.shared.generateCloudChatCompletion(messages: messageThread.messages, model: context.modelCode, aiRunConfig: context.aiRunConfig, chatStatusStream: chatStatusStream) { message in
                self.context.resultMessage = message
                FreeToken.shared.logger("🏁 Cloud AI run completed with message: \(message.content)", .info)
                await success(self.context)
            } error: { error in
                FreeToken.shared.logger("🔴 Cloud AI run failed with error: \(error)", .error)
                await failure(error, self.context)
            }
        }
    }
    
    // MARK: - Run AI Model Locally:
    
    final class RunAIModelLocally: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async -> Void>
        let aiModelManager: AIModelManager?
        let aiRunConfig: AIRunConfig?
        let messageThread: MessageThread
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.chatStatusStream = context.chatStatusStream
            self.aiModelManager = context.aiModelManager
            self.aiRunConfig = context.aiRunConfig
            self.messageThread = context.messageThread!
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            guard let cloudRun = context.cloudRun, !cloudRun else {
                // Not a local run, so just call success and move on
                FreeToken.shared.logger("🏁 Not a local run, skipping local AI execution", .info)
                await success(context)
                return
            }
            
            await chatStatusStream?(nil, .sending_to_local_ai)
            
            let resultText: String
            let usage: TokenUsage?
            let messages = messageThread.messages
            
            FreeToken.shared.logger("🔍 WORKFLOW: Processing \(messages.count) messages in thread", .info)
            for (index, msg) in messages.enumerated() {
                FreeToken.shared.logger("🔍 WORKFLOW: Message \(index): role=\(msg.role), attachments=\(msg.attachments?.count ?? 0)", .info)
            }
            
            let profiler = Profiler()
            do {
                let aiModelManager = context.aiModelManager!
                
                FreeToken.shared.logger("🏁 Running message thread locally with ID: \(context.messageThreadID)", .info)
                (resultText, usage) = try await aiModelManager.sendMessagesToAI(messages: messages, runIdentifier: messageThread.id, aiRunConfig: aiRunConfig) { tokens in
                    await self.chatStatusStream?(tokens, .streaming_tokens)
                    // TODO: Try to start handling tool calls before the AI completes?
                }

                profiler.end(eventType: .generateLocalChatCompletion, isSuccess: true, tokenStats: usage)
                context.resultMessage = Message(role: .assistant, content: resultText, tokenUsage: usage)

                FreeToken.shared.logger("🧠 Local AI run completed successfully", .info)
                await success(context)
            } catch {
                let error = error as! FreeTokenError
                
                FreeToken.shared.logger("🔴 Local AI run failed with error: \(error.message)", .error)
                
                // Check if we should fall back to cloud
                if context.runLocation == .localRun {
                    // User explicitly requested local run, so fail without fallback
                    FreeToken.shared.logger("❌ Local run explicitly requested, not falling back to cloud", .error)
                    await failure(error, context)
                } else if context.deviceMode?.isQuickStartMode == true {
                    // If we're in Quick Start mode and not explicitly local, failback to cloud
                    FreeToken.shared.logger("🔄 Quick Start mode active, AI Model failed, falling back to cloud run", .warning)
                    context.cloudRun = true
                    await success(context) // Continue to the next step which will run in the cloud
                } else {
                    await failure(error, context)
                }
            }
        }
        
    }
 
    // MARK: - Add Message to Thread
    
    final class AddMessageToThread: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let messagesManager: MessagesManager
        let resultMessage: Message
        let messageThread: MessageThread
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.messagesManager = context.messagesManager
            self.resultMessage = context.resultMessage!
            self.messageThread = context.messageThread!
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            await messagesManager.addMessage(message: resultMessage, messageThreadID: messageThread.id) { result in
                switch result {
                case .success(let resultMessage):
                    self.context.resultMessage = resultMessage
                    FreeToken.shared.logger("✅ Message added to thread successfully", .info)
                    await success(self.context)
                case .failure(let error):
                    FreeToken.shared.logger("🔴 Failed to add message to thread: \(error.message)", .error)
                    await failure(error, self.context)
                    return
                }
            }
        }
    }
    
    // MARK: - Run Tool Calls
    
    final class RunToolCalls: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let deviceDetails: FreeToken.Codings.ShowDeviceSessionResponse
        let toolNames: [String]
        let resultMessage: Message
        let documentSearchScope: String?
        let privateDocumentStoreIds: [String]?
        let externalToolCallback: Optional<@Sendable ([FreeToken.ToolCall]) async -> String>
        let messagesManager: MessagesManager
        let messageThread: MessageThread
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.toolNames = context.deviceDetails?.toolNames ?? []
            self.deviceDetails = context.deviceDetails!
            self.resultMessage = context.resultMessage!
            self.documentSearchScope = context.documentSearchScope
            self.privateDocumentStoreIds = context.privateDocumentStoreIds
            self.externalToolCallback = context.toolCallback
            self.messagesManager = context.messagesManager
            self.messageThread = context.messageThread!
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            guard toolNames.count > 0 else {
                FreeToken.shared.logger("🛠️ No tool calls defined, skipping", .info)
                await success(context)
                return
            }
            
            FreeToken.shared.logger("🛠️ Checking for tool calls", .info)
  
            let cloudCallNames: [String] = [] // This is not implemented yet.
            let toolCallManager = ToolCallsManager(messageContent: resultMessage.content, availableCloudToolCalls: cloudCallNames, toolNames: toolNames, documentSearchScope: documentSearchScope, privateDocumentStoreIds: privateDocumentStoreIds)
            let profiler = Profiler()
            
            do {
                await self.context.chatStatusStream?(nil, .evaluating_tool_calls)
                try await toolCallManager.process(externalToolCallHandler: externalToolCallback) { cloudToolCalls in
                    // TODO: Handle Cloud Tool Calls
                    return ""
                } success: { result in
                    FreeToken.shared.logger("✅ Tool calls processed successfully", .info)
                    profiler.end(eventType: .toolCallAgentRun, isSuccess: true)
                    if result == "" {
                        // No tool calls to handle, just continue
                        await self.context.chatStatusStream?(nil, .stream_ended)
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
                    await self.messagesManager.addMessage(message: toolMessage, messageThreadID: self.messageThread.id) { result in
                        switch result {
                        case .success(_):
                            if self.context.toolCallRecursiveRuns >= 3 {
                                FreeToken.shared.logger("⚠️ AI made too many recursive tool calls, stopping execution", .warning)
                                profiler.end(eventType: .toolCallAgentRun, isSuccess: false, errorMessage: "Too many recursive tool calls")
                                await self.context.chatStatusStream?(nil, .stream_ended)
                                await success(self.context)
                                return
                            }

                            // Add additional steps to this workflow to handle tool calls
                            let additionalSteps: [any WorkflowStep.Type] = [
                                GetMessageThread.self,
                                RunAIModelInCloud.self,
                                RunAIModelLocally.self,
                                AddMessageToThread.self,
                                RunToolCalls.self
                            ]
                            self.context.toolCallRecursiveRuns += 1
                            let workflow = WorkflowManager(context: self.context, steps: additionalSteps)
                            await workflow.execute(success: success, failure: failure)
                        case .failure(let error):
                            FreeToken.shared.logger("🔴 Failed to add tool message: \(error.message)", .error)
                            await failure(error, self.context)
                        }
                    }
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
