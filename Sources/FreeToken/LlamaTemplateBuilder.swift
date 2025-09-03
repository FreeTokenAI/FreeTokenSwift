//  LlamaTemplateBuilder.swift
//  FreeToken
//
//  Incremental template token builder using llama_chat_apply_template.
//  Builds conversation tokens message-by-message by re-rendering full chat and diffing.
//  
//  IMPORTANT: This implementation NEVER rebuilds the KV cache from scratch.
//  Only two operations are allowed:
//  1. Appending new tokens to the end of the KV cache (addMessages)
//  2. Removing tokens from the KV cache (removeMessages)
//  
//  If template divergence is detected (tokens don't match expected), an error is thrown.
//  This ensures KV cache consistency and prevents expensive rebuilds.

import Foundation

extension FreeToken {
    final class LlamaTemplateBuilder {
        struct Span { let start: Int; let end: Int; var count: Int { end - start } }
        private(set) var messages: [Message] = []
        private(set) var spans: [Span] = [] // aligned with messages
        private(set) var tokens: [Int32] = [] // cumulative rendered template tokens (no assistant slot)
        private let session: LlamaSession
        private let logPrefix = "TEMPLATE_BUILDER"
        
        init(session: LlamaSession) {
            self.session = session
        }
        
        func addMessages(_ newMessages: [Message]) async throws -> [Span] {
            guard !newMessages.isEmpty else { return [] }
            
            // Normalize roles helper function
            func canon(_ r: MessageRole) -> String {
                let raw = r.rawValue.lowercased()
                switch raw {
                case "system", "user", "assistant": return raw
                default:
                    FreeTokenLogger.shared.log("TEMPLATE_BUILDER unknown_role raw=\(r.rawValue) -> forcing 'user'", level: .warning)
                    return "user"
                }
            }
            
            // PHASE 1: Template all message combinations in parallel
            let parallelStart = Date()
            // Capture current messages before task group to avoid data race
            let currentMessages = self.messages
            let templateResults = try await withThrowingTaskGroup(of: (Int, [Int32]).self) { group in
                for (index, _) in newMessages.enumerated() {
                    // Capture values needed in the task
                    let messagesToTemplate = currentMessages + Array(newMessages[0...index])
                    let sess = self.session
                    
                    group.addTask {
                        let compact = messagesToTemplate.map { (canon($0.role), $0.content) }
                        let rendered = try await sess.applyChatTemplate(messages: compact, includeAssistantPrefix: false)
                        return (index, rendered.map { Int32($0) })
                    }
                }
                
                var results = Array(repeating: [Int32](), count: newMessages.count)
                for try await (index, tokens) in group {
                    results[index] = tokens
                }
                return results
            }
            let parallelMs = Int(Date().timeIntervalSince(parallelStart) * 1000)
            FreeTokenLogger.shared.log("\(logPrefix) parallel_template count=\(newMessages.count) ms=\(parallelMs)", level: .info)
            
            // PHASE 2: Validate consistency and calculate the final delta
            guard let finalTokens = templateResults.last else { return [] }
            
            // Verify tokens match up to current length (no divergence allowed)
            var lcpLength = 0
            let minC = min(tokens.count, finalTokens.count)
            while lcpLength < minC && tokens[lcpLength] == finalTokens[lcpLength] { lcpLength += 1 }
            
            if lcpLength != tokens.count {
                let errorMsg = "FATAL: Template divergence detected! Cannot append messages. " +
                              "LCP=\(lcpLength), oldCount=\(tokens.count), newCount=\(finalTokens.count). " +
                              "This indicates a template consistency issue that requires investigation."
                FreeTokenLogger.shared.log("\(logPrefix) \(errorMsg)", level: .error)
                throw FreeToken.FreeTokenError.aiRunFailed(message: errorMsg)
            }
            
            // PHASE 3: Single batch evaluation of all new tokens
            let deltaTokens = Array(finalTokens.dropFirst(tokens.count))
            if !deltaTokens.isEmpty {
                let evalStart = Date()
                
                // Optimize by evaluating all tokens except the last without logits
                if deltaTokens.count > 1 {
                    // Evaluate all but the last token without logits (faster)
                    let promptTokens = Array(deltaTokens.dropLast())
                    try await session.evalOptimized(tokens: promptTokens.map { Int($0) }, needsLogits: false)
                }
                
                // Always evaluate the last token WITH logits for generation
                let lastToken = deltaTokens.last!
                try await session.evalOptimized(tokens: [Int(lastToken)], needsLogits: true)
                
                let evalMs = Int(Date().timeIntervalSince(evalStart) * 1000)
                FreeTokenLogger.shared.log("\(logPrefix) batch_eval messages=\(newMessages.count) tokens=\(deltaTokens.count) ms=\(evalMs) tps=\(Double(deltaTokens.count * 1000) / Double(evalMs))", level: .info)
            }
            
            // PHASE 4: Update internal state - calculate spans for each message
            var appendedSpans: [Span] = []
            var previousEnd = tokens.count
            
            for (index, message) in newMessages.enumerated() {
                let currentTokens = templateResults[index]
                // The span for this message is from where the previous ended to where this one ends
                let span = Span(start: previousEnd, end: currentTokens.count)
                
                appendedSpans.append(span)
                spans.append(span)
                messages.append(message)
                
                FreeTokenLogger.shared.log("\(logPrefix) added messageRole=\(message.role.rawValue) msgIndex=\(messages.count-1) spanTokens=\(span.count) position=[\(span.start),\(span.end))", level: .debug)
                
                previousEnd = currentTokens.count
            }
            
            // Update the tokens to the final state
            tokens = finalTokens
            
            FreeTokenLogger.shared.log("\(logPrefix) batch_complete messages_added=\(newMessages.count) total_messages=\(messages.count) total_tokens=\(tokens.count)", level: .info)
            
            return appendedSpans
        }
        
