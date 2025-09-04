//
//  LlamaManager.swift
//  FreeToken
//
//  Phase 1 Skeleton: Public manager surface & basic updateContext structure.
//

import Foundation

extension FreeToken {
    /// LlamaManager
    /// ---------------------------------
    /// Internal orchestrator maintaining a single llama.cpp session and
    /// a list of contiguous message token spans. Upstream logic is
    /// responsible for pruning (middle-out) and passes the authoritative
    /// ordered messages array to `updateContext`. This manager only:
    ///  * Removes whole messages no longer present
    ///  * Appends new tail messages
    ///  * Rejects insertions/reorders (throws)
    ///  * Provides future streaming generation APIs
    ///  * Enforces invariants for contiguous spans
    ///  * (Diagnostics mode) On unexpected insertion/reorder we now throw with
    ///    detailed logs instead of performing a silent full KV rebuild.
    final class LlamaManager: @unchecked Sendable {
        private let session: LlamaSession
        private let options: LlamaInitOptions
        private var spans: [_LlamaKVSpan] = []
        private var busy: Bool = false
        private let sequenceId: Int32 = 0 // single sequence
    
        // Incremental chat template builder
        private let templateBuilder: LlamaTemplateBuilder
        private var isUnloaded: Bool = false

        @inline(__always)
        private func ensureActive(_ fn: StaticString = #function) throws {
            if isUnloaded { throw FreeTokenError.aiRunFailed(message: "LlamaManager was unloaded; call site: \(fn)") }
        }
        
        init(modelPath: String, options: LlamaInitOptions) throws {
            // Load model separately
            let model = try FreeToken.LlamaModel(path: modelPath)
            // Use static factory to avoid sendability issues
            self.session = try LlamaSession(model: model, config: options)
            self.templateBuilder = LlamaTemplateBuilder(session: session)
            self.options = options
        }
                
        // Public snapshot of tracked messages
        /// External read-only snapshot of tracked messages (message + token count).
        var kvMessages: [KVMessage] {
            spans.map { KVMessage(message: $0.message, tokenCount: $0.tokenCount) }
        }
        
