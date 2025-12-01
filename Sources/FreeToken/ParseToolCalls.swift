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

        /// Codable struct for parsing tool call JSON
        private struct ToolCallJSON: Codable {
            let type: String?  // Optional field that can be omitted
            let name: String?  // Optional field - can use 'type' if 'name' is missing
            let arguments: [String: AnyCodableValue]?

            /// Returns the tool name, using 'name' if available, otherwise 'type'
            var toolName: String? {
                return name ?? type
            }

            /// Helper to decode arguments with any value type
            struct AnyCodableValue: Codable {
                let value: Any

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()

                    if let stringValue = try? container.decode(String.self) {
                        value = stringValue
                    } else if let intValue = try? container.decode(Int.self) {
                        value = intValue
                    } else if let doubleValue = try? container.decode(Double.self) {
                        value = doubleValue
                    } else if let boolValue = try? container.decode(Bool.self) {
                        value = boolValue
                    } else if let arrayValue = try? container.decode([AnyCodableValue].self) {
                        value = arrayValue.map { $0.value }
                    } else if let dictValue = try? container.decode([String: AnyCodableValue].self) {
                        value = dictValue.mapValues { $0.value }
                    } else {
                        value = NSNull()
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    try container.encode(String(describing: value))
                }

                var stringValue: String {
                    return String(describing: value)
                }
            }
        }

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

            // Normalize whitespace: replace all newlines with spaces to handle multi-line JSON
            messageContent = messageContent.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")

            var foundToolCalls: [String] = []

            // First try to parse JSON syntax
            let jsonToolCalls = try parseJsonToolCalls()
            parsedTools.append(contentsOf: jsonToolCalls.toolCalls)
            foundToolCalls.append(contentsOf: jsonToolCalls.matches)

            // Then parse square bracket syntax
            let squareBracketToolCalls = try parseSquareBracketToolCalls()
            parsedTools.append(contentsOf: squareBracketToolCalls.toolCalls)
            foundToolCalls.append(contentsOf: squareBracketToolCalls.matches)

            // Then parse XML toolUse syntax
            let xmlToolCalls = try parseXmlToolUseCalls()
            parsedTools.append(contentsOf: xmlToolCalls.toolCalls)
            foundToolCalls.append(contentsOf: xmlToolCalls.matches)

            toolMatches = foundToolCalls
            allTools = foundToolCalls.isEmpty ? nil : "[\(foundToolCalls.joined(separator: ", "))]"

            return parsedTools
        }

        private func parseJsonToolCalls() throws -> (toolCalls: [ToolCall], matches: [String]) {
            var toolCalls: [ToolCall] = []
            var matches: [String] = []

            // Extract all JSON objects from the message
            let jsonObjects = extractJsonObjects(from: messageContent)

            for jsonMatch in jsonObjects {
                guard let data = jsonMatch.data(using: .utf8) else {
                    continue
                }

                // First try to parse as an array of tool calls
                if let toolCallArray = try? JSONDecoder().decode([ToolCallJSON].self, from: data) {
                    for toolCallJSON in toolCallArray {
                        // Get tool name from either 'name' or 'type' field
                        guard let toolName = toolCallJSON.toolName else {
                            continue  // Skip if neither field is present
                        }

                        // Check if tool name is in allowed list
                        guard toolNames.contains(toolName) else {
                            continue
                        }

                        // Extract arguments and convert to strings
                        var arguments: [String: String] = [:]
                        if let argsDict = toolCallJSON.arguments {
                            for (key, value) in argsDict {
                                arguments[key] = value.stringValue
                            }
                        }

                        let toolCall = ToolCall(name: toolName, arguments: arguments)
                        toolCalls.append(toolCall)
                    }

                    matches.append(jsonMatch)
                }
                // If not an array, try to parse as a single tool call
                else if let toolCallJSON = try? JSONDecoder().decode(ToolCallJSON.self, from: data) {
                    // Get tool name from either 'name' or 'type' field
                    guard let toolName = toolCallJSON.toolName else {
                        continue  // Skip if neither field is present
                    }

                    // Check if tool name is in allowed list
                    guard toolNames.contains(toolName) else {
                        continue
                    }

                    // Extract arguments and convert to strings
                    var arguments: [String: String] = [:]
                    if let argsDict = toolCallJSON.arguments {
                        for (key, value) in argsDict {
                            arguments[key] = value.stringValue
                        }
                    }

                    let toolCall = ToolCall(name: toolName, arguments: arguments)
                    toolCalls.append(toolCall)
                    matches.append(jsonMatch)
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

        /// Extracts JSON objects and arrays from text by counting braces/brackets
        /// This is more robust than regex for nested JSON structures
        private func extractJsonObjects(from text: String) -> [String] {
            var jsonObjects: [String] = []
            var currentObject = ""
            var braceCount = 0
            var bracketCount = 0
            var inString = false
            var escapeNext = false

            for char in text {
                // Handle escape sequences in strings
                if escapeNext {
                    escapeNext = false
                    if braceCount > 0 || bracketCount > 0 {
                        currentObject.append(char)
                    }
                    continue
                }

                if char == "\\" {
                    escapeNext = true
                    if braceCount > 0 || bracketCount > 0 {
                        currentObject.append(char)
                    }
                    continue
                }

                // Track whether we're inside a string
                if char == "\"" {
                    inString.toggle()
                    if braceCount > 0 || bracketCount > 0 {
                        currentObject.append(char)
                    }
                    continue
                }

                // Only count braces/brackets outside of strings
                if !inString {
                    if char == "{" {
                        if braceCount == 0 && bracketCount == 0 {
                            currentObject = "{"
                        } else {
                            currentObject.append(char)
                        }
                        braceCount += 1
                    } else if char == "}" {
                        if braceCount > 0 {
                            currentObject.append(char)
                            braceCount -= 1

                            // Complete object found
                            if braceCount == 0 && bracketCount == 0 {
                                jsonObjects.append(currentObject)
                                currentObject = ""
                            }
                        }
                    } else if char == "[" {
                        if braceCount == 0 && bracketCount == 0 {
                            currentObject = "["
                        } else {
                            currentObject.append(char)
                        }
                        bracketCount += 1
                    } else if char == "]" {
                        if bracketCount > 0 {
                            currentObject.append(char)
                            bracketCount -= 1

                            // Complete array found
                            if braceCount == 0 && bracketCount == 0 {
                                jsonObjects.append(currentObject)
                                currentObject = ""
                            }
                        }
                    } else if braceCount > 0 || bracketCount > 0 {
                        currentObject.append(char)
                    }
                } else if braceCount > 0 || bracketCount > 0 {
                    currentObject.append(char)
                }
            }

            return jsonObjects
        }

        /// Parse XML-style <toolUse> tags followed by JSON arguments
        /// Format: <toolUse>tool_name</toolUse> followed by ```json {...} ```
        private func parseXmlToolUseCalls() throws -> (toolCalls: [ToolCall], matches: [String]) {
            var toolCalls: [ToolCall] = []
            var matches: [String] = []

            // Pattern to match <toolUse>tool_name</toolUse> followed by JSON in code block
            // The JSON can be in ```json {...} ``` or just {...}
            // Note: newlines are already normalized to spaces at this point
            let pattern = #"<toolUse>\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*</toolUse>\s*(?:```(?:json)?\s*)?\{([^}]*)\}\s*(?:```)?"#
            let regex = try NSRegularExpression(pattern: pattern, options: [])

            // Use NSString for consistent UTF-16 handling to avoid emoji offset issues
            let nsContent = messageContent as NSString
            let xmlMatches = regex.matches(in: messageContent, options: [], range: NSRange(location: 0, length: nsContent.length))

            for match in xmlMatches {
                // Use NSString substring to avoid UTF-16/Swift String offset mismatches with emojis
                let toolNameNSRange = match.range(at: 1)
                let argsNSRange = match.range(at: 2)
                let fullNSRange = match.range

                guard toolNameNSRange.location != NSNotFound,
                      argsNSRange.location != NSNotFound,
                      fullNSRange.location != NSNotFound else {
                    continue
                }

                let toolName = nsContent.substring(with: toolNameNSRange)
                let argsInner = nsContent.substring(with: argsNSRange)
                let argsContent = "{\(argsInner)}"
                let fullMatch = nsContent.substring(with: fullNSRange)

                // Verify tool name is in allowed list
                guard toolNames.contains(toolName) else {
                    continue
                }

                // Parse JSON arguments
                if let data = argsContent.data(using: .utf8),
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
    }
}
