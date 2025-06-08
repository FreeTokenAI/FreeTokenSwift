import Foundation
import llama

extension FreeToken {
    struct AIModelConfiguration {
        let topK: Int
        let topP: Float
        let nCTX: Int
        let temperature: Float
        let maxTokenCount: Int
        let penaltyLastN: Int32
        let penaltyRepeat: Float
        let penaltyFrequency: Float
        let penaltyPresence: Float
        let stopTokens: [String]
        
        
        internal init(from modelOptions: Codings.AiModelConfigResponse.ModelOptions) {
            self.topK = modelOptions.topK
            self.topP = modelOptions.topP
            self.nCTX = modelOptions.contextWindowSize
            self.temperature = modelOptions.temperature
            self.maxTokenCount = modelOptions.maxTokenCount
            self.penaltyLastN = modelOptions.penaltyLastN
            self.penaltyRepeat = modelOptions.penaltyRepeat
            self.penaltyFrequency = modelOptions.penaltyFrequency
            self.penaltyPresence = modelOptions.penaltyPresence
            self.stopTokens = modelOptions.stopTokens
        }
    }
}
