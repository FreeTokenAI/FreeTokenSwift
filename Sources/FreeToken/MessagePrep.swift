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
        
        init(messages: [Message], 
             promptTemplateConfig: Codings.AiModelConfigResponse.PromptTemplateConfig) {
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
                if let systemIndex = messages.firstIndex(where: { $0.role == .system }) {
                    let systemMessage = messages[systemIndex]
                    // Remove the system message if it exists
                    messages.remove(at: systemIndex)
                    // Append the system message content to the user prompt
                    if let userIndex = messages.firstIndex(where: { $0.role == .user }) {
                        let userMessage = messages[userIndex]
                        // Update the content of the user message with the system message
                        let newContent = "Today's Date: \(Date().formatted(.dateTime))\n\n\(systemMessage.content)\n\n\(userMessage.content)"
                        let newUserMessage = Message(role: .user, content: newContent, attachments: userMessage.attachments)
                        // Replace the user message with the new one
                        messages[userIndex] = newUserMessage
                    } else {
                        // If no user message exists, create a new one with the system content
                        let newContent = "Today's Date: \(Date().formatted(.dateTime))\n\n\(systemMessage.content)"
                        let newUserMessage = Message(role: .user, content: newContent, attachments: systemMessage.attachments)
                        messages.append(newUserMessage)
                    }
                }
            } else {
                // Inject system date into the system message
                if let systemIndex = messages.firstIndex(where: { $0.role == .system }) {
                    let systemMessage = messages[systemIndex]
                    // Update the content of the system message with the current date
                    let newContent = "Today's Date: \(Date().formatted(.dateTime))\n\n\(systemMessage.content)"
                    let newSystemMessage = Message(role: .system, content: newContent, attachments: systemMessage.attachments)
                    // Replace the system message with the new one
                    messages[systemIndex] = newSystemMessage
                }
            }
        }
        
        private func convertMessagesToProperRoles() {
            messages = messages.map { message in
                switch message.role {
                case .system:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.systemRole)!, content: message.content, attachments: message.attachments)
                case .user:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.userRole)!, content: message.content, attachments: message.attachments)
                case .assistant:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.assistantRole)!, content: message.content, attachments: message.attachments)
                case .tool:
                    return Message(role: MessageRole(rawValue: promptTemplateConfig.toolRole)!, content: message.content, attachments: message.attachments)
                }
            }
        }
        
        private func ensureMessagesAlternate() throws {
            if promptTemplateConfig.messagesMustAlternate {
                
                if messages.count <= 1 {
                    return
                }
                
                for i in 1..<messages.count {
                    if messages[i].role == messages[i - 1].role {
                        throw FreeTokenError.messagesMustAlternate
                    }
                }
            }
        }
    }
}
