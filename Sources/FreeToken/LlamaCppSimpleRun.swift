import Foundation
import llama

extension FreeToken {
    @LlamaCppSwiftActor
    class LlamaCppMultiContextRun: @unchecked Sendable {
        private let model: OpaquePointer
        private let modelNVocab: Int32
        private let configuration: AIModelConfiguration
        private let modelPath: String
        
        // Multi-context management
        private var contexts: [String: ContextInfo] = [:]
        private var oneTimeRuns: Set<String> = [] // Track one-time run identifiers
        private let deviceMemoryBuffer: Int = 1 * 1024 * 1024 * 1024 // How much memory to leave on the device before clearing cache
        private var isGenerating: Bool = false
        private var shouldStopGeneration: Bool = false
        
        // Actor-based queue management
        private var generationQueue: [(task: Task<Void, Never>, runIdentifier: String)] = []
        private var currentlyGeneratingIdentifier: String?
        
        // Context information
        struct ContextInfo {
            let context: OpaquePointer
            var conversationTokenCount: Int
            var lastPromptTokens: [llama_token]
            var lastAccessTime: Date
            let creationTime: Date
            
            init(context: OpaquePointer) {
                self.context = context
                self.conversationTokenCount = 0
                self.lastPromptTokens = []
                self.lastAccessTime = Date()
                self.creationTime = Date()
            }
            
            mutating func updateAccess() {
                self.lastAccessTime = Date()
            }
        }
        
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
        var lastRunStats: LastRunStats?
        
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
            
            let vocab = llama_model_get_vocab(model)
            self.modelNVocab = llama_vocab_n_tokens(vocab)
            self.configuration = configuration
        }
        
        // MARK: - Context Management
        
        /// Creates a new context for a run identifier
        private func createContext() -> OpaquePointer? {
            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = UInt32(configuration.nCTX)
            ctxParams.n_batch = UInt32(configuration.nCTX - configuration.maxTokenCount)
            return llama_init_from_model(model, ctxParams)
        }
        
