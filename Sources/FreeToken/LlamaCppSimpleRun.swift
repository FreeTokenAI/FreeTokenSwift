//
//  SimpleRun.swift
//  LlamaCppSwift
//
//  Created by Vince Francesi on 5/21/25.
//

import Foundation
import llama

extension FreeToken {
    @LlamaCppSwiftActor
    class LlamaCppSimpleRun: @unchecked Sendable {
        private let model: OpaquePointer
        private var ctx: OpaquePointer
        private let modelNVocab: Int32
        private let configuration: AIModelConfiguration
        private let modelPath: String
        private var isGenerating: Bool = false
        private var shouldStopGeneration: Bool = false
        private var conversationTokenCount: Int = 0
        private var currentRunIdentifier: String?
        private var lastPromptTokens: [llama_token] = []
        var lastRunStats: LastRunStats?
        
        // Actor-based queue management
        private var generationQueue: [(task: Task<Void, Never>, runIdentifier: String)] = []
        private var currentlyGeneratingIdentifier: String?
        
        // Generation status
        enum GenerationStatus {
            case idle
            case generating(runIdentifier: String, position: Int, total: Int)
            case queued(runIdentifier: String, position: Int)
        }
        
        // Observable status
        private(set) var status: GenerationStatus = .idle {
            didSet {
                statusContinuation?.yield(status)
            }
        }
        
        // Status stream
        private var statusContinuation: AsyncStream<GenerationStatus>.Continuation?
        var statusStream: AsyncStream<GenerationStatus> {
            AsyncStream { continuation in
                self.statusContinuation = continuation
                continuation.yield(self.status)
            }
        }
        
        struct LastRunStats {
            let totalTokens: Int
            let elapsed: TimeInterval
            let tokensPerSecond: Double
        }
        
        init(modelPath: String, configuration: AIModelConfiguration) {
            self.modelPath = modelPath
            
            llama_backend_init()
            llama_numa_init(GGML_NUMA_STRATEGY_DISABLED)
            
            var modelParams = llama_model_default_params()
            
#if targetEnvironment(simulator)
            modelParams.n_gpu_layers = 0 // CPU-only for portability
#endif
            
            guard let modelPtr = llama_model_load_from_file(modelPath, modelParams) else {
                fatalError("Failed to load model")
            }
            self.model = modelPtr
            
            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = UInt32(configuration.nCTX)
            ctxParams.n_batch = UInt32(configuration.nCTX - configuration.maxTokenCount)
            guard let ctxPtr = llama_init_from_model(model, ctxParams) else {
                fatalError("Failed to init context")
            }
            self.ctx = ctxPtr
            
            let vocab = llama_model_get_vocab(model)
            self.modelNVocab = llama_vocab_n_tokens(vocab)
            self.configuration = configuration
        }
        
        func isModelLoaded() -> Bool {
            let bufferSize = 256
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            
            let desc = llama_model_desc(model, buffer, bufferSize)
            if desc > 0 {
                return true
            } else {
                return false
            }
        }
        
        /// Tokenizes a prompt
        func tokenize(_ prompt: String, addBos: Bool = false) -> [llama_token] {
            let vocab = llama_model_get_vocab(model)
            let utf8Count = prompt.utf8.count
            var tokens = [llama_token](repeating: 0, count: utf8Count + 2)
            let n = llama_tokenize(vocab, prompt, Int32(utf8Count), &tokens, Int32(tokens.count), addBos, true)
            return Array(tokens.prefix(Int(n)))
        }
        
        func tokenCount(_ prompt: String, addBos: Bool = false) -> Int {
            return tokenize(prompt, addBos: addBos).count
        }
        
        /// Clears all model and batch state for a completely new conversation
        func resetConversation() {
            isGenerating = false
            shouldStopGeneration = false
            llama_kv_self_clear(ctx)
            conversationTokenCount = 0
            currentRunIdentifier = nil
            lastPromptTokens = []
        }
        
        /// Gets the current status
        func getStatus() -> GenerationStatus {
            return status
        }
        
        /// Light reset that preserves KV cache for conversation continuity
        private func resetGeneration() {
            isGenerating = false
            shouldStopGeneration = false
            // Preserve KV cache and conversation state
        }
        
        /// Stop Generation - cancels current and all queued generations
        func stopGeneration() {
            shouldStopGeneration = true
            // Cancel all queued tasks
            for (task, _) in generationQueue {
                task.cancel()
            }
            updateQueueStatus()
        }
        
