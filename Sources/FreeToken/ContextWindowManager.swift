//
//  ContextWindowManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 4/2/25.
//
import Foundation

extension FreeToken {
    
    class ContextWindowManager: @unchecked Sendable {
        static let notEnoughAvailableTokensError = Codings.ErrorResponse(error: "notEnoughAvailableTokens", message: "There are not enough available tokens in the context window for the system prompt and user message", code: 10000)
        
        static let missingSystemPromptError = Codings.ErrorResponse(error: "missingSystemPrompt", message: "The system prompt must be the first message", code: 10001)
        static let missingPromptMessageError = Codings.ErrorResponse(error: "missingPromptMessage", message: "A prompt is missing.", code: 10002)
        
        
        let maxPromptWindowSize: Int
        let modelManager: AIModelManager
        
        struct ContentBlock {
            let content: String
            let tokenCount: Int
            let message: Message
            
            init(content: String, tokenCount: Int, message: Message) {
                self.content = content
                self.message = message
                self.tokenCount = tokenCount
            }
        }
        
        init(modelManager: AIModelManager) {
            let modelConfig = modelManager.modelOptions
            self.maxPromptWindowSize = modelConfig.contextWindowSize - modelConfig.maxTokenCount
            self.modelManager = modelManager
        }
        
        func generate(messages: [Message]) async throws -> String {
            let systemPrompt = messages.first
            let promptMessage = messages.last
            let chatHistory: [Message] = messages.dropFirst().dropLast()
            
            guard systemPrompt != nil, systemPrompt!.role == .system else {
                throw Self.missingSystemPromptError
            }
            
            guard promptMessage != nil else {
                throw Self.missingPromptMessageError
            }
            
            let blocks = try await messagesGenerate(systemPrompt: systemPrompt!, promptMessage: promptMessage!, chatHistory: chatHistory)
            
            let prompt = blocks.map { $0.content }.joined(separator: "")
            FreeToken.shared.logger("Context window managed prompt:\n\(prompt)\n", .debug)
            
            return prompt
        }
        
        func filterMessages(messages: [Message]) async throws -> [Message] {
            let systemPrompt = messages.first
            let promptMessage = messages.last
            let chatHistory: [Message] = messages.dropFirst().dropLast()
            
            guard systemPrompt != nil, systemPrompt!.role == .system else {
                throw Self.missingSystemPromptError
            }
            
            guard promptMessage != nil else {
                throw Self.missingPromptMessageError
            }
            
            let blocks = try await messagesGenerate(systemPrompt: systemPrompt!, promptMessage: promptMessage!, chatHistory: chatHistory)
            
            return blocks.map { $0.message }
        }
        
        private func messagesGenerate(systemPrompt: Message, promptMessage: Message, chatHistory: [Message]) async throws -> [ContentBlock] {
            let systemPromptBlock = generateBlock(message: systemPrompt)
            let userMessageBlock = generateBlock(message: promptMessage)
            let chatHistoryBlocks = chatHistory.map { message in
                return self.generateBlock(message: message)
            }
            
            let assistantPromptBlock = generateBlock(message: Message(role: .assistant, content: ""), headerOnly: true)
            
            guard preFlight([systemPromptBlock, userMessageBlock, assistantPromptBlock]) else {
                throw Self.notEnoughAvailableTokensError
            }

            return assembleBlocks(systemBlock: systemPromptBlock, userBlock: userMessageBlock, chatHistoryBlocks: chatHistoryBlocks, assistantBlock: assistantPromptBlock)
        }
        
        private func preFlight(_ blocks: [ContentBlock]) -> Bool {
            var availableTokens = maxPromptWindowSize
            
            for block in blocks {
                availableTokens -= block.tokenCount
            }
                        
            return availableTokens > 0
        }
        
        
        private func generateBlock(message: Message, headerOnly: Bool = false) -> ContentBlock {
            let (content, tokenCount) = modelManager.generateMessagePrompt(message: message, headerOnly: headerOnly)
            
            return ContentBlock(content: content, tokenCount: tokenCount, message: message)
        }
        
        private func assembleBlocks(systemBlock: ContentBlock, userBlock: ContentBlock, chatHistoryBlocks: [ContentBlock], assistantBlock: ContentBlock) -> [ContentBlock] {
            let availableTokens = maxPromptWindowSize
            let slidingWindowTokens = availableTokens - systemBlock.tokenCount - userBlock.tokenCount - assistantBlock.tokenCount
            let slidingWindowBlocks = slidingWindow(contentBlocks: chatHistoryBlocks, availableTokens: slidingWindowTokens)
            
            let blocks: [ContentBlock] = [systemBlock] + slidingWindowBlocks + [userBlock, assistantBlock]
            
            return blocks
        }
        
        private func slidingWindow(contentBlocks: [ContentBlock], availableTokens: Int) -> [ContentBlock] {
            guard !contentBlocks.isEmpty else {
                // There are no content blocks to include in the sliding window.
                return []
            }
            
            
            // Take the last messages from the array first and work your way back until there are no more messages or no more available tokens.
            var remainingTokens = availableTokens
            
            let reversedContentBlocks = contentBlocks.reversed()
            var blocksToInclude: [ContentBlock] = []
            
            for block in reversedContentBlocks {
                remainingTokens -= block.tokenCount
                
                if remainingTokens >= 0 {
                    blocksToInclude.append(block)
                } else {
                    break
                }
            }
            
            let blocks = blocksToInclude.reversed() as Array<ContentBlock>
            
            if  blocks.isEmpty {
                FreeToken.shared.logger("Warning: No content blocks were included in the sliding window due to token size constraints.", .warning)
            }
            
            return blocks
        }
        
        
    }
    
}
