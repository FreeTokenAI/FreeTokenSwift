//
//  LlamaManager.swift
//  FreeToken
//
//  Token-based KV cache management with sliding window support
//  Simplified architecture that tracks raw token positions instead of message boundaries
//

import Foundation

extension FreeToken {
    /// LlamaManager - Token-based KV cache manager
    /// ---------------------------------
    /// Manages a single llama.cpp session with token-based KV cache sliding.
    /// No message boundary tracking - just raw token positions for simplicity.
    final class LlamaManager: @unchecked Sendable {
        private let session: LlamaSession
        private let options: LlamaInitOptions
        private var busy: Bool = false
        private let sequenceId: Int32 = 0 // single sequence
        
        // Token position tracking (simple and clean)
        private var n_past: Int32 = 0      // Total tokens currently in context
        private var n_keep: Int32 = 0      // Tokens to preserve during sliding (calculated from first message)
        private var messages: [Message] = [] // Keep messages for reference only
        private var templatedTokens: [Int32] = [] // Current templated tokens in KV cache
        
        private var isUnloaded: Bool = false
        
        // Sliding configuration
        private let slidingRatio: Float = 0.5  // Remove 50% of available tokens when sliding

        @inline(__always)
        private func ensureActive(_ fn: StaticString = #function) throws {
            if isUnloaded { throw FreeTokenError.aiRunFailed(message: "LlamaManager was unloaded; call site: \(fn)") }
        }
        
        init(modelPath: String, options: LlamaInitOptions) throws {
            // Load model separately
            let model = try FreeToken.LlamaModel(path: modelPath)
            // Use static factory to avoid sendability issues
            self.session = try LlamaSession(model: model, config: options)
            self.options = options
            
            FreeTokenLogger.shared.log("KV_SLIDING: LlamaManager initialized with contextSize=\(options.contextSize)", level: .info)
        }
        
        // Public read-only access to messages (without token tracking)
        var currentMessages: [Message] {
            return messages
        }
        
        // MARK: - Simple Templating Functions
        
        /// Template messages and return tokens - no state management needed
        private func templateMessages(_ messages: [Message]) async throws -> [Int32] {
            let compact = messages.map { ($0.role.rawValue, $0.content) }
            let tokens = try await session.applyChatTemplate(
                messages: compact,
                includeAssistantPrefix: false
            )
            return tokens.map { Int32($0) }
        }
        
        /// Template messages with assistant slot for generation
        private func templateWithAssistantSlot(_ messages: [Message]) async throws -> [Int32] {
            let compact = messages.map { ($0.role.rawValue, $0.content) }
            let tokens = try await session.applyChatTemplate(
                messages: compact,
                includeAssistantPrefix: true
            )
            return tokens.map { Int32($0) }
        }
        
        // MARK: - Simplified Context Update
        
