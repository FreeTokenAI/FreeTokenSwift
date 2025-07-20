//
//  ParseToolCalls.swift
//  FreeToken
//
//  Created by Vince Francesi on 1/23/25.
//

import Foundation

extension FreeToken {
    class ParseToolCalls {
        private var messageContent: String
        private var toolMatches: [String]?
        private var allTools: String?
        private var parsedTools: [ToolCall] = []
        private let toolNames: [String]
        
        init(messageContent: String, toolNames: [String]) {
            self.messageContent = messageContent
            self.toolNames = toolNames
        }
        
        func parse() throws -> [ToolCall] {
            guard !toolNames.isEmpty else {
                throw FreeTokenError.noToolNamesProvided
            }
            
            // Clear previous results
            parsedTools = []
            toolMatches = []
            
            // Create pattern to match any of the specified tool names followed by parentheses
            let escapedToolNames = toolNames.map { NSRegularExpression.escapedPattern(for: $0) }
            let toolNamesPattern = escapedToolNames.joined(separator: "|")
            let pattern = #"(\#(toolNamesPattern))\s*\(([^)]*)\)"#
            
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let matches = regex.matches(in: messageContent, options: [], range: NSRange(location: 0, length: messageContent.utf16.count))
            
            var foundToolCalls: [String] = []
            
            for match in matches {
                guard let toolNameRange = Range(match.range(at: 1), in: messageContent),
                      let paramsRange = Range(match.range(at: 2), in: messageContent) else {
                    continue
                }
                
                let toolName = String(messageContent[toolNameRange])
                let rawParams = String(messageContent[paramsRange])
                let fullMatch = String(messageContent[Range(match.range, in: messageContent)!])
                
                foundToolCalls.append(fullMatch)
                
                // Parse parameters
                let arguments = try parseParameters(rawParams)
                let toolCall = ToolCall(name: toolName, arguments: arguments)
                
                parsedTools.append(toolCall)
            }
            
            toolMatches = foundToolCalls
            allTools = foundToolCalls.isEmpty ? nil : "[\(foundToolCalls.joined(separator: ", "))]"
                        
            return parsedTools
        }
        
        private func parseParameters(_ rawParams: String) throws -> [String: String] {
            guard !rawParams.trimmingCharacters(in: .whitespaces).isEmpty else {
                return [:]
            }
            
            var arguments: [String: String] = [:]
            
            // Pattern to match key=value pairs with quoted or unquoted values
            let paramPattern = #"([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*("[^"]*"|'[^']*'|[^,\s]+)"#
            let paramRegex = try NSRegularExpression(pattern: paramPattern, options: [])
            let paramMatches = paramRegex.matches(in: rawParams, options: [], range: NSRange(location: 0, length: rawParams.utf16.count))
            
            for match in paramMatches {
                guard let keyRange = Range(match.range(at: 1), in: rawParams),
                      let valueRange = Range(match.range(at: 2), in: rawParams) else {
                    continue
                }
                
                let key = String(rawParams[keyRange])
                var value = String(rawParams[valueRange])
                
                // Remove surrounding quotes if present
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                
                arguments[key] = value
            }
            
            return arguments
        }
    }
}
