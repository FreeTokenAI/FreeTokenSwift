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
            
            var foundToolCalls: [String] = []
            
            // First try to parse JSON syntax
            let jsonToolCalls = try parseJsonToolCalls()
            parsedTools.append(contentsOf: jsonToolCalls.toolCalls)
            foundToolCalls.append(contentsOf: jsonToolCalls.matches)
            
            // Then parse square bracket syntax
            let squareBracketToolCalls = try parseSquareBracketToolCalls()
            parsedTools.append(contentsOf: squareBracketToolCalls.toolCalls)
            foundToolCalls.append(contentsOf: squareBracketToolCalls.matches)
            
            toolMatches = foundToolCalls
            allTools = foundToolCalls.isEmpty ? nil : "[\(foundToolCalls.joined(separator: ", "))]"
                        
            return parsedTools
        }
        
        private func parseJsonToolCalls() throws -> (toolCalls: [ToolCall], matches: [String]) {
            var toolCalls: [ToolCall] = []
            var matches: [String] = []
            
            // First try to find JSON arrays containing tool calls
            // Use a more comprehensive pattern that handles nested objects
            let arrayPattern = #"\[(?:\s*\{(?:[^{}]|\{[^}]*\})*\}\s*,?)+\]"#
            if let arrayRegex = try? NSRegularExpression(pattern: arrayPattern, options: []) {
                let arrayMatches = arrayRegex.matches(in: messageContent, options: [], range: NSRange(location: 0, length: messageContent.utf16.count))
                
                for arrayMatch in arrayMatches {
                    guard let arrayRange = Range(arrayMatch.range, in: messageContent) else { continue }
                    let arrayString = String(messageContent[arrayRange])
                    
                    // Try to parse as JSON array
                    if let data = arrayString.data(using: .utf8),
                       let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        for jsonObject in jsonArray {
                            // Handle format: { "type": "function_call", "name": "...", "arguments": {...} }
                            if let type = jsonObject["type"] as? String,
                               type == "function_call" || type == "function",
                               let name = jsonObject["name"] as? String,
                               toolNames.contains(name) {
                                
                                var arguments: [String: String] = [:]
                                if let argsDict = jsonObject["arguments"] as? [String: Any] {
                                    for (key, value) in argsDict {
                                        arguments[key] = String(describing: value)
                                    }
                                }
                                
                                let toolCall = ToolCall(name: name, arguments: arguments)
                                toolCalls.append(toolCall)
                                matches.append(arrayString)
                            }
                        }
                    }
                }
            }
            
            // Also try to find individual JSON objects with type field (without array brackets)
            let singleJsonWithTypePattern = #"\{\s*"type"\s*:\s*"(function_call|function)"\s*,\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*(\{(?:[^{}]|\{[^}]*\})*\})\s*\}"#
            if let singleJsonRegex = try? NSRegularExpression(pattern: singleJsonWithTypePattern, options: []) {
                let singleJsonMatches = singleJsonRegex.matches(in: messageContent, options: [], range: NSRange(location: 0, length: messageContent.utf16.count))
                
                for match in singleJsonMatches {
                    guard Range(match.range(at: 1), in: messageContent) != nil,
                          let nameRange = Range(match.range(at: 2), in: messageContent),
                          let argsRange = Range(match.range(at: 3), in: messageContent),
                          let fullRange = Range(match.range, in: messageContent) else {
                        continue
                    }
                    
                    let toolName = String(messageContent[nameRange])
                    let argsJson = String(messageContent[argsRange])
                    let fullMatch = String(messageContent[fullRange])
                    
                    // Verify tool name is in allowed list
                    guard toolNames.contains(toolName) else {
                        continue
                    }
                    
                    // Skip if already processed as part of an array
                    if matches.contains(where: { $0.contains(fullMatch) }) {
                        continue
                    }
                    
                    // Parse JSON arguments
                    if let data = argsJson.data(using: .utf8),
                       let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Convert all values to strings
                        var arguments: [String: String] = [:]
                        for (key, value) in jsonObject {
                            arguments[key] = String(describing: value)
                        }
                        
                        let toolCall = ToolCall(name: toolName, arguments: arguments)
                        toolCalls.append(toolCall)
                        matches.append(fullMatch)
                    }
                }
            }
            
            // Also support individual JSON objects (original format)
            let jsonPattern = #"\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})\s*\}"#
            let regex = try NSRegularExpression(pattern: jsonPattern, options: [])
            let jsonMatches = regex.matches(in: messageContent, options: [], range: NSRange(location: 0, length: messageContent.utf16.count))
            
            for match in jsonMatches {
                guard let nameRange = Range(match.range(at: 1), in: messageContent),
                      let argsRange = Range(match.range(at: 2), in: messageContent),
                      let fullRange = Range(match.range, in: messageContent) else {
                    continue
                }
                
                let toolName = String(messageContent[nameRange])
                let argsJson = String(messageContent[argsRange])
                let fullMatch = String(messageContent[fullRange])
                
                // Verify tool name is in allowed list
                guard toolNames.contains(toolName) else {
                    continue
                }
                
                // Skip if already processed as part of an array
                if matches.contains(where: { $0.contains(fullMatch) }) {
                    continue
                }
                
                // Parse JSON arguments
                if let data = argsJson.data(using: .utf8),
                   let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Convert all values to strings
                    var arguments: [String: String] = [:]
                    for (key, value) in jsonObject {
                        arguments[key] = String(describing: value)
                    }
                    
                    let toolCall = ToolCall(name: toolName, arguments: arguments)
                    toolCalls.append(toolCall)
                    matches.append(fullMatch)
                }
            }
            
            return (toolCalls, matches)
        }
        
        private func parseSquareBracketToolCalls() throws -> (toolCalls: [ToolCall], matches: [String]) {
            var toolCalls: [ToolCall] = []
            var matches: [String] = []
            
            // Create pattern to match any of the specified tool names followed by parentheses
            let escapedToolNames = toolNames.map { NSRegularExpression.escapedPattern(for: $0) }
            let toolNamesPattern = escapedToolNames.joined(separator: "|")
            let pattern = #"(\#(toolNamesPattern))\s*\(([^)]*)\)"#
            
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let bracketMatches = regex.matches(in: messageContent, options: [], range: NSRange(location: 0, length: messageContent.utf16.count))
            
            for match in bracketMatches {
                guard let toolNameRange = Range(match.range(at: 1), in: messageContent),
                      let paramsRange = Range(match.range(at: 2), in: messageContent) else {
                    continue
                }
                
                let toolName = String(messageContent[toolNameRange])
                let rawParams = String(messageContent[paramsRange])
                let fullMatch = String(messageContent[Range(match.range, in: messageContent)!])
                
                // Parse parameters
                let arguments = try parseParameters(rawParams)
                let toolCall = ToolCall(name: toolName, arguments: arguments)
                
                toolCalls.append(toolCall)
                matches.append(fullMatch)
            }
            
            return (toolCalls, matches)
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
