//
//  ParseToolCals.swift
//  FreeToken
//
//  Created by Vince Francesi on 1/23/25.
//

import Foundation

extension FreeToken {
    class ParseToolCalls {
        var toolCalls: String?
        var toolMatches: [String]?
        var allTools: String?
        var parsedTools: [[String: ToolValues]] = []
        
        enum ToolValues {
            case name(String)
            case arguments([String: String])
        }
        
        init(toolCalls: String?) {
            self.toolCalls = toolCalls
        }
        
        func call() throws {
            guard let toolCalls = toolCalls, !toolCalls.isEmpty else {
                throw ParseError.message("Tool calls not provided")
            }
            
            // Regular expression to extract tool calls inside square brackets
            let toolPattern = #"\[\s*[a-zA-Z_]\w*\s*\(\s*(?:[a-zA-Z_]\w*\s*[:=]\s*(?:"[^"]*"|'[^']*'|\d+)(?:\s*,\s*[a-zA-Z_]\w*\s*[:=]\s*(?:"[^"]*"|'[^']*'|\d+))*)?\s*\)(?:\s*,\s*[a-zA-Z_]\w*\s*\(\s*(?:[a-zA-Z_]\w*\s*[:=]\s*(?:"[^"]*"|'[^']*'|\d+)(?:\s*,\s*[a-zA-Z_]\w*\s*[:=]\s*(?:"[^"]*"|'[^']*'|\d+))*)?\s*\))*\s*\]"#

            let regex = try NSRegularExpression(pattern: toolPattern, options: [])
            
            // Match the tool calls inside the square brackets
            if let match = regex.firstMatch(in: toolCalls, options: [], range: NSRange(location: 0, length: toolCalls.utf16.count)) {
                let range = match.range
                if let matchString = Range(range, in: toolCalls) {
                    toolMatches = [String(toolCalls[matchString])]
                }
            }
            
            guard let toolMatches = toolMatches else {
                throw ParseError.message("No tool calls found")
            }
            
            // Solve for the scenario where the AI returns multiple sets of [] tool calls
            var toolStrings: [String] = []
            for match in toolMatches {
                let trimmedMatch = String(match.dropFirst().dropLast()) // Remove square brackets
                toolStrings.append(trimmedMatch)
            }
            
            let toolsString = toolStrings.joined(separator: ", ")
            allTools = "[\(toolsString)]"
            
            // Split the individual tools calls
            let individualToolPattern = #"[a-zA-Z_][a-zA-Z0-9_]*\([^\)]*\)"#
            let individualRegex = try NSRegularExpression(pattern: individualToolPattern, options: [])
            let individualMatches = individualRegex.matches(in: toolsString, options: [], range: NSRange(location: 0, length: toolsString.utf16.count))
            
            var tools: [String] = []
            for match in individualMatches {
                if let range = Range(match.range, in: toolsString) {
                    tools.append(String(toolsString[range]))
                }
            }
            
            // Parse each tool call into name and arguments
            let toolPartsPattern = #"([a-zA-Z_][a-zA-Z0-9_]*)\((.*)\)"#
            let toolPartsRegex = try NSRegularExpression(pattern: toolPartsPattern, options: [])
            let argsPattern = #"([a-zA-Z_][a-zA-Z0-9_]*)=("[^"]*"|'[^']*'|[^,\s]+)"#
            let argsRegex = try NSRegularExpression(pattern: argsPattern, options: [])

            for tool in tools {
                if let match = toolPartsRegex.firstMatch(in: tool, options: [], range: NSRange(location: 0, length: tool.utf16.count)) {
                    if let nameRange = Range(match.range(at: 1), in: tool),
                       let argsRange = Range(match.range(at: 2), in: tool) {
                        
                        let toolName = String(tool[nameRange])
                        let rawArgs = String(tool[argsRange])
                        
                        // Parse arguments into key-value structure
                        let argsMatches = argsRegex.matches(in: rawArgs, options: [], range: NSRange(location: 0, length: rawArgs.utf16.count))
                        
                        
                        var arguments: [String: String] = [:]
                        
                        
                        for argMatch in argsMatches {
                            if let keyRange = Range(argMatch.range(at: 1), in: rawArgs),
                               let valueRange = Range(argMatch.range(at: 2), in: rawArgs) {
                                let key = String(rawArgs[keyRange])
                                var value = String(rawArgs[valueRange])
                                
                                // Remove surrounding quotes
                                if value.hasPrefix("\"") || value.hasPrefix("'") {
                                    value.removeFirst()
                                    value.removeLast()
                                }
                                arguments[key] = value
                            }
                        }
                        
                        parsedTools.append([
                            "name": .name(toolName),
                            "arguments": .arguments(arguments)
                        ])
                    }
                }
            }
        }
        
        enum ParseError: Error {
            case message(String)
        }
    }
}
