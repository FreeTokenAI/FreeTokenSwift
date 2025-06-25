//
//  MessagePrep.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/24/25.
//
import Foundation

extension FreeToken {
    
    class MessagePrep {
        private var messages: [Message]
        private let promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig
        
        init(messages: [Message], promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig) {
            self.messages = messages
            self.promptTemplateConfig = promptTemplateConfig
        }
        
        func prepareMessages() throws -> [Message] {
            prepareSystemMessage()
            convertMessagesToProperRoles()
            try ensureMessagesAlternate()
            return messages
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