        /// Stop a specific generation by runIdentifier
        func stopGeneration(runIdentifier: String) {
            if currentlyGeneratingIdentifier == runIdentifier {
                shouldStopGeneration = true
            }
            // Cancel specific task in queue
            if let index = generationQueue.firstIndex(where: { $0.runIdentifier == runIdentifier }) {
                generationQueue[index].task.cancel()
                generationQueue.remove(at: index)
                updateQueueStatus()
            }
        }
        
        /// Get queue position for a runIdentifier
        func getQueuePosition(for runIdentifier: String) -> Int? {
            if currentlyGeneratingIdentifier == runIdentifier {
                return 0 // Currently processing
            }
            return generationQueue.firstIndex(where: { $0.runIdentifier == runIdentifier })
                .map { $0 + 1 } // 1-based position
        }
        
        /// Get total queue size
        func getQueueSize() -> Int {
            return generationQueue.count + (currentlyGeneratingIdentifier != nil ? 1 : 0)
        }
        
        /// Update queue status for all items
        private func updateQueueStatus() {
            // Clean up completed/cancelled tasks
            generationQueue.removeAll { task, _ in
                task.isCancelled
            }
            
            // Update status based on current state
            if let currentId = currentlyGeneratingIdentifier {
                let total = generationQueue.count + 1
                status = .generating(runIdentifier: currentId, position: 1, total: total)
            } else if generationQueue.isEmpty {
                status = .idle
            }
            
            // Notify queued items of their positions
            for (index, (_, runId)) in generationQueue.enumerated() {
                // You could emit individual status updates here if needed
                _ = GenerationStatus.queued(runIdentifier: runId, position: index + 2)
            }
        }
        
        /// Gets the current run identifier
        func getCurrentRunIdentifier() -> String? {
            return currentRunIdentifier
        }
        
        /// Gets current conversation length in tokens
        func getConversationLength() -> Int {
            return conversationTokenCount
        }
        
        /// Checks if additional tokens can fit in context window
        func canFitInContext(additionalTokens: Int) -> Bool {
            let reservedTokens = 4
            return conversationTokenCount + additionalTokens + configuration.maxTokenCount < Int(configuration.nCTX) - reservedTokens
        }
        
        /// Finds the new tokens that were added to the end of the current prompt compared to the last prompt
        private func findNewTokens(currentTokens: [llama_token], previousTokens: [llama_token]) -> [llama_token] {
            // If previous is empty, all current tokens are new
            guard !previousTokens.isEmpty else { return currentTokens }
            
            // If current is shorter than previous, this is a completely new conversation
            guard currentTokens.count >= previousTokens.count else { return currentTokens }
            
            // Check if the previous tokens are a prefix of the current tokens
            let prefixMatches = zip(previousTokens, currentTokens).allSatisfy { $0 == $1 }
            
            if prefixMatches {
                // Previous tokens are a prefix, return only the new tokens at the end
                return Array(currentTokens.dropFirst(previousTokens.count))
            } else {
                // The prompts diverged, treat as completely new conversation
                return currentTokens
            }
        }
        
