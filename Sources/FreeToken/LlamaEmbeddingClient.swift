//
//  LlamaEmbeddingClient.swift
//  FreeToken
//
//  Created by Vince Francesi on 7/29/25.
//

import Foundation
import llama

extension FreeToken {
    /// Lightweight client for generating embeddings using llama.cpp
    /// This is a minimal implementation focused only on embedding generation
    class LlamaEmbeddingClient: @unchecked Sendable {

        // MARK: - Helpers

        /// Check if model is loaded
        var isLoaded: Bool {
            return model != nil && context != nil
        }
        
        /// Get the embedding dimension
        var embeddingDimension: Int? {
            guard let model = model else { return nil }
            return Int(llama_model_n_embd(model))
        }
        
        // MARK: - Properties
        
        private let modelPath: String
        private let contextSize: Int
        private let batchSize: Int
        private let threads: Int
        private let poolingType: Codings.EmbeddingPoolingTypes
        private let deviceAICapable: Bool
        
        private var model: OpaquePointer?
        private var context: OpaquePointer?
        private var batch: llama_batch?
        
        // MARK: - Initialization
        
        init(modelPath: String, contextSize: Int, batchSize: Int, poolingType: Codings.EmbeddingPoolingTypes, deviceAICapable: Bool) {
            self.modelPath = modelPath
            self.contextSize = contextSize
            self.batchSize = batchSize
            self.threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
            self.poolingType = poolingType
            self.deviceAICapable = deviceAICapable
        }
        
        deinit {
            unload()
        }
        
        // MARK: - Model Management
        
        /// Load the model for embedding generation
        func loadModel() throws {
            // Initialize llama backend
            llama_backend_init()
            
            // Set up model parameters
            var modelParams = llama_model_default_params()
            if !deviceAICapable {
                modelParams.n_gpu_layers = 0
                modelParams.use_mmap = false
            }
            
            // Load the model
            guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
                throw FreeTokenError.failedToLoadModel
            }
            self.model = loadedModel
            
            // Set up context parameters for embeddings
            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = UInt32(contextSize)
            ctxParams.n_threads = Int32(threads)
            ctxParams.n_threads_batch = Int32(threads)
            ctxParams.embeddings = true
            
            switch poolingType {
            case .last:
                ctxParams.pooling_type = LLAMA_POOLING_TYPE_LAST
            case .mean:
                ctxParams.pooling_type = LLAMA_POOLING_TYPE_MEAN
            case .cls:
                ctxParams.pooling_type = LLAMA_POOLING_TYPE_CLS
            case .none:
                ctxParams.pooling_type = LLAMA_POOLING_TYPE_NONE
            case .rank:
                ctxParams.pooling_type = LLAMA_POOLING_TYPE_RANK
            case .unspecified:
                ctxParams.pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED
            }
            
            // Create context
            guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
                llama_model_free(loadedModel)
                self.model = nil
                throw FreeTokenError.failedToLoadModel
            }
            self.context = ctx
            
            // Initialize batch
            let newBatch = llama_batch_init(Int32(batchSize), 0, 1)
            self.batch = newBatch
            
            FreeToken.shared.logger("📊 Llama embedding model loaded successfully", .info)
        }
        
        /// Unload the model and free resources
        func unload() {
            if batch != nil {
                llama_batch_free(batch!)
                self.batch = nil
            }
            
            if let context = context {
                llama_free(context)
                self.context = nil
            }
            
            if let model = model {
                llama_model_free(model)
                self.model = nil
            }
        }
        
        // MARK: - Embedding Generation
        
        /// Generate embeddings for a single text
        func generateEmbedding(text: String) throws -> [Float] {
            guard let model = model, let context = context else {
                throw FreeTokenError.aiModelNotLoaded
            }
            
            // Get vocab for tokenization
            let vocab = llama_model_get_vocab(model)
            
            // Tokenize the text
            let maxTokens = Int32(contextSize)
            var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
            let tokenCount = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(
                    vocab,
                    text,
                    Int32(text.utf8.count),
                    buffer.baseAddress,
                    maxTokens,
                    true,  // add BOS
                    true   // special tokens
                )
            }
            
            guard tokenCount > 0 else {
                throw FreeTokenError.encoding(message: "Failed to tokenize text")
            }
            
            // Truncate to actual token count
            tokens = Array(tokens.prefix(Int(tokenCount)))
            
            // Clear the batch
            guard var batch = batch else {
                throw FreeTokenError.aiModelNotLoaded
            }
            batch.n_tokens = 0
            
            // Add tokens to batch
            for (i, token) in tokens.enumerated() {
                batch.token[i] = token
                batch.pos[i] = Int32(i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = (i == tokens.count - 1) ? 1 : 0  // Only need logits for last token
            }
            batch.n_tokens = Int32(tokens.count)
            
            // Clear previous KV cache
            if let memory = llama_get_memory(context) {
                llama_memory_clear(memory, true)
            }
            
            // Process the batch
            if llama_decode(context, batch) != 0 {
                throw FreeTokenError.failedToRunAIWithError(message: "Failed to decode batch")
            }
            
            // Get embeddings
            guard let embeddings = llama_get_embeddings_seq(context, 0) else {
                throw FreeTokenError.noOutputsFoundInResult
            }
            
            // Get embedding dimension
            let nEmbd = Int(llama_model_n_embd(model))
            
            // Copy embeddings to array
            var result = [Float](repeating: 0, count: nEmbd)
            for i in 0..<nEmbd {
                result[i] = embeddings[i]
            }
            
            // Normalize embeddings (L2 normalization)
            let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
            if norm > 0 {
                result = result.map { $0 / norm }
            }
            
            return result
        }
        
        /// Generate embeddings for multiple texts in a batch
        func generateEmbeddings(texts: [String]) throws -> [[Float]] {
            var results: [[Float]] = []
            
            // Process each text individually for now
            // TODO: Optimize to process multiple texts in a single batch
            for text in texts {
                let embedding = try generateEmbedding(text: text)
                results.append(embedding)
            }
            
            return results
        }
        
        
    }
}
