//
//  LlamaTokenizer.swift
//  FreeToken
//
//  Created by Vince Francesi on 8/27/25.
//
import Foundation
import llama

extension FreeToken {
    
    class LlamaTokenizer {
        
        let model: OpaquePointer
        let vocab: OpaquePointer
        
        init(modelPath: String) {
            var params = llama_model_params()
            params.vocab_only = true
            params.use_mmap = true
            
            self.model = llama_model_load_from_file(modelPath, params)
            self.vocab = llama_model_get_vocab(model)
        }
        
        func tokenize(text: String) -> [Int32] {
            var tokens: [llama_token] = Array(repeating: 0, count: 512)
            _ = llama_tokenize(vocab, text, Int32(text.count), &tokens, 512, false, false)
            
            return tokens
        }
        
        deinit {
            llama_model_free(model)
        }
        
    }
    
}
