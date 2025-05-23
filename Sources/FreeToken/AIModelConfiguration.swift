import Foundation
import llama

extension FreeToken {
    struct AIModelConfiguration {
        let topK: Int
        let topP: Float
        let nCTX: Int
        let temperature: Float
        let maxTokenCount: Int
        let stopTokens: [String]
        
        init(topK: Int, topP: Float, nCTX: Int, temperature: Float, maxTokenCount: Int, stopTokens: [String]) {
            self.topK = topK
            self.topP = topP
            self.nCTX = nCTX
            self.temperature = temperature
            self.maxTokenCount = maxTokenCount
            self.stopTokens = stopTokens
        }
    }
}
