//
//  FreeToken.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/25/25.
//

import XCTest
import FreeToken

final class FreeTokenTests: XCTestCase {
    let freeToken = FreeToken.shared
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        _ = try FreeToken.shared.configure(
            appToken: "test-token",
            baseURL: URL(string: "http://localhost:3000/api/v1/"),
            logLevel: .debug
        )
        // Register Device
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try await FreeToken.shared.resetChatCache()
//            try await FreeToken.shared.resetModelCaches()
            await FreeToken.shared.registerDeviceSession(scope: "swift-tests") {
                await FreeToken.shared.downloadAIModel { isLocal in
                    print("AI model downloaded successfully. Local: \(isLocal)")
                    semaphore.signal()
                } error: { error in
                    XCTFail("Failed to download AI model: \(error.message)")
                } progressPercent: { progressPercent in
                    // NOTE: This is not getting called during the test download
                    print("Download progress - TEST: \(progressPercent * 100.0)%")
                }
            } error: { error in
                XCTFail("Failed to register device session: \(error.message)")
            }
        }
        semaphore.wait() // Wait until complete
        print("---------------------------------- STOPPED WAITING ----------------------------------")
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        print("--------------------------------- RESETTING -----------------------------------------")
        Task {
            try await FreeToken.shared.resetDevice()
        }
    }
    
    func testChatSession() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")
        
        Task {
            let session = try await FreeToken.shared.getChatSession()
            
            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Italy"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }, toolUseHandler: nil)
            
            await session.unload()
            XCTAssertTrue(response.content.contains("Rome"), "Expected response to contain 'Rome'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testCloudChatSession() throws {
        let expectation = self.expectation(description: "Waiting for cloud chat session test")
        
        Task {
            let session = try await FreeToken.shared.getChatSession(runLocation: .cloudRun)
            
            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Germany"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }, toolUseHandler: nil)
            
            await session.unload()
            XCTAssertTrue(response.content.contains("Berlin"), "Expected response to contain 'Berlin'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testCompletionSession() throws {
        let expectation = self.expectation(description: "Waiting for completion session test")
        
        Task {
            let session = try await FreeToken.shared.getCompletionSession(runLocation: .localRun)
            
            let response = try await session.generateCompletion(from: "Tell me a fun fact about space", chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
            })
            
            await session.unload()
            XCTAssertTrue(response.response.contains("space"), "Expected response to contain 'space'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testCloudCompletionSession() throws {
        let expectation = self.expectation(description: "Waiting for cloud completion session test")
        
        Task {
            let session = try await FreeToken.shared.getCompletionSession(runLocation: .cloudRun)
            
            let response = try await session.generateCompletion(from: "Tell me a fun fact about oceans", chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
            })
            
            await session.unload()
            XCTAssertTrue(response.response.contains("ocean"), "Expected response to contain 'ocean'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testMemoryChatSession() throws {
        let expectation = self.expectation(description: "Waiting for memory chat session test")
        
        Task {
            let session = try await FreeToken.shared.getMemoryChatSession()
            
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Japan"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
            }, toolUseHandler: nil)
            
            await session.unload()
            XCTAssertTrue(response.content.contains("Tokyo"), "Expected response to contain 'Tokyo'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testCloudMemoryChatSession() throws {
        let expectation = self.expectation(description: "Waiting for memory chat session test")
        
        Task {
            let session = try await FreeToken.shared.getMemoryChatSession(runLocation: .cloudRun)
            
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Japan"))
            
            do {
                let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                    if let token = token {
                        print(token, separator: "")
                    } else {
                        print("\n[Status] \(status)")
                    }
                }, toolUseHandler: nil)
                
                await session.unload()
                XCTAssertTrue(response.content.contains("Tokyo"), "Expected response to contain 'Tokyo'")
                expectation.fulfill()
            } catch {
                XCTAssertTrue(false, "Cloud memory chat session failed with error: \(error)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testChatSessionToolCalling() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")
        
        Task {
            // name and definition can be empty for this test
            // definition is OpenAI JSON tool spec
            let getWeatherToolCall = FreeToken.ToolDefinition(name: "get_weather", definition: """
                    { "name": "get_weather",
                      "description": "Get the current weather for a given location",
                      "parameters": {
                        "type": "object",
                        "properties": {
                          "location": {
                            "type": "string",
                            "description": "The city and state, e.g. San Francisco, CA"
                          }
                        },
                        "required": ["location"]
                      }
                    }
                """)
            await FreeToken.shared.registerToolDefinitions([getWeatherToolCall])
            
            let session = try await FreeToken.shared.getChatSession()
            
            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the weather in Rome Italy?"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }) { toolCalls in
                var results = ""
                for toolCall in toolCalls {
                    if toolCall.name == "get_weather" {
                        // Simulate getting weather data
                        let location = toolCall.arguments["location"]
                        
                        if let location = location {
                            results += "The current weather in \(location) is sunny with a high of 25°C.\n"
                        } else {
                            results += "Location not provided.\n"
                        }
                    }
                }
                return results
            }
            
            await session.unload()
            await FreeToken.shared.removeAllToolDefinitions()
            XCTAssertTrue(response.content.contains("25°C"), "Expected response to contain '25°C'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testMemoryChatToolCalling() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")
        
        Task {
            // name and definition can be empty for this test
            // definition is OpenAI JSON tool spec
            let getWeatherToolCall = FreeToken.ToolDefinition(name: "get_weather", definition: """
                    { "name": "get_weather",
                      "description": "Get the current weather for a given location",
                      "parameters": {
                        "type": "object",
                        "properties": {
                          "location": {
                            "type": "string",
                            "description": "The city and state, e.g. San Francisco, CA"
                          }
                        },
                        "required": ["location"]
                      }
                    }
                """)
            await FreeToken.shared.registerToolDefinitions([getWeatherToolCall])
            
            let session = try await FreeToken.shared.getMemoryChatSession()
            
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the weather in Rome Italy?"))
            
            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }
                
            }) { toolCalls in
                var results = ""
                for toolCall in toolCalls {
                    if toolCall.name == "get_weather" {
                        // Simulate getting weather data
                        let location = toolCall.arguments["location"]
                        
                        if let location = location {
                            results += "The current weather in \(location) is sunny with a high of 25°C.\n"
                        } else {
                            results += "Location not provided.\n"
                        }
                    }
                }
                return results
            }
            
            await session.unload()
            await FreeToken.shared.removeAllToolDefinitions()
            XCTAssertTrue(response.content.contains("25°C"), "Expected response to contain '25°C'")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    func testMultiMessageConversation() throws {
        let expectation = self.expectation(description: "Waiting for chat session test")

        Task {
            let session = try await FreeToken.shared.getChatSession()

            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of Italy"))

            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }

            }, toolUseHandler: nil)


            XCTAssertTrue(response.content.contains("Rome"), "Expected response to contain 'Rome'")

            _ = try await session.addMessage(message: .init(role: .user, content: "Now what is the capital of Germany?"))

            let response2 = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                } else {
                    print("\n[Status] \(status)")
                }

            }, toolUseHandler: nil)

            XCTAssertTrue(response2.content.contains("Berlin"), "Expected response to contain 'Berlin'")

            await session.unload()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60.0)
    }

    // MARK: - Generation Cancellation Tests

    /// Error thrown from chatStatusStream to trigger cancellation
    struct UserCancellationError: Error {}

    /// Thread-safe counter for use in @Sendable closures
    actor TokenCounter {
        private var count = 0

        func increment() -> Int {
            count += 1
            return count
        }

        func value() -> Int {
            return count
        }
    }

    /// Thread-safe flag for use in @Sendable closures
    actor Flag {
        private var value = false

        func set(_ newValue: Bool) {
            value = newValue
        }

        func get() -> Bool {
            return value
        }
    }

    func testChatSessionCancellation() throws {
        let expectation = self.expectation(description: "Waiting for chat session cancellation test")

        Task {
            let session = try await FreeToken.shared.getChatSession(runLocation: .localRun)

            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "Write a very long story about a dragon"))

            let counter = TokenCounter()

            do {
                _ = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                    if token != nil {
                        let count = await counter.increment()
                        print("Token \(count)")
                        // Cancel after receiving 5 tokens
                        if count >= 5 {
                            print("Throwing cancellation error after \(count) tokens")
                            throw UserCancellationError()
                        }
                    } else {
                        print("\n[Status] \(status)")
                    }
                }, toolUseHandler: nil)

                XCTFail("Expected generationCancelled error to be thrown")
                expectation.fulfill()
            } catch let error as FreeToken.FreeTokenError {
                print("Caught error: \(error)")
                XCTAssertEqual(error.code, FreeToken.FreeTokenError.generationCancelled.code, "Expected generationCancelled error, got \(error)")
                expectation.fulfill()
            } catch {
                XCTFail("Expected FreeTokenError.generationCancelled, got \(error)")
                expectation.fulfill()
            }

            await session.unload()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60.0)
    }

    func testMemoryChatSessionCancellation() throws {
        let expectation = self.expectation(description: "Waiting for memory chat session cancellation test")

        Task {
            let session = try await FreeToken.shared.getMemoryChatSession()

            _ = try await session.addMessage(message: .init(role: .user, content: "Write a very long story about a wizard"))

            let counter = TokenCounter()

            do {
                _ = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                    if token != nil {
                        let count = await counter.increment()
                        print("Token \(count)")
                        // Cancel after receiving 5 tokens
                        if count >= 5 {
                            print("Throwing cancellation error after \(count) tokens")
                            throw UserCancellationError()
                        }
                    } else {
                        print("\n[Status] \(status)")
                    }
                }, toolUseHandler: nil)

                XCTFail("Expected generationCancelled error to be thrown")
            } catch let error as FreeToken.FreeTokenError {
                print("Caught error: \(error)")
                XCTAssertEqual(error.code, FreeToken.FreeTokenError.generationCancelled.code, "Expected generationCancelled error, got \(error)")
            } catch {
                XCTFail("Expected FreeTokenError.generationCancelled, got \(error)")
            }

            await session.unload()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60.0)
    }

    func testCancellationDoesNotTriggerCloudFallback() throws {
        let expectation = self.expectation(description: "Waiting for cancellation no-fallback test")

        Task {
            // Use automatic run location to verify cloud fallback doesn't occur
            let session = try await FreeToken.shared.getChatSession(runLocation: .automatic)

            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "Tell me about the universe"))

            let counter = TokenCounter()
            let sawCloudFallbackFlag = Flag()

            do {
                _ = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                    if status == .cloud_fallback {
                        await sawCloudFallbackFlag.set(true)
                        print("ERROR: Cloud fallback triggered!")
                    }
                    if token != nil {
                        let count = await counter.increment()
                        // Cancel after receiving 3 tokens
                        if count >= 3 {
                            throw UserCancellationError()
                        }
                    }
                }, toolUseHandler: nil)

                XCTFail("Expected generationCancelled error to be thrown")
            } catch let error as FreeToken.FreeTokenError {
                XCTAssertEqual(error.code, FreeToken.FreeTokenError.generationCancelled.code, "Expected generationCancelled error")
                let sawCloudFallback = await sawCloudFallbackFlag.get()
                XCTAssertFalse(sawCloudFallback, "Cloud fallback should NOT be triggered on user cancellation")
            } catch {
                XCTFail("Expected FreeTokenError.generationCancelled, got \(error)")
            }

            await session.unload()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 60.0)
    }

    func testGenerationWorksAfterCancellation() throws {
        let expectation = self.expectation(description: "Waiting for generation after cancellation test")

        Task {
            let session = try await FreeToken.shared.getChatSession()

            _ = try await session.createMessageThread()
            _ = try await session.addMessage(message: .init(role: .user, content: "What is 2+2?"))

            let counter = TokenCounter()

            // First: cancel a generation
            do {
                _ = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                    if token != nil {
                        let count = await counter.increment()
                        if count >= 3 {
                            throw UserCancellationError()
                        }
                    }
                }, toolUseHandler: nil)
            } catch let error as FreeToken.FreeTokenError {
                XCTAssertEqual(error.code, FreeToken.FreeTokenError.generationCancelled.code)
                print("First generation cancelled as expected")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            // Second: verify generation still works after cancellation
            _ = try await session.addMessage(message: .init(role: .user, content: "What is the capital of France?"))

            let response = try await session.generateNewMessage(documentSearchScope: nil, privateDocumentStoreIDs: nil, chatStatusStream: { token, status in
                if let token = token {
                    print(token, separator: "")
                }
            }, toolUseHandler: nil)

            print("\nResponse after cancellation: \(response.content)")
            XCTAssertTrue(response.content.contains("Paris"), "Expected response to contain 'Paris' after recovery from cancellation")

            await session.unload()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 120.0)
    }

    // MARK: - Document & Embedding Tests

    /// Thread-safe holder for document data (id and scope)
    actor DocumentData {
        private var id: String?
        private var scope: String?

        func set(id: String, scope: String) {
            self.id = id
            self.scope = scope
        }

        func getId() -> String? {
            return id
        }

        func getScope() -> String? {
            return scope
        }
    }

    /// Thread-safe holder for error message
    actor ErrorMessage {
        private var message: String?

        func set(_ msg: String) {
            message = msg
        }

        func get() -> String? {
            return message
        }
    }

    /// Thread-safe holder for search result data (count and first chunk content)
    actor SearchResultData {
        private var count: Int = 0
        private var firstChunkContent: String?

        func set(count: Int, firstChunkContent: String?) {
            self.count = count
            self.firstChunkContent = firstChunkContent
        }

        func getCount() -> Int {
            return count
        }

        func getFirstChunkContent() -> String? {
            return firstChunkContent
        }
    }

    /// Thread-safe holder for optional string
    actor StringHolder {
        private var value: String?

        func set(_ val: String) {
            value = val
        }

        func get() -> String? {
            return value
        }
    }

    /// Thread-safe holder for FreeTokenError
    actor ErrorHolder {
        private var error: FreeToken.FreeTokenError?

        func set(_ err: FreeToken.FreeTokenError) {
            error = err
        }

        func get() -> FreeToken.FreeTokenError? {
            return error
        }
    }

    func testDocumentCreation() throws {
        let expectation = self.expectation(description: "Waiting for document creation test")

        Task {
            let testContent = "The quick brown fox jumps over the lazy dog. This is a test document for embedding generation."
            let testScope = "test-scope-\(UUID().uuidString)"

            let documentData = DocumentData()
            let errorMessage = ErrorMessage()

            try await FreeToken.shared.createDocument(
                content: testContent,
                metadata: "test-metadata",
                searchScope: testScope,
                privateDocumentStoreID: nil,
                success: { document in
                    let docId = document.id
                    let docScope = document.searchScope
                    print("✅ Document created with ID: \(docId)")
                    Task { await documentData.set(id: docId, scope: docScope) }
                },
                error: { error in
                    let errorMsg = error.message
                    print("🔴 Document creation failed: \(errorMsg)")
                    Task { await errorMessage.set(errorMsg) }
                }
            )

            // Wait a moment for callbacks to complete
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            let createError = await errorMessage.get()
            let docId = await documentData.getId()
            let docScope = await documentData.getScope()

            XCTAssertNil(createError, "Document creation should not fail: \(createError ?? "")")
            XCTAssertNotNil(docId, "Document should be created")
            if let id = docId {
                XCTAssertFalse(id.isEmpty, "Document ID should not be empty")
            }
            if let scope = docScope {
                XCTAssertEqual(scope, testScope, "Search scope should match")
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 120.0)
    }

    func testDocumentSearch() throws {
        let expectation = self.expectation(description: "Waiting for document search test")

        Task {
            // First, create a document with unique content
            let uniqueId = UUID().uuidString.prefix(8)
            let testContent = "Quantum computing uses qubits instead of classical bits. Test ID: \(uniqueId)"
            let testScope = "search-test-\(uniqueId)"

            let docCreatedFlag = Flag()

            try await FreeToken.shared.createDocument(
                content: testContent,
                metadata: "quantum-test",
                searchScope: testScope,
                privateDocumentStoreID: nil,
                success: { document in
                    let docId = document.id
                    print("✅ Test document created with ID: \(docId)")
                    Task { await docCreatedFlag.set(true) }
                },
                error: { error in
                    let errorMsg = error.message
                    print("🔴 Document creation failed: \(errorMsg)")
                }
            )

            // Wait for document creation
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            let documentCreated = await docCreatedFlag.get()
            XCTAssertTrue(documentCreated, "Document should be created before searching")

            // Now search for the document
            let resultsData = SearchResultData()
            let errorMessage = ErrorMessage()

            await FreeToken.shared.searchDocuments(
                query: "quantum computing qubits",
                searchScope: testScope,
                privateDocumentStoreIds: nil,
                maxResults: 5,
                success: { results in
                    let count = results.documentChunks.count
                    let firstContent = results.documentChunks.first?.contentChunk
                    print("✅ Search returned \(count) results")
                    Task { await resultsData.set(count: count, firstChunkContent: firstContent) }
                },
                error: { error in
                    let errorMsg = error.message
                    print("🔴 Search failed: \(errorMsg)")
                    Task { await errorMessage.set(errorMsg) }
                }
            )

            // Wait for search to complete
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            let searchError = await errorMessage.get()
            let resultCount = await resultsData.getCount()
            let firstChunkContent = await resultsData.getFirstChunkContent()

            XCTAssertNil(searchError, "Search should not fail: \(searchError ?? "")")
            XCTAssertGreaterThan(resultCount, 0, "Should find at least one document chunk")
            // Verify the content matches what we created
            let foundContent = firstChunkContent ?? ""
            XCTAssertTrue(foundContent.contains("quantum") || foundContent.contains("qubits"),
                         "Search result should contain relevant content")

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 180.0)
    }

    func testPrivateDocumentStoreCreationAndSearch() throws {
        let expectation = self.expectation(description: "Waiting for private document store test")

        Task {
            // Step 1: Create a private document store
            let storeIdHolder = StringHolder()
            let storeErrorMessage = ErrorMessage()

            await FreeToken.shared.createPrivateDocumentStore(
                name: "Test Private Store \(UUID().uuidString.prefix(8))",
                success: { store in
                    let storeId = store.id
                    print("✅ Private document store created with ID: \(storeId)")
                    Task { await storeIdHolder.set(storeId) }
                },
                error: { error in
                    let errorMsg = error.message
                    print("🔴 Private store creation failed: \(errorMsg)")
                    Task { await storeErrorMessage.set(errorMsg) }
                }
            )

            // Wait for store creation
            try await Task.sleep(nanoseconds: 500_000_000)

            let storeError = await storeErrorMessage.get()
            let storeId = await storeIdHolder.get()

            XCTAssertNil(storeError, "Private store creation should not fail: \(storeError ?? "")")
            XCTAssertNotNil(storeId, "Store ID should be returned")

            guard let privateStoreId = storeId else {
                XCTFail("Cannot continue without store ID")
                expectation.fulfill()
                return
            }

            // Step 2: Create a private document in the store
            let uniqueId = UUID().uuidString.prefix(8)
            let privateContent = "This is confidential information about project alpha. Secret code: \(uniqueId)"
            let privateScope = "private-test-\(uniqueId)"

            let privateDocCreatedFlag = Flag()

            try await FreeToken.shared.createDocument(
                content: privateContent,
                metadata: "confidential",
                searchScope: privateScope,
                privateDocumentStoreID: privateStoreId,
                success: { document in
                    let docId = document.id
                    print("✅ Private document created with ID: \(docId)")
                    Task { await privateDocCreatedFlag.set(true) }
                },
                error: { error in
                    let errorMsg = error.message
                    print("🔴 Private document creation failed: \(errorMsg)")
                }
            )

            // Wait for document creation
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let privateDocCreated = await privateDocCreatedFlag.get()
            XCTAssertTrue(privateDocCreated, "Private document should be created")

            // Step 3: Search within the private document store
            let searchResultsData = SearchResultData()
            let searchErrorMessage = ErrorMessage()

            await FreeToken.shared.searchDocuments(
                query: "confidential project alpha",
                searchScope: privateScope,
                privateDocumentStoreIds: [privateStoreId],
                maxResults: 5,
                success: { results in
                    let count = results.documentChunks.count
                    print("✅ Private search returned \(count) results")
                    Task { await searchResultsData.set(count: count, firstChunkContent: nil) }
                },
                error: { error in
                    let errorMsg = error.message
                    print("🔴 Private search failed: \(errorMsg)")
                    Task { await searchErrorMessage.set(errorMsg) }
                }
            )

            // Wait for search
            try await Task.sleep(nanoseconds: 500_000_000)

            let searchError = await searchErrorMessage.get()
            let searchResultCount = await searchResultsData.getCount()

            XCTAssertNil(searchError, "Private search should not fail: \(searchError ?? "")")
            XCTAssertGreaterThan(searchResultCount, 0, "Should find the private document")

            // Step 4: Clean up - delete the private document store
            await FreeToken.shared.deletePrivateDocumentStore(
                id: privateStoreId,
                success: {
                    print("✅ Private document store deleted")
                },
                error: { error in
                    let errorMsg = error.message
                    print("⚠️ Failed to delete private store (non-fatal): \(errorMsg)")
                }
            )

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 180.0)
    }

    func testEmbeddingModelDownloadAndGeneration() throws {
        let expectation = self.expectation(description: "Waiting for embedding model test")

        Task {
            // This test verifies the embedding model downloads and works correctly
            // by creating a document (which requires embedding generation)

            let testContent = """
            Machine learning is a subset of artificial intelligence that enables systems
            to learn and improve from experience without being explicitly programmed.
            Neural networks are computing systems inspired by biological neural networks.
            """
            let testScope = "embedding-test-\(UUID().uuidString.prefix(8))"

            let docCreatedFlag = Flag()
            let errorHolder = ErrorHolder()

            print("📥 Starting embedding model test - this will download the embedding model if needed...")

            try await FreeToken.shared.createDocument(
                content: testContent,
                metadata: "ml-test",
                searchScope: testScope,
                privateDocumentStoreID: nil,
                success: { document in
                    print("✅ Document created successfully - embedding model is working!")
                    print("   Document ID: \(document.id)")
                    Task { await docCreatedFlag.set(true) }
                },
                error: { error in
                    print("🔴 Document creation failed: \(error.message)")
                    Task { await errorHolder.set(error) }
                }
            )

            // Wait for document creation (may take longer if embedding model needs to download)
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            let createError = await errorHolder.get()
            let documentCreated = await docCreatedFlag.get()

            XCTAssertNil(createError, "Embedding generation should succeed: \(createError?.message ?? "")")
            XCTAssertTrue(documentCreated, "Document should be created using embedding model")

            // Now verify we can search using embeddings
            let searchResultsData = SearchResultData()

            await FreeToken.shared.searchDocuments(
                query: "artificial intelligence neural networks",
                searchScope: testScope,
                privateDocumentStoreIds: nil,
                maxResults: 3,
                success: { results in
                    let count = results.documentChunks.count
                    print("✅ Search with embeddings returned \(count) results")
                    Task { await searchResultsData.set(count: count, firstChunkContent: nil) }
                },
                error: { error in
                    print("🔴 Search failed: \(error.message)")
                }
            )

            try await Task.sleep(nanoseconds: 500_000_000)

            let searchResultCount = await searchResultsData.getCount()
            XCTAssertGreaterThan(searchResultCount, 0, "Search using embedding model should find results")

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 300.0) // 5 minutes to allow for embedding model download
    }

}