        // MARK: - Context Update
        /// Reconcile KV state with authoritative ordered messages.
        /// Allowed transformations:
        ///  - Remove any subset of existing messages (whole) anywhere.
        ///  - Append new messages at tail.
        /// Disallowed:
        ///  - Middle insertion of a *new* message before all retained ones (throws unexpectedInsertion).
        ///  - Reordering existing messages (also triggers unexpectedInsertion).
        ///  - Messages containing image attachments (multimodal unsupported locally).
        func updateContext(messages desired: [Message]) async throws {
            try ensureActive()
            FreeTokenLogger.shared.log("updateContext start currentSpans=\(spans.count) desired=\(desired.count)", level: .debug)
            let promptStartTime = Date()
            
            // 1. Guard multimodal
            if desired.contains(where: { msg in (msg.attachments?.contains { $0.type == .image }) == true }) {
                throw FreeTokenError.llamaMultimodalNotSupported
            }
            
            // 2. Fast equality
            if spans.count == desired.count && zip(spans, desired).allSatisfy({ $0.message.role == $1.role && $0.message.content == $1.content }) {
                FreeTokenLogger.shared.log("updateContext no-op (identical)", level: .info)
                return
            }
            
            // 3. Longest common prefix
            var p = 0
            while p < spans.count && p < desired.count {
                let span = spans[p]
                let msg = desired[p]
                if span.message.role == msg.role && span.message.content == msg.content { p += 1 } else { break }
            }
            
            // 4. Scan beyond prefix
            var dIdx = p
            var removalIndices: [Int] = []
            var kept: [_LlamaKVSpan] = Array(spans.prefix(p))
            var sIdx = p
            while sIdx < spans.count {
                let span = spans[sIdx]
                if dIdx < desired.count {
                    let target = desired[dIdx]
                    if span.message.role == target.role && span.message.content == target.content {
                        kept.append(span)
                        dIdx += 1
                    } else {
                        // Check if this span appears later in desired tail -> unexpected insertion
                        if (dIdx + 1) < desired.count && desired[(dIdx+1)...].contains(where: { $0.role == span.message.role && $0.content == span.message.content }) {
                            // DIAGNOSTIC BLOCK: unexpected middle insertion / reorder detected.
                            let prefixMatched = p
                            let currentTrackedMsg = span.message
                            let desiredMsg = desired[dIdx]
                            let remainingTrackedRoles = spans[sIdx...].map { $0.message.role.rawValue }.joined(separator: ",")
                            let remainingDesiredRoles = desired[dIdx...].map { $0.role.rawValue }.joined(separator: ",")
                            let tailContainsTrackedIndex = desired[(dIdx+1)...].firstIndex(where: { $0.role == currentTrackedMsg.role && $0.content == currentTrackedMsg.content })
                            let trackedSnippet = String(currentTrackedMsg.content.prefix(200))
                            let desiredSnippet = String(desiredMsg.content.prefix(200))
                            // Break long diagnostic into multiple lines to avoid very long single string literal issues.
                            FreeTokenLogger.shared.log("updateContext insertion_detected spanIndex=\(sIdx) desiredIndex=\(dIdx) prefixMatched=\(prefixMatched)", level: .error)
                            FreeTokenLogger.shared.log("trackedRole=\(currentTrackedMsg.role.rawValue) desiredRole=\(desiredMsg.role.rawValue)", level: .error)
                            FreeTokenLogger.shared.log("trackedSnippet=\(trackedSnippet.debugDescription) desiredSnippet=\(desiredSnippet.debugDescription)", level: .error)
                            FreeTokenLogger.shared.log("remainingTrackedRoles=[\(remainingTrackedRoles)] remainingDesiredRoles=[\(remainingDesiredRoles)]", level: .error)
                            let tailIndexStr = tailContainsTrackedIndex.map { String(describing: $0) } ?? "nil"
                            FreeTokenLogger.shared.log("tailFoundTrackedAtDesiredIndex=\(tailIndexStr)", level: .error)
                            FreeTokenLogger.shared.log("updateContext throwing .llamaUnexpectedInsertion (diagnostics mode; no rebuild)", level: .error)
                            throw FreeTokenError.llamaUnexpectedInsertion
                        } else {
                            removalIndices.append(sIdx)
                        }
                    }
                } else {
                    // Extra tracked spans not in desired
                    removalIndices.append(sIdx)
                }
                sIdx += 1
            }
            
            // 5. Perform removals (coalesce consecutive)
            if !removalIndices.isEmpty {
                try await performRemovals(removalIndices: removalIndices)
            } else {
                spans = kept + spans.dropFirst(kept.count)
            }
            
            // 6. Append new tail messages
            if dIdx < desired.count {
                let tail = Array(desired[dIdx...])
                let tailStartTokTime = Date()
                
                // Parallel tokenization for estimation
                let contents = tail.map { $0.content }
                let tokenArrays = try await session.tokenizeParallel(contents)
                let estNewTokens = tokenArrays.reduce(0) { $0 + $1.count }
                
                let used = templateBuilder.tokens.count
                if used + estNewTokens > options.contextSize {
                    FreeTokenLogger.shared.log("updateContext overflow estNew=\(estNewTokens) used=\(used) limit=\(options.contextSize)", level: .warning)
                    throw FreeTokenError.llamaContextOverflow
                }
                try await appendTail(messages: tail)
                let tailElapsed = Date().timeIntervalSince(tailStartTokTime)
                FreeTokenLogger.shared.log("updateContext tail_append messages=\(tail.count) estTokens=\(estNewTokens) ms=\(Int(tailElapsed*1000))", level: .debug)
            }
            
            try invariantCheck()
                let promptElapsed = Date().timeIntervalSince(promptStartTime)
                FreeTokenLogger.shared.log("updateContext complete totalTokens=\(spans.totalTokens()) spans=\(spans.count) ms=\(Int(promptElapsed*1000))", level: .info)
        }
        
        // MARK: - Generation (Skeleton)

        /// Tokenize arbitrary text using the underlying session (stubbed until llama.cpp wiring).
        func tokenize(_ text: String) async throws -> [Int] {
            try ensureActive()
            return try await session.tokenize(text)
        }
        
        func unload() async {
            if isUnloaded { return }
            await session.unload()
            spans.removeAll()
            isUnloaded = true
        }
        
