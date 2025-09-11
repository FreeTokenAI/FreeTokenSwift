//
//  LlamaAPI.swift
//  FreeToken
//
//  Thin wrapper around llama.cpp C API for basic operations.
//  Does NOT include sampling - that's handled by freetoken_bridge.c
//

import Foundation
import llama

nonisolated(unsafe) private var isLlamaInitialized = false

extension FreeToken {

    typealias LlamaToken = llama_token
    typealias LlamaPos = llama_pos
    
    /// Wrapper for basic llama.cpp operations
    enum LlamaAPI {
        
        // MARK: - Backend Management
        
        static func backendInit() {
            if isLlamaInitialized { return }
            llama_backend_init()
            isLlamaInitialized = true
        }
        
        static func backendFree() {
            isLlamaInitialized = false
            llama_backend_free()
        }
        
        // MARK: - Model Management
        
        static func modelDefaultParams() -> llama_model_params {
            return llama_model_default_params()
        }
        
        static func loadModel(_ path: String, _ params: llama_model_params) -> OpaquePointer? {
            return llama_model_load_from_file(path, params)
        }
        
        static func freeModel(_ model: OpaquePointer) {
            llama_model_free(model)
        }
        
        static func vocabSize(_ model: OpaquePointer) -> Int {
            guard let vocab = llama_model_get_vocab(model) else { return 0 }
            return Int(llama_vocab_n_tokens(vocab))
        }
        
        /// Get the model's built-in chat template
        static func modelChatTemplate(_ model: OpaquePointer, name: String? = nil) -> String? {
            let cStr: UnsafePointer<CChar>?
            if let name = name {
                cStr = name.withCString { nameCStr in
                    llama_model_chat_template(model, nameCStr)
                }
            } else {
                cStr = llama_model_chat_template(model, nil)
            }
            
            guard let cStr = cStr else { return nil }
            return String(cString: cStr)
        }
        
        // MARK: - Context Management
        
        static func contextDefaultParams() -> llama_context_params {
            return llama_context_default_params()
        }
        
        static func newContext(_ model: OpaquePointer, _ params: llama_context_params) -> OpaquePointer? {
            return llama_init_from_model(model, params)
        }
        
        static func freeContext(_ context: OpaquePointer) {
            llama_free(context)
        }
        
        static func contextSize(_ context: OpaquePointer) -> Int {
            return Int(llama_n_ctx(context))
        }
        
        // MARK: - Tokenization
        
        static func tokenize(model: OpaquePointer, text: String, addBos: Bool, special: Bool) throws -> [LlamaToken] {
            guard let vocab = llama_model_get_vocab(model) else {
                throw FreeToken.FreeTokenError.llamaModelLoadFailed(message: "No vocab")
            }
            
            let utf8 = Array(text.utf8)
            let maxTokens = utf8.count + (addBos ? 1 : 0) + 10  // Buffer for safety
            var tokens = [LlamaToken](repeating: 0, count: maxTokens)
            
            let count = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocab, utf8, Int32(utf8.count), buffer.baseAddress, Int32(buffer.count), addBos, special)
            }
            
            guard count >= 0 else {
                throw FreeToken.FreeTokenError.aiRunFailed(message: "Tokenization failed")
            }
            
