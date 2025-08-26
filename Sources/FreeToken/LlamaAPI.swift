//
//  LlamaAPI.swift
//  FreeToken
//
//  Thin wrapper around llama.cpp C API for basic operations.
//  Does NOT include sampling - that's handled by freetoken_bridge.c
//

import Foundation
import llama

typealias LlamaToken = llama_token
typealias LlamaPos = llama_pos

extension FreeToken {
    
    /// Wrapper for basic llama.cpp operations
    enum LlamaAPI {
        
        // MARK: - Backend Management
        
        static func backendInit() {
            llama_backend_init()
        }
        
        static func backendFree() {
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
            
            // Apply template to get formatted text
            let bufferSize = 32768
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
        
        // MARK: - Template Detection
        
        /// Detect chat template style from template string (similar to llama.cpp's llm_chat_detect_template)
        static func detectTemplateStyle(from template: String) -> FreeToken.ChatTemplateStyle {
            // Check for specific markers in order of specificity
            
            // ChatML format
            if template.contains("<|im_start|>") {
                if template.contains("<|im_sep|>") {
                    return .phi4
                }
                return .chatml
            }
            
            // Llama 3 format
            if template.contains("<|start_header_id|>") || template.contains("<|begin_of_text|>") {
                return .llama3
            }
            
            // Mistral/Llama 2 formats (both use [INST] but with variations)
            if template.contains("[INST]") {
                // Mistral V7
                if template.contains("[SYSTEM_PROMPT]") {
                    return .mistralV7
                }
                // Mistral V3
                if template.contains("[AVAILABLE_TOOLS]") || template.contains("'[INST]'") {
                    return .mistralV3
                }
                // Llama 2 with system
                if template.contains("<<SYS>>") {
                    return .llama2Sys
                }
                // Mistral V1 or basic Llama 2
                if template.contains(" [INST]") {
                    return .mistralV1
                }
                return .llama2
            }
            
            // Gemma format
            if template.contains("<start_of_turn>") {
                return .gemma
            }
            
            // Phi-3 format
            if template.contains("<|user|>") && template.contains("<|assistant|>") {
                return .phi3
            }
            
            // DeepSeek format
            if template.contains("<｜begin▁of▁sentence｜>") || template.contains("User:") && template.contains("Assistant:") {
                return .deepseek
            }
            
            // Command-R format
            if template.contains("<|START_OF_TURN_TOKEN|>") {
                return .commandR
            }
            
            // Vicuna format
            if template.contains("USER:") && template.contains("ASSISTANT:") {
                return .vicuna
            }
            
            // Alpaca format
            if template.contains("### Instruction:") && template.contains("### Response:") {
                return .alpaca
            }
            
            // Zephyr format
            if template.contains("<|system|>") && template.contains("<|user|>") {
                return .zephyr
            }
            
            // OpenChat format
            if template.contains("GPT4 Correct ") {
                return .openchat
            }
            
            // Default to ChatML as fallback
            return .chatml
        }
    }
}