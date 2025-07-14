//
//  MessagePrep.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/24/25.
//
import Foundation
import LocalLLMClient
import LocalLLMClientLlama

extension FreeToken {
    
    class MessagePrep {
        private var messages: [Message]
        private let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
        private let contextWindowSize: Int
        private let model: LLMSession.DownloadModel?
        private let isNewSession: Bool
        private let isSessionRebuild: Bool
        
        // System message cache for reinjection
        private var systemMessageContent: String? = nil
        private var systemMessageTokenCount: Int = 0
        
        init(messages: [Message], 
             promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig,
             contextWindowSize: Int,
             model: LLMSession.DownloadModel? = nil,
             isNewSession: Bool = false,
             isSessionRebuild: Bool = false) {
            self.messages = messages
            self.promptTemplateConfig = promptTemplateConfig
            self.contextWindowSize = contextWindowSize
            self.model = model
            self.isNewSession = isNewSession
            self.isSessionRebuild = isSessionRebuild
            
            // Extract and cache system message content
            cacheSystemMessage()
        }
        
        func prepareMessages() throws -> [Message] {
            // Check if we need to truncate for new session with large thread OR session rebuild
            if (isNewSession && shouldTruncateForInitialLoad()) || (isSessionRebuild && shouldTruncateForSessionRebuild()) {
                try truncateThreadForInitialLoad()
            }
            
            // Prepare system message after potential truncation to avoid double work
            prepareSystemMessage()
            
            convertMessagesToProperRoles()
            try ensureMessagesAlternate()
            return messages
        }
        
        // MARK: - System Message Caching
        
        private func cacheSystemMessage() {
            // Find and cache the system message content before any transformations
            if let systemMessage = messages.first(where: { $0.role == .system }) {
                systemMessageContent = systemMessage.content
                
                // If we have a model, calculate token count
                if let model = model {
                    systemMessageTokenCount = estimateTokenCount(for: systemMessage.content, using: model)
                    FreeToken.shared.logger("💾 Cached system message with ~\(systemMessageTokenCount) tokens", .info)
                }
            }
        }
        
        // MARK: - Context Window Management (Deprecated - using KV cache optimization instead)
        
        private func shouldManageContext() -> Bool {
            // Context management now handled by KV cache optimization in AIModelManager
            return false
        }
        
        private func performContextWindowManagement() throws {
            // No-op: Context management now handled by KV cache optimization
        }
        
        // MARK: - Thread Truncation for New Sessions
        
        private func shouldTruncateForInitialLoad() -> Bool {
            // For thread reload: Truncate if thread is larger than (context window - max generation tokens)
            let totalTokens = estimateTotalTokens()
            let maxGenerationTokens = contextWindowSize / 10  // Reserve 10% for generation (same as truncateThreadForInitialLoad)
            let availableForMessages = contextWindowSize - maxGenerationTokens
            
            FreeToken.shared.logger("📊 New session thread analysis: \(totalTokens) tokens, available space: \(availableForMessages) tokens (context: \(contextWindowSize), generation: \(maxGenerationTokens))", .debug)
            
            // Threshold for truncation - if thread exceeds available space for messages
            let shouldTruncate = totalTokens > availableForMessages
            
            if shouldTruncate {
                FreeToken.shared.logger("📦 Large thread detected for reload - will truncate to fit available space (\(availableForMessages) tokens)", .info)
            }
            
            return shouldTruncate
        }
        
        private func shouldTruncateForSessionRebuild() -> Bool {
            // For session rebuilds, we ALWAYS truncate since we know there was an overflow risk
            let totalTokens = estimateTotalTokens()
            let contextWindows = Double(totalTokens) / Double(contextWindowSize)
            
            FreeToken.shared.logger("📊 Session rebuild analysis: \(totalTokens) tokens (~\(String(format: "%.1f", contextWindows))x context windows)", .debug)
            FreeToken.shared.logger("🔄 Session rebuild - will truncate to fit context window", .info)
            
            return true // Always truncate for session rebuilds
        }
        
