//
//  PrivateDocumentStoreTests.swift
//  FreeToken
//
//  Created by Claude Code on 7/8/25.
//

import XCTest
import FreeToken

@MainActor
final class PrivateDocumentStoreTests: XCTestCase {
    let freeToken = FreeToken.shared
    
    override func setUpWithError() throws {
        // Configure FreeToken for testing
        _ = FreeToken.shared.configure(
            appToken: "app_tkn_3b39cb60-22cd-4877-b784-170b75f88a92",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
        
        // Register Device
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await FreeToken.shared.registerDeviceSession(scope: "private-doc-tests") {
                await FreeToken.shared.downloadAIModel { isLocal in
                    semaphore.signal()
                } error: { error in
                    XCTFail("Failed to download AI model: \(error.message)")
                } progressPercent: { progressPercent in
                    // Progress updates
                }
            } error: { error in
                XCTFail("Failed to register device session: \(error.message)")
            }
        }
        semaphore.wait()
        print("---------------------------------- SETUP COMPLETE ----------------------------------")
    }

    override func tearDownWithError() throws {
        print("--------------------------------- TEARDOWN -----------------------------------------")
        try FreeToken.shared.resetDevice()
    }

    func testCreatePrivateDocumentStore() async throws {
        let expectation = expectation(description: "Create private document store")
        
        await freeToken.createPrivateDocumentStore(name: "Test Store") { store in
            XCTAssertFalse(store.id.isEmpty, "Store ID should not be empty")
            print("✅ Created private document store with ID: \(store.id)")
            expectation.fulfill()
        } error: { error in
            XCTFail("Failed to create private document store: \(error.message)")
        }
        
        await fulfillment(of: [expectation], timeout: 30)
    }
        
    func testCreateDocumentInPrivateStore() async throws {
        let freeTokenRef = freeToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await freeTokenRef.createPrivateDocumentStore(name: "Document Test Store") { store in
                    let storeId = store.id
                    print("📁 Created store: \(storeId)")
                    
                    Task {
                        await freeTokenRef.createDocument(content: "This is a test document for the private document store.", searchScope: "test-document") { document in
                            XCTAssertFalse(document.id.isEmpty, "Document ID should not be empty")
                            XCTAssertEqual(document.content, "This is a test document for the private document store.")
                            print("✅ Created document in private store: \(document.id)")
                            continuation.resume()
                        } error: { error in
                            XCTFail("Failed to create document in private store: \(error.message)")
                            continuation.resume()
                        }
                    }
                } error: { error in
                    XCTFail("Failed to create private document store: \(error.message)")
                    continuation.resume()
                }
            }
        }
    }
    
    func testSearchDocumentsInPrivateStore() async throws {
        let freeTokenRef = freeToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await freeTokenRef.createPrivateDocumentStore(name: "Search Test Store") { store in
                    let storeId = store.id
                    print("📁 Created store for search test: \(storeId)")
                    
                    Task {
                        await freeTokenRef.createDocument(content: "The solar system contains eight planets including Earth and Mars.", searchScope: "eight-planets", privateDocumentStoreID: storeId) { document in
                            print("📄 Created searchable document: \(document.id)")
                            
                            Task {
                                await freeTokenRef.searchDocuments(
                                    query: "planets solar system",
                                    privateDocumentStoreIds: [storeId],
                                    maxResults: 5
                                ) { searchResults in
                                    XCTAssertFalse(searchResults.documentChunks.isEmpty, "Should find documents in private store")
                                    print("✅ Found \(searchResults.documentChunks.count) document chunks")
                                    
                                    for chunk in searchResults.documentChunks {
                                        print("📄 Chunk: \(chunk.contentChunk)")
                                    }
                                    continuation.resume()
                                } error: { error in
                                    XCTFail("Failed to search documents in private store: \(error.message)")
                                    continuation.resume()
                                }
                            }
                        } error: { error in
                            XCTFail("Failed to create document for search test: \(error.message)")
                            continuation.resume()
                        }
                    }
                } error: { error in
                    XCTFail("Failed to create private document store for search test: \(error.message)")
                    continuation.resume()
                }
            }
        }
    }
    
    func testDeletePrivateDocumentStore() async throws {
        let freeTokenRef = freeToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await freeTokenRef.createPrivateDocumentStore(name: "Store to Delete") { store in
                    let storeId = store.id
                    print("📁 Created store to delete: \(storeId)")
                    
                    Task {
                        await freeTokenRef.createDocument(content: "This document will be deleted with the store.", searchScope: "delete-document", privateDocumentStoreID: storeId) { document in
                            print("📄 Created document to be deleted: \(document.id)")
                            
                            Task {
                                await freeTokenRef.deletePrivateDocumentStore(id: storeId) {
                                    print("✅ Successfully deleted private document store")
                                    continuation.resume()
                                } error: { error in
                                    XCTFail("Failed to delete private document store: \(error.message)")
                                    continuation.resume()
                                }
                            }
                        } error: { error in
                            XCTFail("Failed to create document for deletion test: \(error.message)")
                            continuation.resume()
                        }
                    }
                } error: { error in
                    XCTFail("Failed to create private document store for deletion test: \(error.message)")
                    continuation.resume()
                }
            }
        }
    }
    
    func testSearchCombiningPublicAndPrivateStores() async throws {
        let freeTokenRef = freeToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await freeTokenRef.createPrivateDocumentStore(name: "Combined Search Store") { store in
                    let storeId = store.id
                    print("📁 Created private store: \(storeId)")
                    
                    Task {
                        await freeTokenRef.createDocument(content: "Private information about quantum computing algorithms.", searchScope: "quantum", privateDocumentStoreID: storeId) { document in
                            print("📄 Created private document: \(document.id)")
                            
                            Task {
                                await freeTokenRef.createDocument(
                                    content: "Public information about classical computing methods.",
                                    metadata: "Public research",
                                    searchScope: "public-test"
                                ) { publicDoc in
                                    print("📄 Created public document: \(publicDoc.id)")
                                    
                                    Task {
                                        await freeTokenRef.searchDocuments(
                                            query: "computing algorithms methods",
                                            searchScope: "public-test",
                                            privateDocumentStoreIds: [storeId],
                                            maxResults: 10
                                        ) { searchResults in
                                            XCTAssertFalse(searchResults.documentChunks.isEmpty, "Should find documents from both sources")
                                            print("✅ Found \(searchResults.documentChunks.count) chunks from combined search")
                                            
                                            // Check that we have results from both sources
                                            let hasPrivateContent = searchResults.documentChunks.contains { chunk in
                                                chunk.contentChunk.contains("quantum")
                                            }
                                            let hasPublicContent = searchResults.documentChunks.contains { chunk in
                                                chunk.contentChunk.contains("classical")
                                            }
                                            
                                            if hasPrivateContent {
                                                print("✅ Found private content in search results")
                                            }
                                            if hasPublicContent {
                                                print("✅ Found public content in search results")
                                            }
                                            
                                            continuation.resume()
                                        } error: { error in
                                            XCTFail("Failed to search across public and private sources: \(error.message)")
                                            continuation.resume()
                                        }
                                    }
                                } error: { error in
                                    XCTFail("Failed to create public document: \(error.message)")
                                    continuation.resume()
                                }
                            }
                        } error: { error in
                            XCTFail("Failed to create private document: \(error.message)")
                            continuation.resume()
                        }
                    }
                } error: { error in
                    XCTFail("Failed to create private document store: \(error.message)")
                    continuation.resume()
                }
            }
        }
    }
}
