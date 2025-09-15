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
            // Step 1: guesstimate required size
            let words = text.split(separator: " ").count
            let estimatedSize = Int(Double(words) * 1.5) + 500
            
            // Step 2: allocate
            var tokens = Array<llama_token>(repeating: 0, count: estimatedSize)
            
            // Step 3: tokenize
            let produced = llama_tokenize(vocab, text, Int32(text.count),
                                          &tokens, Int32(tokens.count),
                                          false, false)
            
            // Step 4: trim trailing zeroes
            return tokens.prefix(Int(produced)).map { Int32($0) }
        }
        
        deinit {
            llama_model_free(model)
        }
        
    }
    
}
