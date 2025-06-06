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
        
        /// Light reset that preserves KV cache for conversation continuity
        private func resetGeneration() {
            isGenerating = false
            shouldStopGeneration = false
            // Preserve KV cache and conversation state
        }
        
        /// Stop Generation
        func stopGeneration() {
            if isGenerating {
                shouldStopGeneration = true
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
        func appendToConversation(_ text: String, runIdentifier: String) throws {
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
        func generate(prompt: String, runIdentifier: String) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            
            Task { @Sendable [self] in
                self.isGenerating = true
                do {
                    resetGeneration()
                    
                    let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
                    defer { llama_sampler_free(sampler) }
                    
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
                        print("🗣️ Cache MISS: New conversation - processing \(tokensToProcess.count) tokens")
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
                            print("🗣️ Cache MISS: Conversation diverged - processing \(tokensToProcess.count) tokens")
                        } else {
                            // Only process the new tokens at the end
                            tokensToProcess = newTokens
                            startPosition = conversationTokenCount
                            lastPromptTokens = promptTokens
                            print("🗣️ Cache HIT: Processing \(tokensToProcess.count) new tokens (saved \(promptTokens.count - tokensToProcess.count) tokens)")
                        }
                    }
                    
                    // Check context limits
                    let reservedTokens = 4
                    let totalNeededTokens = startPosition + tokensToProcess.count + configuration.maxTokenCount
                    if totalNeededTokens > Int(configuration.nCTX) - reservedTokens {
                        throw NSError(
                            domain: "llama",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Conversation (\(startPosition)) + prompt (\(tokensToProcess.count)) + maxTokens (\(configuration.maxTokenCount)) exceeds context window (\(Int(configuration.nCTX) - reservedTokens))."]
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
                    var lastBatchSize = tokensToProcess.count // Track the size of the last batch processed
                    while generated < configuration.maxTokenCount {
                        if shouldStopGeneration {
                            shouldStopGeneration = false
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
                    print("Generated \(generated) tokens in \(elapsed) seconds (\(tokensPerSecond) tokens/sec)")
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
                    self.isGenerating = false
                    self.shouldStopGeneration = false
                } catch {
                    continuation.finish(throwing: error)
                    self.isGenerating = false
                    self.shouldStopGeneration = false
                }
            }
            
            return stream
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
