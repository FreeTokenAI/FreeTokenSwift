//
//  ChatStreamManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 5/31/25.
//

extension FreeToken {
    class ChatStreamManager: @unchecked Sendable {
        private var chatStream: String = ""
        private var streamQueue: String = ""
        private var toolCalls: [[String: ToolValues]] = []
        private var presumedHasDetectedTool: Bool = false
        private var hasDetectedTool: Bool = false
        private let toolBegin: String
        private let toolEnd: String
        private let toolNames: [String]
        
        enum ToolMode: String, Equatable {
            case json
            case python
        }
        
        init(toolNames: [String] = [], toolMode: ToolMode = .python) {
            if toolMode == .json {
                self.toolBegin = "{"
                self.toolEnd = "}"
            } else {
                self.toolBegin = "["
                self.toolEnd = "]"
            }
            
            self.toolNames = toolNames
        }
        
        func streamChunkFilter(_ text: String, isFinal: Bool = false) -> String {
            self.appendToStream(text)
            
            return text
//            streamQueue += text
//            
//            if (presumedHasDetectedTool || hasDetectedTool) && isFinal == false {
//                return ""
//            } else {
//                let queueText = streamQueue
//                streamQueue = ""
//                return queueText
//            }
        }
        
        func queuedTokens() -> String {
            return streamQueue
        }
        
        private func appendToStream(_ text: String) {
            chatStream += text
            detectToolBeginning()
            
            detectToolEnd()
        }
        
        private func detectToolBeginning() {
            if hasDetectedTool == true { return }
            
            if chatStream.contains(toolBegin) {
                // What is the position of the toolBegin in the chatStream?
                let toolBeginPosition = chatStream.firstIndex(of: toolBegin.first!)!
                // Is the toolBeginPosition at the end of the chatStream?
                if toolBeginPosition == chatStream.endIndex {
                    // Begin queueing by flipping the hasDetectedTool flag
                    presumedHasDetectedTool = true
                } else {
                    // We can start to detect of a tool call is present
                    // How many characters are there between the toolBeginPosition and the end of the chatStream?
                    let remainingCharacters = chatStream[toolBeginPosition...].count
                    // Slice the remainingCharacters count off of each toolName - do any of them match?
                    let slicedToolNames = toolNames.map { $0.prefix(remainingCharacters) }
                    // If any of the slicedToolNames match, we have a tool call
                    if slicedToolNames.contains(where: { toolName in
                        chatStream[toolBeginPosition...].contains(toolName)
                    }) {
                        // We very likely have a tool call, so we can flip the hasDetectedTool flag
                        hasDetectedTool = true
                    } else {
                        // No tool call detected, reset the stream
                        presumedHasDetectedTool = false
                    }
                }
            }
        }
        
        private func detectToolEnd() {
            if !hasDetectedTool { return }
            
            if chatStream.contains(toolEnd) {
                // Try to parse the tool call from the stream
                let parser = ParseToolCalls(toolCalls: chatStream)
                do {
                    try parser.call()
                    // If successful, append the tool calls to the toolCalls array
                    self.toolCalls.append(contentsOf: parser.parsedTools)
                    
                    // Remove the tool call from the chatStream
                    // Find everything from the LAST toolBegin to the LAST toolEnd
                    if let lastToolBeginIndex = chatStream.lastIndex(of: toolBegin.first!),
                       let lastToolEndIndex = chatStream.lastIndex(of: toolEnd.first!) {
                        let range = lastToolBeginIndex...lastToolEndIndex
                        chatStream.removeSubrange(range)
                    }
                    
                    // Reset the chatStream and flags
                    presumedHasDetectedTool = false
                    hasDetectedTool = false
                } catch {
                    // If parsing fails, we can assume that the tool call is not complete yet
                    // We will keep the stream as is for further processing
                }
            }
        }
    }
}
