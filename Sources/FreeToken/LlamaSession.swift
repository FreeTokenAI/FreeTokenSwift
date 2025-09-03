//
//  LlamaSession.swift
//  FreeToken
//
//  Phase 1 Skeleton: Actor encapsulating llama.cpp context. Actual llama.cpp calls TBD.
//

import Foundation
import llama
import FreeTokenCBridge

extension FreeToken {
    
    /// Static model management functions
    class LlamaModel: @unchecked Sendable {
        let model: OpaquePointer
        
        init(path: String) throws {
            LlamaAPI.backendInit()
            
            var modelParams = LlamaAPI.modelDefaultParams()
            modelParams.use_mmap = true
            
            guard let model = LlamaAPI.loadModel(path, modelParams) else {
                throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Failed to load model at \(path)")
            }
            
            self.model = model
            
            FreeTokenLogger.shared.log("Model loaded from \(path)", level: .info)
        }
        
        
        /// Free a loaded model
        func free() {
            LlamaAPI.freeModel(model)
            FreeTokenLogger.shared.log("Model freed", level: .debug)
        }
    }
    
    actor LlamaSession {
        private let model: LlamaModel
        private let context: OpaquePointer
        private let session: OpaquePointer
        private let template: String
        private let batch: llama_batch
        private let batchSize: Int32
        private var tokenCache: [Int32: String] = [:]
        private var pos: Int32 = 0
        private var isUnloaded: Bool = false
        @inline(__always) private func ensureActive(_ fn: StaticString = #function) throws { if isUnloaded { throw FreeToken.FreeTokenError.aiRunFailed(message: "LlamaSession was unloaded; call site: \(fn)") } }
        
        init(model: LlamaModel, config: LlamaInitOptions) throws {
            // Create Context
            var params = LlamaAPI.contextDefaultParams()
            params.n_ctx = UInt32(config.contextSize)
            params.n_batch = UInt32(config.batchSize ?? 512)
            params.n_seq_max = 1 // Only one sequence per session (memory will scale linarly with number of sequences - it's a multiplicative factor)
            // Count number of CPUs and reserve 2 for system/UI tasks
            params.n_threads = max(1, min(8, Int32(ProcessInfo.processInfo.activeProcessorCount) - 2))
            params.n_threads_batch = params.n_threads
            params.offload_kqv = true // Offload the KV cache to GPU
            params.swa_full = false // Disable sliding window attention full state if supported
            params.type_k = GGML_TYPE_Q8_0 // Quantize K for better memory with little difference in result
            params.type_v = GGML_TYPE_Q8_0 // Quantize V for better memory with little difference in result
            params.flash_attn = true
            
            guard let context = LlamaAPI.newContext(model.model, params) else {
                throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Failed to create context")
            }
            
            // Create Sampler
            var samplerConfig = freetoken_sampling_config()
            samplerConfig.temperature = config.temperature
            samplerConfig.top_k = Int32(config.topK)
            samplerConfig.top_p = config.topP
            samplerConfig.min_p = 0.0  // Disabled by default
            samplerConfig.typical_p = 0.0  // Disabled by default
            samplerConfig.frequency_penalty = config.frequencyPenalty
            samplerConfig.presence_penalty = config.presencePenalty
            samplerConfig.mirostat = 0  // Disabled by default (was incorrectly set to 2)
            samplerConfig.mirostat_tau = 5.0  // Default target entropy
            samplerConfig.mirostat_eta = 0.1  // Default learning rate
            samplerConfig.repeat_penalty = config.repeatPenalty  // Use config value, not hardcoded
            samplerConfig.repeat_last_n = Int32(config.repeatLastN)
            // DRY sampler parameters
            samplerConfig.dry_multiplier = config.dryMultiplier
            samplerConfig.dry_base = config.dryBase
            samplerConfig.dry_allowed_length = Int32(config.dryAllowedLength)
            samplerConfig.dry_penalty_last_n = Int32(config.dryPenaltyLastN)
            // XTC sampler parameters
            samplerConfig.xtc_probability = config.xtcProbability
            samplerConfig.xtc_threshold = config.xtcThreshold
            if let seed = config.seed {
                samplerConfig.seed = seed
                samplerConfig.use_seed = true
            } else {
                samplerConfig.seed = UInt32(Date().timeIntervalSince1970)
                samplerConfig.use_seed = true
            }
            
            
            // Create session
            guard let session = freetoken_session_create(
                UnsafeMutableRawPointer(model.model),
                UnsafeMutableRawPointer(context),
                samplerConfig
            ) else {
                LlamaAPI.freeContext(context)
                throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Failed to create session")
            }
            
            guard let template = LlamaAPI.modelChatTemplate(model.model) else {
                freetoken_session_free(session)
                LlamaAPI.freeContext(context)
                throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Failed to get build in model chat template")
            }
            
            self.model = model
            self.context = context
            self.session = session
            self.batch = llama_batch_init(Int32(config.batchSize ?? 512), 0, 1)
            self.batchSize = Int32(config.batchSize ?? 512)
            self.template = template
        }
        
        /// Tokenize text -> token ids
        @inline(__always)
        func tokenize(_ text: String) async throws -> [Int] {
            try ensureActive()
            do {
                let toks = try LlamaAPI.tokenize(model: model.model, text: text, addBos: false, special: false)
                return toks.map(Int.init)
            } catch {
                FreeTokenLogger.shared.log("tokenize failed len=\(text.utf8.count) error=\(error)", level: .error)
                throw error
            }
        }
        
        @inline(__always)
        func detokenize(tokens: [Int32]) -> String {
            if isUnloaded { return "" }
            var out = String(); out.reserveCapacity(tokens.count * 4)
            for t in tokens {
                if let cached = tokenCache[t] {
                    out += cached
                } else {
                    let piece = LlamaAPI.tokenToPiece(model: model.model, token: t)
                    tokenCache[t] = piece
                    out += piece
                }
            }
            return out
        }
    
        /// Tokenize multiple texts in parallel (safe since it's read-only)
        func tokenizeParallel(_ texts: [String]) async throws -> [[Int]] {
            try ensureActive()
            return try await withThrowingTaskGroup(of: (Int, [Int]).self) { group in
                for (index, text) in texts.enumerated() {
                    group.addTask { [weak self] in
                        guard let self = self else { throw FreeToken.FreeTokenError.aiRunFailed(message: "Session deallocated") }
                        let tokens = try await self.tokenize(text)
                        return (index, tokens)
                    }
                }
    
                var results = Array(repeating: [Int](), count: texts.count)
                for try await (index, tokens) in group {
                    results[index] = tokens
                }
                return results
            }
        }
        
        /// Optimized batch evaluation using C bridge
        /// - Parameters:
        ///   - tokens: Tokens to evaluate
        ///   - feedToSampler: Whether to feed tokens to sampler for penalty tracking (default true for chat, false for raw completion)
        ///   - needsLogits: Whether to calculate logits for the last token (default: true for generation, false for prompt loading)
        func evalOptimized(tokens: [Int], feedToSampler: Bool = true, needsLogits: Bool = true) async throws {
            try ensureActive()
            guard !tokens.isEmpty else { return }
    
            let start = CFAbsoluteTimeGetCurrent()
    
            // Convert to Int32 and use C bridge
            let converted = tokens.map { Int32($0) }
            let processed: Int32
    
            if feedToSampler {
                // Use session-based eval that also feeds tokens to sampler for repetition penalty tracking
                processed = converted.withUnsafeBufferPointer { buffer in
                    freetoken_eval_batch_with_session_ex(
                        session,
                        buffer.baseAddress,
                        Int32(buffer.count),
                        pos,
                        Int32(batchSize),
                        0,
                        needsLogits
                    )
                }
            } else {
                // Use regular eval (for cases where we don't have a session yet or don't need penalty tracking)
                processed = converted.withUnsafeBufferPointer { buffer in
                    freetoken_eval_batch_ex(
                        UnsafeMutableRawPointer(context),
                        buffer.baseAddress,
                        Int32(buffer.count),
                        pos,
                        Int32(batchSize),
                        0,
                        needsLogits
                    )
                }
            }
    
            guard processed == Int32(tokens.count) else {
                throw FreeToken.FreeTokenError.aiRunFailed(message: "C bridge eval failed: processed=\(processed) expected=\(tokens.count)")
            }
    
            pos += Int32(tokens.count)
    
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed > 0 {
                let tps = Double(tokens.count) / elapsed
                FreeTokenLogger.shared.log("eval (C bridge) tokens=\(tokens.count) time=\(String(format: "%.3f", elapsed))s tps=\(String(format: "%.1f", tps))", level: .debug)
            }
        }
    
    
        /// Optimized generation using C bridge for maximum performance
        func generateNextTokenOptimized() async throws -> (token: Int32, text: String, evalMs: Float, sampleMs: Float)? {
            try ensureActive()
    
            // Call C bridge with session (sampler is already configured)
            let result = freetoken_generate_next(
                session,
                UnsafeMutableRawPointer(model.model),
                pos,
                0
            )
    
            guard result.success else {
                throw FreeToken.FreeTokenError.aiRunFailed(message: "C bridge generation failed")
            }
    
            // Detokenize using fast C implementation
            var textBuffer = [CChar](repeating: 0, count: 256)
            let textLen = freetoken_token_to_piece_fast(
                UnsafeMutableRawPointer(model.model),
                result.token,
                &textBuffer,
                Int32(textBuffer.count)
            )
    
            let text: String
            if textLen > 0 {
                let data = Data(bytes: textBuffer, count: Int(textLen))
                text = String(data: data, encoding: .utf8) ?? ""
            } else {
                text = ""
            }
    
            pos += 1
    
            // Don't log per-token, let the manager handle periodic logging
    
            return (result.token, text, result.eval_time_ms, result.sample_time_ms)
        }
        
        // MARK: - Get Special Tokens

        /// Get the EOS token ID for the model
        func getEOSToken() -> Int32 {
            if isUnloaded { return -1 }
            return { let v = llama_model_get_vocab(model.model); return v != nil ? llama_vocab_eos(v) : -1 }()
        }
    
        /// Get the EOT (end-of-turn) token ID for the model
        func getEOTToken() -> Int32 {
            if isUnloaded { return -1 }
            return { let v = llama_model_get_vocab(model.model); return v != nil ? llama_vocab_eot(v) : -1 }()
        }
    
        /// Get all stop tokens (EOS, EOT) for the model
        func getStopTokens() -> Set<Int32> {
            if isUnloaded { return [] }
            return { guard let vocab = llama_model_get_vocab(model.model) else { return [] }; var s = Set<Int32>(); let eos = llama_vocab_eos(vocab); let eot = llama_vocab_eot(vocab); if eos >= 0 { s.insert(eos) }; if eot >= 0 { s.insert(eot) }; return s }()
        }
        
        // MARK: KV Cache Management
        
        /// Reset the sampler state (clears token history for penalties)
        /// Use this for stateless operations like raw completion
        func resetSampler() {
            if isUnloaded { return }
            freetoken_session_reset_sampler(session)
            FreeTokenLogger.shared.log("Sampler reset for stateless generation", level: .debug)
        }
    
        /// Clear the entire KV cache
        func clearKVCache() async {
            if isUnloaded { return }
            let memory = llama_get_memory(context)
            // Remove all tokens for this sequence (p1 = -1 means to end)
            llama_memory_seq_rm(memory, 0, 0, -1)
            pos = 0
            FreeTokenLogger.shared.log("KV cache cleared", level: .debug)
        }
    
        /// Remove tokens from KV cache in the given range [from, to)
        func removeKVCacheTokens(from: Int32, to: Int32) async throws {
            try ensureActive()
            let memory = llama_get_memory(context)
            let success = llama_memory_seq_rm(memory, 0, from, to)
            if !success {
                throw FreeToken.FreeTokenError.aiRunFailed(message: "Failed to remove KV cache tokens [\(from),\(to))")
            }
            FreeTokenLogger.shared.log("Removed KV cache tokens [\(from),\(to))", level: .debug)
        }
    
        /// Shift tokens in KV cache by adding delta to their positions
        /// from: starting position (inclusive)
        /// count: number of tokens to shift
        /// by: delta to add to positions (negative to shift left, positive to shift right)
        func shiftKVCacheTokens(from startPos: Int32, count: Int32, by delta: Int32) async throws {
            try ensureActive()
            let memory = llama_get_memory(context)
    
            // Use llama_memory_seq_add to shift positions
            // This adds 'delta' to all token positions in the range [startPos, startPos + count)
            let endPos = count < 0 ? -1 : startPos + count  // -1 means to end
            llama_memory_seq_add(memory, 0, startPos, endPos, delta)
    
            // Update our position tracker if needed
            if pos > startPos {
                pos = max(0, pos + delta)
            }
    
            FreeTokenLogger.shared.log("Shifted KV cache tokens from=\(startPos) count=\(count) by=\(delta)", level: .debug)
        }
    
        /// Free underlying context resources (model is managed externally).
        func unload() {
            if isUnloaded { return }
            // Free session (which includes sampler)
            freetoken_session_free(session)
            // Free context
            LlamaAPI.freeContext(context)
            pos = 0
            llama_batch_free(batch)
            tokenCache.removeAll()
            model.free()
            isUnloaded = true
        }

        /// Internal full reset used by managers to rebuild KV/state without destroying the underlying model+context.
        /// This avoids freeing the context/model so subsequent tokenization & eval remain valid.
        /// NOTE: Does NOT free sampler/session because they remain in use; just clears KV + sampler history and local caches.
        func resetForRebuild() {
            if isUnloaded { return }
            // Clear KV cache for sequence 0
            let memory = llama_get_memory(context)
            llama_memory_seq_rm(memory, 0, 0, -1)
            pos = 0
            // Reset sampler penalties/history
            resetSampler()
            // Clear local caches
            tokenCache.removeAll()
            FreeTokenLogger.shared.log("Session resetForRebuild: cleared KV, sampler, caches (model/context preserved)", level: .debug)
        }
        
        // MARK: Chat Template
        
        func applyChatTemplate(messages: [(role: String, content: String)], includeAssistantPrefix: Bool) throws -> [Int] {
            try ensureActive()
            return try LlamaAPI.chatApplyTemplate(model: model.model, template: template, messages: messages, addAssistant: includeAssistantPrefix).map(Int.init)
        }
        
    }
}
