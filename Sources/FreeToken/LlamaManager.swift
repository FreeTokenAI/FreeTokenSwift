//
//  LlamaManager.swift
//  FreeToken
//
//  Token-based KV cache management with sliding window support
//  Simplified architecture that tracks raw token positions instead of message boundaries
//

import Foundation
import CryptoKit

extension FreeToken {
    /// LlamaManager - Token-based KV cache manager
    /// ---------------------------------
    /// Manages a single llama.cpp session with token-based KV cache sliding.
    /// No message boundary tracking - just raw token positions for simplicity.
    final actor LlamaManager: @unchecked Sendable {
        private let session: LlamaSession
        private let options: LlamaInitOptions
        private let modelFileName: String
        private let stateBaseURL: URL
        private let sequenceId: Int32 = 0 // single sequence
        
        // Token position tracking (simple and clean)
        private var n_keep: Int32 = 0 // Tokens to preserve during sliding (calculated from first message)
        private var templatedTokens: [Int32] = [] // Current templated tokens in KV cache
        
        private var isUnloaded: Bool = false
        
        // Sliding configuration
        private let slidingRatio: Float = 0.5  // Remove 50% of available tokens when sliding
        
        private var isPrewarmed: Bool = false
        private var runID: String = ""

        @inline(__always)
        private func ensureActive(_ fn: StaticString = #function) throws {
            if isUnloaded { throw FreeTokenError.aiRunFailed(message: "LlamaManager was unloaded; call site: \(fn)") }
        }
        
        init(modelPath: String, options: LlamaInitOptions, repoName: String) throws {
            // Load model separately
            let model = try FreeToken.LlamaModel(path: modelPath)
            // Use static factory to avoid sendability issues
            self.session = try LlamaSession(model: model, config: options)
            self.options = options
            self.modelFileName = URL(fileURLWithPath: modelPath).lastPathComponent
            
            self.stateBaseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("FreeToken").appendingPathComponent("chats").appendingPathComponent(repoName).appendingPathComponent(modelFileName)
            
            FreeTokenLogger.shared.log("LlamaManager initialized with contextSize=\(options.contextSize)", level: .info)
        }
        
        var templatedTokenCount: Int {
            return templatedTokens.count
        }

        /// Get the actual KV cache position from the session
        /// More accurate than templatedTokenCount after context sliding or state reload
        var kvCachePosition: Int {
            get async {
                return Int(await session.getPos())
            }
        }
        
        // MARK: - Prewarm System Message
        
        func generatePrewarmBuffer(_ systemMessage: Message) async throws {
            try ensureActive()
            
            let systemMessageSHA: String = SHA256.hash(data: Data(systemMessage.content.utf8)).compactMap { String(format: "%02x", $0) }.joined()
            let stateFileName = "prewarm_\(systemMessageSHA).bin"
            
            let filePath = stateBaseURL.appendingPathComponent(session.configSHA256).appendingPathComponent(stateFileName)
            
            // Does it exist at that path?
            if FileManager.default.fileExists(atPath: filePath.path) {
                FreeToken.shared.logger("Prewarm buffer already exists at path: \(filePath.path)", .info)
                return
            }
            
            // Template and evaluate system message
            // System message should already be combined with user message in models that require it
            let compact = [(systemMessage.role.rawValue, systemMessage.content)]
            
            let template = try await session.getTemplatedMessageString(messages: compact)
            
            FreeToken.shared.logger("Templated message string created: \(template)", .debug)
            
            let content = systemMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Find the end of the system message in the template
            if let range = template.range(of: content) {
                let prefix = String(template[..<range.upperBound]) // Get everything up to the end of the system message
                
                FreeToken.shared.logger("Prefix template generated: \(prefix)", .debug)
                
                let tokens = try await session.tokenize(prefix, addBos: false, special: true) // Tokenize with special token strings, and don't add BOS as this was already added in the template.
                let prewarmedTokens = tokens.map { Int32($0) }
                
                FreeToken.shared.logger("Evaluating \(tokens.count) tokens for prewarm", .debug)
                try await self.resetSession()
                _ = try await session.evalOptimized(tokens: tokens, feedToSampler: false, needsLogits: false) // Evaluate it into the KV cache
                self.templatedTokens = prewarmedTokens
                self.n_keep = Int32(prewarmedTokens.count) // Protect system message from being slid out

                // Write session to disk
                try await session.writeStateToFile(fileName: stateFileName, basePath: stateBaseURL, tokens: prewarmedTokens)
                
                self.isPrewarmed = true
                FreeToken.shared.logger("💾 Session buffer saved to disk", .debug)
            } else {
                throw FreeTokenError.aiRunFailed(message: "Failed to locate system message in template")
            }
        }
        
        func prewarmSession(systemMessage: Message, runID: String) async throws {
            try ensureActive()
            
            if self.runID != runID {
                _ = try await self.resetSession()
                self.runID = runID
            }
            
            if isPrewarmed {
                FreeToken.shared.logger("Session is already prewarmed", .info)
                return
            }
            
            let systemMessageSHA: String = SHA256.hash(data: Data(systemMessage.content.utf8)).compactMap { String(format: "%02x", $0) }.joined()
            let stateFileName = "prewarm_\(systemMessageSHA).bin"
            
            do {
                _ = try await resetSession()
                let result = try await session.loadStateFromFile(fileName: stateFileName, basePath: stateBaseURL)
                let prewarmedTokens = result.tokens.map { Int32($0) }
                self.templatedTokens = prewarmedTokens
                self.isPrewarmed = true
                self.n_keep = Int32(prewarmedTokens.count)
                FreeToken.shared.logger("🏃‍♂️ Loaded prewarm buffer with \(prewarmedTokens.count) tokens", .info)
            } catch {
                FreeToken.shared.logger("Prewarm buffer not found, generating new one", .info)
                try await generatePrewarmBuffer(systemMessage)
            }
        }
        
        func saveSession(fileName: String) async throws {
            try ensureActive()
            try await session.writeStateToFile(fileName: fileName, basePath: stateBaseURL, tokens: templatedTokens)
        }
        
        func loadSession(fileName: String, systemMessage: Message, runID: String) async throws {
            try ensureActive()
            let fullPath = stateBaseURL.appendingPathComponent(session.configSHA256).appendingPathComponent(fileName)
            
            if !FileManager.default.fileExists(atPath: fullPath.path) {
                FreeToken.shared.logger("⚠️ Session could not be found at path: \(fullPath.path)", .warning)
                throw FreeTokenError.llamaFailedToReadSessionStateFromFile
            }
            
            self.runID = runID
            _ = try await resetSession()
            let result = try await session.loadStateFromFile(fileName: fileName, basePath: stateBaseURL)
            self.templatedTokens = result.tokens.map { Int32($0) }
            let tokenCount = try await templateMessages([systemMessage]).count
            self.n_keep = Int32(tokenCount) // n_keep prevents system message from being rolled out the context window.
        }
        
        // MARK: - Simple Templating Functions
        
        /// Template messages and return tokens - no state management needed
        private func templateMessages(_ messages: [Message]) async throws -> [Int32] {
            try ensureActive()
            let compact = messages.map { ($0.role.rawValue, $0.content) }
            let tokens = try await session.applyChatTemplate(
                messages: compact,
                includeAssistantPrefix: false
            )
            return tokens.map { Int32($0) }
        }
        
        /// Template messages with assistant slot for generation
        private func templateWithAssistantSlot(_ messages: [Message]) async throws -> [Int32] {
            try ensureActive()
            let compact = messages.map { ($0.role.rawValue, $0.content) }
            let tokens = try await session.applyChatTemplate(
                messages: compact,
                includeAssistantPrefix: true
            )
            return tokens.map { Int32($0) }
        }
        
        // MARK: - Simplified Context Update
        
        func addMessage(message: Message, runID: String) async throws {
            try ensureActive()
            let newMessageTokens = try await templateMessages([message])

            FreeTokenLogger.shared.log("KV_SLIDING: addMessage called - role=\(message.role.rawValue), tokenCount=\(newMessageTokens.count), templatedTokens.count=\(templatedTokens.count), n_keep=\(n_keep), pos=\(await session.getPos())", level: .debug)

            // If this is the first message (system message), set n_keep to protect it from sliding
            if templatedTokens.isEmpty && n_keep == 0 {
                n_keep = Int32(newMessageTokens.count)
                FreeTokenLogger.shared.log("KV_SLIDING: Set n_keep=\(n_keep) from first message in addMessage", level: .info)
            }

            if Int(await session.getPos()) + newMessageTokens.count > options.contextSize {
                FreeTokenLogger.shared.log("KV_SLIDING: addMessage triggering slidingTokenChunkUpdate - n_keep=\(n_keep)", level: .debug)
                try await slidingTokenChunkUpdate(newTokens: newMessageTokens)
            } else {
                // Just direct update the tokens
                try await session.evalOptimized(tokens: newMessageTokens.map { Int($0) }, feedToSampler: false, needsLogits: false)
                templatedTokens.append(contentsOf: newMessageTokens)
            }
        }
        
        /// Update context with new messages using token-based approach
        func updateContext(messages desired: [Message], runID: String) async throws {
            try ensureActive()
            
            if self.runID != runID {
                _ = try await self.resetSession()
                self.runID = runID
            }
            
            FreeTokenLogger.shared.log("KV_SLIDING: updateContext start desired=\(desired.count) pos=\(await session.getPos()) n_keep=\(n_keep)", level: .debug)
            
            // Guard multimodal
            if desired.contains(where: { msg in (msg.attachments?.contains { $0.type == .image }) == true }) {
                throw FreeTokenError.llamaMultimodalNotSupported
            }
            
            // Fast equality check
            let tokens = try await templateMessages(desired)
            
            var needsRebuild = false
            
            if tokens.count < templatedTokenCount {
                FreeTokenLogger.shared.log("KV_SLIDING: updateContext requires full rebuild (token count decreased)", level: .warning)
                needsRebuild = true
            } else {
                var tokenDeltaCount = 0
                for templatedIndex in 0..<templatedTokenCount {
                    if templatedTokens[templatedIndex] != tokens[templatedIndex] {
                        tokenDeltaCount += 1
                    }
                }
                
                // If 99% of tokens are the same, just keep going.
                if Float(tokenDeltaCount) / Float(templatedTokenCount) > 0.01 {
                    FreeTokenLogger.shared.log("KV_SLIDING: updateContext requires full rebuild (token divergence exceeds 99% similarity threshold: \(Float(tokenDeltaCount) / Float(templatedTokenCount))) - delta token count: \(tokenDeltaCount)", level: .warning)
                    needsRebuild = true
                } else {
                    FreeToken.shared.logger("KV_SLIDING: Token divergence meets threshold - no rebuild required. Diverged token count: \(tokenDeltaCount)", .debug)
                }
            }
            
            if !needsRebuild, tokens.count == templatedTokenCount {
                // No changes needed
                FreeTokenLogger.shared.log("KV_SLIDING: updateContext - no changes needed", level: .info)
                return
            }
            
            if needsRebuild {
                FreeTokenLogger.shared.log("KV_SLIDING: Full rebuild required - resetting context", level: .warning)
                try await self.resetSession()
            }
            
            var deltaTokens = [Int32]()
            
            for index in 0..<tokens.count {
                if index >= templatedTokenCount {
                    deltaTokens.append(tokens[index])
                }
            }
            
            if deltaTokens.count == 0 {
                FreeTokenLogger.shared.log("KV_SLIDING: No new tokens to evaluate after context update", level: .info)
                return
            }

            // Reset n_keep to the first message
            if !desired.isEmpty {
                let firstMessageTokens = try await templateMessages([desired[0]])
                n_keep = Int32(firstMessageTokens.count)
                FreeTokenLogger.shared.log("KV_SLIDING: Calculated n_keep=\(n_keep) from first message", level: .info)
            } else {
                n_keep = 0
            }
            
            if (deltaTokens.count + Int(await session.getPos())) > options.contextSize {
                FreeTokenLogger.shared.log("KV_SLIDING: updateContext triggering slidingTokenChunkUpdate - n_keep=\(n_keep), deltaTokens=\(deltaTokens.count), pos=\(await session.getPos())", level: .debug)
                try await slidingTokenChunkUpdate(newTokens: deltaTokens)
            } else {
                FreeTokenLogger.shared.log("KV_SLIDING: Evaluating \(deltaTokens.count) new tokens", level: .debug)
                try await session.evalOptimized(tokens: deltaTokens.map { Int($0) }, feedToSampler: false, needsLogits: false)
                templatedTokens.append(contentsOf: deltaTokens)
            }
        }
        
        private func slidingTokenChunkUpdate(newTokens deltaTokens: [Int32]) async throws {
            // Let's batch the tokens in 50% context size chunks
            let chunkSize = options.contextSize / 2
            // Slice the deltaTokens Array into chunks
            var startIndex = 0
            while startIndex < deltaTokens.count {
                let endIndex = min(startIndex + chunkSize, deltaTokens.count)
                let chunk = Array(deltaTokens[startIndex..<endIndex])
                
                if chunk.count + Int(await session.getPos()) >= options.contextSize {
                    FreeTokenLogger.shared.log("KV_SLIDING: Chunk of \(chunk.count) tokens exceeds context size; performing KV slide before evaluation. n_keep=\(n_keep)", level: .warning)
                    try await performKVSliding()
                }
                
                FreeTokenLogger.shared.log("KV_SLIDING: Evaluating chunk of \(chunk.count) tokens", level: .debug)
                
                try await session.evalOptimized(tokens: chunk.map { Int($0) }, feedToSampler: false, needsLogits: false)
                templatedTokens.append(contentsOf: chunk)
                
                
                startIndex += chunkSize
            }
        }
        
        // MARK: - KV Cache Sliding
        
        /// Perform KV cache sliding when context is full
        /// This follows llama.cpp's main.cpp sliding logic exactly
        private func performKVSliding() async throws {
            try ensureActive()
            
            guard n_keep > 0 else {
                FreeTokenLogger.shared.log("KV_SLIDING: ERROR - Cannot slide without n_keep set. templatedTokens.count=\(templatedTokens.count), pos=\(await session.getPos()), isPrewarmed=\(isPrewarmed)", level: .error)
                throw FreeTokenError.aiRunFailed(message: "KV sliding requires n_keep to be set")
            }
            
            let n_left = await session.getPos() - n_keep  // Tokens available for removal
            guard n_left > 0 else {
                FreeTokenLogger.shared.log("KV_SLIDING: No tokens available to slide (n_left=0)", level: .warning)
                return
            }
            
            let n_discard = Int32(Float(n_left) * slidingRatio)  // Remove half of available space
            
            FreeTokenLogger.shared.log("KV_SLIDING: Starting slide - pos=\(await session.getPos()) n_keep=\(n_keep) n_left=\(n_left) n_discard=\(n_discard)", level: .info)
            
            // Remove tokens from position n_keep to n_keep + n_discard
            let removeStart = n_keep
            let removeEnd = n_keep + n_discard
            
            FreeTokenLogger.shared.log("KV_SLIDING: Removing tokens [\(removeStart), \(removeEnd))", level: .debug)
            try await session.removeKVCacheTokens(from: removeStart, to: removeEnd)
            templatedTokens.removeSubrange(Int(removeStart)...Int(removeEnd))
            
            // Shift remaining tokens backward by n_discard positions
            let shiftStart = removeEnd
            let shiftCount: Int32 = -1  // -1 means shift to end
            
            FreeTokenLogger.shared.log("KV_SLIDING: Shifting tokens from \(shiftStart) by -\(n_discard)", level: .debug)
            try await session.shiftKVCacheTokens(from: shiftStart, count: shiftCount, by: Int32(-n_discard))
            
            // Note: We don't update templatedTokens as they represent the logical message tokens,
            // not the physical KV cache state after sliding
            
            FreeTokenLogger.shared.log("KV_SLIDING: Slide complete - new pos=\(await session.getPos()) (removed \(n_discard) tokens)", level: .info)
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
            // Perplexity and confidence tracking
            var logProbSum: Double = 0.0
            var averageLogProb: Double? = nil
            var perplexity: Double? = nil
            var confidence: Double? = nil
        }
        
        private(set) var lastGenerationMetrics: GenerationMetrics? = nil

        func getLastGenerationMetrics() async -> GenerationMetrics? {
            return lastGenerationMetrics
        }
        
        /// Streaming generation with automatic KV cache sliding
        func generate(runID: String) async throws -> AsyncThrowingStream<String, Error> {
            try ensureActive()
            
            guard templatedTokenCount > 0 else {
                throw FreeTokenError.llamaEvaluatingEmptyContext
            }
            
            if self.runID != runID {
                throw FreeTokenError.llamaUnexpectedInternalState
            }
            
            
            // Check initial capacity
            let initialHeadroom = options.contextSize - Int(await session.getPos())
            FreeTokenLogger.shared.log("KV_SLIDING: generate start pos=\(await session.getPos()) headroom=\(initialHeadroom) maxNew=\(options.maxNewTokens)", level: .info)
            
            if initialHeadroom <= 0 {
                throw FreeTokenError.llamaContextOverflow
            }
            
            // Get tokens with assistant slot
            // TODO: This may not work. We might need to dummy template in another way.
            let assistantSlotTokens = try await templateWithAssistantSlot([])
            
            // Find the assistant slot tokens (delta from current state)
            
            if !assistantSlotTokens.isEmpty {
                // Check if we need to slide BEFORE evaluating assistant slot tokens
                let currentPos = Int(await session.getPos())
                if currentPos + assistantSlotTokens.count > options.contextSize {
                    FreeTokenLogger.shared.log("KV_SLIDING: Not enough headroom for \(assistantSlotTokens.count) assistant slot tokens (pos=\(currentPos)) - triggering slide", level: .warning)
                    try await performKVSliding()
                }

                FreeTokenLogger.shared.log("KV_SLIDING: Evaluating \(assistantSlotTokens.count) assistant slot tokens", level: .debug)

                // Evaluate all assistant slot tokens in one batch
                // The C bridge will handle logits efficiently (only for last token when needsLogits=true)
                // Feed to sampler since these are part of generation
                let slotTokensInt = assistantSlotTokens.map { Int($0) }
                try await session.evalOptimized(tokens: slotTokensInt, feedToSampler: true, needsLogits: true)
                templatedTokens.append(contentsOf: assistantSlotTokens)
            }
            
            return AsyncThrowingStream { continuation in
                Task {
                    var emitted = ""
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
                            if await session.getPos() >= options.contextSize {
                                FreeTokenLogger.shared.log("KV_SLIDING: Context full at token \(tokenIndex) - triggering slide", level: .warning)
                                try await self.performKVSliding()
                                metrics.slidingOccurred = true
                                metrics.slidingCount += 1
                            }
                            
                            if Task.isCancelled {
                                metrics.canceled = true
                                metrics.stopReason = "canceled"
                                // We don't want to leave the model in a bad state - reset the session so that it will be rebuilt on next run. 
                                try await self.resetSession()
                                break
                            }
                            
                            // Generate next token
                            guard let result = try await session.generateNextTokenOptimized() else {
                                throw FreeTokenError.aiRunFailed(message: "Generation failed")
                            }

                            let nextToken = result.token
                            let piece = result.text

                            generated.append(nextToken)
                            metrics.producedTokens += 1

                            // Track metrics
                            metrics.sampleTimeTotal += TimeInterval(result.sampleMs / 1000.0)
                            metrics.evalTimeTotal += TimeInterval(result.evalMs / 1000.0)

                            // Accumulate log probability for perplexity calculation
                            metrics.logProbSum += Double(result.logProb)
                            
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
                        }
                        
                        // Finalize generation
                        if metrics.producedTokens > 0 && !metrics.canceled {
                            // Update our templated tokens to include the generated message
                            // Note: This is approximate as we don't re-template, but it's good enough
                            // for tracking purposes since we'll re-template on next updateContext
                            templatedTokens.append(contentsOf: generated)
                            
                            metrics.committed = true
                            
                            FreeTokenLogger.shared.log("KV_SLIDING: Generation complete - tokens=\(metrics.producedTokens) pos=\(await session.getPos()) slides=\(metrics.slidingCount)", level: .info)
                        }
                        
                        metrics.end = Date()
                        if let first = metrics.firstToken, let end = metrics.end, metrics.producedTokens > 0 {
                            metrics.tokensPerSecond = Double(metrics.producedTokens) / max(end.timeIntervalSince(first), 0.0001)
                            metrics.avgTokenLatency = end.timeIntervalSince(first) / Double(metrics.producedTokens)
                        }

                        // Calculate perplexity and confidence
                        if metrics.producedTokens > 0 {
                            metrics.averageLogProb = metrics.logProbSum / Double(metrics.producedTokens)
                            metrics.perplexity = exp(-metrics.averageLogProb!)
                            // Confidence as normalized inverse perplexity (0-1 scale)
                            // Lower perplexity = higher confidence
                            metrics.confidence = 1.0 / (1.0 + metrics.perplexity!)
                        }

                        self.lastGenerationMetrics = metrics
                        continuation.finish()
                        
                    } catch {
                        metrics.end = Date()
                        self.lastGenerationMetrics = metrics
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
            _ = await session.unload()
            templatedTokens.removeAll()
            n_keep = 0
            isPrewarmed = false
            isUnloaded = true
        }
        
        func resetSession() async throws {
            try ensureActive()
            FreeTokenLogger.shared.log("KV_SLIDING: resetSession called - clearing n_keep (was \(n_keep))", level: .debug)
            await session.resetForRebuild()
            n_keep = 0
            templatedTokens.removeAll()
            self.isPrewarmed = false
        }

        /// Clears all cached chat states from disk
        func resetChatCache() async throws {
            // Clear the entire chat cache directory for this model
            let cacheDirectory = stateBaseURL

            // Check if directory exists
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                do {
                    try FileManager.default.removeItem(at: cacheDirectory)
                    FreeTokenLogger.shared.log("✅ Cleared chat cache at: \(cacheDirectory.path)", level: .info)
                } catch {
                    FreeTokenLogger.shared.log("🔴 Failed to clear chat cache: \(error)", level: .error)
                    throw FreeTokenError.fileOperationFailed(message: "Failed to clear chat cache: \(error.localizedDescription)")
                }
            } else {
                FreeTokenLogger.shared.log("ℹ️ Chat cache directory does not exist, nothing to clear", level: .debug)
            }

            // Reset current session state as well
            try await resetSession()
        }
    }
}
