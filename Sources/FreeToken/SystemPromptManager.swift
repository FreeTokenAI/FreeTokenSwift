//
//  SystemPromptManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/2/25.
//
extension FreeToken {

    class SystemPromptManager {
        private let decrypt: Optional<(_ decrypt: String) -> String>
        private let systemPromptParts: Codings.SystemPromptParts
        private let threadSearchResults: [Codings.ShowMessageResponse]
        
        init(decrypt: Optional<(_ decrypt: String) -> String> = nil, systemPromptParts: Codings.SystemPromptParts, threadSearchResults: [Codings.ShowMessageResponse]) {
            self.systemPromptParts = systemPromptParts
            self.threadSearchResults = threadSearchResults
            self.decrypt = decrypt
        }

        func generate() -> Message {
            var systemContext = systemPromptParts.instructions
            
            if let threadSearchResultsContext = systemPromptParts.threadSearchResultsContext {
                systemContext += threadSearchResultsContext
                systemContext += "\n\n"
                for message in threadSearchResults {
                    systemContext += "\(message.role): \(passThroughDecrypt(message.content))\n"
                }
            }
            
            if let toolDefinitions = systemPromptParts.toolDefinitions {
                systemContext += toolDefinitions.prompt
            }
            
            if let pinnedContext = systemPromptParts.pinnedContext {
                systemContext += "\n\n\(passThroughDecrypt(pinnedContext))\n\n"
            }
            
            return Message(role: .system, content: systemContext)
        }
        
        private func passThroughDecrypt(_ content: String) -> String {
            if let decrypt = self.decrypt {
                return decrypt(content)
            } else {
                return content
            }
        }
    }

}