            return Array(tokens.prefix(Int(count)))
        }
        
        static func tokenToPiece(model: OpaquePointer, token: LlamaToken) -> String {
            guard let vocab = llama_model_get_vocab(model) else { return "" }
            
            let bufferSize = 256
            var buffer = [CChar](repeating: 0, count: bufferSize)
            
            let written = buffer.withUnsafeMutableBufferPointer { ptr in
                llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(bufferSize), 0, false)
            }
            
            guard written > 0 else { return "" }
            // Convert CChar (Int8) buffer to String
            let data = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
            return String(decoding: data, as: UTF8.self)
        }
        
        // MARK: - Chat Templates
        
        static func chatApplyTemplate(
            model: OpaquePointer,
            template: String?,
            messages: [(role: String, content: String)],
            addAssistant: Bool
        ) throws -> [LlamaToken] {
            // Convert messages to chat format expected by llama.cpp
            var chatMessages = messages.map { msg in
                llama_chat_message(role: msg.role.withCString { strdup($0) }, content: msg.content.withCString { strdup($0) })
            }
            defer {
                for msg in chatMessages {
                    free(UnsafeMutableRawPointer(mutating: msg.role))
                    free(UnsafeMutableRawPointer(mutating: msg.content))
                }
            }
            
            // Calculate a reasonable buffer size based on message content
            // Each message contributes its content + role + template overhead (~100 chars per message)
            let estimatedSize = messages.reduce(0) { $0 + $1.content.count + $1.role.count + 100 }
            // Use at least 32KB, but scale up for large conversations
            let bufferSize = max(32768, estimatedSize * 2)  // 2x for safety margin
            var buffer = [CChar](repeating: 0, count: bufferSize)
            
            let result = chatMessages.withUnsafeMutableBufferPointer { msgPtr in
                buffer.withUnsafeMutableBufferPointer { bufPtr in
                    if let tmpl = template {
                        return tmpl.withCString { tmplCStr in
                            llama_chat_apply_template(
                                tmplCStr,
                                msgPtr.baseAddress,
                                msgPtr.count,
                                addAssistant,
                                bufPtr.baseAddress,
                                Int32(bufferSize)
                            )
                        }
                    } else {
                        return llama_chat_apply_template(
                            nil,
                            msgPtr.baseAddress,
                            msgPtr.count,
                            addAssistant,
                            bufPtr.baseAddress,
                            Int32(bufferSize)
                        )
                    }
                }
            }
            
            guard result > 0 else {
                throw FreeToken.FreeTokenError.aiRunFailed(message: "Template application failed")
            }
            
            // Find null terminator and convert to string
            let nullIndex = buffer.firstIndex(of: 0) ?? buffer.count
            let data = buffer.prefix(nullIndex).map { UInt8(bitPattern: $0) }
            let formatted = String(decoding: data, as: UTF8.self)
            return try tokenize(model: model, text: formatted, addBos: false, special: true)
        }
        
        static func chatTemplateString( model: OpaquePointer, template: String?, messages: [(role: String, content: String)] ) throws -> String {
            var chatMessages = messages.map { msg in
                llama_chat_message(role: msg.role.withCString { strdup($0) }, content: msg.content.withCString { strdup($0) })
            }
            defer {
                for msg in chatMessages {
                    free(UnsafeMutableRawPointer(mutating: msg.role))
                    free(UnsafeMutableRawPointer(mutating: msg.content))
                }
            }
            
            // Calculate a reasonable buffer size based on message content
            // Each message contributes its content + role + template overhead (~100 chars per message)
            let estimatedSize = messages.reduce(0) { $0 + $1.content.count + $1.role.count + 100 }
            // Use at least 32KB, but scale up for large conversations
            let bufferSize = max(32768, estimatedSize * 2)  // 2x for safety margin
            var buffer = [CChar](repeating: 0, count: bufferSize)
            
            let result = chatMessages.withUnsafeMutableBufferPointer { msgPtr in
                buffer.withUnsafeMutableBufferPointer { bufPtr in
                    if let tmpl = template {
                        return tmpl.withCString { tmplCStr in
                            llama_chat_apply_template(
                                tmplCStr,
                                msgPtr.baseAddress,
                                msgPtr.count,
                                false,
                                bufPtr.baseAddress,
                                Int32(bufferSize)
                            )
                        }
                    } else {
                        return llama_chat_apply_template(
                            nil,
                            msgPtr.baseAddress,
                            msgPtr.count,
                            false,
                            bufPtr.baseAddress,
                            Int32(bufferSize)
                        )
                    }
                }
            }
            
            guard result > 0 else {
                throw FreeToken.FreeTokenError.aiRunFailed(message: "Template application failed")
            }
            
            // Find null terminator and convert to string
            let nullIndex = buffer.firstIndex(of: 0) ?? buffer.count
            let data = buffer.prefix(nullIndex).map { UInt8(bitPattern: $0) }
            let formatted = String(decoding: data, as: UTF8.self)
            
            return formatted
        }
        
        // MARK: - Batch Operations
        
        static func batchInit(_ nTokens: Int32, _ embd: Int32, _ nSeqMax: Int32) -> llama_batch {
            return llama_batch_init(nTokens, embd, nSeqMax)
        }
        
        static func batchFree(_ batch: inout llama_batch) {
            llama_batch_free(batch)
        }
        
        // MARK: - Logits Access
        
        static func logitsPointer(_ context: OpaquePointer) -> UnsafePointer<Float>? {
            return UnsafePointer(llama_get_logits(context))
        }
        
        static func logitsIthPointer(_ context: OpaquePointer, _ i: Int32) -> UnsafePointer<Float>? {
            return UnsafePointer(llama_get_logits_ith(context, i))
        }
        
        // MARK: - State Data
        
        static func getStateData(_ context: OpaquePointer, sequenceID: Int32 = 0) -> [UInt8] {
            let stateSize = llama_state_seq_get_size(context, sequenceID)
            var buffer = [UInt8](repeating: 0, count: stateSize)
            buffer.withUnsafeMutableBufferPointer { buf in
                _ = llama_state_seq_get_data(context, buf.baseAddress, stateSize, sequenceID)
            }
            return buffer
        }
        
        static func loadStateData(_ context: OpaquePointer, _ data: [UInt8], sequenceID: Int32 = 0) -> Bool {
            return data.withUnsafeBytes { buf in
                llama_state_seq_set_data(context, data, data.count, sequenceID) == data.count
            }
        }
        
        static func writeStateToDisk(_ context: OpaquePointer, path: String, sequenceID: Int32 = 0, tokens: [llama_token]) -> Bool {
            let result = llama_state_seq_save_file(context, path, sequenceID, tokens, tokens.count)
            if result == 0 {
                FreeToken.shared.logger("🔴 Failed to write state to disk at path: \(path)", .error)
            }
            
            return result != 0
        }
        
        static func loadStateFromDisk(
            _ context: OpaquePointer,
            path: String,
            sequenceID: Int32 = 0
        ) -> (tokens: [llama_token], token_count_out: Int) {
            // Setup token buffer & count
            let maxTokens = llama_n_ctx(context)
            var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
            
            return tokens.withUnsafeMutableBufferPointer { buf in
                var countOut = 0
                let result = llama_state_seq_load_file(context, path, sequenceID, buf.baseAddress, buf.count, &countOut)
                if result == 0 {
                    FreeToken.shared.logger("🔴 Failed to load state from disk at path: \(path)", .error)
                    return ([], 0)  // Failed to load
                } else {
                    return (Array(buf.prefix(countOut)), countOut)
                }
            }
        }
    }
}