        private func truncateThreadForInitialLoad() throws {
            let initialTokenCount = estimateTotalTokens()
            FreeToken.shared.logger("✂️ Truncating large thread for new session to preserve recent context", .warning)
            FreeToken.shared.logger("📊 Pre-truncation: \(messages.count) messages, ~\(initialTokenCount) tokens", .info)
            
            // Extract and preserve system message
            guard let systemMessage = messages.first(where: { $0.role == .system }) else {
                FreeToken.shared.logger("⚠️ No system message found during truncation", .warning)
                return
            }
            
            // Calculate available space for message history
            // Target ~50% context usage to leave plenty of headroom for future messages
            let maxGenerationTokens = contextWindowSize / 10  // Reserve 10% for generation
            let targetContextUsage = Int(Double(contextWindowSize) * 0.5)  // Target 50% total usage
            
            let systemTokens: Int
            if let model = model {
                systemTokens = estimateTokenCount(for: systemMessage.content, using: model)
            } else {
                systemTokens = max(1, systemMessage.content.count / 4)
            }
            
            // Available tokens = target usage - generation buffer - system message
            let availableTokens = targetContextUsage - maxGenerationTokens - systemTokens
            
            FreeToken.shared.logger("📐 Token allocation targeting 50% context usage: \(systemTokens) system + \(availableTokens) history + \(maxGenerationTokens) generation = \(targetContextUsage) target (of \(contextWindowSize) total)", .debug)
            
            // Work backwards from most recent messages
            let recentMessages = selectRecentMessages(targetTokens: availableTokens)
            
            // Reconstruct message array: [system] + [recent messages]
            let originalCount = messages.count
            messages = [systemMessage] + recentMessages
            
            let finalTokenCount = estimateTotalTokens()
            FreeToken.shared.logger("📦 Thread truncated for new session: \(originalCount) → \(messages.count) messages", .info)
            FreeToken.shared.logger("📊 Post-truncation: ~\(finalTokenCount) tokens (reduced by \(initialTokenCount - finalTokenCount) tokens)", .info)
            FreeToken.shared.logger("📊 Target context usage: 50% (\(targetContextUsage)/\(contextWindowSize) tokens)", .info)
        }
        
        private func selectRecentMessages(targetTokens: Int) -> [Message] {
            var selectedMessages: [Message] = []
            var tokenCount = 0
            
            // Get all non-system messages
            let nonSystemMessages = messages.filter { $0.role != .system }
            
            FreeToken.shared.logger("🔍 Selecting recent messages from \(nonSystemMessages.count) candidates, target: \(targetTokens) tokens", .debug)
            
            // Work backwards from the end to get most recent messages
            for message in nonSystemMessages.reversed() {
                let messageTokens: Int
                if let model = model {
                    messageTokens = estimateTokenCount(for: message.content, using: model)
                } else {
                    messageTokens = max(1, message.content.count / 4)
                }
                
                // Check if adding this message would exceed our target
                if tokenCount + messageTokens <= targetTokens {
                    selectedMessages.insert(message, at: 0) // Maintain chronological order
                    tokenCount += messageTokens
                    FreeToken.shared.logger("✅ Selected message (\(messageTokens) tokens): \(message.role) - \(message.content.prefix(50))...", .debug)
                } else {
                    FreeToken.shared.logger("❌ Skipped message (\(messageTokens) tokens) - would exceed target: \(message.role) - \(message.content.prefix(50))...", .debug)
                    break // Stop when we'd exceed target
                }
            }
            
            FreeToken.shared.logger("📋 Selected \(selectedMessages.count) recent messages totaling ~\(tokenCount) tokens", .info)
            return selectedMessages
        }
        
        
        private func reinjectSystemMessageIfNeeded() {
            guard let systemContent = systemMessageContent else { return }
            
            if promptTemplateConfig.appendSystemToUserPrompt {
                // For models that don't support system messages, check if system content is in first user message
                if let firstUserMessage = messages.first(where: { $0.role == .user }) {
                    // Check if the user message already contains the system content (check for a key phrase)
                    // We need to be more specific than just contains() to avoid false positives
                    let hasSystemContent = firstUserMessage.content.contains("Today's Date:") && 
                                         firstUserMessage.content.contains(systemContent)
                    
                    if !hasSystemContent {
                        FreeToken.shared.logger("💉 Reinjecting system message into first user message", .info)
                        
                        // Find the index of the first user message
                        if let userIndex = messages.firstIndex(where: { $0.role == .user }) {
                            let currentContent = messages[userIndex].content
                            let newContent = "Today's Date: \(Date().formatted(.dateTime))\n\n\(systemContent)\n\n\(currentContent)"
                            let updatedMessage = Message(role: .user, content: newContent)
                            messages[userIndex] = updatedMessage
                        }
                    }
                } else {
                    // No user message exists, create one with system content
                    FreeToken.shared.logger("💉 Creating user message with system content (no user messages found)", .info)
                    let systemUserMessage = Message(role: .user, content: "Today's Date: \(Date().formatted(.dateTime))\n\n\(systemContent)")
                    messages.append(systemUserMessage)
                }
            } else {
                // For models that support system messages, check if system message still exists
                let hasSystemMessage = messages.contains(where: { $0.role == .system })
                
                if !hasSystemMessage {
                    FreeToken.shared.logger("💉 Reinjecting system message to preserve AI instructions", .info)
                    
                    // Create new system message with cached content
                    let systemMessage = Message(role: .system, content: systemContent)
                    
                    // Insert at beginning
                    messages.insert(systemMessage, at: 0)
                }
            }
        }
        
