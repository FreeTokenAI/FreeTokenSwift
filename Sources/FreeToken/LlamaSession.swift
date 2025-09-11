//
//  LlamaSession.swift
//  FreeToken
//
//  Phase 1 Skeleton: Actor encapsulating llama.cpp context. Actual llama.cpp calls TBD.
//

import Foundation
import llama
import FreeTokenCBridge
import CryptoKit

extension FreeToken {
    
    /// Static model management functions
    class LlamaModel: @unchecked Sendable {
        let model: OpaquePointer
        
        init(path: String) throws {
            LlamaAPI.backendInit()
            
            var modelParams = LlamaAPI.modelDefaultParams()
            modelParams.use_mmap = true
            modelParams.use_mlock = false
            
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
        private var pos: Int32 = 0
        private var isUnloaded: Bool = false
        let configSHA256: String
        @inline(__always) private func ensureActive(_ fn: StaticString = #function) throws { if isUnloaded { throw FreeToken.FreeTokenError.aiRunFailed(message: "LlamaSession was unloaded; call site: \(fn)") } }
        
        struct ContextConfig: Encodable {
            let n_ctx: Int
            let n_batch: Int
            let n_seq_max: Int
            let type_k: String
            let type_v: String
            let flash_attn: Bool
            let swa_full: Bool
            
            func dump() -> String {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) {
                    return json
                } else {
                    return "{}"
                }
            }
            
            func sha256() -> String {
                let data = Data(dump().utf8)
                return data.sha256Hex()
            }
        }
        
        init(model: LlamaModel, config: LlamaInitOptions) throws {
            // Create Context
            var params = LlamaAPI.contextDefaultParams()
            params.n_ctx = UInt32(config.contextSize)
            params.n_batch = UInt32(config.batchSize ?? 512)
            params.n_seq_max = 1 // Only one sequence per session (memory will scale linarly with number of sequences - it's a multiplicative factor)
            // Count number of CPUs and reserve 2 for system/UI tasks
            params.n_threads = max(1, min(8, Int32(ProcessInfo.processInfo.activeProcessorCount) - 2))
            params.n_threads_batch = params.n_threads
            params.offload_kqv = true // Offload the KV cache to GPU - CRITICAL FOR PERFORMANCE
            params.swa_full = false // Disable sliding window attention full state if supported
            params.type_k = GGML_TYPE_Q8_0 // Quantize K for better memory with little difference in result
            params.type_v = GGML_TYPE_Q8_0 // Quantize V for better memory with little difference in result
            params.flash_attn = true
            
            let contextConfig = ContextConfig(
                n_ctx: Int(params.n_ctx),
                n_batch: Int(params.n_batch),
                n_seq_max: Int(params.n_seq_max),
                type_k: String(describing: params.type_k),
                type_v: String(describing: params.type_v),
                flash_attn: params.flash_attn,
                swa_full: params.swa_full
            )
            self.configSHA256 = contextConfig.sha256()
            
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
        func tokenize(_ text: String, addBos: Bool = false, special: Bool = false) async throws -> [Int] {
            try ensureActive()
            do {
                let toks = try LlamaAPI.tokenize(model: model.model, text: text, addBos: addBos, special: special)
                return toks.map(Int.init)
            } catch {
                FreeTokenLogger.shared.log("tokenize failed len=\(text.utf8.count) error=\(error)", level: .error)
                throw error
            }
        }
        
        /// Detokenize an array of tokens back to text
        @inline(__always)
        func detokenize(_ tokens: [Int]) async throws -> String {
            try ensureActive()
            guard !tokens.isEmpty else { return "" }
            
            // Convert to Int32 array for C bridge
            let tokenArray = tokens.map { Int32($0) }
            
            // Allocate a reasonable buffer size (average ~4 chars per token)
            let bufferSize = max(tokens.count * 8, 1024)
            var buffer = [CChar](repeating: 0, count: bufferSize)
            
            // Call the C bridge function
            let bytesWritten = tokenArray.withUnsafeBufferPointer { tokenBuffer in
                freetoken_tokens_to_text(
                    UnsafeMutableRawPointer(model.model),
                    tokenBuffer.baseAddress,
                    Int32(tokenBuffer.count),
                    &buffer,
                    Int32(bufferSize)
                )
            }
            
            guard bytesWritten > 0 else {
                FreeTokenLogger.shared.log("detokenize failed for \(tokens.count) tokens", level: .error)
                throw FreeToken.FreeTokenError.aiRunFailed(message: "Failed to detokenize \(tokens.count) tokens")
            }
            
            // Convert the C string to Swift String
            let data = Data(bytes: buffer, count: Int(bytesWritten))
            guard let result = String(data: data, encoding: .utf8) else {
                throw FreeToken.FreeTokenError.aiRunFailed(message: "Failed to decode detokenized text as UTF-8")
            }
            
            FreeTokenLogger.shared.log("Detokenized \(tokens.count) tokens to \(bytesWritten) bytes", level: .debug)
            return result
        }
        
        
        /// Optimized batch evaluation using C bridge
        /// - Parameters:
        ///   - tokens: Tokens to evaluate
        ///   - feedToSampler: Whether to feed tokens to sampler for penalty tracking (default true for chat, false for raw completion)
        ///   - needsLogits: Whether to calculate logits for the last token (default: true for generation, false for prompt loading)
        func evalOptimized(tokens: [Int], feedToSampler: Bool = true, needsLogits: Bool = true) async throws {
            try ensureActive()
            guard !tokens.isEmpty else { return }
    
            // DEBUG: Track position before and after
            let startPos = pos
            FreeTokenLogger.shared.log("EVAL_DEBUG: Starting eval at pos=\(startPos) for \(tokens.count) tokens, feedToSampler=\(feedToSampler)", level: .debug)
    
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
            
            // DEBUG: Confirm position advanced correctly
            FreeTokenLogger.shared.log("EVAL_DEBUG: Position advanced from \(startPos) to \(pos) (delta=\(Int32(tokens.count)))", level: .debug)
    
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed > 0 {
                let tps = Double(tokens.count) / elapsed
                FreeTokenLogger.shared.log("eval (C bridge) tokens=\(tokens.count) time=\(String(format: "%.3f", elapsed))s tps=\(String(format: "%.1f", tps)) finalPos=\(pos)", level: .debug)
            }
        }
        
        // Get templated String for chat messages
        func getTemplatedMessageString(messages: [(role: String, content: String)]) throws -> String {
            return try LlamaAPI.chatTemplateString(model: model.model, template: template, messages: messages)
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
            model.free()
            isUnloaded = true
        }

        /// Internal full reset used by managers to rebuild KV/state without destroying the underlying model+context.
        /// This avoids freeing the context/model so subsequent tokenization & eval remain valid.
        /// NOTE: Does NOT free sampler/session because they remain in use; just clears KV + sampler history and local caches.
        func resetForRebuild() {
            if isUnloaded { return }
            
            // DEBUG: Log position before reset
            let oldPos = pos
            
            // Clear KV cache for sequence 0
            let memory = llama_get_memory(context)
            llama_memory_seq_rm(memory, 0, 0, -1)
            pos = 0
            // Reset sampler penalties/history
            resetSampler()
            FreeTokenLogger.shared.log("Session resetForRebuild: cleared KV, sampler. Position reset from \(oldPos) to 0", level: .debug)
        }
        
        // MARK: Chat Template
        
        func applyChatTemplate(messages: [(role: String, content: String)], includeAssistantPrefix: Bool) throws -> [Int] {
            try ensureActive()
            return try LlamaAPI.chatApplyTemplate(model: model.model, template: template, messages: messages, addAssistant: includeAssistantPrefix).map(Int.init)
        }
        
        // MARK: State Data Management
        
        func getStateData() -> [UInt8] {
            return LlamaAPI.getStateData(context)
        }
        
        func loadStateData(_ data: [UInt8], pos: Int) throws {
            try ensureActive()
            FreeToken.shared.logger("Attempting to load state data into context", .debug)
            
            if LlamaAPI.loadStateData(context, data) {
                self.pos = Int32(pos) // Put the pointer in the right position to begin evaluating
                FreeTokenLogger.shared.log("💾 Loaded state data of size \(data.count) bytes", level: .info)
            } else {
                FreeToken.shared.logger("🔴 Failed to load state data of size \(data.count) bytes", .error)
                throw FreeToken.FreeTokenError.aiRunFailed(message: "Failed to load state data of size \(data.count) bytes")
            }
        }
        
        func writeStateToFile(fileName: String, basePath: URL, tokens: [llama_token]) throws {
            let fullPath = basePath.appending(component: configSHA256, directoryHint: .isDirectory)
            // Ensure directory exists
            try FileManager.default.createDirectory(at: fullPath, withIntermediateDirectories: true)
            let fileURL = fullPath.appendingPathComponent(fileName)
            
            if LlamaAPI.writeStateToDisk(context, path: fileURL.path, tokens: tokens) {
                FreeTokenLogger.shared.log("💾 Wrote state to file \(fileURL.path)", level: .info)
            } else {
                FreeTokenLogger.shared.log("🔴 Failed to write state to file \(fileURL.path)", level: .error)
                throw FreeTokenError.llamaFailedToWriteSessionStateToFile
            }
        }
        
        func loadStateFromFile(fileName: String, basePath: URL) throws -> (tokens: [llama_token], token_count_out: Int) {
            let fullPath = basePath.appending(component: configSHA256, directoryHint: .isDirectory)
            let fileURL = fullPath.appendingPathComponent(fileName)
            
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FreeToken.shared.logger("⚠️ State file does not exist at \(fileURL.path)", .warning)
                throw FreeTokenError.llamaFailedToReadSessionStateFromFile
            } else {
                let result = LlamaAPI.loadStateFromDisk(context, path: fileURL.path)
                pos = Int32(result.tokens.count)
                return result
            }
        }
        
    }
}

extension Data {
    func sha256Hex() -> String {
        let hash = SHA256.hash(data: self)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