        /// Update context with new messages using token-based approach
        func updateContext(messages desired: [Message]) async throws {
            try ensureActive()
            
            FreeTokenLogger.shared.log("KV_SLIDING: updateContext start desired=\(desired.count) n_past=\(n_past) n_keep=\(n_keep)", level: .debug)
            
            // Guard multimodal
            if desired.contains(where: { msg in (msg.attachments?.contains { $0.type == .image }) == true }) {
                throw FreeTokenError.llamaMultimodalNotSupported
            }
            
            // Fast equality check
            if messages.count == desired.count && 
               zip(messages, desired).allSatisfy({ $0.0.role == $0.1.role && $0.0.content == $0.1.content }) {
                FreeTokenLogger.shared.log("KV_SLIDING: updateContext no-op (identical messages)", level: .info)
                return
            }
            
            // For simplicity: if messages changed significantly, rebuild
            let needsRebuild = messages.count > desired.count || 
                              (messages.count > 0 && desired.count > 0 && messages[0].content != desired[0].content)
            
            if needsRebuild {
                FreeTokenLogger.shared.log("KV_SLIDING: Full rebuild required - resetting context", level: .warning)
                await session.resetForRebuild()
                n_past = 0
                n_keep = 0
                messages.removeAll()
                templatedTokens.removeAll()
            }
            
            // Check if we're just appending new messages (common case)
            let messagesToAdd = Array(desired.dropFirst(messages.count))
            
            if messagesToAdd.isEmpty && !needsRebuild {
                // No changes needed
                return
            }
            
            // Template all messages
            let allTokens = try await templateMessages(desired)
            
            FreeTokenLogger.shared.log("KV_SLIDING: Templated \(desired.count) messages into \(allTokens.count) tokens", level: .info)
            
            // If this is an append operation, only evaluate the new tokens
            if !needsRebuild && !messagesToAdd.isEmpty {
                // Find the delta tokens to evaluate
                let deltaTokens = Array(allTokens.dropFirst(templatedTokens.count))
                
                if !deltaTokens.isEmpty {
                    FreeTokenLogger.shared.log("KV_SLIDING: Evaluating \(deltaTokens.count) new tokens", level: .debug)
                    
                    // Don't calculate logits here - they'll be calculated in generate() after assistant slot
                    // Don't feed to sampler - these are context tokens, not generated tokens
                    try await session.evalOptimized(tokens: deltaTokens.map { Int($0) }, feedToSampler: false, needsLogits: false)
                }
            } else {
                // Full evaluation needed (rebuild case)
                FreeTokenLogger.shared.log("KV_SLIDING: Full evaluation of \(allTokens.count) tokens", level: .debug)
                
                // Don't calculate logits here - they'll be calculated in generate() after assistant slot
                // Don't feed to sampler - these are context tokens, not generated tokens
                try await session.evalOptimized(tokens: allTokens.map { Int($0) }, feedToSampler: false, needsLogits: false)
            }
            
            // Update state
            templatedTokens = allTokens
            n_past = Int32(allTokens.count)
            messages = desired
            
            // Calculate n_keep from first message if not set
            if n_keep == 0 && !desired.isEmpty {
                let firstMessageTokens = try await templateMessages([desired[0]])
                n_keep = Int32(firstMessageTokens.count)
                FreeTokenLogger.shared.log("KV_SLIDING: Calculated n_keep=\(n_keep) from first message", level: .info)
            }
            
            FreeTokenLogger.shared.log("KV_SLIDING: Context updated - n_past=\(n_past) n_keep=\(n_keep) totalMessages=\(messages.count)", level: .info)
            
            // Check if we're approaching context limit
            let headroom = options.contextSize - Int(n_past)
            if headroom < options.maxNewTokens {
                FreeTokenLogger.shared.log("KV_SLIDING: WARNING - Low headroom=\(headroom) maxNew=\(options.maxNewTokens)", level: .warning)
            }
        }
        
        // MARK: - KV Cache Sliding
        
        /// Perform KV cache sliding when context is full
        /// This follows llama.cpp's main.cpp sliding logic exactly
        private func performKVSliding() async throws {
            try ensureActive()
            
            guard n_keep > 0 else {
                FreeTokenLogger.shared.log("KV_SLIDING: ERROR - Cannot slide without n_keep set", level: .error)
                throw FreeTokenError.aiRunFailed(message: "KV sliding requires n_keep to be set")
            }
            
            let n_left = n_past - n_keep  // Tokens available for removal
            guard n_left > 0 else {
                FreeTokenLogger.shared.log("KV_SLIDING: No tokens available to slide (n_left=0)", level: .warning)
                return
            }
            
            let n_discard = Int32(Float(n_left) * slidingRatio)  // Remove half of available space
            
            FreeTokenLogger.shared.log("KV_SLIDING: Starting slide - n_past=\(n_past) n_keep=\(n_keep) n_left=\(n_left) n_discard=\(n_discard)", level: .info)
            
            // Remove tokens from position n_keep to n_keep + n_discard
            let removeStart = n_keep
            let removeEnd = n_keep + n_discard
            
            FreeTokenLogger.shared.log("KV_SLIDING: Removing tokens [\(removeStart), \(removeEnd))", level: .debug)
            try await session.removeKVCacheTokens(from: removeStart, to: removeEnd)
            
            // Shift remaining tokens backward by n_discard positions
            let shiftStart = removeEnd
            let shiftCount: Int32 = -1  // -1 means shift to end
            
            FreeTokenLogger.shared.log("KV_SLIDING: Shifting tokens from \(shiftStart) by -\(n_discard)", level: .debug)
            try await session.shiftKVCacheTokens(from: shiftStart, count: shiftCount, by: -n_discard)
            
            // Update position tracking
            n_past -= n_discard
            
            // Note: We don't update templatedTokens as they represent the logical message tokens,
            // not the physical KV cache state after sliding
            
            FreeTokenLogger.shared.log("KV_SLIDING: Slide complete - new n_past=\(n_past) (removed \(n_discard) tokens)", level: .info)
        }
        
