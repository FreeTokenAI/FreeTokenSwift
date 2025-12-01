//
//  ToolCallsManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 2/4/25.
//

import Foundation

extension FreeToken {
    class ToolCallsManager: @unchecked Sendable {
        internal let builtInToolDefinitions: [ToolDefinition]
        internal let applicationToolDefinitions: [ToolDefinition]
        internal let cloudToolDefinitions: [ToolDefinition]
        
        private let messageContent: String
        private let documentSearchScope: String?
        private let privateDocumentStoreIds: [String]?
        
        private var toolCalls: [ToolCall] = []
                
        internal init(
            messageContent: String,
            builtInToolDefinitions: [ToolDefinition],
            applicationToolDefinitions: [ToolDefinition] = [],
            cloudToolDefinitions: [ToolDefinition] = [],
            documentSearchScope: String?,
            privateDocumentStoreIds: [String]?
        ) {
            self.messageContent = messageContent
            self.documentSearchScope = documentSearchScope
            self.privateDocumentStoreIds = privateDocumentStoreIds
            self.builtInToolDefinitions = builtInToolDefinitions
            self.cloudToolDefinitions = cloudToolDefinitions
            self.applicationToolDefinitions = applicationToolDefinitions
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
            externalToolCallHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil,
            cloudToolCallHandler: @escaping @Sendable ([ToolCall]) async -> String,
            success successCallback: @escaping @Sendable (_ result: String) async throws -> Void
        ) async throws {
            try parseToolCalls()

            if toolCalls.isEmpty {
                try await successCallback("")
                return
            }
            
            let cloudToolCallNames = cloudToolDefinitions.map { $0.name }
            let builtInToolCallNames = builtInToolDefinitions.map { $0.name }

            let remainingToolCalls = toolCalls.filter { toolCall in
                let isCloudCall = cloudToolCallNames.contains { $0 == toolCall.name }
                let isInternalCall = builtInToolCallNames.contains { $0 == toolCall.name }
                return !isCloudCall && !isInternalCall
            }

            let cloudToolCalls = toolCalls.filter { cloudToolCallNames.contains($0.name) }
            let internalCalls = toolCalls.filter { builtInToolCallNames.contains($0.name) }

            var results = ""

            if !cloudToolCalls.isEmpty {
                let result = await self.handleInternalCloudCalls(toolCalls: cloudToolCalls, cloudToolCallHandler: cloudToolCallHandler)
                results += "\n\n\(result)"
            }

            if !remainingToolCalls.isEmpty {
                FreeToken.shared.logger("🔍 ToolCallsManager: sending \(remainingToolCalls.count) tool calls to external handler", .info)
                for tc in remainingToolCalls {
                    FreeToken.shared.logger("🔍   External tool: \(tc.name)", .info)
                }
                let result = await self.handleExternalCalls(toolCalls: remainingToolCalls, externalToolCallHandler: externalToolCallHandler)
                results += "\n\n\(result)"
            } else {
                FreeToken.shared.logger("🔍 ToolCallsManager: no remaining tool calls for external handler", .info)
            }

            if !internalCalls.isEmpty {
                let result = await self.handleInternalLocalCalls(toolCalls: internalCalls)
                results += "\n\n\(result)"
            }

            // If all lists are empty, notify immediately (avoid hanging)
            if cloudToolCalls.isEmpty && remainingToolCalls.isEmpty && internalCalls.isEmpty {
                try await successCallback("")
                return
            } else {
                try await successCallback(results)
            }
        }
        
        private func parseToolCalls() throws {
            let toolNames = builtInToolDefinitions.map { $0.name } + applicationToolDefinitions.map { $0.name } + cloudToolDefinitions.map { $0.name }
            FreeToken.shared.logger("🔍 ToolCallsManager.parseToolCalls: combined toolNames = \(toolNames)", .info)
            FreeToken.shared.logger("🔍   builtIn: \(builtInToolDefinitions.map { $0.name })", .info)
            FreeToken.shared.logger("🔍   application: \(applicationToolDefinitions.map { $0.name })", .info)
            FreeToken.shared.logger("🔍   cloud: \(cloudToolDefinitions.map { $0.name })", .info)
            let parser = ParseToolCalls(messageContent: messageContent, toolNames: toolNames)

            self.toolCalls = try parser.parse()
            FreeToken.shared.logger("🔍 ToolCallsManager.parseToolCalls: parsed \(self.toolCalls.count) tool calls", .info)
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
                        await internal_articleLookup(query: query, searchScope: documentSearchScope, privateDocumentStoreIds: privateDocumentStoreIds) { result in
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
        
        private func handleInternalCloudCalls(toolCalls: [ToolCall], cloudToolCallHandler: @escaping @Sendable ([ToolCall]) async -> String) async -> String {
            if toolCalls.isEmpty {
                return ""
            }
            return await cloudToolCallHandler(toolCalls)
        }
        
        private func handleExternalCalls(toolCalls: [ToolCall], externalToolCallHandler: Optional<@Sendable ([ToolCall]) async -> String> = nil) async -> String {
            if toolCalls.isEmpty || externalToolCallHandler == nil {
                return ""
            }
            return await externalToolCallHandler!(toolCalls)
        }
        
        private func internal_articleLookup(query: String, searchScope: String?, privateDocumentStoreIds: [String]?, success successCallback: @escaping @Sendable (_ result: String) async -> Void) async {
            let result = await withCheckedContinuation { continuation in
                Task {
                    await FreeToken.shared.searchDocuments(query: query, searchScope: searchScope, privateDocumentStoreIds: privateDocumentStoreIds, maxResults: 3) { searchResults in
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
                        
                        continuation.resume(returning: result)
                    } error: { error in
                        // NoOp
                        FreeToken.shared.logger("Internal article lookup failed to retrieve documents from cloud. Ignoring", .warning)
                        continuation.resume(returning: "")
                    }
                }
            }
            
            await successCallback(result)
        }
        
        private func internal_webSearch(query: String, success successCallback: @escaping @Sendable (_ result: String) async -> Void) async {
            
            let result = await withCheckedContinuation { continuation in
                Task {
                    await FreeToken.shared.webSearch(query: query) { searchResults in
                        var result = "WEB SEARCH RESULTS\n\nUse these results to answer the user's question:"
                        
                        for webResult in searchResults {
                            result.append("""
                            =================================================
                            WEB SEARCH RESULT: 
                            TITLE: \(webResult.title)
                            URL: \(webResult.url != nil ? webResult.url! : "No URL provided")
                            DESCRIPTION: \(webResult.description)
                            RESULT AGE: \(webResult.age)
                            \(webResult.metadata.isEmpty ? "" : "ADDITIONAL METADATA: \(webResult.metadata)")
                            RELEVANT CONTENT CHUNKS: 
                            \(webResult.snippet)
                            
                        """)
                        }
                        
                        result.append("\n\nALWAYS cite URLs of web searches in your response\n\n------ END WEB SEARCH RESULTS ------\n\n")
                        
                        continuation.resume(returning: result)
                    } error: { error in
                        // NoOp
                        FreeToken.shared.logger("Internal web search failed to retrieve documents from cloud. Ignoring", .warning)
                        continuation.resume(returning: "")
                    }
                }
            }
            
            await successCallback(result)
        }
    }
}
