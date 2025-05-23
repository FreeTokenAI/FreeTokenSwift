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
        var lastRunStats: LastRunStats?
        
        struct LastRunStats {
            let totalTokens: Int
            let elapsed: TimeInterval
            let tokensPerSecond: Double
        }
        
        init(modelPath: String, configuration: AIModelConfiguration) {
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
        
        /// Clears all model and batch state for a fresh run
        func reset() {
            llama_kv_self_clear(ctx)
        }
        
        /// Generates output from a prompt, up to maxTokens
        func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            
            Task { @Sendable [self] in
                do {
                    reset()
                    
                    let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
                    llama_sampler_chain_add(sampler, llama_sampler_init_temp(configuration.temperature))
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(configuration.topK)))
                    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(configuration.topP, 1))
                    llama_sampler_chain_add(sampler, llama_sampler_init_dist(1234))
                    
                    // 1. Tokenize prompt
                    let promptTokens = tokenize(prompt) // Prompt tokens
                    let reservedTokens = 4 // Throw in a few extra tokens to give some breathing room
                    if promptTokens.count + configuration.maxTokenCount > Int(configuration.nCTX) - reservedTokens {
                        throw NSError(
                            domain: "llama",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Prompt (\(promptTokens.count)) + maxTokens (\(configuration.maxTokenCount)) exceeds context window (\(Int(configuration.nCTX) - reservedTokens))."]
                        )
                    }
                    var genBatch = llama_batch_init(Int32(promptTokens.count), 0, 1)
                    
                    // Fill batch with prompt tokens
                    for (i, tok) in promptTokens.enumerated() {
                        genBatch.add(token: tok, position: Int32(i), seqIDs: [0], logit: false)
                    }
                    genBatch.logits[Int(genBatch.n_tokens) - 1] = 1 // compute logits for last token
                    
                    if llama_decode(ctx, genBatch) != 0 {
                        throw NSError(domain: "llama", code: 1, userInfo: [NSLocalizedDescriptionKey: "Decode failed"])
                    }
                    llama_batch_free(genBatch)
                    
                    let genStart = Date()
                    
                    var generated = 0
                    var utf8Buffer = Data()
                    var outputBuffer = ""
                    
                    // 2. Generate tokens, using a new batch each time
                    while generated < configuration.maxTokenCount {
                        guard let logitsPtr = llama_get_logits(ctx) else {
                            throw NSError(domain: "llama", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to get logits"])
                        }
                        let maxToken = llama_sampler_sample(sampler, ctx, genBatch.n_tokens - 1)
                        let vocab = llama_model_get_vocab(model)
                        if llama_vocab_is_eog(vocab, maxToken) {
                            break
                        }
                        
                        // Convert token to string (as bytes)
                        var piece = [CChar](repeating: 0, count: 32)
                        let nPiece = llama_token_to_piece(vocab, maxToken, &piece, 32, 0, false)
                        if nPiece > 0 {
                            let index = min(Int(nPiece), piece.count - 1)
                            piece[index] = 0
                            let bytes = piece[0..<index].map { UInt8(bitPattern: $0) }
                            utf8Buffer.append(contentsOf: bytes)
                            
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
                        
                        // Prepare fresh batch for next token
                        genBatch = llama_batch_init(1, 0, 1)
                        genBatch.add(token: maxToken, position: Int32(promptTokens.count) + Int32(generated), seqIDs: [0], logit: true)
                        if llama_decode(ctx, genBatch) != 0 { break }
                        llama_batch_free(genBatch)
                        
                        generated += 1
                        
                        if Int32(generated) + Int32(promptTokens.count) >= configuration.nCTX {
                            break
                        }
                    }
                    
                    let genEnd = Date()
                    let elapsed = genEnd.timeIntervalSince(genStart)
                    let tokensPerSecond = elapsed > 0 ? Double(generated) / elapsed : 0
                    print("Generated \(generated) tokens in \(elapsed) seconds (\(tokensPerSecond) tokens/sec)")
                    self.lastRunStats = LastRunStats(totalTokens: generated, elapsed: elapsed, tokensPerSecond: tokensPerSecond)
                    
                    if !outputBuffer.isEmpty {
                        continuation.yield(outputBuffer)
                    }
                    if !utf8Buffer.isEmpty, let str = String(data: utf8Buffer, encoding: .utf8) {
                        continuation.yield(str)
                        await Task.yield()
                    }
                    continuation.finish()
                    llama_sampler_free(sampler)
                } catch {
                    continuation.finish(throwing: error)
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
            if let (idx, stop) = earliest {
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
