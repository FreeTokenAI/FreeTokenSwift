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
            
            init(content: String, tokenCount: Int) {
                self.content = content
                self.tokenCount = tokenCount
            }
        }
        
        init(contextWindowSize: Int, maxGenerationTokens: Int, modelManager: AIModelManager) {
            self.maxPromptWindowSize = contextWindowSize - maxGenerationTokens
            self.modelManager = modelManager
        }
        
        func generate(messages: [Codings.ShowMessageResponse]) async throws -> String {
            let systemPrompt = messages.first
            let promptMessage = messages.last
            let chatHistory: [Codings.ShowMessageResponse] = messages.dropFirst().dropLast()
            
            guard systemPrompt != nil, systemPrompt!.role == "system" else {
                throw Self.missingSystemPromptError
            }
            
            guard promptMessage != nil else {
                throw Self.missingPromptMessageError
            }
            
            return try await messagesGenerate(systemPrompt: systemPrompt!, promptMessage: promptMessage!, chatHistory: chatHistory)
        }
        
        func messagesGenerate(systemPrompt: Codings.ShowMessageResponse, promptMessage: Codings.ShowMessageResponse, chatHistory: [Codings.ShowMessageResponse]? = nil) async throws -> String {
            let systemPromptBlock = try await generateBlock(message: systemPrompt)
            let userMessageBlock = try await generateBlock(message: promptMessage)
            let chatHistoryBlocks = try await chatHistory?.concurrentMap { message in
                return try await self.generateBlock(message: message)
            }
            let assistantMessage = Codings.ShowMessageResponse(id: nil, role: "assistant", content: "", toolCalls: nil, toolResult: nil, isToolMessage: nil, encryptionEnabled: nil, createdAt: nil, updatedAt: nil, tokenUsage: nil)
            let assistantPromptBlock = try await generateBlock(message: assistantMessage, headerOnly: true)
            
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
            
        
        private func generateBlock(message: Codings.ShowMessageResponse, headerOnly: Bool = false) async throws -> ContentBlock {
            let content = modelManager.generateMessagePrompt(message: message, headerOnly: headerOnly)
            let tokenCount = try await modelManager.tokenCount(content)
            
            return ContentBlock(content: content, tokenCount: tokenCount)
        }
        
        private func assembleBlocks(systemBlock: ContentBlock, userBlock: ContentBlock, chatHistoryBlocks: [ContentBlock]?, assistantBlock: ContentBlock) -> String {
            let availableTokens = maxPromptWindowSize
            let slidingWindowTokens = availableTokens - systemBlock.tokenCount - userBlock.tokenCount - assistantBlock.tokenCount
            var slidingWindowContent = ""
            if let chatHistoryBlocks = chatHistoryBlocks {
                slidingWindowContent = slidingWindow(contentBlocks: chatHistoryBlocks, availableTokens: slidingWindowTokens)
            }
            
            var contentWindow = ""
            contentWindow += systemBlock.content
            contentWindow += slidingWindowContent
            contentWindow += userBlock.content
            contentWindow += assistantBlock.content
            
            return contentWindow
        }
        
        private func slidingWindow(contentBlocks: [ContentBlock], availableTokens: Int) -> String {
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
            
            let blocks = blocksToInclude.reversed()
            
            if  blocks.isEmpty {
                FreeToken.shared.logger("Warning: No content blocks were included in the sliding window due to token size constraints.", .warning)
            }
            
            var slidingWindow = ""
            for block in blocks {
                slidingWindow += block.content
            }
            return slidingWindow
        }
        
        
    }
    
}
