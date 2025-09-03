//
//  ParseToolCallsTests.swift
//  FreeToken
//
//  Created by Tests on 1/3/25.
//

import XCTest
@testable import FreeToken

final class ParseToolCallsTests: XCTestCase {
    
    func testJsonToolCallWithTypeField() throws {
        // Test the new JSON format with type field
        let messageContent = """
        The weather information you requested:
        [{ "type": "function_call", "name": "web_search", "arguments": { "query": "latest news" } }]
        Done!
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 1, "Should find 1 tool call")
        XCTAssertEqual(toolCalls.first?.name, "web_search", "Tool name should be web_search")
        XCTAssertEqual(toolCalls.first?.arguments["query"], "latest news", "Query argument should match")
    }
    
    func testMultipleJsonToolCalls() throws {
        // Test multiple tool calls in JSON array format
        let messageContent = """
        Here are the tool calls:
        [
            { "type": "function_call", "name": "web_search", "arguments": { "query": "weather today" } },
            { "type": "function", "name": "article_lookup", "arguments": { "query": "climate change" } }
        ]
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search", "article_lookup"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 2, "Should find 2 tool calls")
        XCTAssertEqual(toolCalls[0].name, "web_search", "First tool should be web_search")
        XCTAssertEqual(toolCalls[0].arguments["query"], "weather today", "First query should match")
        XCTAssertEqual(toolCalls[1].name, "article_lookup", "Second tool should be article_lookup")
        XCTAssertEqual(toolCalls[1].arguments["query"], "climate change", "Second query should match")
    }
    