        func renderWithAssistantSlot() async throws -> [Int32] {
            let compact = messages.map { ($0.role.rawValue, $0.content) }
            let rendered = try await session.applyChatTemplate(messages: compact, includeAssistantPrefix: true)
            return rendered.map { Int32($0) }
        }
        
        func removeMessages(at indices: [Int]) async throws {
            guard !indices.isEmpty else { return }
            
            let sortedIndices = indices.sorted()
            
            // If removing everything, just clear
            if sortedIndices.count == messages.count {
                await session.clearKVCache()
                messages.removeAll()
                spans.removeAll()
                tokens.removeAll()
                FreeTokenLogger.shared.log("\(logPrefix) removed_all_messages", level: .info)
                return
            }
            
            // Since we're doing middle-out removal, the indices should be contiguous
            // Find the range of tokens to remove
            let firstIndexToRemove = sortedIndices.first!
            let lastIndexToRemove = sortedIndices.last!
            
            // Validate that indices are contiguous (for middle-out strategy)
            let expectedCount = lastIndexToRemove - firstIndexToRemove + 1
            if sortedIndices.count != expectedCount {
                FreeTokenLogger.shared.log("\(logPrefix) warning: non-contiguous removal indices=\(sortedIndices)", level: .warning)
            }
            
            // Calculate the token range to remove
            let startToken = spans[firstIndexToRemove].start
            let endToken = spans[lastIndexToRemove].end
            let tokensToRemove = endToken - startToken
            
            FreeTokenLogger.shared.log("\(logPrefix) removing_messages indices=[\(firstIndexToRemove)...\(lastIndexToRemove)] tokenRange=[\(startToken),\(endToken)) count=\(tokensToRemove)", level: .info)
            
            // Remove the token range from KV cache
            try await session.removeKVCacheTokens(from: Int32(startToken), to: Int32(endToken))
            
            // Shift all tokens after the removed range
            if lastIndexToRemove < messages.count - 1 {
                // There are messages after the removed ones that need shifting
                let shiftStart = spans[lastIndexToRemove + 1].start
                try await session.shiftKVCacheTokens(
                    from: Int32(shiftStart),
                    count: Int32(tokens.count - shiftStart),
                    by: -Int32(tokensToRemove)
                )
            }
            
            // Update our internal state
            // Keep messages not in the removal set
            let removalSet = Set(sortedIndices)
            let keptMessages = messages.enumerated().compactMap { removalSet.contains($0.offset) ? nil : $0.element }
            
            // Rebuild spans for kept messages
            var newSpans: [Span] = []
            
            for (index, span) in spans.enumerated() {
                if index < firstIndexToRemove {
                    // Messages before removal - keep as is
                    newSpans.append(span)
                } else if index > lastIndexToRemove {
                    // Messages after removal - shift by tokensToRemove
                    let shiftedSpan = Span(start: span.start - tokensToRemove, end: span.end - tokensToRemove)
                    newSpans.append(shiftedSpan)
                }
                // Skip removed messages
            }
            
            // Update tokens array by removing the range
            let updatedTokens = Array(tokens[0..<startToken] + tokens[endToken..<tokens.count])
            
            // Update state
            messages = keptMessages
            spans = newSpans
            tokens = updatedTokens
            
            FreeTokenLogger.shared.log("\(logPrefix) removed_messages complete. remaining=\(messages.count) totalTokens=\(tokens.count)", level: .info)
        }
    }
}
