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

/// Wrapper for unsafe model pointer to make it Sendable
struct ModelHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Static model management functions
struct LlamaModel {
    /// Load a model from disk
    static func load(path: String, gpuLayers: Int32? = nil) throws -> OpaquePointer {
        // Initialize backend if needed
        LlamaAPI.backendInit()
        
        let modelParams = LlamaAPI.modelDefaultParams()
        // Optionally set GPU layers if specified
        // if let layers = gpuLayers {
        //     modelParams.n_gpu_layers = layers  // Uncomment if field exists
        // }
        
        guard let model = LlamaAPI.loadModel(path, modelParams) else {
            throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Failed to load model at \(path)")
        }
        
        FreeTokenLogger.shared.log("Model loaded from \(path)", level: .info)
        return model
    }
    
    /// Free a loaded model
    static func free(_ model: OpaquePointer) {
        LlamaAPI.freeModel(model)
        FreeTokenLogger.shared.log("Model freed", level: .debug)
    }
}

/// LlamaSession
/// Actor encapsulating llama.cpp model & context lifecycle, tokenization and evaluation.
actor LlamaSession {
    static func createSession(model: OpaquePointer, options: FreeToken.LlamaInitOptions) -> LlamaSession {
        // Wrap in sendable handle
        let handle = FreeToken.ModelHandle(pointer: model)
        // With isolated models, always use sequence ID 0
        return LlamaSession(modelHandle: handle, options: options, sequenceID: 0)
    }
    // MARK: - Underlying llama.cpp handles (opaque C pointers)
    // NOTE: Names assume standard llama.cpp C API; adjust to actual exported symbols if they differ.
    // We keep them as UnsafeMutableRawPointer? until specific typed pointers are confirmed.
    private let modelHandle: OpaquePointer  // Required at initialization
    private var contextHandle: OpaquePointer? = nil
    private var sessionHandle: OpaquePointer? = nil  // Combined context + sampler
    
    // MARK: - Lifecycle State
    private let options: FreeToken.LlamaInitOptions
    private let sequenceID: Int32  // Unique ID for this session's KV cache
    private var isLoaded = false
    private var pos: Int32 = 0
    private var chatTemplate: String? = nil // explicit override (nil -> use model default)
    private var detectedStyle: FreeToken.ChatTemplateStyle? = nil // Cached detected style
    // Performance caches
    private var promptBatch: llama_batch? = nil
    private var promptBatchCapacity: Int32 = 0
    private var detokCache: [Int32: String] = [:]
    private var detokCacheHits: Int = 0
    private var detokCacheMiss: Int = 0
    private var detokTimeTotal: TimeInterval = 0
    
    init(model: OpaquePointer, options: FreeToken.LlamaInitOptions) {
        self.modelHandle = model
        self.options = options
        // With isolated models, always use sequence ID 0
        self.sequenceID = 0
        FreeTokenLogger.shared.log("LlamaSession created with isolated model", level: .debug)
    }
    
    /// Initialize with sendable wrapper (for crossing actor boundaries)
    private init(modelHandle: FreeToken.ModelHandle, options: FreeToken.LlamaInitOptions, sequenceID: Int32) {
        self.modelHandle = modelHandle.pointer
        self.options = options
        self.sequenceID = sequenceID
        FreeTokenLogger.shared.log("LlamaSession created with isolated model (seq=\(sequenceID))", level: .debug)
    }
    
    /// Lazy-load context if not already loaded.
    func loadIfNeeded() throws {
        guard !isLoaded else { return }
        
        // Create context params
        var ctxParams = LlamaAPI.contextDefaultParams()
        ctxParams.n_ctx = UInt32(options.contextSize)
        ctxParams.n_seq_max = UInt32(options.maxSequences)  // Allow configured number of parallel sequences
        if let th = options.threadCount, th > 0 { ctxParams.n_threads = Int32(th) }
        if let thb = options.threadCountBatch, thb > 0 { ctxParams.n_threads_batch = Int32(thb) }
        if let bs = options.batchSize, bs > 0 { ctxParams.n_batch = UInt32(bs) }
        // Disable sliding window attention full state if supported (mirrors previous LocalLLMClient setting)
        // If the field is not present in the current llama_context_params version this line may need adjusting.
        ctxParams.swa_full = false
        
        guard let ctx = LlamaAPI.newContext(modelHandle, ctxParams) else {
            throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "context creation failed")
        }
        self.contextHandle = ctx
        
        // Create session with sampler
        var samplerConfig = freetoken_sampling_config()
        samplerConfig.temperature = options.temperature
        samplerConfig.top_k = Int32(options.topK)
        samplerConfig.top_p = options.topP
        samplerConfig.min_p = 0.0  // Disabled by default
        samplerConfig.typical_p = 0.0  // Disabled by default
        samplerConfig.repeat_penalty = options.repeatPenalty
        samplerConfig.repeat_last_n = Int32(options.repeatLastN)
        samplerConfig.frequency_penalty = options.frequencyPenalty
        samplerConfig.presence_penalty = options.presencePenalty
        samplerConfig.mirostat = 0  // Disabled by default
        samplerConfig.mirostat_tau = 5.0  // Default target entropy
        samplerConfig.mirostat_eta = 0.1  // Default learning rate
        if let seed = options.seed {
            samplerConfig.seed = seed
            samplerConfig.use_seed = true
        } else {
            samplerConfig.use_seed = false
        }
        
        guard let session = freetoken_session_create(
            UnsafeMutableRawPointer(modelHandle), 
            UnsafeMutableRawPointer(ctx), 
            samplerConfig
        ) else {
            LlamaAPI.freeContext(ctx)
            throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "session creation failed")
        }
        self.sessionHandle = session
        // Pre-allocate prompt batch for better performance
        let batchCap = Int32(options.batchSize ?? 512)
        promptBatchCapacity = batchCap
        promptBatch = llama_batch_init(promptBatchCapacity, 0, 1)
        isLoaded = true
    // If model supplies internal template it will be used with nil argument.

        // Heuristic chat marker detection to clarify which style the model vocabulary supports.
        // This helps explain why a certain template (e.g. Llama3 <|im_start|>) appears while using a Gemma model.
        let markerGroups: [(name: String, markers: [String])] = [
            ("llama3", ["<|im_start|>", "<|im_end|>"]),
            ("gemma", ["<start_of_turn>", "<end_of_turn>"]),
            ("mistral", ["[INST]", "[/INST]"])
        ]
        var recognized: [String] = []
        for group in markerGroups {
            var singleTokenAll = true
            var anyPresent = false
            for m in group.markers {
                if let toks = try? LlamaAPI.tokenize(model: modelHandle, text: m, addBos: false, special: true) {
                    anyPresent = anyPresent || !toks.isEmpty
                    if toks.count != 1 { singleTokenAll = false }
                } else {
                    singleTokenAll = false
                }
            }
            if anyPresent {
                recognized.append("\(group.name):singleTokenAll=\(singleTokenAll)")
            }
        }
        FreeTokenLogger.shared.log("CHAT_MARKERS vocab_probe recognized=[\(recognized.joined(separator: ", "))] (nil template -> llama_chat_apply_template auto)", level: .info)
        
        // Detect template style if using auto
        if options.chatStyle == .auto {
            detectedStyle = detectChatTemplateStyle()
            FreeTokenLogger.shared.log("Template auto-detected: \(String(describing: detectedStyle))", level: .info)
        }
    }
    
    /// Detect the chat template style from the model
    private func detectChatTemplateStyle() -> FreeToken.ChatTemplateStyle {
        // First try to get the model's built-in template
        if let modelTemplate = LlamaAPI.modelChatTemplate(modelHandle) {
            // Detect based on template content
            return LlamaAPI.detectTemplateStyle(from: modelTemplate)
        }
        
        // Fallback: Check for specific token markers in vocabulary
        // This is a simpler heuristic based on what tokens are recognized
        let testMarkers: [(style: FreeToken.ChatTemplateStyle, markers: [String])] = [
            (.llama3, ["<|start_header_id|>", "<|end_header_id|>"]),
            (.chatml, ["<|im_start|>", "<|im_end|>"]),
            (.gemma, ["<start_of_turn>", "<end_of_turn>"]),
            (.mistralV1, ["[INST]", "[/INST]"]),
            (.phi3, ["<|user|>", "<|assistant|>"])
        ]
        
        for (style, markers) in testMarkers {
            var allFound = true
            for marker in markers {
                if let toks = try? LlamaAPI.tokenize(model: modelHandle, text: marker, addBos: false, special: true),
                   toks.isEmpty {
                    allFound = false
                    break
                }
            }
            if allFound {
                return style
            }
        }
        
        // Default fallback
        return .chatml
    }
    
    /// Tokenize text -> token ids
    @inline(__always)
    func tokenize(_ text: String) async throws -> [Int] {
        try loadIfNeeded()
        do {
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: text, addBos: false, special: false)
            return toks.map(Int.init)
        } catch {
            FreeTokenLogger.shared.log("tokenize failed len=\(text.utf8.count) error=\(error)", level: .error)
            throw error
        }
    }
    
    /// Get the EOS token ID for the model
    func getEOSToken() -> Int32 {
        guard let vocab = llama_model_get_vocab(modelHandle) else { return -1 }
        return llama_vocab_eos(vocab)
    }
    
    /// Get the EOT (end-of-turn) token ID for the model
    func getEOTToken() -> Int32 {
        guard let vocab = llama_model_get_vocab(modelHandle) else { return -1 }
        return llama_vocab_eot(vocab)
    }
    
    /// Get all stop tokens (EOS, EOT) for the model
    func getStopTokens() -> Set<Int32> {
        guard let vocab = llama_model_get_vocab(modelHandle) else { return [] }
        var tokens = Set<Int32>()
        let eos = llama_vocab_eos(vocab)
        let eot = llama_vocab_eot(vocab)
        if eos >= 0 { tokens.insert(eos) }
        if eot >= 0 { tokens.insert(eot) }
        return tokens
    }
    
    /// Evaluate a batch of tokens with optimized batching
    func eval(tokens: [Int]) async throws {
        guard !tokens.isEmpty else { return }
        try loadIfNeeded()
        guard let contextHandle else { throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Context nil") }
        let start = CFAbsoluteTimeGetCurrent()
        
        // Convert once and reuse
        let converted = tokens.map { LlamaToken($0) }
        
        guard var batch = promptBatch else { throw FreeToken.FreeTokenError.aiRunFailed(message: "prompt batch nil") }
        
        var offset = 0
        while offset < converted.count {
            let remaining = converted.count - offset
            let take = min(Int(promptBatchCapacity), remaining)
            
            // Fill batch directly without closure to avoid isolation issues
            for i in 0..<take {
                batch.token[i] = converted[offset + i]
                batch.pos[i] = pos + Int32(offset + i)
                batch.n_seq_id[i] = 1
                if let seqPtr = batch.seq_id[i] { seqPtr[0] = sequenceID }
                batch.logits[i] = (i == take - 1) ? 1 : 0
            }
            
            batch.n_tokens = Int32(take)
            let rc = llama_decode(contextHandle, batch)
            if rc != 0 { throw FreeToken.FreeTokenError.aiRunFailed(message: "eval batch rc=\(rc) offset=\(offset) take=\(take)") }
            offset += take
        }
        
        pos += Int32(converted.count)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed > 0 {
            let tps = Double(converted.count) / elapsed
            FreeTokenLogger.shared.log("eval(prompt) tokens=\(converted.count) ms=\(Int(elapsed*1000)) tps=\(String(format: "%.2f", tps)) batchSize=\(promptBatchCapacity)", level: .debug)
        }
    }
    
    /// Optimized batch evaluation using C bridge
    /// - Parameters:
    ///   - tokens: Tokens to evaluate
    ///   - feedToSampler: Whether to feed tokens to sampler for penalty tracking (default true for chat, false for raw completion)
    func evalOptimized(tokens: [Int], feedToSampler: Bool = true) async throws {
        guard !tokens.isEmpty else { return }
        try loadIfNeeded()
        guard let contextHandle else { throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Context nil") }
        
        let start = CFAbsoluteTimeGetCurrent()
        
        // Convert to Int32 and use C bridge
        let converted = tokens.map { Int32($0) }
        let processed: Int32
        
        if feedToSampler, let sessionHandle = self.sessionHandle {
            // Use session-based eval that also feeds tokens to sampler for repetition penalty tracking
            processed = converted.withUnsafeBufferPointer { buffer in
                freetoken_eval_batch_with_session(
                    sessionHandle,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    pos,
                    Int32(options.batchSize ?? 512),
                    sequenceID
                )
            }
        } else {
            // Use regular eval (for cases where we don't have a session yet or don't need penalty tracking)
            processed = converted.withUnsafeBufferPointer { buffer in
                freetoken_eval_batch(
                    UnsafeMutableRawPointer(contextHandle),
                    buffer.baseAddress,
                    Int32(buffer.count),
                    pos,
                    Int32(options.batchSize ?? 512),
                    sequenceID
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
        try loadIfNeeded()
        guard let sessionHandle else { 
            throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "Session nil") 
        }
        
        // Call C bridge with session (sampler is already configured)
        let result = freetoken_generate_next(
            sessionHandle,
            UnsafeMutableRawPointer(modelHandle),
            pos,
            sequenceID
        )
            
        guard result.success else {
            throw FreeToken.FreeTokenError.aiRunFailed(message: "C bridge generation failed")
        }
        
        // Detokenize using fast C implementation
        var textBuffer = [CChar](repeating: 0, count: 256)
        let textLen = freetoken_token_to_piece_fast(
            UnsafeMutableRawPointer(modelHandle),
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

    /// Combined operation: sample + eval + detokenize in minimal FFI calls
    // REMOVED: Old generateNextToken function that used Swift-based sampling
    // Now using generateNextTokenOptimized with native llama_sampler chain
    

    // MARK: - KV Cache Low-Level Operations
    // (Removed KV cache direct ops for now; future: implement with correct symbols from embedded framework)
    
    // MARK: - Detokenization
    @inline(__always)
    func detokenize(tokens: [Int32]) -> String {
        // modelHandle is always available now
        let startT = CFAbsoluteTimeGetCurrent()  // Faster than Date()
        var out = String(); out.reserveCapacity(tokens.count * 4)
        for t in tokens {
            if let piece = detokCache[t] { 
                detokCacheHits += 1
                out += piece
                continue 
            }
            let piece = LlamaAPI.tokenToPiece(model: modelHandle, token: t)
            detokCache[t] = piece
            detokCacheMiss += 1
            out += piece
        }
        detokTimeTotal += CFAbsoluteTimeGetCurrent() - startT
        return out
    }
    
    /// Tokenize multiple texts in parallel (safe since it's read-only)
    func tokenizeParallel(_ texts: [String]) async throws -> [[Int]] {
        try loadIfNeeded()
        
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
    
    /// Reset the sampler state (clears token history for penalties)
    /// Use this for stateless operations like raw completion
    func resetSampler() {
        guard let sessionHandle else { return }
        freetoken_session_reset_sampler(sessionHandle)
        FreeTokenLogger.shared.log("Sampler reset for stateless generation", level: .debug)
    }
    
    /// Clear the entire KV cache
    func clearKVCache() async {
        guard let ctx = contextHandle else { return }
        let memory = llama_get_memory(ctx)
        // Remove all tokens for this sequence (p1 = -1 means to end)
        llama_memory_seq_rm(memory, sequenceID, 0, -1)
        pos = 0
        FreeTokenLogger.shared.log("KV cache cleared for sequence \(sequenceID)", level: .debug)
    }
    
    /// Remove tokens from KV cache in the given range [from, to)
    func removeKVCacheTokens(from: Int32, to: Int32) async throws {
        guard let ctx = contextHandle else { 
            throw FreeToken.FreeTokenError.aiRunFailed(message: "No context for KV cache operation")
        }
        let memory = llama_get_memory(ctx)
        let success = llama_memory_seq_rm(memory, sequenceID, from, to)
        if !success {
            throw FreeToken.FreeTokenError.aiRunFailed(message: "Failed to remove KV cache tokens [\(from),\(to))")
        }
        FreeTokenLogger.shared.log("Removed KV cache tokens [\(from),\(to)) for sequence \(sequenceID)", level: .debug)
    }
    
    /// Shift tokens in KV cache by adding delta to their positions
    /// from: starting position (inclusive)
    /// count: number of tokens to shift
    /// by: delta to add to positions (negative to shift left, positive to shift right)
    func shiftKVCacheTokens(from startPos: Int32, count: Int32, by delta: Int32) async throws {
        guard let ctx = contextHandle else {
            throw FreeToken.FreeTokenError.aiRunFailed(message: "No context for KV cache operation")
        }
        let memory = llama_get_memory(ctx)
        
        // Use llama_memory_seq_add to shift positions
        // This adds 'delta' to all token positions in the range [startPos, startPos + count)
        let endPos = count < 0 ? -1 : startPos + count  // -1 means to end
        llama_memory_seq_add(memory, sequenceID, startPos, endPos, delta)
        
        // Update our position tracker if needed
        if pos > startPos {
            pos = max(0, pos + delta)
        }
        
        FreeTokenLogger.shared.log("Shifted KV cache tokens from=\(startPos) count=\(count) by=\(delta) for sequence \(sequenceID)", level: .debug)
    }
    
    /// Free underlying context resources (model is managed externally).
    func unload() {
        // Free session (which includes sampler)
        if let session = sessionHandle {
            freetoken_session_free(session)
            sessionHandle = nil
        }
        // Free context
        if let ctx = contextHandle {
            LlamaAPI.freeContext(ctx)
        }
        contextHandle = nil
        pos = 0
        chatTemplate = nil
        if let pb = promptBatch { llama_batch_free(pb); promptBatch = nil; promptBatchCapacity = 0 }
        detokCache.removeAll(); detokCacheHits = 0; detokCacheMiss = 0; detokTimeTotal = 0
        isLoaded = false
    }

    // Apply embedded chat template to messages -> token ids. Adds assistant prefix slot if requested.
    func applyChatTemplate(messages: [(role: String, content: String)], includeAssistantPrefix: Bool) throws -> [Int] {
        try loadIfNeeded()
        guard options.useChatTemplate else { throw FreeToken.FreeTokenError.aiRunFailed(message: "applyChatTemplate called but disabled") }
        // modelHandle is always available now
        
        // Determine which style to use
        let styleToUse: FreeToken.ChatTemplateStyle
        if options.chatStyle == .auto {
            styleToUse = detectedStyle ?? .chatml
        } else {
            styleToUse = options.chatStyle
        }
        
        // Manual selection based on determined style.
        switch styleToUse {
        case .auto:
            // Should never reach here as we resolve auto above
            let toks = try LlamaAPI.chatApplyTemplate(model: modelHandle, template: chatTemplate, messages: messages, addAssistant: includeAssistantPrefix)
            return toks.map { Int($0) }
            
        case .chatml:
            // ChatML format: <|im_start|>role\ncontent<|im_end|>\n
            var builder = String()
            for (role, content) in messages {
                builder += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
            }
            if includeAssistantPrefix {
                builder += "<|im_start|>assistant\n"
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
            
        case .llama2:
            // Basic Llama 2 format without system support
            var builder = String()
            for (role, content) in messages {
                if role == "user" {
                    builder += "[INST] \(content) [/INST]"
                } else if role == "assistant" {
                    builder += " \(content) </s>"
                }
            }
            if includeAssistantPrefix {
                builder += " "
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: true, special: true)
            return toks.map { Int($0) }
            
        case .llama2Sys:
            // Llama 2 with system message support
            var builder = String()
            var hasSystem = false
            
            for (role, content) in messages {
                if role == "system" && !hasSystem {
                    builder = "[INST] <<SYS>>\n\(content)\n<</SYS>>\n\n"
                    hasSystem = true
                } else if role == "user" {
                    if hasSystem {
                        builder += "\(content) [/INST]"
                        hasSystem = false
                    } else {
                        builder += "[INST] \(content) [/INST]"
                    }
                } else if role == "assistant" {
                    builder += " \(content) </s>"
                }
            }
            if includeAssistantPrefix {
                builder += " "
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: true, special: true)
            return toks.map { Int($0) }
            
        case .llama3:
            // Use llama.cpp's native template application for Llama 3
            let toks = try LlamaAPI.chatApplyTemplate(model: modelHandle, template: chatTemplate, messages: messages, addAssistant: includeAssistantPrefix)
            return toks.map { Int($0) }
        case .gemma:
            // Gemma format typical:
            // <start_of_turn>user\n...<end_of_turn>\n<start_of_turn>model\n (assistant content...) <end_of_turn>
            // We only build the prompt up to (optionally) assistant prefix slot.
            var builder = String()
            for (r,c) in messages {
                let role = (r == "assistant" ? "model" : r) // gemma uses 'model' for assistant role
                builder += "<start_of_turn>" + role + "\n" + c + "<end_of_turn>\n"
            }
            if includeAssistantPrefix {
                builder += "<start_of_turn>model\n" // model response begins
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
        case .mistralV1:
            // Mistral V1 format
            var builder = String()
            for (role, content) in messages {
                if role == "user" {
                    builder += " [INST] \(content) [/INST]"
                } else if role == "assistant" {
                    builder += "\(content)</s>"
                }
            }
            if includeAssistantPrefix {
                builder += " "
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: true, special: true)
            return toks.map { Int($0) }
            
        case .mistralV3:
            // Mistral V3 format - similar to V1 but with tool support
            var builder = String()
            for (role, content) in messages {
                if role == "user" {
                    builder += "[INST] \(content) [/INST]"
                } else if role == "assistant" {
                    builder += "\(content)</s>"
                }
            }
            if includeAssistantPrefix {
                builder += " "
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
            
        case .mistralV7:
            // Mistral V7 format with SYSTEM_PROMPT
            var builder = String()
            for (role, content) in messages {
                if role == "system" {
                    builder += "[SYSTEM_PROMPT] \(content)[/SYSTEM_PROMPT]"
                } else if role == "user" {
                    builder += "[INST] \(content)[/INST]"
                } else if role == "assistant" {
                    builder += " \(content)</s>"
                }
            }
            if includeAssistantPrefix {
                builder += " "
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
            
        case .phi3:
            // Phi-3 format
            var builder = String()
            for (role, content) in messages {
                if role == "system" {
                    builder += "<|system|>\n\(content)<|end|>\n"
                } else if role == "user" {
                    builder += "<|user|>\n\(content)<|end|>\n"
                } else if role == "assistant" {
                    builder += "<|assistant|>\n\(content)<|end|>\n"
                }
            }
            if includeAssistantPrefix {
                builder += "<|assistant|>\n"
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
            
        case .phi4:
            // Phi-4 format (similar to ChatML but with <|im_sep|>)
            var builder = String()
            for (role, content) in messages {
                builder += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
            }
            if includeAssistantPrefix {
                builder += "<|im_start|>assistant\n"
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
            
        case .deepseek, .deepseek2:
            // DeepSeek format
            var builder = String()
            for (role, content) in messages {
                if role == "user" {
                    builder += "User: \(content)\n\n"
                } else if role == "assistant" {
                    builder += "Assistant: \(content)\n\n"
                } else if role == "system" {
                    builder += "\(content)\n\n"
                }
            }
            if includeAssistantPrefix {
                builder += "Assistant: "
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: true, special: false)
            return toks.map { Int($0) }
            
        case .commandR:
            // Command-R format
            var builder = String()
            for (role, content) in messages {
                builder += "<|START_OF_TURN_TOKEN|><|\(role.uppercased())_TOKEN|>\(content)<|END_OF_TURN_TOKEN|>"
            }
            if includeAssistantPrefix {
                builder += "<|START_OF_TURN_TOKEN|><|ASSISTANT_TOKEN|>"
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
            
        case .vicuna:
            // Vicuna format
            var builder = String()
            for (role, content) in messages {
                if role == "system" {
                    builder += "\(content)\n\n"
                } else if role == "user" {
                    builder += "USER: \(content)\n"
                } else if role == "assistant" {
                    builder += "ASSISTANT: \(content)\n"
                }
            }
            if includeAssistantPrefix {
                builder += "ASSISTANT: "
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: true, special: false)
            return toks.map { Int($0) }
            
        case .alpaca:
            // Alpaca format
            var builder = String()
            var systemMsg = ""
            
            for (role, content) in messages {
                if role == "system" {
                    systemMsg = content
                } else if role == "user" {
                    if !systemMsg.isEmpty {
                        builder += "### Instruction:\n\(systemMsg)\n\n\(content)\n\n"
                        systemMsg = ""
                    } else {
                        builder += "### Instruction:\n\(content)\n\n"
                    }
                } else if role == "assistant" {
                    builder += "### Response:\n\(content)\n\n"
                }
            }
            if includeAssistantPrefix {
                builder += "### Response:\n"
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: true, special: false)
            return toks.map { Int($0) }
            
        case .zephyr:
            // Zephyr format
            var builder = String()
            for (role, content) in messages {
                builder += "<|\(role)|>\n\(content)</s>\n"
            }
            if includeAssistantPrefix {
                builder += "<|assistant|>\n"
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
            
        case .openchat:
            // OpenChat format
            var builder = String()
            for (role, content) in messages {
                if role == "user" {
                    builder += "GPT4 Correct User: \(content)<|end_of_turn|>"
                } else if role == "assistant" {
                    builder += "GPT4 Correct Assistant: \(content)<|end_of_turn|>"
                }
            }
            if includeAssistantPrefix {
                builder += "GPT4 Correct Assistant:"
            }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: builder, addBos: false, special: true)
            return toks.map { Int($0) }
        case .raw:
            // Minimal raw: "system: ...\nuser: ...\nassistant: "
            var out = String()
            for (r,c) in messages { out += r + ": " + c + "\n" }
            if includeAssistantPrefix { out += "assistant: " }
            let toks = try LlamaAPI.tokenize(model: modelHandle, text: out, addBos: false, special: false)
            return toks.map { Int($0) }
        }
    }
}
}