        /// Processes tokens and adds them to the conversation context without generating
        /// - Parameters:
        ///   - text: The text to add to conversation context
        ///   - runIdentifier: Identifier for the conversation thread
        func appendToConversation(_ text: String, runIdentifier: String) async throws {
            // Wait for all queued generations to complete to ensure exclusive access
            for (task, _) in generationQueue {
                await task.value
            }
            
            // Check if we need to start fresh
            if currentRunIdentifier != runIdentifier {
                resetConversation()
                currentRunIdentifier = runIdentifier
            }
            
            let tokens = tokenize(text)
            let newTokens = findNewTokens(currentTokens: tokens, previousTokens: lastPromptTokens)
            
            guard canFitInContext(additionalTokens: newTokens.count) else {
                throw NSError(
                    domain: "llama",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Adding new tokens would exceed context window."]
                )
            }
            
            if !newTokens.isEmpty {
                var batch = llama_batch_init(Int32(newTokens.count), 0, 1)
                defer { llama_batch_free(batch) }
                
                for (i, token) in newTokens.enumerated() {
                    batch.add(
                        token: token,
                        position: Int32(conversationTokenCount + i),
                        seqIDs: [0],
                        logit: false  // Don't compute logits for context-only tokens
                    )
                }
                
                if llama_decode(ctx, batch) != 0 {
                    throw NSError(domain: "llama", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to process context tokens"])
                }
                
                conversationTokenCount += newTokens.count
                lastPromptTokens = tokens
            }
        }
        
        /// Generates output from a prompt with conversation continuity based on run identifier
        /// - Parameters:
        ///   - prompt: The input prompt to generate from
        ///   - runIdentifier: Unique identifier for the conversation thread. If different from last run, starts fresh.
        ///   - maxTokens: Optional override for max tokens (must be less than configuration.maxTokenCount)
        func generate(prompt: String, runIdentifier: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            
            // Validate and set the effective max token count
            let effectiveMaxTokens: Int
            if let requestedMaxTokens = maxTokens {
                if requestedMaxTokens <= configuration.maxTokenCount {
                    effectiveMaxTokens = requestedMaxTokens
                    FreeToken.shared.logger("📝 Using custom max tokens: \(effectiveMaxTokens)", .info)
                } else {
                    FreeToken.shared.logger("⚠️ Requested max tokens (\(requestedMaxTokens)) exceeds configuration limit (\(configuration.maxTokenCount)). Falling back to configuration max.", .warning)
                    effectiveMaxTokens = configuration.maxTokenCount
                }
            } else {
                effectiveMaxTokens = configuration.maxTokenCount
            }
            
            // Create the generation task
            let newTask = Task { @Sendable [weak self] in
                guard let self = self else {
                    continuation.finish(throwing: NSError(domain: "llama", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self was deallocated"]))
                    return
                }
                
                // Find our position in the queue
                var position = 1
                var tasksToWaitFor: [Task<Void, Never>] = []
                
                // Calculate position and get tasks to wait for
                for (task, id) in self.generationQueue {
                    if id == runIdentifier {
                        break
                    }
                    position += 1
                    tasksToWaitFor.append(task)
                }
                
                // Update status to queued if not first
                if position > 1 || self.currentlyGeneratingIdentifier != nil {
                    let actualPosition = self.currentlyGeneratingIdentifier != nil ? position + 1 : position
                    self.status = .queued(runIdentifier: runIdentifier, position: actualPosition)
                }
                
                // Wait for all previous tasks to complete
                for previousTask in tasksToWaitFor {
                    await previousTask.value
                }
                
                // Also wait for current generation if any
                if self.currentlyGeneratingIdentifier != nil {
                    // Wait a bit for current generation to complete
                    while self.currentlyGeneratingIdentifier != nil {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    }
                }
                
                do {
                    // Check for cancellation after waiting
                    try Task.checkCancellation()
                    
                    // We're now the active generation
                    self.currentlyGeneratingIdentifier = runIdentifier
                    self.updateQueueStatus()
                    
                    // Perform the generation with the effective max tokens
                    try await self._performGeneration(
                        prompt: prompt,
                        runIdentifier: runIdentifier,
                        continuation: continuation,
                        maxTokens: effectiveMaxTokens
                    )
                    
                    // Clear current identifier when done
                    self.currentlyGeneratingIdentifier = nil
                    
                    // Remove ourselves from the queue
                    if let index = self.generationQueue.firstIndex(where: { $0.runIdentifier == runIdentifier }) {
                        self.generationQueue.remove(at: index)
                    }
                    
                    self.updateQueueStatus()
                } catch is CancellationError {
                    self.currentlyGeneratingIdentifier = nil
                    // Remove ourselves from the queue
                    if let index = self.generationQueue.firstIndex(where: { $0.runIdentifier == runIdentifier }) {
                        self.generationQueue.remove(at: index)
                    }
                    self.updateQueueStatus()
                    continuation.finish()
                } catch {
                    self.currentlyGeneratingIdentifier = nil
                    // Remove ourselves from the queue
                    if let index = self.generationQueue.firstIndex(where: { $0.runIdentifier == runIdentifier }) {
                        self.generationQueue.remove(at: index)
                    }
                    self.updateQueueStatus()
                    continuation.finish(throwing: error)
                }
            }
            
            // Add to queue
            generationQueue.append((task: newTask, runIdentifier: runIdentifier))
            updateQueueStatus()
            
            return stream
        }
        
        /// Internal method that performs the actual generation
        private func _performGeneration(
            prompt: String,
            runIdentifier: String,
            continuation: AsyncThrowingStream<String, Error>.Continuation,
            maxTokens: Int? = nil
        ) async throws {
            self.isGenerating = true
            defer {
                self.isGenerating = false
                self.shouldStopGeneration = false
            }
            
            // Use provided maxTokens or fall back to configuration
            let effectiveMaxTokens = maxTokens ?? configuration.maxTokenCount
            
            resetGeneration()
            
            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
            defer { llama_sampler_free(sampler) }
            
            // FIXED: Correct sampler order - penalties FIRST
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                configuration.penaltyLastN,    // penalty_last_n
                configuration.penaltyRepeat,   // penalty_repeat
                configuration.penaltyFrequency,   // penalty_freq
                0.0    // penalty_present
            ))
            
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(configuration.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(configuration.topK)))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(configuration.topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(1234))
            
            // Tokenize the full prompt
            let promptTokens = tokenize(prompt)
            
            // Determine if we need to start fresh or continue existing conversation
            let isNewConversation = currentRunIdentifier != runIdentifier
            let tokensToProcess: [llama_token]
            let startPosition: Int
            
            if isNewConversation {
                // New conversation - reset everything
                resetConversation()
                currentRunIdentifier = runIdentifier
                tokensToProcess = promptTokens
                startPosition = 0
                lastPromptTokens = promptTokens
                FreeToken.shared.logger("🗣️ Cache MISS: New conversation - processing \(tokensToProcess.count) tokens", .info)
            } else {
                // Continuing existing conversation - find only the new tokens
                let newTokens = findNewTokens(currentTokens: promptTokens, previousTokens: lastPromptTokens)
                
                if newTokens.count == promptTokens.count {
                    // The entire prompt is new (diverged from previous), reset conversation
                    resetConversation()
                    currentRunIdentifier = runIdentifier
                    tokensToProcess = promptTokens
                    startPosition = 0
                    lastPromptTokens = promptTokens
                    FreeToken.shared.logger("🗣️ Cache MISS: Conversation diverged - processing \(tokensToProcess.count) tokens", .info)
                } else {
                    // Only process the new tokens at the end
                    tokensToProcess = newTokens
                    startPosition = conversationTokenCount
                    lastPromptTokens = promptTokens
                    FreeToken.shared.logger("🗣️ Cache HIT: Processing \(tokensToProcess.count) new tokens (saved \(promptTokens.count - tokensToProcess.count) tokens)", .info)
                }
            }
            
            // Check context limits
            let reservedTokens = 4
            let totalNeededTokens = startPosition + tokensToProcess.count + effectiveMaxTokens
            if totalNeededTokens > Int(configuration.nCTX) - reservedTokens {
                throw NSError(
                    domain: "llama",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Conversation (\(startPosition)) + prompt (\(tokensToProcess.count)) + maxTokens (\(effectiveMaxTokens)) exceeds context window (\(Int(configuration.nCTX) - reservedTokens))."]
                )
            }
            
            // Process the new prompt tokens (if any)
            if !tokensToProcess.isEmpty {
                var promptBatch = llama_batch_init(Int32(tokensToProcess.count), 0, 1)
                defer { llama_batch_free(promptBatch) }
                
                for (i, token) in tokensToProcess.enumerated() {
                    let tokenPosition = Int32(startPosition + i)
                    let isLastToken = i == tokensToProcess.count - 1
                    promptBatch.add(
                        token: token,
                        position: tokenPosition,
                        seqIDs: [0],
                        logit: isLastToken  // Only compute logits for last token
                    )
                }
                
                if llama_decode(ctx, promptBatch) != 0 {
                    throw NSError(domain: "llama", code: 1, userInfo: [NSLocalizedDescriptionKey: "Decode failed"])
                }
                
                conversationTokenCount = startPosition + tokensToProcess.count
            } else {
                // No new tokens to process - this shouldn't happen on first run
                throw NSError(domain: "llama", code: 4, userInfo: [NSLocalizedDescriptionKey: "No tokens to process"])
            }
            
            let genStart = Date()
            
            var generated = 0
            var utf8Buffer = Data()
            var outputBuffer = ""
            
            // Generate tokens one by one
            let lastBatchSize = tokensToProcess.count // Track the size of the last batch processed
            while generated < effectiveMaxTokens {
                // Check for cancellation
                try Task.checkCancellation()
                
                if shouldStopGeneration {
                    break
                }
                
                // For the first iteration, use the prompt batch logits
                // For subsequent iterations, use the single-token generation batch logits
                let logitIndex: Int32
                if generated == 0 {
                    // First generation - use the last token from the prompt batch
                    logitIndex = Int32(lastBatchSize - 1)
                } else {
                    // Subsequent generations - use the single token from the generation batch
                    logitIndex = 0
                }
                
                // Sample using the correct logit index
                let nextToken = llama_sampler_sample(sampler, ctx, logitIndex)
                let vocab = llama_model_get_vocab(model)
                
                // Check for end of generation
                if llama_vocab_is_eog(vocab, nextToken) {
                    break
                }
                
                // Convert token to string
                var piece = [CChar](repeating: 0, count: 32)
                let nPiece = llama_token_to_piece(vocab, nextToken, &piece, 32, 0, false)
                if nPiece > 0 {
                    let index = min(Int(nPiece), piece.count - 1)
                    piece[index] = 0
                    let bytes = piece[0..<index].map { UInt8(bitPattern: $0) }
                    utf8Buffer.append(contentsOf: bytes)
                    
                    // Process UTF-8 buffer
                    while !utf8Buffer.isEmpty {
                        var maxValidPrefix = 0
                        for i in (1...utf8Buffer.count) {
                            let prefix = utf8Buffer.prefix(i)
                            if let _ = String(data: prefix, encoding: .utf8) {
                                maxValidPrefix = i
                            }
                        }
                        if maxValidPrefix > 0 {
                            let validData = utf8Buffer.prefix(maxValidPrefix)
                            if let validStr = String(data: validData, encoding: .utf8) {
                                outputBuffer += validStr
                                let (prefix, shouldStop) = checkForStopToken(outputBuffer)
                                if shouldStop {
                                    continuation.yield(prefix)
                                    continuation.finish()
                                    return
                                } else {
                                    continuation.yield(outputBuffer)
                                    outputBuffer = ""
                                    await Task.yield()
                                }
                            }
                            utf8Buffer.removeFirst(maxValidPrefix)
                        } else {
                            break
                        }
                    }
                }
                
                // Prepare batch for next token
                var genBatch = llama_batch_init(1, 0, 1)
                defer { llama_batch_free(genBatch) }
                
                genBatch.add(
                    token: nextToken,
                    position: Int32(conversationTokenCount),
                    seqIDs: [0],
                    logit: true
                )
                
                if llama_decode(ctx, genBatch) != 0 {
                    break
                }
                
                conversationTokenCount += 1
                generated += 1
                
                // Check context limits
                if conversationTokenCount >= Int(configuration.nCTX) - reservedTokens {
                    break
                }
            }
            
            let genEnd = Date()
            let elapsed = genEnd.timeIntervalSince(genStart)
            let tokensPerSecond = elapsed > 0 ? Double(generated) / elapsed : 0
            FreeToken.shared.logger("Generated \(generated) tokens in \(elapsed) seconds (\(tokensPerSecond) tokens/sec)", .info)
            self.lastRunStats = LastRunStats(totalTokens: generated, elapsed: elapsed, tokensPerSecond: tokensPerSecond)
            
            // Send any remaining output
            if !outputBuffer.isEmpty {
                continuation.yield(outputBuffer)
            }
            if !utf8Buffer.isEmpty, let str = String(data: utf8Buffer, encoding: .utf8) {
                continuation.yield(str)
                await Task.yield()
            }
            
            continuation.finish()
        }
        
