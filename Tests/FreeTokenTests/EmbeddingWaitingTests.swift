//
//  EmbeddingWaitingTests.swift
//  FreeTokenTests
//
//  Created by Assistant on 2025-07-28.
//

import XCTest
import FreeToken

final class EmbeddingWaitingTests: XCTestCase {
    let freeToken = FreeToken.shared
    
    override func setUpWithError() throws {
        // Configure FreeToken
        _ = try FreeToken.shared.configure(
            appToken: "app_tkn_3b39cb60-22cd-4877-b784-170b75f88a92",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
        
        // Register Device
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await FreeToken.shared.registerDeviceSession(scope: "embedding-waiting-tests") {
                // Don't download AI model here, let the embedding test handle it
                semaphore.signal()
            } error: { error in
                XCTFail("Failed to register device session: \(error.message)")
                semaphore.signal()
            }
        }
        semaphore.wait()
    }
    
    override func tearDownWithError() throws {
        // Clean up after tests
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            _ = try await FreeToken.shared.resetDevice()
            semaphore.signal()
        }
        semaphore.wait()
    }
    
    func testEmbeddingWaitsForModelDownload() async throws {
        // This test simulates the scenario where embedding is requested while model is downloading
        // Since we can't directly access internal components, we'll test the behavior
        
        let expectation = XCTestExpectation(description: "Document creation should wait for embedding model")
        
        // Start document creation which will trigger embedding and potentially model download
        try await FreeToken.shared.createDocument(
            content: "This is a test document that needs embedding. The embedding model should download first before processing.",
            searchScope: "test-scope",
            success: { document in
                print("✅ Document created successfully: \(document.id)")
                print("   Document type: \(document.documentType)")
                print("   Content length: \(document.content.count)")
                
                // Document creation success means embeddings were generated successfully
                // This validates that the embedding model either was ready or downloaded successfully
                expectation.fulfill()
            },
            error: { error in
                XCTFail("Failed to create document: \(error)")
                expectation.fulfill()
            }
        )
        
        await fulfillment(of: [expectation], timeout: 60.0) // Give enough time for model download
    }
    
    func testSearchDocumentsWithEmbedding() async throws {
        // Ensure we have a document to search
        let createExpectation = XCTestExpectation(description: "Create document for search")
        
        try await FreeToken.shared.createDocument(
            content: "Swift is a powerful programming language for iOS development. It provides safety, performance, and expressiveness.",
            searchScope: "test-scope",
            success: { _ in
                createExpectation.fulfill()
            },
            error: { error in
                XCTFail("Failed to create document: \(error)")
                createExpectation.fulfill()
            }
        )
        
        await fulfillment(of: [createExpectation], timeout: 30.0)
        
        // Now test search which also requires embeddings
        let searchExpectation = XCTestExpectation(description: "Search should work with embeddings")
        
        await FreeToken.shared.searchDocuments(
            query: "Swift programming",
            searchScope: "test-scope",
            success: { results in
                print("✅ Search completed with \(results.documentChunks.count) results")
                searchExpectation.fulfill()
            },
            error: { error in
                XCTFail("Search failed: \(error)")
                searchExpectation.fulfill()
            }
        )
        
        await fulfillment(of: [searchExpectation], timeout: 30.0)
    }
}
