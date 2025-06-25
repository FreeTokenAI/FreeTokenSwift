//
//  ToolCallsManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 2/4/25.
//

import Foundation

extension FreeToken {
    class ToolCallsManager: @unchecked Sendable {
        private let messageContent: String
        private let toolNames: [String]
        
        private let availableCloudToolCalls: [String]
        private let internalLocalToolCalls = ["article_lookup", "web_search"]
        private let documentSearchScope: String?
        
        private var toolCalls: [ToolCall] = []
                
        internal init(messageContent: String, availableCloudToolCalls: [String], toolNames: [String], documentSearchScope: String?) {
            self.messageContent = messageContent
            self.availableCloudToolCalls = availableCloudToolCalls
            self.documentSearchScope = documentSearchScope
            self.toolNames = toolNames
        }
        
        actor ToolCallResultsCollector {
            var toolResults: [String] = []
            
            func appendResult(_ result: String) {
                toolResults.append(result)
            }
            
            func getResults() -> String {
                return toolResults.joined(separator: "\n\n")
            }
        }
        
        internal func process(
            externalToolCallHandler: Optional<@Sendable ([ToolCall]) -> String> = nil,
            cloudToolCallHandler: @escaping @Sendable ([ToolCall]) -> String,
            success successCallback: @escaping @Sendable (_ result: String) async -> Void
        ) async throws {
            try parseToolCalls()

            if toolCalls.isEmpty {
                await successCallback("")
                return
            }

            let remainingToolCalls = toolCalls.filter { toolCall in
                let isCloudCall = availableCloudToolCalls.contains { $0 == toolCall.name }
                let isInternalCall = internalLocalToolCalls.contains { $0 == toolCall.name }
                return !isCloudCall && !isInternalCall
            }

            let cloudToolCalls = toolCalls.filter { availableCloudToolCalls.contains($0.name) }
            let internalCalls = toolCalls.filter { internalLocalToolCalls.contains($0.name) }

            let toolCallResultsCollector = ToolCallResultsCollector()
            let dispatchGroup = DispatchGroup()

            func launchTask(_ task: @Sendable @escaping () async -> Void) {
                dispatchGroup.enter()
                Task {
                    defer { dispatchGroup.leave() }
                    await task()
                }
            }

            if !cloudToolCalls.isEmpty {
                launchTask { [self] in
                    let result = await self.handleInternalCloudCalls(toolCalls: cloudToolCalls, cloudToolCallHandler: cloudToolCallHandler)
                    await toolCallResultsCollector.appendResult(result)
                }
            }

            if !remainingToolCalls.isEmpty {
                launchTask { [self] in
                    let result = await self.handleExternalCalls(toolCalls: remainingToolCalls, externalToolCallHandler: externalToolCallHandler)
                    await toolCallResultsCollector.appendResult(result)
                }
            }

            if !internalCalls.isEmpty {
                launchTask { [self] in
                    let result = await self.handleInternalLocalCalls(toolCalls: internalCalls)
                    await toolCallResultsCollector.appendResult(result)
                }
            }

            // If all lists are empty, notify immediately (avoid hanging)
            if cloudToolCalls.isEmpty && remainingToolCalls.isEmpty && internalCalls.isEmpty {
                await successCallback("")
                return
            }

            dispatchGroup.notify(queue: .main) {
                Task {
                    let results = await toolCallResultsCollector.getResults()
                    await successCallback(results)
                }
            }
        }
        
        private func parseToolCalls() throws {
            let parser = ParseToolCalls(messageContent: messageContent, toolNames: toolNames)
            
            self.toolCalls = try parser.parse()
        }
        
        private func handleInternalLocalCalls(toolCalls: [ToolCall]) async -> String {
            var results = ""
            
            for toolCall in toolCalls {
                do {
                    let result = try await handleInternalLocalCall(toolCall: toolCall)
                    results += result
                } catch {
                    FreeToken.shared.logger("Error handling internal local call: \(error)", .error)
                }
            }
            
            return results
        }
        
        private func handleInternalLocalCall(toolCall: ToolCall) async throws -> String {
            if toolCall.name == "article_lookup", let query = toolCall.arguments["query"] {
                return await withCheckedContinuation { continuation in
                    Task {
                        await internal_articleLookup(query: query, searchScope: documentSearchScope) { result in
                            continuation.resume(returning: result)
                        }
                    }
                }
            } else if toolCall.name == "web_search", let query = toolCall.arguments["query"] {
                return await withCheckedContinuation { continuation in
                    Task {
                        await internal_webSearch(query: query) { result in
                            continuation.resume(returning: result)
                        }
                    }
                }
            } else if toolCall.name == "void" {
                return ""
            } else {
                throw FreeTokenError.unhandledInternalToolCall
            }
        }
        
        private func handleInternalCloudCalls(toolCalls: [ToolCall], cloudToolCallHandler: @escaping @Sendable ([ToolCall]) -> String) async -> String {
            if toolCalls.isEmpty {
                return ""
            }
            return cloudToolCallHandler(toolCalls)
        }
        
        private func handleExternalCalls(toolCalls: [ToolCall], externalToolCallHandler: Optional<@Sendable ([ToolCall]) -> String> = nil) async -> String {
            if toolCalls.isEmpty || externalToolCallHandler == nil {
                return ""
            }
            return externalToolCallHandler!(toolCalls)
        }
        
        private func internal_articleLookup(query: String, searchScope: String?, success successCallback: @escaping @Sendable (_ result: String) -> Void) async {
            await FreeToken.shared.searchDocuments(query: query, searchScope: searchScope, maxResults: 3) { searchResults in
                var result = "Article excerpts to help answer the user's question:"
                
                for documentChunk in searchResults.documentChunks {
                    var metadata = ""
                    if documentChunk.documentMetadata != nil {
                        metadata = documentChunk.documentMetadata!
                    }
                    
                    result.append("""
                    \(metadata)
                    
                    \(documentChunk.contentChunk)
                
                """)
                }
                
                successCallback(result)
            } error: { error in
                // NoOp
                FreeToken.shared.logger("Internal article lookup failed to retrieve documents from cloud. Ignoring", .warning)
                successCallback("")
            }
        }
        
        private func internal_webSearch(query: String, success successCallback: @escaping @Sendable (_ result: String) -> Void) async {
            
            await FreeToken.shared.webSearch(query: query) { searchResults in
                var result = "WEB SEARCH RESULTS\n\nUse these results to answer the user's question:"
                
                for webResult in searchResults {
                    result.append("""
                    =================================================
                    WEB SEARCH RESULT: 
                    TITLE: \(webResult.title)
                    URL: \(webResult.url != nil ? webResult.url!.absoluteString : "No URL provided")
                    DESCRIPTION: \(webResult.description)
                    RESULT AGE: \(webResult.age)
                    \(webResult.metadata.isEmpty ? "" : "ADDITIONAL METADATA: \(webResult.metadata)")
                    RELEVANT CONTENT CHUNKS: 
                    \(webResult.snippet)
                    
                """)
                }
                
                result.append("\n\nALWAYS cite URLs of web searches in your response\n\n------ END WEB SEARCH RESULTS ------\n\n")
                
                successCallback(result)
            } error: { error in
                // NoOp
                FreeToken.shared.logger("Internal web search failed to retrieve documents from cloud. Ignoring", .warning)
                successCallback("")
            }
        }
    }
}