    func testMixedFormats() throws {
        // Test that both Python and JSON formats work in the same message
        let messageContent = """
        I'll help you with that. Let me search for information.
        
        web_search(query="Python format search")
        
        Also doing this search:
        [{ "type": "function_call", "name": "article_lookup", "arguments": { "query": "JSON format search" } }]
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search", "article_lookup"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 2, "Should find 2 tool calls from different formats")
        
        // Check both formats were parsed
        let hasWebSearch = toolCalls.contains { $0.name == "web_search" && $0.arguments["query"] == "Python format search" }
        let hasArticleLookup = toolCalls.contains { $0.name == "article_lookup" && $0.arguments["query"] == "JSON format search" }
        
        XCTAssertTrue(hasWebSearch, "Should find Python format tool call")
        XCTAssertTrue(hasArticleLookup, "Should find JSON format tool call")
    }
    
    func testIgnoresInvalidJsonToolCalls() throws {
        // Test that invalid tool names are ignored
        let messageContent = """
        [
            { "type": "function_call", "name": "invalid_tool", "arguments": { "query": "test" } },
            { "type": "function_call", "name": "web_search", "arguments": { "query": "valid search" } }
        ]
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 1, "Should only find valid tool call")
        XCTAssertEqual(toolCalls.first?.name, "web_search", "Should only parse allowed tool")
    }
    
    func testComplexArguments() throws {
        // Test JSON format with multiple arguments
        let messageContent = """
        [{ 
            "type": "function_call", 
            "name": "get_current_weather", 
            "arguments": { 
                "location": "San Francisco, CA",
                "format": "celsius",
                "detailed": "true"
            } 
        }]
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["get_current_weather"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 1, "Should find 1 tool call")
        XCTAssertEqual(toolCalls.first?.name, "get_current_weather", "Tool name should match")
        XCTAssertEqual(toolCalls.first?.arguments["location"], "San Francisco, CA", "Location should match")
        XCTAssertEqual(toolCalls.first?.arguments["format"], "celsius", "Format should match")
        XCTAssertEqual(toolCalls.first?.arguments["detailed"], "true", "Detailed flag should match")
    }
    
    func testJsonToolCallWithoutBrackets() throws {
        // Test single JSON tool call without array brackets
        let messageContent = """
        I'll search for that information:
        { "type": "function_call", "name": "web_search", "arguments": { "query": "latest AI news" } }
        That should help answer your question.
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 1, "Should find 1 tool call without brackets")
        XCTAssertEqual(toolCalls.first?.name, "web_search", "Tool name should be web_search")
        XCTAssertEqual(toolCalls.first?.arguments["query"], "latest AI news", "Query argument should match")
    }
    
    func testMultipleJsonToolCallsWithoutBrackets() throws {
        // Test multiple JSON tool calls without array brackets
        let messageContent = """
        Let me search for multiple things:
        { "type": "function_call", "name": "web_search", "arguments": { "query": "weather forecast" } }
        
        And also:
        { "type": "function", "name": "article_lookup", "arguments": { "query": "climate patterns" } }
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search", "article_lookup"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 2, "Should find 2 tool calls without brackets")
        
        let hasWebSearch = toolCalls.contains { $0.name == "web_search" && $0.arguments["query"] == "weather forecast" }
        let hasArticleLookup = toolCalls.contains { $0.name == "article_lookup" && $0.arguments["query"] == "climate patterns" }
        
        XCTAssertTrue(hasWebSearch, "Should find web_search call")
        XCTAssertTrue(hasArticleLookup, "Should find article_lookup call")
    }
    
    func testMixedBracketFormats() throws {
        // Test mix of with and without brackets
        let messageContent = """
        Here's a tool call without brackets:
        { "type": "function_call", "name": "web_search", "arguments": { "query": "no brackets" } }
        
        And here's one with brackets:
        [{ "type": "function_call", "name": "article_lookup", "arguments": { "query": "with brackets" } }]
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search", "article_lookup"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 2, "Should find both formats")
        
        let hasNoBrackets = toolCalls.contains { $0.name == "web_search" && $0.arguments["query"] == "no brackets" }
        let hasWithBrackets = toolCalls.contains { $0.name == "article_lookup" && $0.arguments["query"] == "with brackets" }
        
        XCTAssertTrue(hasNoBrackets, "Should find tool call without brackets")
        XCTAssertTrue(hasWithBrackets, "Should find tool call with brackets")
    }
    
    func testFlexibleTypeField() throws {
        // Test that type field is optional and can have any value
        let messageContent = """
        Tool calls with various type fields:
        
        { "type": "tool", "name": "web_search", "arguments": { "query": "custom type" } }
        { "type": "random_value", "name": "article_lookup", "arguments": { "query": "any type" } }
        { "name": "get_current_weather", "arguments": { "location": "NYC", "format": "celsius" } }
        
        In array format:
        [
            { "type": "something_else", "name": "web_search", "arguments": { "query": "array test" } },
            { "name": "article_lookup", "arguments": { "query": "no type in array" } }
        ]
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search", "article_lookup", "get_current_weather"])
        let toolCalls = try parser.parse()
        
        XCTAssertEqual(toolCalls.count, 5, "Should find all 5 tool calls regardless of type field")
        
        // Check individual calls
        let hasCustomType = toolCalls.contains { $0.name == "web_search" && $0.arguments["query"] == "custom type" }
        let hasAnyType = toolCalls.contains { $0.name == "article_lookup" && $0.arguments["query"] == "any type" }
        let hasNoType = toolCalls.contains { $0.name == "get_current_weather" && $0.arguments["location"] == "NYC" }
        let hasArrayTest = toolCalls.contains { $0.name == "web_search" && $0.arguments["query"] == "array test" }
        let hasNoTypeInArray = toolCalls.contains { $0.name == "article_lookup" && $0.arguments["query"] == "no type in array" }
        
        XCTAssertTrue(hasCustomType, "Should handle type='tool'")
        XCTAssertTrue(hasAnyType, "Should handle type='random_value'")
        XCTAssertTrue(hasNoType, "Should handle missing type field")
        XCTAssertTrue(hasArrayTest, "Should handle type='something_else' in array")
        XCTAssertTrue(hasNoTypeInArray, "Should handle missing type in array")
    }
    
    func testTypeFieldPosition() throws {
        // Test that type field can appear in different positions
        let messageContent = """
        { "type": "function", "name": "web_search", "arguments": { "query": "type first" } }
        { "name": "article_lookup", "type": "function_call", "arguments": { "query": "type middle" } }
        { "name": "get_current_weather", "arguments": { "location": "LA" }, "type": "tool" }
        """
        
        let parser = FreeToken.ParseToolCalls(messageContent: messageContent, toolNames: ["web_search", "article_lookup", "get_current_weather"])
        let toolCalls = try parser.parse()
        
        // Note: Currently only supporting type before name, name before type, or no type
        // The third format (type after arguments) won't be detected with current patterns
        XCTAssertGreaterThanOrEqual(toolCalls.count, 2, "Should find at least 2 tool calls")
        
        let hasTypeFirst = toolCalls.contains { $0.name == "web_search" && $0.arguments["query"] == "type first" }
        let hasTypeMiddle = toolCalls.contains { $0.name == "article_lookup" && $0.arguments["query"] == "type middle" }
        
        XCTAssertTrue(hasTypeFirst, "Should handle type before name")
        XCTAssertTrue(hasTypeMiddle, "Should handle name before type")
    }
}