        // MARK: - Token Estimation
        
        private func estimateTokenCount(for text: String, using model: LLMSession.DownloadModel) -> Int {
            // This is a rough estimation
            // For more accurate counting, we'd need access to the actual tokenizer
            // Rough estimate: ~1 token per 4 characters for English text
            // This is a conservative estimate that works reasonably well
            return max(1, text.count / 4)
        }
        
        private func estimateTotalTokens() -> Int {
            var totalTokens = 0
            
            if let model = model {
                // Use model-based estimation if available
                for message in messages {
                    totalTokens += estimateTokenCount(for: message.content, using: model)
                }
            } else {
                // Fallback to simple estimation
                for message in messages {
                    totalTokens += max(1, message.content.count / 4)
                }
            }
            
            // Add some buffer for special tokens and formatting
            totalTokens = Int(Double(totalTokens) * 1.1)
            
            return totalTokens
        }
        
        private func prepareSystemMessage() {
            if promptTemplateConfig.appendSystemToUserPrompt {
                // Find the first system message index
                let systemIndex = messages.firstIndex(where: { $0.role == .system })
                
                if let systemIndex = systemIndex {
                    let systemMessage = messages[systemIndex]
                    // Remove the system message from the messages array
                    messages.remove(at: systemIndex)

                    // Find the index of the first user message
                    if let userIndex = messages.firstIndex(where: { $0.role == .user }) {
                        // Create a new user message with system content prepended
                        let newUserMessage = Message(role: .user, content: "Today's Date: \(Date().formatted(.dateTime) )\n\n\(systemMessage.content)\n\n\(messages[userIndex].content)")
                        // Replace the user message with the new one
                        messages[userIndex] = newUserMessage
                    }
                }
            } else {
                // Inject system date into the system message
                if let systemIndex = messages.firstIndex(where: { $0.role == .system }) {
                    let systemMessage = messages[systemIndex]
                    // Update the content of the system message with the current date
                    let newContent = "Today's Date: \(Date().formatted(.dateTime))\n\n\(systemMessage.content)"
                    let newSystemMessage = Message(role: .system, content: newContent)
                    // Replace the system message with the new one
                    messages[systemIndex] = newSystemMessage
                }
            }
        }
        
        private func convertMessagesToProperRoles() {
            messages = messages.map { message in
                switch message.role {
                case .system:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.systemRole)!, content: message.content)
                case .user:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.userRole)!, content: message.content)
                case .assistant:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.assistantRole)!, content: message.content)
                case .tool:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.toolRole)!, content: message.content)
                }
            }
        }
        
        private func ensureMessagesAlternate() throws {
            if promptTemplateConfig.messagesMustAlternate {
                for i in 1..<messages.count {
                    if messages[i].role == messages[i - 1].role {
                        throw FreeTokenError.messagesMustAlternate
                    }
                }
            }
        }
    }
}
