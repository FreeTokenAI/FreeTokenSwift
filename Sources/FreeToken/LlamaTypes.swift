//
//  LlamaTypes.swift
//  FreeToken
//
//  Phase 1 Skeleton: Public-facing types & internal data models for llama.cpp manager.
//

import Foundation

extension FreeToken {
    enum ChatTemplateStyle {
        // Automatic detection (default)
        case auto
        
        // Specific template formats
        case chatml
        case llama2
        case llama2Sys
        case llama3
        case gemma
        case mistralV1
        case mistralV3
        case mistralV7
        case phi3
        case phi4
        case deepseek
        case deepseek2
        case commandR
        case vicuna
        case alpaca
        case zephyr
        case openchat
        case raw      // no special template formatting
    }
    /// Initialization & sampling configuration for the llama manager.
    struct LlamaInitOptions {
        let contextSize: Int
        let maxSequences: Int  // Maximum parallel sequences/sessions
        let maxNewTokens: Int
        let temperature: Float
        let topK: Int
        let topP: Float
        let repeatPenalty: Float
        let repeatLastN: Int
        let frequencyPenalty: Float
        let presencePenalty: Float
        let stopSequences: [String]
        let seed: UInt32?
        let useChatTemplate: Bool
        let assistantPrefix: String?
        let chatStyle: ChatTemplateStyle
    let threadCount: Int?      // desired inference thread count (nil -> auto)
    let batchSize: Int?        // prompt decoding batch size hint (nil -> library default)
    let threadCountBatch: Int? // threads for prompt / batch processing if API distinguishes
        
        init(
            contextSize: Int = 4096,
            maxSequences: Int = 4,  // Default to 4 parallel sequences
            maxNewTokens: Int = 512,
            temperature: Float = 0.8,
            topK: Int = 40,
            topP: Float = 0.95,
            repeatPenalty: Float = 1.1,
            repeatLastN: Int = 64,
            frequencyPenalty: Float = 0.0,
            presencePenalty: Float = 0.0,
            stopSequences: [String] = [],
            seed: UInt32? = nil,
            useChatTemplate: Bool = true,
            assistantPrefix: String? = nil,
            chatStyle: ChatTemplateStyle = .auto,
            threadCount: Int? = nil,
            batchSize: Int? = nil,
            threadCountBatch: Int? = nil
        ) {
            self.contextSize = contextSize
            self.maxSequences = maxSequences
            self.maxNewTokens = maxNewTokens
            self.temperature = temperature
            self.topK = topK
            self.topP = topP
            self.repeatPenalty = repeatPenalty
            self.repeatLastN = repeatLastN
            self.frequencyPenalty = frequencyPenalty
            self.presencePenalty = presencePenalty
            self.stopSequences = stopSequences
            self.seed = seed
            self.useChatTemplate = useChatTemplate
            self.assistantPrefix = assistantPrefix
            self.chatStyle = chatStyle
            self.threadCount = threadCount
            self.batchSize = batchSize
            self.threadCountBatch = threadCountBatch
        }
    }
    
    /// Snapshot of a tracked message and its token count (used externally for context sizing/UI).
    struct KVMessage {
        let message: Message
        let tokenCount: Int
    }
    // Internal representation of a tracked message span in the KV cache.
    /// Internal representation of a message's token span within the logical KV stream.
    struct _LlamaKVSpan {
    var start: Int
    var end: Int // exclusive
    let hash: UInt64
    let message: Message
    var tokenCount: Int { end - start }
    let tokens: [Int32] // stored tokens for repetition penalties & potential reconstruction
}
}

extension Array where Element == FreeToken._LlamaKVSpan {
    func totalTokens() -> Int { self.last?.end ?? 0 }
}