        /// Perform message removals. Phase 1: in-memory only; future phase will invoke llama
        /// KV cache removal (seq_rm) + shifting (seq_shift). Indices refer to current `spans`.
        private func performRemovals(removalIndices: [Int]) async throws {
            try ensureActive()
            // Fallback strategy: full rebuild of remaining kept messages (no in-place KV cache surgery yet).
            guard !removalIndices.isEmpty else { return }
            FreeTokenLogger.shared.log("performRemovals(rebuild) indices=\(removalIndices)", level: .debug)
            // Determine kept spans in original order
            let removalSet = Set(removalIndices)
            let keptMessages = spans.enumerated().filter { !removalSet.contains($0.offset) }.map { $0.element.message }
            // Instead of unloading (which frees model/context then reuses dangling pointers), perform an in-place reset.
            // This preserves the underlying model/context/sampler pointers and avoids use-after-free.
            await session.resetForRebuild()
            // Clear the template builder when rebuilding to prevent stale messages
            templateBuilder.reset()
            spans.removeAll(keepingCapacity: true)
            
            // Rebuild template builder state with kept messages if any
            if !keptMessages.isEmpty {
                _ = try await templateBuilder.addMessages(keptMessages)
            }
            
            var cursor = 0
            for msg in keptMessages {
                let tokens = try await session.tokenize(msg.content)
                try await session.evalOptimized(tokens: tokens)
                let start = cursor
                let end = start + tokens.count
                let span = _LlamaKVSpan(start: start, end: end, hash: _hash(msg), message: msg, tokens: tokens.map { Int32($0) })
                spans.append(span)
                cursor = end
            }
            FreeTokenLogger.shared.log("performRemovals(rebuild) keptMessages=\(keptMessages.count) newTotalTokens=\(spans.totalTokens())", level: .debug)
        }
        
        /// Append tail messages (authoritative new messages). Tokenization currently stubbed.
        private func appendTail(messages: [Message]) async throws {
            try ensureActive()
            let addedSpans = try await templateBuilder.addMessages(messages)
            // Mirror template spans into local spans (approx message token counts via builder span lengths) using builder span ordering
            // We approximate token slice per message by re-tokenizing content to maintain repetition penalty integrity.
            for (idx, msg) in messages.enumerated() {
                let mtoks = try await session.tokenize(msg.content)
                let start = spans.last?.end ?? 0
                let end = start + mtoks.count
                let span = _LlamaKVSpan(start: start, end: end, hash: _hash(msg), message: msg, tokens: mtoks.map { Int32($0) })
                spans.append(span)
                FreeTokenLogger.shared.log("appendTail(builder) msgRole=\(msg.role.rawValue) newTemplateSpan=\(addedSpans[idx].start)..<\(addedSpans[idx].end) approxMsgTokens=\(mtoks.count)", level: .debug)
            }
            
        }
        
        /// Verify contiguous, gapless spans ordering; throw if violated.
        private func invariantCheck() throws {
            if isUnloaded { throw FreeTokenError.aiRunFailed(message: "LlamaManager unloaded; invariantCheck invalid") }
            // Simple contiguous check
            for i in 1..<spans.count {
                if spans[i-1].end != spans[i].start {
                    throw FreeTokenError.llamaInvariantViolation(message: "Non-contiguous spans at index \(i)")
                }
            }
            if spans.last?.end != spans.totalTokens() { // always true by definition but keep placeholder
                // No action; spans.totalTokens uses last.end
            }
        }

        // MARK: - Streaming Generation
        struct GenerationMetrics {
            var start: Date = Date()
            var firstToken: Date? = nil
            var end: Date? = nil
            var producedTokens: Int = 0
            var committed: Bool = false
            var canceled: Bool = false
            var stopReason: String? = nil // stopSequence | maxTokens | canceled
            var tokensPerSecond: Double? = nil
            var firstTokenLatency: TimeInterval? = nil
            var avgTokenLatency: TimeInterval? = nil
            var sampleTimeTotal: TimeInterval = 0
            var evalTimeTotal: TimeInterval = 0
        }
        private(set) var lastGenerationMetrics: GenerationMetrics? = nil