        /// Gets or creates a context for the given run identifier
        private func getOrCreateContext(for runIdentifier: String) throws -> ContextInfo {
            // Update access time if context exists
            if var existingContext = contexts[runIdentifier] {
                existingContext.updateAccess()
                contexts[runIdentifier] = existingContext
                FreeToken.shared.logger("🔄 Context cache HIT for \(runIdentifier)", .info)
                return existingContext
            }
            
            // Check memory usage before creating new context
            try enforceMemoryLimits()
            
            // Create new context
            guard let newContext = createContext() else {
                throw FreeTokenError(domain: "com.freetoken.llama", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Failed to create context for \(runIdentifier)"])
            }
            
            let contextInfo = ContextInfo(context: newContext)
            contexts[runIdentifier] = contextInfo
            FreeToken.shared.logger("🆕 Created new context for \(runIdentifier). Total contexts: \(contexts.count)", .info)
            
            return contextInfo
        }
        
        /// Estimates memory usage and cleans up contexts if needed
        private func enforceMemoryLimits() throws {
            let availableMemory = os_proc_available_memory()
            FreeToken.shared.logger("Available system memory is \(availableMemory / 1024 / 1024) mb", .info)
            
            if availableMemory < deviceMemoryBuffer {
                FreeToken.shared.logger("💾 Evacuating old caches as memory has hit threshold (available: \(availableMemory / 1024 / 1024) mb, free memory buffer: \(deviceMemoryBuffer))", .info)
                try cleanupOldestContexts(targetCount: max(1, contexts.count / 2))
            }
        }
        
        /// Cleans up the oldest contexts based on last access time
        private func cleanupOldestContexts(targetCount: Int) throws {
            let sortedContexts = contexts.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
            let contextsToRemove = Array(sortedContexts.prefix(targetCount))
            
            for (runId, contextInfo) in contextsToRemove {
                // Don't remove currently generating context
                if currentlyGeneratingIdentifier == runId {
                    continue
                }
                
                llama_free(contextInfo.context)
                contexts.removeValue(forKey: runId)
                FreeToken.shared.logger("🗑️ Cleaned up context for \(runId)", .info)
            }
            
            FreeToken.shared.logger("🧹 Context cleanup complete. Remaining contexts: \(contexts.count)", .info)
        }
        
        /// Forces cleanup of a specific context
        func clearContext(for runIdentifier: String) {
            guard let contextInfo = contexts.removeValue(forKey: runIdentifier) else { return }
            llama_free(contextInfo.context)
            FreeToken.shared.logger("🗑️ Manually cleared context for \(runIdentifier)", .info)
        }
        
        /// Clears all contexts
        func clearAllContexts() {
            for (runId, contextInfo) in contexts {
                llama_free(contextInfo.context)
                FreeToken.shared.logger("🗑️ Cleared context for \(runId)", .info)
            }
            contexts.removeAll()
            FreeToken.shared.logger("🧹 All contexts cleared", .info)
        }
        
        // MARK: - Public API
        
        func isModelLoaded() -> Bool {
            let bufferSize = 256
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            
            let desc = llama_model_desc(model, buffer, bufferSize)
            return desc > 0
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
        
        /// Clears conversation for a specific run identifier
        func resetConversation(for runIdentifier: String) {
            guard var contextInfo = contexts[runIdentifier] else { return }
            
            llama_kv_self_clear(contextInfo.context)
            contextInfo.conversationTokenCount = 0
            contextInfo.lastPromptTokens = []
            contextInfo.updateAccess()
            contexts[runIdentifier] = contextInfo
            
            FreeToken.shared.logger("🔄 Reset conversation for \(runIdentifier)", .info)
        }
        
        /// Gets the current status
        func getStatus() -> GenerationStatus {
            return status
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
        }
        
        /// Gets current conversation length for a specific run identifier
        func getConversationLength(for runIdentifier: String) -> Int {
            return contexts[runIdentifier]?.conversationTokenCount ?? 0
        }
        
        /// Checks if additional tokens can fit in context window for a specific run identifier
        func canFitInContext(additionalTokens: Int, for runIdentifier: String) -> Bool {
            let reservedTokens = 100
            let currentTokens = contexts[runIdentifier]?.conversationTokenCount ?? 0
            return currentTokens + additionalTokens + configuration.maxTokenCount < Int(configuration.nCTX) - reservedTokens
        }
        
        /// Check if a run identifier is marked as one-time
        func isOneTimeRun(_ runIdentifier: String) -> Bool {
            return oneTimeRuns.contains(runIdentifier)
        }
        
        /// Mark a run identifier as one-time (will be cleaned up after completion)
        func markAsOneTimeRun(_ runIdentifier: String) {
            oneTimeRuns.insert(runIdentifier)
            FreeToken.shared.logger("🔥 Marked \(runIdentifier) as one-time run", .info)
        }
        
        /// Unmark a run identifier as one-time (context will persist)
        func unmarkOneTimeRun(_ runIdentifier: String) {
            oneTimeRuns.remove(runIdentifier)
            FreeToken.shared.logger("📌 Unmarked \(runIdentifier) as one-time run", .info)
        }
        
        /// Finds the new tokens that were added to the end of the current prompt compared to the last prompt
        /// Returns the tokens that need to be processed and whether this is a cache miss
        private func findNewTokens(currentTokens: [llama_token], previousTokens: [llama_token]) -> (tokensToProcess: [llama_token], isCacheMiss: Bool) {
            // If previous is empty, all current tokens are new (cache miss)
            guard !previousTokens.isEmpty else {
                return (tokensToProcess: currentTokens, isCacheMiss: true)
            }
            
            // If current is shorter than previous, this is a completely new conversation (cache miss)
            guard currentTokens.count >= previousTokens.count else {
                return (tokensToProcess: currentTokens, isCacheMiss: true)
            }
            
            // Check if the previous tokens are a prefix of the current tokens (cache hit)
            let prefixMatches = zip(previousTokens, currentTokens).allSatisfy { $0 == $1 }
            
            if prefixMatches {
                // Cache hit - previous tokens are a prefix, return only the new tokens at the end
                let newTokens = Array(currentTokens.dropFirst(previousTokens.count))
                return (tokensToProcess: newTokens, isCacheMiss: false)
            } else {
                // Cache miss - the prompts diverged, need to reprocess everything
                return (tokensToProcess: currentTokens, isCacheMiss: true)
            }
        }
        
        /// Processes tokens and adds them to the conversation context without generating
        func appendToConversation(_ text: String, runIdentifier: String) async throws {
            // Wait for all queued generations to complete to ensure exclusive access
            for (task, _) in generationQueue {
                await task.value
            }
            
            var contextInfo = try getOrCreateContext(for: runIdentifier)
            let tokens = tokenize(text)
            let (newTokens, isCacheMiss) = findNewTokens(currentTokens: tokens, previousTokens: contextInfo.lastPromptTokens)
            
            if isCacheMiss {
                // Cache miss - need to reset context and process all tokens
                llama_kv_self_clear(contextInfo.context)
                contextInfo.conversationTokenCount = 0
                FreeToken.shared.logger("🗣️ Cache MISS for \(runIdentifier): Processing \(tokens.count) tokens (context reset)", .warning)
                
                // Check if the full prompt fits in context
                guard tokens.count + configuration.maxTokenCount < Int(configuration.nCTX) - 4 else {
                    throw FreeTokenError(
                        domain: "com.freetoken.llama",
                        code: 1002,
                        userInfo: [NSLocalizedDescriptionKey: "Full prompt (\(tokens.count) tokens) + maxTokens (\(configuration.maxTokenCount)) exceeds context window for \(runIdentifier)."]
                    )
                }
                
                // Process all tokens
                let tokensToProcess = tokens
                if !tokensToProcess.isEmpty {
                    var batch = llama_batch_init(Int32(tokensToProcess.count), 0, 1)
                    defer { llama_batch_free(batch) }
                    
                    for (i, token) in tokensToProcess.enumerated() {
                        let idx = Int(batch.n_tokens)
                        batch.token[idx] = token
                        batch.pos[idx] = Int32(i)
                        batch.n_seq_id[idx] = 1
                        batch.seq_id[idx]?[0] = 0
                        batch.logits[idx] = 0  // Don't compute logits for context-only tokens
                        batch.n_tokens += 1
                    }
                    
                    if llama_decode(contextInfo.context, batch) != 0 {
                        throw FreeTokenError(domain: "com.freetoken.llama", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Failed to process context tokens for \(runIdentifier) (cache miss)"])
                    }
                    
                    contextInfo.conversationTokenCount = tokensToProcess.count
                }
            } else {
                // Cache hit - only process new tokens
                FreeToken.shared.logger("🗣️ Cache HIT for \(runIdentifier): Processing \(newTokens.count) new tokens (saved \(tokens.count - newTokens.count) tokens)", .info)
                
                // Check if adding new tokens would exceed context
                guard contextInfo.conversationTokenCount + newTokens.count + configuration.maxTokenCount < Int(configuration.nCTX) - 4 else {
                    throw FreeTokenError(
                        domain: "com.freetoken.llama",
                        code: 1002,
                        userInfo: [NSLocalizedDescriptionKey: "Adding new tokens would exceed context window for \(runIdentifier)."]
                    )
                }
                
                if !newTokens.isEmpty {
                    var batch = llama_batch_init(Int32(newTokens.count), 0, 1)
                    defer { llama_batch_free(batch) }
                    
                    for (i, token) in newTokens.enumerated() {
                        let idx = Int(batch.n_tokens)
                        batch.token[idx] = token
                        batch.pos[idx] = Int32(contextInfo.conversationTokenCount + i)
                        batch.n_seq_id[idx] = 1
                        batch.seq_id[idx]?[0] = 0
                        batch.logits[idx] = 0  // Don't compute logits for context-only tokens
                        batch.n_tokens += 1
                    }
                    
                    if llama_decode(contextInfo.context, batch) != 0 {
                        throw FreeTokenError(domain: "com.freetoken.llama", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Failed to process context tokens for \(runIdentifier) (cache hit)"])
                    }
                    
                    contextInfo.conversationTokenCount += newTokens.count
                }
            }
            
            contextInfo.lastPromptTokens = tokens
            contextInfo.updateAccess()
            contexts[runIdentifier] = contextInfo
        }
        
        /// Generates output from a prompt with multi-context support
        /// - Parameters:
        ///   - prompt: The input prompt to generate from
        ///   - runIdentifier: Unique identifier for the conversation thread
        ///   - maxTokens: Optional override for max tokens
        ///   - isOneTimeRun: If true, the context will be automatically cleaned up after generation completes
        func generate(prompt: String, runIdentifier: String, maxTokens: Int? = nil, isOneTimeRun: Bool = false) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            
            // Mark as one-time run if specified
            if isOneTimeRun {
                oneTimeRuns.insert(runIdentifier)
                FreeToken.shared.logger("🔥 Marked \(runIdentifier) as one-time run", .info)
            }
            
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
                    continuation.finish(throwing: FreeTokenError(domain: "com.freetoken.llama", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Self was deallocated during generation"]))
                    return
                }
                
                // Wait for previous tasks in queue
                var position = 1
                var tasksToWaitFor: [Task<Void, Never>] = []
                
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
                while self.currentlyGeneratingIdentifier != nil {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
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
                    
                    // Clean up one-time run contexts immediately
                    if self.oneTimeRuns.contains(runIdentifier) {
                        self.clearContext(for: runIdentifier)
                        self.oneTimeRuns.remove(runIdentifier)
                        FreeToken.shared.logger("🧹 Auto-cleaned one-time run context: \(runIdentifier)", .info)
                    }
                    
                    // Clear current identifier when done
                    self.currentlyGeneratingIdentifier = nil
                    
                    // Remove ourselves from the queue
                    if let index = self.generationQueue.firstIndex(where: { $0.runIdentifier == runIdentifier }) {
                        self.generationQueue.remove(at: index)
                    }
                    
                    self.updateQueueStatus()
                } catch is CancellationError {
                    self.currentlyGeneratingIdentifier = nil
                    // Clean up one-time run even if cancelled
                    if self.oneTimeRuns.contains(runIdentifier) {
                        self.clearContext(for: runIdentifier)
                        self.oneTimeRuns.remove(runIdentifier)
                        FreeToken.shared.logger("🧹 Auto-cleaned cancelled one-time run context: \(runIdentifier)", .info)
                    }
                    // Remove ourselves from the queue
                    if let index = self.generationQueue.firstIndex(where: { $0.runIdentifier == runIdentifier }) {
                        self.generationQueue.remove(at: index)
                    }
                    self.updateQueueStatus()
                    continuation.finish()
                } catch {
                    self.currentlyGeneratingIdentifier = nil
                    // Clean up one-time run even if error occurred
                    if self.oneTimeRuns.contains(runIdentifier) {
                        self.clearContext(for: runIdentifier)
                        self.oneTimeRuns.remove(runIdentifier)
                        FreeToken.shared.logger("🧹 Auto-cleaned failed one-time run context: \(runIdentifier)", .info)
                    }
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
        
        /// Internal method that performs the actual generation using the appropriate context
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
            
            // Get or create context for this run identifier
            var contextInfo = try getOrCreateContext(for: runIdentifier)
            
            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
            defer { llama_sampler_free(sampler) }
            
            // Setup sampler chain
            llama_sampler_chain_add(sampler, llama_sampler_init_penalties(
                configuration.penaltyLastN,
                configuration.penaltyRepeat,
                configuration.penaltyFrequency,
                0.0
            ))
            
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(configuration.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(configuration.topK)))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(configuration.topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(1234))
            
            // Tokenize the full prompt
            let promptTokens = tokenize(prompt)
            
            // Compare against cached tokens to determine cache hit/miss
            let (newTokens, isCacheMiss) = findNewTokens(currentTokens: promptTokens, previousTokens: contextInfo.lastPromptTokens)
            
            var tokensToProcess: [llama_token]
            var startPosition: Int
            
            if isCacheMiss {
                // Cache miss - need to reset context and process all tokens
                llama_kv_self_clear(contextInfo.context)
                contextInfo.conversationTokenCount = 0
                FreeToken.shared.logger("🗣️ Context \(runIdentifier): CACHE MISS - Processing \(promptTokens.count) tokens (context reset)", .warning)
                
                // Check if the full prompt + generation fits in context
                let totalNeeded = promptTokens.count + effectiveMaxTokens + 4 // reservedTokens
                if totalNeeded > Int(configuration.nCTX) {
                    throw FreeTokenError(
                        domain: "com.freetoken.llama",
                        code: 1005,
                        userInfo: [NSLocalizedDescriptionKey: "Context \(runIdentifier): Full prompt (\(promptTokens.count)) + maxTokens (\(effectiveMaxTokens)) + reserved (4) = \(totalNeeded) exceeds context window (\(Int(configuration.nCTX)))."]
                    )
                }
                
                startPosition = 0
                // Process all tokens since it's a cache miss
                tokensToProcess = promptTokens
            } else {
                // Cache hit - only process new tokens
                let startPos = contextInfo.conversationTokenCount
                FreeToken.shared.logger("🗣️ Context \(runIdentifier): CACHE HIT - Processing \(newTokens.count) new tokens (saved \(promptTokens.count - newTokens.count) tokens)", .info)
                
                // Check if adding new tokens + generation fits in context
                let totalNeeded = startPos + newTokens.count + effectiveMaxTokens + 4 // reservedTokens
                if totalNeeded > Int(configuration.nCTX) {
                    throw FreeTokenError(
                        domain: "com.freetoken.llama",
                        code: 1005,
                        userInfo: [NSLocalizedDescriptionKey: "Context \(runIdentifier): Current (\(startPos)) + new tokens (\(newTokens.count)) + maxTokens (\(effectiveMaxTokens)) + reserved (4) = \(totalNeeded) exceeds context window (\(Int(configuration.nCTX)))."]
                    )
                }
                
                startPosition = startPos
                tokensToProcess = newTokens
            }
            
            // Process the new prompt tokens (if any)
            if !tokensToProcess.isEmpty {
                var promptBatch = llama_batch_init(Int32(tokensToProcess.count), 0, 1)
                defer { llama_batch_free(promptBatch) }
                
                for (i, token) in tokensToProcess.enumerated() {
                    let tokenPosition = Int32(startPosition + i)
                    let isLastToken = i == tokensToProcess.count - 1
                    let idx = Int(promptBatch.n_tokens)
                    promptBatch.token[idx] = token
                    promptBatch.pos[idx] = tokenPosition
                    promptBatch.n_seq_id[idx] = 1
                    promptBatch.seq_id[idx]?[0] = 0
                    promptBatch.logits[idx] = isLastToken ? 1 : 0
                    promptBatch.n_tokens += 1
                }
                
                if llama_decode(contextInfo.context, promptBatch) != 0 {
                    throw FreeTokenError(domain: "com.freetoken.llama", code: 1006, userInfo: [NSLocalizedDescriptionKey: "Decode failed for context \(runIdentifier)"])
                }
                
                contextInfo.conversationTokenCount = startPosition + tokensToProcess.count
                contextInfo.lastPromptTokens = promptTokens
                contextInfo.updateAccess()
                contexts[runIdentifier] = contextInfo
            }
            
            let genStart = Date()
            
            var generated = 0
            var utf8Buffer = Data()
            var outputBuffer = ""
            
            // Generate tokens one by one
            let lastBatchSize = tokensToProcess.count
            while generated < effectiveMaxTokens {
                // Check for cancellation
                try Task.checkCancellation()
                
                if shouldStopGeneration {
                    break
                }
                
                let logitIndex: Int32 = generated == 0 ? Int32(lastBatchSize - 1) : 0
                let nextToken = llama_sampler_sample(sampler, contextInfo.context, logitIndex)
                let vocab = llama_model_get_vocab(model)
                
                // Check for end of generation
                if llama_vocab_is_eog(vocab, nextToken) {
                    break
                }
                
                // Convert token to string and process output
                var piece = [CChar](repeating: 0, count: 32)
                let nPiece = llama_token_to_piece(vocab, nextToken, &piece, 32, 0, true)
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
                
                let idx = Int(genBatch.n_tokens)
                genBatch.token[idx] = nextToken
                genBatch.pos[idx] = Int32(contextInfo.conversationTokenCount)
                genBatch.n_seq_id[idx] = 1
                genBatch.seq_id[idx]?[0] = 0
                genBatch.logits[idx] = 1
                genBatch.n_tokens += 1
                
                if llama_decode(contextInfo.context, genBatch) != 0 {
                    break
                }
                
                contextInfo.conversationTokenCount += 1
                generated += 1
                
                // Update context info
                contextInfo.updateAccess()
                contexts[runIdentifier] = contextInfo
                
                // Check context limits
                if contextInfo.conversationTokenCount >= Int(configuration.nCTX) - 4 {
                    break
                }
            }
            
            let genEnd = Date()
            let elapsed = genEnd.timeIntervalSince(genStart)
            let tokensPerSecond = elapsed > 0 ? Double(generated) / elapsed : 0
            FreeToken.shared.logger("Context \(runIdentifier): Generated \(generated) tokens in \(elapsed) seconds (\(tokensPerSecond) tokens/sec)", .info)
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
            guard !configuration.stopTokens.isEmpty else { return (text, false) }
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
            
            // Clean up all contexts
            clearAllContexts()
            
            // Clean up model
            llama_model_free(model)
        }
    }
}