        // MARK: - Generation with Sliding Support
        
        struct GenerationMetrics {
            var start: Date = Date()
            var firstToken: Date? = nil
            var end: Date? = nil
            var producedTokens: Int = 0
            var slidingOccurred: Bool = false
            var slidingCount: Int = 0
            var committed: Bool = false
            var canceled: Bool = false
            var stopReason: String? = nil
            var tokensPerSecond: Double? = nil
            var firstTokenLatency: TimeInterval? = nil
            var avgTokenLatency: TimeInterval? = nil
            var sampleTimeTotal: TimeInterval = 0
            var evalTimeTotal: TimeInterval = 0
        }
        
        private(set) var lastGenerationMetrics: GenerationMetrics? = nil
        
        /// Streaming generation with automatic KV cache sliding
        func generate() async throws -> AsyncThrowingStream<String, Error> {
            try ensureActive()
            
            // Check initial capacity
            let initialHeadroom = options.contextSize - Int(n_past)
            FreeTokenLogger.shared.log("KV_SLIDING: generate start n_past=\(n_past) headroom=\(initialHeadroom) maxNew=\(options.maxNewTokens)", level: .info)
            
            if initialHeadroom <= 0 {
                throw FreeTokenError.llamaContextOverflow
            }
            
            // Get tokens with assistant slot
            let withSlot = try await templateWithAssistantSlot(messages)
            
            // Find the assistant slot tokens (delta from current state)
            let assistantSlotTokens = Array(withSlot.dropFirst(templatedTokens.count))
            
            if !assistantSlotTokens.isEmpty {
                FreeTokenLogger.shared.log("KV_SLIDING: Evaluating \(assistantSlotTokens.count) assistant slot tokens", level: .debug)
                
                // Evaluate all assistant slot tokens in one batch
                // The C bridge will handle logits efficiently (only for last token when needsLogits=true)
                // Feed to sampler since these are part of generation
                let slotTokensInt = assistantSlotTokens.map { Int($0) }
                try await session.evalOptimized(tokens: slotTokensInt, feedToSampler: true, needsLogits: true)
                
                n_past += Int32(assistantSlotTokens.count)
            }
            
            return AsyncThrowingStream { continuation in
                Task {
                    var emitted = ""
                    var stopHit = false
                    var metrics = GenerationMetrics()
                    var generated: [Int32] = []
                    
                    // Note: Assistant prefix is already included in the template with includeAssistantPrefix: true
                    // No need to evaluate it separately
                    
                    do {
                        let stopTokens = await session.getStopTokens()
                        var recentText = ""
                        
                        // Main generation loop
                        for tokenIndex in 0..<options.maxNewTokens {
                            // Check for context fullness BEFORE generating next token
                            if n_past >= options.contextSize {
                                FreeTokenLogger.shared.log("KV_SLIDING: Context full at token \(tokenIndex) - triggering slide", level: .warning)
                                try await self.performKVSliding()
                                metrics.slidingOccurred = true
                                metrics.slidingCount += 1
                            }
                            
                            if Task.isCancelled {
                                metrics.canceled = true
                                metrics.stopReason = "canceled"
                                break
                            }
                            
                            // Generate next token
                            guard let result = try await session.generateNextTokenOptimized() else {
                                throw FreeTokenError.aiRunFailed(message: "Generation failed")
                            }
                            
                            let nextToken = result.token
                            let piece = result.text
                            
                            generated.append(nextToken)
                            n_past += 1  // Increment position after generation
                            metrics.producedTokens += 1
                            
                            // Track metrics
                            metrics.sampleTimeTotal += TimeInterval(result.sampleMs / 1000.0)
                            metrics.evalTimeTotal += TimeInterval(result.evalMs / 1000.0)
                            
                            if metrics.firstToken == nil {
                                metrics.firstToken = Date()
                                metrics.firstTokenLatency = metrics.firstToken!.timeIntervalSince(metrics.start)
                                FreeTokenLogger.shared.log("KV_SLIDING: First token latency=\(String(format: "%.3f", metrics.firstTokenLatency!))s", level: .info)
                            }
                            
                            // Check stop conditions
                            if stopTokens.contains(nextToken) {
                                FreeTokenLogger.shared.log("KV_SLIDING: Hit stop token \(nextToken)", level: .info)
                                metrics.stopReason = "stopToken"
                                break
                            }
                            
                            // Emit token
                            if !piece.isEmpty {
                                emitted += piece
                                continuation.yield(piece)
                                
                                // Track for repetition detection
                                recentText += piece
                                if recentText.count > 300 {
                                    recentText = String(recentText.suffix(300))
                                }
                                
                                // Simplified repetition detection
                                if recentText.count >= 100 {
                                    let minSequenceLength = 25
                                    let textToCheck = recentText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    
                                    for startIdx in textToCheck.indices {
                                        guard textToCheck.distance(from: startIdx, to: textToCheck.endIndex) >= minSequenceLength else { break }
                                        
                                        let endIdx = textToCheck.index(startIdx, offsetBy: minSequenceLength)
                                        let sequence = String(textToCheck[startIdx..<endIdx])
                                        
                                        var positions: [String.Index] = []
                                        var searchRange = textToCheck.startIndex..<textToCheck.endIndex
                                        
                                        while let range = textToCheck.range(of: sequence, options: .literal, range: searchRange) {
                                            positions.append(range.lowerBound)
                                            searchRange = range.upperBound..<textToCheck.endIndex
                                        }
                                        
                                        if positions.count >= 3 {
                                            var consecutiveCount = 1
                                            for i in 1..<positions.count {
                                                let distance = textToCheck.distance(from: positions[i-1], to: positions[i])
                                                if distance <= minSequenceLength * 2 {
                                                    consecutiveCount += 1
                                                    if consecutiveCount >= 3 {
                                                        FreeTokenLogger.shared.log("KV_SLIDING: Detected repetition, stopping", level: .warning)
                                                        metrics.stopReason = "repetition"
                                                        break
                                                    }
                                                } else {
                                                    consecutiveCount = 1
                                                }
                                            }
                                            if metrics.stopReason == "repetition" { break }
                                        }
                                    }
                                    
                                    if metrics.stopReason == "repetition" { break }
                                }
                            }
                            
                            // Check stop sequences
                            if !options.stopSequences.isEmpty {
                                for stop in options.stopSequences {
                                    if emitted.hasSuffix(stop) {
                                        stopHit = true
                                        metrics.stopReason = "stopSequence"
                                        break
                                    }
                                }
                            }
                            if stopHit { break }
                        }
                        
                        // Finalize generation
                        if metrics.producedTokens > 0 && !metrics.canceled {
                            let msg = Message(role: .assistant, content: emitted, attachments: nil)
                            messages.append(msg)
                            
                            // Update our templated tokens to include the generated message
                            // Note: This is approximate as we don't re-template, but it's good enough
                            // for tracking purposes since we'll re-template on next updateContext
                            templatedTokens.append(contentsOf: generated)
                            
                            metrics.committed = true
                            
                            FreeTokenLogger.shared.log("KV_SLIDING: Generation complete - tokens=\(metrics.producedTokens) n_past=\(n_past) slides=\(metrics.slidingCount)", level: .info)
                        }
                        
                        metrics.end = Date()
                        if let first = metrics.firstToken, let end = metrics.end, metrics.producedTokens > 0 {
                            metrics.tokensPerSecond = Double(metrics.producedTokens) / max(end.timeIntervalSince(first), 0.0001)
                            metrics.avgTokenLatency = end.timeIntervalSince(first) / Double(metrics.producedTokens)
                        }
                        
                        self.lastGenerationMetrics = metrics
                        self.busy = false
                        continuation.finish()
                        
                    } catch {
                        metrics.end = Date()
                        self.lastGenerationMetrics = metrics
                        self.busy = false
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        
        /// Raw completion with sliding support
        func generate(text: String) async throws -> AsyncThrowingStream<String, Error> {
            try ensureActive()
            
            // Reset for stateless generation
            await session.resetSampler()
            
            // Tokenize and evaluate prompt
            let promptTokens = try await session.tokenize(text)
            
            // Calculate n_keep for raw generation (use the prompt as keep tokens)
            n_keep = min(Int32(promptTokens.count), Int32(options.contextSize / 4))  // Keep up to 25% of context
            n_past = Int32(promptTokens.count)
            
            FreeTokenLogger.shared.log("KV_SLIDING: Raw generation - promptTokens=\(promptTokens.count) n_keep=\(n_keep)", level: .info)
            
            try await session.evalOptimized(tokens: promptTokens, feedToSampler: true)
            
            // Use similar generation logic with sliding
            let maxTokens = min(options.maxNewTokens, options.contextSize - promptTokens.count)
            
            return AsyncThrowingStream { continuation in
                Task {
                    var emitted = ""
                    var metrics = GenerationMetrics()
                    var generated: [Int32] = []
                    
                    defer {
                        metrics.end = Date()
                        if let first = metrics.firstToken, let end = metrics.end, metrics.producedTokens > 0 {
                            metrics.tokensPerSecond = Double(metrics.producedTokens) / max(end.timeIntervalSince(first), 0.0001)
                        }
                        self.lastGenerationMetrics = metrics
                        self.busy = false
                        continuation.finish()
                    }
                    
                    do {
                        let stopTokens = await session.getStopTokens()
                        
                        for _ in 0..<maxTokens {
                            // Check for sliding need
                            if n_past >= options.contextSize {
                                FreeTokenLogger.shared.log("KV_SLIDING: Raw generation context full - sliding", level: .warning)
                                try await self.performKVSliding()
                                metrics.slidingOccurred = true
                                metrics.slidingCount += 1
                            }
                            
                            if Task.isCancelled {
                                metrics.canceled = true
                                metrics.stopReason = "canceled"
                                break
                            }
                            
                            guard let result = try await session.generateNextTokenOptimized() else {
                                throw FreeTokenError.aiRunFailed(message: "Generation failed")
                            }
                            
                            generated.append(result.token)
                            n_past += 1
                            metrics.producedTokens += 1
                            
                            if metrics.firstToken == nil {
                                metrics.firstToken = Date()
                            }
                            
                            metrics.sampleTimeTotal += TimeInterval(result.sampleMs / 1000.0)
                            metrics.evalTimeTotal += TimeInterval(result.evalMs / 1000.0)
                            
                            if stopTokens.contains(result.token) {
                                metrics.stopReason = "stopToken"
                                break
                            }
                            
                            let piece = result.text
                            if !piece.isEmpty {
                                emitted += piece
                                continuation.yield(piece)
                            }
                            
                            // Check stop sequences
                            for stop in options.stopSequences {
                                if emitted.hasSuffix(stop) {
                                    metrics.stopReason = "stopSequence"
                                    break
                                }
                            }
                            if metrics.stopReason == "stopSequence" { break }
                        }
                        
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        
        // MARK: - Utility Functions
        
        func tokenize(_ text: String) async throws -> [Int] {
            try ensureActive()
            return try await session.tokenize(text)
        }
        
        func unload() async {
            if isUnloaded { return }
            await session.unload()
            messages.removeAll()
            templatedTokens.removeAll()
            n_past = 0
            n_keep = 0
            isUnloaded = true
        }
        
        func resetSession() async {
            await session.resetForRebuild()
            n_past = 0
            n_keep = 0
            messages.removeAll()
            templatedTokens.removeAll()
        }
    }
}