        /// Streaming assistant generation with sampling, stop sequences, capacity guard, assistant prefix, and commit-on-complete.
        func generate() async throws -> AsyncThrowingStream<String, Error> {
            try ensureActive()
            // Capacity guard
            // If in template mode, use actual template token count for headroom estimation if available
            let templateCount = templateBuilder.tokens.count
            let adjustedHeadroom = options.contextSize - templateCount
            
            if adjustedHeadroom <= 0 || adjustedHeadroom < options.maxNewTokens {
                throw FreeTokenError.llamaContextOverflow
            }
            
            FreeTokenLogger.shared.log("generate start headroom=\(adjustedHeadroom) maxNew=\(options.maxNewTokens)", level: .info)
            let maxTokens = min(options.maxNewTokens, adjustedHeadroom)
            
            // Render with assistant slot; reuse builder.tokens prefix.
            let withSlot = try await templateBuilder.renderWithAssistantSlot()
            let base = templateBuilder.tokens
            var i = 0; let minC = min(base.count, withSlot.count)
            while i < minC && base[i] == withSlot[i] { i += 1 }
            if i == base.count { // append only slot tail
                let tail = Array(withSlot.dropFirst(i))
                if !tail.isEmpty { try await session.evalOptimized(tokens: tail.map { Int($0) }) }
            } else {
                // Unexpected divergence; re-eval full template
                throw FreeTokenError.aiRunFailed(message: "Template divergence detected during generate, create a new session and try again")
            }
            
            return AsyncThrowingStream { continuation in
                Task {
                    var emitted = options.assistantPrefix ?? ""
                    var stopHit = false
                    var metrics = GenerationMetrics()
                    var canceledEarly = false
                    // Local mutable state
                    var generated: [Int32] = []
                    var prefixTokens: [Int32] = []
                    if let prefix = options.assistantPrefix, !prefix.isEmpty {
                        do {
                            let p = try await session.tokenize(prefix).map { Int32($0) }
                            if !p.isEmpty { // eval will advance internal position
                                try await session.evalOptimized(tokens: p.map { Int($0) }); prefixTokens = p
                            }
                        } catch {
                            self.busy = false
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    do {
                        // Capture last user message text for echo suppression heuristics
                        let lastUser = spans.last(where: { $0.message.role == .user })?.message.content
                        let stopTokens = await session.getStopTokens()
                        var recentText = ""  // Track recent text for repetition detection (sliding window)
                        
                        for i in 0..<maxTokens {
                            if Task.isCancelled { canceledEarly = metrics.producedTokens == 0; metrics.stopReason = "canceled"; break }
                            // Combined operation: sample + eval + detokenize in one go (sampler internally tracks penalties)
                            guard let result = try await session.generateNextTokenOptimized() else {
                                throw FreeToken.FreeTokenError.aiRunFailed(message: "Generation failed")
                            }
                            
                            let nextToken = result.token
                            let piece = result.text
                            
                            // Track actual metrics from C bridge
                            metrics.sampleTimeTotal += TimeInterval(result.sampleMs / 1000.0)
                            metrics.evalTimeTotal += TimeInterval(result.evalMs / 1000.0)
                            
                            generated.append(nextToken)
                            metrics.producedTokens += 1
                            
                            // Check for stop tokens (EOS, EOT)
                            if stopTokens.contains(nextToken) {
                                FreeTokenLogger.shared.log("generate hit stop token \(nextToken), stopping", level: .info)
                                metrics.stopReason = "stopToken"
                                break
                            }
                            
                            // Track recent text for repetition detection
                            if !piece.isEmpty {
                                recentText += piece
                                // Keep sliding window of last ~300 characters
                                if recentText.count > 300 {
                                    recentText = String(recentText.suffix(300))
                                }
                                
                                // Check for phrase-level repetition (sequences of 25+ chars repeated 3+ times consecutively)
                                if recentText.count >= 100 {
                                    // Look for repeated sequences of at least 25 characters (increased from 15)
                                    let minSequenceLength = 25
                                    let textToCheck = recentText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    
                                    // Scan for potential repeated sequences
                                    for startIdx in textToCheck.indices {
                                        guard textToCheck.distance(from: startIdx, to: textToCheck.endIndex) >= minSequenceLength else { break }
                                        
                                        let endIdx = textToCheck.index(startIdx, offsetBy: minSequenceLength)
                                        let sequence = String(textToCheck[startIdx..<endIdx])
                                        
                                        // Find all positions of this sequence
                                        var positions: [String.Index] = []
                                        var searchRange = textToCheck.startIndex..<textToCheck.endIndex
                                        
                                        while let range = textToCheck.range(of: sequence, options: .literal, range: searchRange) {
                                            positions.append(range.lowerBound)
                                            searchRange = range.upperBound..<textToCheck.endIndex
                                        }
                                        
                                        // Check if we have 3+ occurrences that are consecutive or nearly consecutive
                                        if positions.count >= 3 {
                                            // Check if positions are close together (within 2x sequence length)
                                            var consecutiveCount = 1
                                            for i in 1..<positions.count {
                                                let distance = textToCheck.distance(from: positions[i-1], to: positions[i])
                                                // If sequences are within 2x the sequence length, consider them consecutive
                                                if distance <= minSequenceLength * 2 {
                                                    consecutiveCount += 1
                                                    if consecutiveCount >= 3 {
                                                        FreeTokenLogger.shared.log("generate detected repetition of '\(sequence)...', stopping", level: .warning)
                                                        metrics.stopReason = "repetition"
                                                        break
                                                    }
                                                } else {
                                                    // Reset counter if sequences are too far apart
                                                    consecutiveCount = 1
                                                }
                                            }
                                            if metrics.stopReason == "repetition" { break }
                                        }
                                    }
                                    
                                    if metrics.stopReason == "repetition" { break }
                                }
                            }
                            
                            if metrics.firstToken == nil {
                                metrics.firstToken = Date()
                                metrics.firstTokenLatency = metrics.firstToken!.timeIntervalSince(metrics.start)
                                FreeTokenLogger.shared.log("generate first_token latency=\(String(format: "%.3f", metrics.firstTokenLatency!))s", level: .info)
                            }
                            
                            if !piece.isEmpty { emitted += piece; continuation.yield(piece) }
                            
                            // Echo suppression: if emitted starts by repeating last user question verbatim more than once, force stop.
                            if let lastUser, metrics.producedTokens < 32 {
                                if emitted.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(lastUser.trimmingCharacters(in: .whitespacesAndNewlines)) && emitted.count >= lastUser.count * 2 {
                                    FreeTokenLogger.shared.log("generate echo_detected stopping early", level: .warning)
                                    metrics.stopReason = "echoDetected"; break
                                }
                            }
                            
                            if !options.stopSequences.isEmpty {
                                for stop in options.stopSequences { if emitted.hasSuffix(stop) { stopHit = true; break } }
                            }
                            if stopHit { metrics.stopReason = "stopSequence"; break }
                            if i == maxTokens - 1 { metrics.stopReason = metrics.stopReason ?? "maxTokens" }
                            
                            // Periodic progress logging every 10 tokens
                            if metrics.producedTokens % 10 == 0 {
                                if let first = metrics.firstToken {
                                    // Progress hook retained (logging suppressed); compute elapsed to keep parity
                                    _ = Date().timeIntervalSince(first)
                                }
                            }
                        }
                        // Commit if any tokens produced and not canceled
                        if !canceledEarly && metrics.producedTokens > 0 {
                            let combined = prefixTokens + generated
                            let fullText = emitted
                            let (trimmedText, trimmedTokens) = self.trimStopSequencesSync(fullText: fullText, tokens: combined)
                            let msg = Message(role: .assistant, content: trimmedText, attachments: nil)
                            let start = spans.last?.end ?? 0
                            let end = start + trimmedTokens.count
                            let span = _LlamaKVSpan(start: start, end: end, hash: _hash(msg), message: msg, tokens: trimmedTokens)
                            spans.append(span)
                            metrics.committed = true
                            FreeTokenLogger.shared.log("generate commit tokens=\(trimmedTokens.count) reason=\(metrics.stopReason ?? "unknown") totalTokens=\(spans.totalTokens())", level: .info)
                        }
                        metrics.end = Date()
                        if let first = metrics.firstToken, let end = metrics.end, metrics.producedTokens > 0 {
                            metrics.tokensPerSecond = Double(metrics.producedTokens) / max(end.timeIntervalSince(first), 0.0001)
                            metrics.avgTokenLatency = (end.timeIntervalSince(first)) / Double(metrics.producedTokens)
                        }
                        self.lastGenerationMetrics = metrics
                        if let tps = metrics.tokensPerSecond, let firstLat = metrics.firstTokenLatency, let avgLat = metrics.avgTokenLatency {
                            let detokMs = 0 // placeholder; detok metrics tracked inside session if exposed later
                            FreeTokenLogger.shared.log("generate done tokens=\(metrics.producedTokens) tps=\(String(format: "%.2f", tps)) first_token_latency=\(String(format: "%.3f", firstLat))s avg_token_latency=\(String(format: "%.3f", avgLat))s sample_ms=\(Int(metrics.sampleTimeTotal*1000)) eval_ms=\(Int(metrics.evalTimeTotal*1000)) detok_ms=\(detokMs) reason=\(metrics.stopReason ?? "unknown")", level: .info)
                        } else {
                            FreeTokenLogger.shared.log("generate done tokens=\(metrics.producedTokens) reason=\(metrics.stopReason ?? "unknown")", level: .info)
                        }
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

        /// Raw completion variant that uses the same generation path as chat (for quality consistency).
        func generate(text: String) async throws -> AsyncThrowingStream<String, Error> {
            try ensureActive()
            
            // CRITICAL: Reset sampler for stateless raw completion
            // This clears any accumulated history from previous completions
            await session.resetSampler()
            
            // Tokenize prompt and evaluate (feeding to sampler for proper tracking)
            let promptTokens = try await session.tokenize(text)
            try await session.evalOptimized(tokens: promptTokens, feedToSampler: true)
            FreeTokenLogger.shared.log("generate(raw) promptTokens=\(promptTokens.count)", level: .info)
            
            // Use the same generation logic as chat, just with the raw prompt as context
            let maxTokens = min(options.maxNewTokens, options.contextSize - promptTokens.count)
            return AsyncThrowingStream { continuation in
                Task {
                    var emitted = ""
                    var stopHit = false
                    var metrics = GenerationMetrics()
                    var canceledEarly = false
                    var generated: [Int32] = []
                    
                    defer {
                        metrics.end = Date()
                        metrics.canceled = canceledEarly
                        if let first = metrics.firstToken, let end = metrics.end, metrics.producedTokens > 0 {
                            metrics.tokensPerSecond = Double(metrics.producedTokens) / max(end.timeIntervalSince(first), 0.0001)
                        }
                        FreeTokenLogger.shared.log("generate(raw) done tokens=\(metrics.producedTokens) tps=\(metrics.tokensPerSecond ?? -1) reason=\(metrics.stopReason ?? "unknown")", level: .info)
                        self.lastGenerationMetrics = metrics
                        self.busy = false; continuation.finish(throwing: nil)
                    }
                    
                    do {
                        let stopTokens = await session.getStopTokens()
                        // Track recent generated text for phrase-level repetition detection
                        var recentText = ""
                        let echoSource: String? = text
                        
                        for i in 0..<maxTokens {
                            if Task.isCancelled { 
                                canceledEarly = metrics.producedTokens == 0
                                metrics.stopReason = "canceled"
                                break 
                            }
                            
                            // Use same penalty logic as chat: prompt + generated tokens
                            guard let result = try await session.generateNextTokenOptimized() else {
                                throw FreeToken.FreeTokenError.aiRunFailed(message: "Generation failed")
                            }
                            
                            generated.append(result.token)
                            metrics.producedTokens += 1
                            
                            // Track timing metrics
                            if metrics.firstToken == nil { 
                                metrics.firstToken = Date() 
                            }
                            metrics.sampleTimeTotal += TimeInterval(result.sampleMs / 1000.0)
                            metrics.evalTimeTotal += TimeInterval(result.evalMs / 1000.0)
                            
                            // Check for stop tokens
                            if stopTokens.contains(result.token) {
                                FreeTokenLogger.shared.log("generate(raw) hit stop token \(result.token)", level: .info)
                                metrics.stopReason = "stopToken"
                                break
                            }
                            
                            // Emit text
                            let piece = result.text
                            if !piece.isEmpty { 
                                emitted += piece
                                continuation.yield(piece) 
                                // Track recent text for repetition detection
                                recentText += piece
                                // Keep sliding window of last ~300 characters
                                if recentText.count > 300 {
                                    recentText = String(recentText.suffix(300))
                                }
                                
                                // Check for phrase-level repetition (sequences of 25+ chars repeated 3+ times consecutively)
                                if recentText.count >= 100 {
                                    // Look for repeated sequences of at least 25 characters (increased from 15)
                                    let minSequenceLength = 25
                                    let textToCheck = recentText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    
                                    // Scan for potential repeated sequences
                                    for startIdx in textToCheck.indices {
                                        guard textToCheck.distance(from: startIdx, to: textToCheck.endIndex) >= minSequenceLength else { break }
                                        
                                        let endIdx = textToCheck.index(startIdx, offsetBy: minSequenceLength)
                                        let sequence = String(textToCheck[startIdx..<endIdx])
                                        
                                        // Find all positions of this sequence
                                        var positions: [String.Index] = []
                                        var searchRange = textToCheck.startIndex..<textToCheck.endIndex
                                        
                                        while let range = textToCheck.range(of: sequence, options: .literal, range: searchRange) {
                                            positions.append(range.lowerBound)
                                            searchRange = range.upperBound..<textToCheck.endIndex
                                        }
                                        
                                        // Check if we have 3+ occurrences that are consecutive or nearly consecutive
                                        if positions.count >= 3 {
                                            // Check if positions are close together (within 2x sequence length)
                                            var consecutiveCount = 1
                                            for i in 1..<positions.count {
                                                let distance = textToCheck.distance(from: positions[i-1], to: positions[i])
                                                // If sequences are within 2x the sequence length, consider them consecutive
                                                if distance <= minSequenceLength * 2 {
                                                    consecutiveCount += 1
                                                    if consecutiveCount >= 3 {
                                                        FreeTokenLogger.shared.log("generate(raw) detected repetition of '\(sequence)...', stopping", level: .warning)
                                                        metrics.stopReason = "repetition"
                                                        break
                                                    }
                                                } else {
                                                    // Reset counter if sequences are too far apart
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

                            // Echo suppression similar to chat path: prevent model from regurgitating the prompt verbatim multiple times
                            if let echoSource, metrics.producedTokens < 64 { // only early window
                                let trimmedPrompt = echoSource.trimmingCharacters(in: .whitespacesAndNewlines)
                                let trimmedEmitted = emitted.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmedPrompt.count > 16, trimmedEmitted.hasPrefix(trimmedPrompt), trimmedEmitted.count >= trimmedPrompt.count * 2 {
                                    FreeTokenLogger.shared.log("generate(raw) echo_detected stopping early", level: .warning)
                                    metrics.stopReason = "echoDetected"
                                    break
                                }
                            }
                            
                            if i == maxTokens - 1 { 
                                metrics.stopReason = metrics.stopReason ?? "maxTokens" 
                            }
                        }
                        
                        self.lastGenerationMetrics = metrics
                        
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        
        func resetSession() async {
            await session.resetForRebuild()
            // Clear the template builder's message cache to prevent stale messages
            templateBuilder.reset()
        }

        // MARK: - Stop Sequence Trimming
        private func trimStopSequencesSync(fullText: String, tokens: [Int32]) -> (String, [Int32]) {
            guard !options.stopSequences.isEmpty else { return (fullText, tokens) }
            let trimmed = fullText
            var matched: String? = nil
            for stop in options.stopSequences {
                if trimmed.hasSuffix(stop) { matched = stop; break }
            }
            guard let stopHit = matched else { return (trimmed, tokens) }
            let targetLength = trimmed.count - stopHit.count
            if targetLength <= 0 { return ("", []) }
            // Simplified: return trimmed string; token list left unchanged (over-commit small) due to lack of deterministic reverse mapping.
            return (String(trimmed.prefix(targetLength)), tokens)
        }
    }
}

// MARK: - Hash Helper
fileprivate func _hash(_ message: FreeToken.Message) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(message.role.rawValue)
    hasher.combine("\u{001F}")
    hasher.combine(message.content)
    let h = hasher.finalize()
    return UInt64(bitPattern: Int64(h))
}
