//
//  LlamaTypes.swift
//  FreeToken
//

import Foundation

extension FreeToken {

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
        // DRY sampler parameters
        let dryMultiplier: Float      // 0.0 = disabled, 0.8-1.5 recommended for IQ2_M
        let dryBase: Float            // typically 1.75
        let dryAllowedLength: Int     // how many tokens can repeat (2-4)
        let dryPenaltyLastN: Int      // context window for DRY (256-512)
        // XTC sampler parameters
        let xtcProbability: Float     // 0.0 = disabled, 0.1-0.2 for IQ2_M
        let xtcThreshold: Float       // typically 0.5-1.0
        let seed: UInt32?
        let assistantPrefix: String?
        let threadCount: Int?      // desired inference thread count (nil -> auto)
        let batchSize: Int?        // prompt decoding batch size hint (nil -> library default)
        let threadCountBatch: Int? // threads for prompt / batch processing if API distinguishes
        
        init(
            contextSize: Int,
            maxSequences: Int,  // Default to 4 parallel sequences
            maxNewTokens: Int,
            temperature: Float,
            topK: Int,
            topP: Float,
            repeatPenalty: Float,
            repeatLastN: Int,
            frequencyPenalty: Float,
            presencePenalty: Float,
            dryMultiplier: Float = 0.0,
            dryBase: Float = 1.75,
            dryAllowedLength: Int = 2,
            dryPenaltyLastN: Int = 256,
            xtcProbability: Float = 0.0,
            xtcThreshold: Float = 0.5,
            seed: UInt32? = nil,
            assistantPrefix: String? = nil,
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
            self.dryMultiplier = dryMultiplier
            self.dryBase = dryBase
            self.dryAllowedLength = dryAllowedLength
            self.dryPenaltyLastN = dryPenaltyLastN
            self.xtcProbability = xtcProbability
            self.xtcThreshold = xtcThreshold
            self.seed = seed
            self.assistantPrefix = assistantPrefix
            self.threadCount = threadCount
            self.batchSize = batchSize
            self.threadCountBatch = threadCountBatch
        }
    }
}