        private func checkForStopToken(_ text: String) -> (String, Bool) {
            // Returns (text up to stop token, shouldStop)
            guard !configuration.stopTokens.isEmpty else { return (text, false) }
            // Find the earliest stop token in the text
            var earliest: (index: String.Index, stop: String)? = nil
            for stop in configuration.stopTokens {
                if let idx = text.range(of: stop)?.lowerBound {
                    if earliest == nil || idx < earliest!.index {
                        earliest = (idx, stop)
                    }
                }
            }
            if let (idx, _) = earliest {
                let prefix = String(text[..<idx])
                return (prefix, true)
            } else {
                return (text, false)
            }
        }
        
        func cleanup() {
            // Cancel all queued generations before cleanup
            for (task, _) in generationQueue {
                task.cancel()
            }
            llama_free(ctx)
            llama_model_free(model)
        }
        
        deinit {
            llama_backend_free()
        }
    }
    
    typealias Batch = llama_batch
}

extension FreeToken.Batch {
    mutating func add(token: llama_token,
                      position: llama_pos,
                      seqIDs: [llama_seq_id],
                      logit: Bool) {
        let nextIndex = Int(n_tokens)
        self.token[nextIndex] = token
        self.pos[nextIndex] = position
        self.n_seq_id[nextIndex] = Int32(seqIDs.count)
        seqIDs.enumerated().forEach { index, id in
            seq_id[nextIndex]?[index] = id
        }
        self.logits[nextIndex] = logit ? 1 : 0
        self.n_tokens += 1
    }
}
