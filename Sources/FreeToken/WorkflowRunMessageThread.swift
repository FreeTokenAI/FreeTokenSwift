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
        let runIdentifier: String
        let deviceDetails: FreeToken.Codings.ShowDeviceSessionResponse?
        let aiModelManager: AIModelManager?
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>
        let toolCallback: Optional<@Sendable ([FreeToken.ToolCall]) async -> String>
        let deviceManager: DeviceManager?
        let documentSearchScope: String?
        let privateDocumentStoreIds: [String]?
        let messagesManager: MessagesManager
        let aiRunConfig: AIRunConfig?
        let jsonToolResults: Bool
        let modelCode: String?
        let toolRunMasks: [ToolRunMask]
        let toolDefinitionsManager: ToolDefinitionsManager
        let additionalContext: String

        var messages: [Message] = []
        var messagesForAI: [Message] = [] // Separate array for AI processing with injected context
        var cloudRun: Bool? = nil
        var resultMessage: Message? = nil
        var tokenUsage: TokenUsage? = nil // Not sure I'll use this, but keeping it for now
        var toolCallRecursiveRuns: Int = 0
        var stopExecution: Bool = false // Special flag to stop execution of the workflow after current step.
        var selectedToolDefinitions: [ToolDefinition] = []
        
        
        init(
            messageThreadID: String,
            runLocation: FreeToken.RunLocation,
            runIdentifier: String?,
            documentSearchScope: String?,
            privateDocumentStoreIds: [String]?,
            deviceDetails: FreeToken.Codings.ShowDeviceSessionResponse?,
            aiModelManager: AIModelManager?,
            deviceManager: DeviceManager?,
            messagesManager: MessagesManager,
            jsonToolResults: Bool,
            aiRunConfig: AIRunConfig? = nil,
            modelCode: String? = nil,
            toolRunMasks: [ToolRunMask],
            additionalContext: String = "",
            allToolDefinitions: [ToolDefinition] = [],
            toolDefinitionsManager: ToolDefinitionsManager,
            chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>,
            toolCallback: Optional<@Sendable ([FreeToken.ToolCall]) async -> String> = nil
        ) {
            self.messageThreadID = messageThreadID
            self.runLocation = runLocation
            self.runIdentifier = runIdentifier != nil ? runIdentifier! : messageThreadID
            self.documentSearchScope = documentSearchScope
            self.privateDocumentStoreIds = privateDocumentStoreIds
            self.deviceDetails = deviceDetails
            self.aiModelManager = aiModelManager
            self.chatStatusStream = chatStatusStream
            self.deviceManager = deviceManager
            self.messagesManager = messagesManager
            self.aiRunConfig = aiRunConfig
            self.toolCallback = toolCallback
            self.jsonToolResults = jsonToolResults
            self.modelCode = modelCode
            self.selectedToolDefinitions = allToolDefinitions
            self.toolRunMasks = toolRunMasks
            self.additionalContext = additionalContext
            self.toolDefinitionsManager = toolDefinitionsManager
        }
    }
    
    // MARK: - Tool Call Masking
    
    final class ToolCallMasking: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let masks: [ToolRunMask]
        
        init(context: any FreeToken.WorkflowContext) {
            self.context = context as! RunMessageThreadContext
            self.masks = self.context.toolRunMasks
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            for mask in masks {
                switch mask {
                case .denyAll:
                    context.selectedToolDefinitions.removeAll()
                case .allow(let name):
                    if context.selectedToolDefinitions.first(where: { $0.name == name }) == nil {
                        let definition = (await context.toolDefinitionsManager.getToolDefinition(for: name))
                        if let definition = definition {
                            context.selectedToolDefinitions.append(definition)
                        } else {
                            FreeToken.shared.logger("⚠️ Explicit allow of tool definition \(name) - tool by that name was not found", .warning)
                        }
                    }
                case .deny(let name):
                    context.selectedToolDefinitions.removeAll(where: { $0.name == name })
                case .allowAll:
                    context.selectedToolDefinitions = await context.toolDefinitionsManager.allToolDefinitions()
                }
            }
            
            await success(context)
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
            if await context.aiModelManager?.getDownloadState() != .downloaded {
                await success(context)
                return
            }
            
            // Try to load session from disk, if it fails continue
            do {
                try await aiModelManager?.loadSessionFromDiskByID(id: context.runIdentifier, messages: context.messages, runConfig: context.aiRunConfig)
                await success(context)
                return
            } catch {
                FreeToken.shared.logger("⏭️ Tried to load session from disk, but failed. Session may not exist on disk.", .info)
            }
            
            do {
                // Use messagesForAI which contains the injected context (populated by InjectAdditionalContext)
                _ = try await context.aiModelManager?.loadSession(for: context.runIdentifier, with: context.messagesForAI, runConfig: context.aiRunConfig)
            } catch {
                if context.runLocation == .localRun {
                    FreeToken.shared.logger("🔴 Failed to load AI model for local run: \(error)", .error)

                    if error as? FreeTokenError == FreeTokenError.messagesMustAlternate {
                        let roles = context.messagesForAI.map { $0.role.rawValue }
                        FreeToken.shared.logger("Roles in order: \(roles.joined(separator: ", "))", .error)
                    }
                    
                    await failure(FreeTokenError.failedToLoadModel, context)
                } else {
                    // If we're in automatic mode, we can just skip loading the model and let it run in the cloud
                    FreeToken.shared.logger("⚠️ Failed to load AI model, automatic run switching to cloud", .warning)
                    context.cloudRun = true
                    await success(context)
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
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>
        let runLocation: FreeToken.RunLocation
        let deviceManager: DeviceManager?
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.deviceDetails = context.deviceDetails
            self.aiModelManager = context.aiModelManager
            self.chatStatusStream = context.chatStatusStream
            self.runLocation = context.runLocation
            self.deviceManager = context.deviceManager
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            // Check if any message in the thread contains images (vision capability required)
            let threadHasImages = context.messages.contains { message in
                message.attachments?.contains { $0.type == .image } ?? false
            }
            
            switch runLocation {
            case .automatic:
                // If thread has images and model supports imageToText, force cloud run (local models don't support vision)
                if threadHasImages {
                    // Check if the model supports imageToText
                    let supportsImageToText = deviceDetails?.aiModel.capabilities.imageToText ?? false
                    
                    if supportsImageToText {
                        FreeToken.shared.logger("📸 Thread contains images and model supports imageToText, routing to cloud (vision not supported locally)", .info)
                        context.cloudRun = true
                        do {
                            try await chatStatusStream?(nil, .starting)
                        } catch {
                            // User cancelled immediately
                            await failure(FreeTokenError.generationCancelled, context)
                            return
                        }
                        await success(context)
                        return
                    } else {
                        FreeToken.shared.logger("❌ Thread contains images but model does not support imageToText", .error)
                        do {
                            try await chatStatusStream?(nil, .failed)
                        } catch {
                            // Ignore errors in failed status
                        }
                        await failure(FreeTokenError.visionModelRequired, context)
                        return
                    }
                }
                
                // Automatically determine if this should be a cloud run or not
                context.cloudRun = await shouldCloudRun()
                await success(context)
                return
                
            case .cloudRun:
                FreeToken.shared.logger("☁️ Force cloud run requested", .info)
                // Even for cloud run, check if model supports imageToText when images are present
                if threadHasImages {
                    let supportsImageToText = deviceDetails?.aiModel.capabilities.imageToText ?? false
                    if !supportsImageToText {
                        FreeToken.shared.logger("❌ Cloud run requested but model does not support imageToText", .error)
                        do {
                            try await chatStatusStream?(nil, .failed)
                        } catch {
                            // Ignore errors in failed status
                        }
                        await failure(FreeTokenError.visionModelRequired, context)
                        return
                    }
                }
                context.cloudRun = true
                await success(context)
            case .localRun:
                // Check for vision requirement in local run
                if threadHasImages {
                    FreeToken.shared.logger("❌ Local run requested but thread contains images - vision not supported on local models", .error)
                    do {
                        try await chatStatusStream?(nil, .failed)
                    } catch {
                        // Ignore errors in failed status
                    }
                    await failure(FreeTokenError.visionNotSupportedLocally, context)
                    return
                }
                
                FreeToken.shared.logger("🧠 Force local run requested", .info)
                context.cloudRun = false
                
                // Check if device is overheating
                if deviceManager?.isTooHot() == true {
                    do {
                        try await chatStatusStream?(nil, .failed)
                    } catch {
                        // Ignore errors in failed status
                    }
                    await failure(FreeTokenError.deviceOverheating, context)
                    return
                }
                
                // Check if AI model is downloaded
                if await aiModelManager?.getDownloadState() != .downloaded {
                    do {
                        try await chatStatusStream?(nil, .failed)
                    } catch {
                        // Ignore errors in failed status
                    }
                    await failure(FreeTokenError.aiModelNotDownloaded, context)
                    return
                }
                
                // Check if device is AI capable
                if deviceManager?.isAICapable != true {
                    do {
                        try await chatStatusStream?(nil, .failed)
                    } catch {
                        // Ignore errors in failed status
                    }
                    await failure(FreeTokenError.deviceNotCapable, context)
                    return
                }
                
                // Check if model is cloud only
                if deviceDetails?.aiModel.cloudOnly == true {
                    do {
                        try await chatStatusStream?(nil, .failed)
                    } catch {
                        // Ignore errors in failed status
                    }
                    await failure(FreeTokenError.isCloudOnlyModel, context)
                    return
                }
                
                await success(context)
            }
        }
        
        private func shouldCloudRun() async -> Bool {
            // Check device capabilities first
            if deviceManager?.isAICapable == true {
                // Device is AI capable, check model state
                if await aiModelManager?.getDownloadState() != .downloaded {
                    // Model not downloaded - use cloud for automatic mode
                    FreeToken.shared.logger("🔽 Model not downloaded, running in cloud", .info)
                    return true
                } else {
                    if self.deviceManager?.isTooHot() == true {
                        FreeToken.shared.logger("🔥 Device too hot, running in cloud", .warning)
                        return true
                    }
                    
                    FreeToken.shared.logger("🧠 Model ready and device capable - Should run locally", .info)
                    return false
                }
            } else {
                // Device not AI capable - use cloud
                FreeToken.shared.logger("☁️🧠 Device not AI capable, running in cloud", .info)
                return true
            }
        }
    }
    
    // MARK: - Get Message Thread from MessageManager:
    
    final class GetMessages: WorkflowStep, @unchecked Sendable {
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
                self.context.messages = messageThread.messages
                await success(self.context)
            } failure: { error in
                await failure(error, self.context)
            }
        }
    }
    
    // MARK: Inject Additional Context

    final class InjectAdditionalContext: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let userAdditionalContext: String

        init(context: any FreeToken.WorkflowContext) {
            self.context = context as! RunMessageThreadContext
            self.userAdditionalContext = self.context.additionalContext
        }

        func execute(success: @escaping @Sendable (any FreeToken.WorkflowContext) async -> Void, failure: @escaping @Sendable (FreeToken.FreeTokenError, any FreeToken.WorkflowContext) async -> Void) async {

            // Create copies of all messages for AI processing
            context.messagesForAI = context.messages.map { originalMessage in
                // Create a new Message instance with the same properties
                Message(
                    id: originalMessage.id,
                    role: originalMessage.role,
                    content: originalMessage.content,
                    attachments: originalMessage.attachments,
                    createdAt: originalMessage.createdAt,
                    tokenUsage: originalMessage.tokenUsage
                )
            }

            // Inject additional context into the last user message copy
            if let lastMessage = context.messagesForAI.last {
                if lastMessage.role == .user {
                    var additionalContext = ""

                    let date = Date()
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    let formattedDate = formatter.string(from: date)
                    additionalContext += "Current Date & Time: \(formattedDate)\n"

                    // Inject User Additional Context
                    if !userAdditionalContext.isEmpty {
                        additionalContext += userAdditionalContext + "\n"
                    }

                    // Modify the COPY, not the original
                    lastMessage.content = "\(additionalContext)\(lastMessage.content)"

                    FreeToken.shared.logger("ℹ️ Full user message with additional context being sent to the model: \(lastMessage.content)", .info)
                }
            }

            await success(context)
        }
    }

    // MARK: - Run AI Model in the Cloud:
    
    final class RunAIModelInCloud: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>
        let messages: [Message]

        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.chatStatusStream = context.chatStatusStream
            // Use messagesForAI which contains the injected context
            self.messages = context.messagesForAI
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
            
            do {
                try await chatStatusStream?(nil, .sending_to_cloud_ai)
            } catch {
                // User cancelled before cloud execution
                await failure(FreeTokenError.generationCancelled, context)
                return
            }
            
            await FreeToken.shared.generateCloudChatCompletion(messages: messages, model: context.modelCode, aiRunConfig: context.aiRunConfig, chatStatusStream: chatStatusStream) { message in
                self.context.resultMessage = message
                self.context.tokenUsage = message.tokenUsage
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
        let chatStatusStream: Optional<@Sendable (_ token: String?, _ status: ChatStreamStatus) async throws -> Void>
        let aiModelManager: AIModelManager?
        let aiRunConfig: AIRunConfig?
        let messages: [Message]

        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.chatStatusStream = context.chatStatusStream
            self.aiModelManager = context.aiModelManager
            self.aiRunConfig = context.aiRunConfig
            // Use messagesForAI which contains the injected context
            self.messages = context.messagesForAI
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
            
            do {
                try await chatStatusStream?(nil, .sending_to_local_ai)
            } catch {
                // User cancelled before local execution
                await failure(FreeTokenError.generationCancelled, context)
                return
            }
            
            let resultText: String
            let usage: TokenUsage?
            let messages = messages
            
            let profiler = Profiler()
            do {
                let aiModelManager = context.aiModelManager!
                
                FreeToken.shared.logger("🏁 Running message thread locally with ID: \(context.messageThreadID)", .info)
                (resultText, usage) = try await aiModelManager.sendMessagesToAI(messages: messages, runIdentifier: context.runIdentifier, runLocation: context.runLocation, aiRunConfig: aiRunConfig) { tokens in
                    do {
                        try await self.chatStatusStream?(tokens, .streaming_tokens)
                    } catch {
                        // User cancelled during streaming - this will be handled by sendMessagesToAI
                        throw error
                    }
                    // TODO: Try to start handling tool calls before the AI completes?
                }

                profiler.end(eventType: .generateLocalChatCompletion, isSuccess: true, tokenStats: usage)
                context.resultMessage = Message(role: .assistant, content: resultText, tokenUsage: usage)
                context.tokenUsage = usage

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
                } else if context.runLocation == .automatic {
                    // Automatic mode - fall back to cloud when local fails
                    FreeToken.shared.logger("🔄 Automatic mode active, AI Model failed, falling back to cloud run", .warning)
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
        let messageThreadID: String
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.messagesManager = context.messagesManager
            self.resultMessage = context.resultMessage!
            self.messageThreadID = context.messageThreadID
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            await messagesManager.addMessage(message: resultMessage, messageThreadID: messageThreadID) { result in
                switch result {
                case .success(let resultMessage):
                    resultMessage.tokenUsage = self.context.tokenUsage // Copy over last token usage
                    self.context.resultMessage = resultMessage
                    // Emit new_message_created event
                    try? await self.context.chatStatusStream?(nil, .new_message_created)
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
    
    // MARK: - Save AI Session to Disk
    
    final class SaveAISessionToDisk: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        
        init(context: any FreeToken.WorkflowContext) {
            self.context = context as! RunMessageThreadContext
        }
        
        func execute(success: @escaping @Sendable (any FreeToken.WorkflowContext) async -> Void, failure: @escaping @Sendable (FreeToken.FreeTokenError, any FreeToken.WorkflowContext) async -> Void) async {
            guard context.cloudRun == false else {
                return
            }
            
            if let aiModelManager = context.aiModelManager {
                do {
                    try await aiModelManager.saveSessionToDiskByID(id: context.messageThreadID)
                } catch {
                    await failure(FreeTokenError.llamaFailedToWriteSessionStateToFile, self.context)
                }
            }
        }
    }
    
    // MARK: - Run Tool Calls
    
    final class RunToolCalls: WorkflowStep, @unchecked Sendable {
        let context: RunMessageThreadContext
        let deviceDetails: FreeToken.Codings.ShowDeviceSessionResponse
        let resultMessage: Message
        let documentSearchScope: String?
        let privateDocumentStoreIds: [String]?
        let externalToolCallback: Optional<@Sendable ([FreeToken.ToolCall]) async -> String>
        let messagesManager: MessagesManager
        let messageThreadID: String
        
        init(context: any FreeToken.WorkflowContext) {
            let context = context as! RunMessageThreadContext
            self.context = context
            self.deviceDetails = context.deviceDetails!
            self.resultMessage = context.resultMessage!
            self.documentSearchScope = context.documentSearchScope
            self.privateDocumentStoreIds = context.privateDocumentStoreIds
            self.externalToolCallback = context.toolCallback
            self.messagesManager = context.messagesManager
            self.messageThreadID = context.messageThreadID
        }
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void {
            let toolNames = await context.toolDefinitionsManager.processToolMask(context.toolRunMasks)
            
            guard toolNames.count > 0 else {
                FreeToken.shared.logger("🛠️ No tool calls defined, skipping", .info)
                await success(context)
                return
            }
            
            FreeToken.shared.logger("🛠️ Checking for tool calls", .info)
            
            let builtInToolDefinitions = await context.toolDefinitionsManager.getToolDefinitions(for: .builtIn).filter { tool in
                return context.selectedToolDefinitions.contains(where: { $0.name == tool.name })
            }
            let applicationToolDefinitions = await context.toolDefinitionsManager.getToolDefinitions(for: .application).filter { tool in
                return context.selectedToolDefinitions.contains(where: { $0.name == tool.name })
            }
            let cloudToolDefinitions = await context.toolDefinitionsManager.getToolDefinitions(for: .cloud).filter { tool in
                return context.selectedToolDefinitions.contains(where: { $0.name == tool.name })
            }
            
            let toolCallManager = ToolCallsManager(messageContent: resultMessage.content, builtInToolDefinitions: builtInToolDefinitions, applicationToolDefinitions: applicationToolDefinitions, cloudToolDefinitions: cloudToolDefinitions, documentSearchScope: context.documentSearchScope, privateDocumentStoreIds: context.privateDocumentStoreIds)
                
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
                    await self.messagesManager.addMessage(message: toolMessage, messageThreadID: self.messageThreadID) { result in
                        switch result {
                        case .success(_):
                            // Emit new_message_created event for tool message
                            try? await self.context.chatStatusStream?(nil, .new_message_created)
                            if self.context.toolCallRecursiveRuns >= 3 {
                                FreeToken.shared.logger("⚠️ AI made too many recursive tool calls, stopping execution", .warning)
                                profiler.end(eventType: .toolCallAgentRun, isSuccess: false, errorMessage: "Too many recursive tool calls")
                                do {
                                    try await self.context.chatStatusStream?(nil, .stream_ended)
                                } catch {
                                    // Ignore errors at stream end
                                }
                                await success(self.context)
                                return
                            }

                            // Add additional steps to this workflow to handle tool calls
                            let additionalSteps: [any WorkflowStep.Type] = [
                                GetMessages.self,
                                InjectAdditionalContext.self,  // Important: inject context for recursive calls
                                RunAIModelLocally.self,
                                RunAIModelInCloud.self,
                                AddMessageToThread.self,
                                SaveAISessionToDisk.self,
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
