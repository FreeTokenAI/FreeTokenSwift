![FreeToken header](./github-header.png)

The FreeToken Swift client provides seamless AI integration for iOS/macOS apps, supporting both on-device and cloud AI, document search, and more.

For more in-depth guides, configuration options, and scenarios, visit the FreeToken documentation: https://docs.freetoken.ai

---

## Features

- **On-device and Cloud AI**: Automatic fallback between local and cloud inference.
- **Client-side Encryption**: Optional encryption/decryption for sensitive data using your own algorithms.
- **Document Indexing & Search**: Store and retrieve context for Retrieval-Augmented Generation (RAG).
- **Private Document Stores**: Secure, isolated document storage with server-generated IDs.
- **Message Threading**: Multi-turn conversations with persistent threads in the cloud for syncing between clients.
- **Function/Tool Calling**: Extendable for advanced AI workflows. 
- **Built in RAG**: Automatically search and retrieve relevant documents for AI context.
- **Web Search**: Automatically perform web searches to enhance AI responses.
- **Streaming & Progress Callbacks**: Real-time feedback for long-running operations.

---

## Requirements

- iOS 16+
- macOS 15+

---

## Installation

Add FreeToken to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/FreeTokenAI/FreeTokenSwift.git", from: "1.0.0")
]
```

---

## Basic Usage

### 1. Configuration

Set up the FreeToken client with your API key from the [FreeToken console](https://app.freetoken.ai).  
_Always call this before any other FreeToken operations._

```swift
import FreeToken

do {
    let client = try FreeToken.shared.configure(appToken: "your-api-key")
    // client is now configured
} catch {
    print("Failed to configure FreeToken: \(error)")
}
```

---

### 2. Device Registration

Register the device with FreeToken Cloud to determine AI capabilities and enable secure communication.

```swift
await client.registerDeviceSession(scope: "my-app-v1") {
    // Successfully registered
} error: { error in
    print("Failed to register device: \(error)")
}
```

_Note:_ The scope parameter can be used for testing message prompts through configuring agent routes on the App in the [FreeToken console](https://app.freetoken.ai). You may want to elect to randomly add a unique scope by appending a letter or number to the end of the scope string, such as "my-app-v1-a". Then in the console you can configure routing so all "a" scoped sessions go to one agent and other sessions go to another.

---

### 3. Download AI Model

Download the AI model for on-device inference.  
_If the device is not capable, FreeToken will **not** download the model and try use cloud fallback for AI if the run location is set to `.automatic`._

```swift
await client.downloadAIModel { state in
    // Ready for use whether on-device or cloud
    switch state {
    case .downloaded:
        // Device supports on-device AI
        print("Model downloaded and ready")
    case .aiNotSupported:
        // Device cannot run the model locally; fallback to cloud
        print("Device not AI-capable; will use cloud fallback")
    default:
        print("Model state: \(state)")
    }
} error: { error in
    print("Download failed: \(error)")
} progressPercent: { progress in
    // progress is 0.0 ... 1.0
    print("Download progress: \(Int(progress * 100))%")
}
```

Note: The `success` callback returns a `DownloadedState` enum (for example `.downloaded` or `.aiNotSupported`) that indicates to your application what happened during the download process. Use the returned state to decide how to proceed.

---

### 4. AI Sessions

FreeToken provides session-based APIs for managing AI interactions. Sessions handle model loading, memory management, and provide cleaner state management compared to older stateless APIs.

#### Chat Sessions

Chat sessions manage persistent conversation threads with automatic model preloading and state management.

**Basic Usage:**

```swift
// Get a chat session (automatically determines local vs cloud based on device capabilities)
let chatSession = try await client.getChatSession()

// Create a new thread
let thread = try await chatSession.createMessageThread()
// Save thread.id for future use

// Add a user message
let userMessage = Message(role: .user, content: "What is a supernova?")
try await chatSession.addMessage(message: userMessage)

// Generate AI response
let response = try await chatSession.generateNewMessage()
print("AI: \(response.content)")

// Free memory when done
await chatSession.unload()
```

**With Streaming and Status Updates:**

```swift
let chatSession = try await client.getChatSession()
let thread = try await chatSession.createMessageThread()

let userMessage = Message(role: .user, content: "Explain black holes")
try await chatSession.addMessage(message: userMessage)

let response = try await chatSession.generateNewMessage(
    chatStatusStream: { token, status in
        switch status {
        case .starting:
            print("Starting...")
        case .sending_to_local_ai:
            print("Using local AI")
        case .sending_to_cloud_ai:
            print("Using cloud AI")
        case .cloud_fallback:
            print("Falling back to cloud")
        case .streaming_tokens:
            if let token = token {
                print(token, terminator: "")
            }
        case .evaluating_tool_calls:
            print("\nEvaluating tools...")
        case .new_message_created:
            print("\nMessage saved")
        case .stream_ended:
            print("\nDone!")
        case .failed:
            print("\nFailed")
        }
    }
)
```

**Force Cloud or Local:**

```swift
// Force cloud-only execution
let cloudSession = try await client.getChatSession(runLocation: .cloudRun)

// Force local execution (will fail if model not downloaded)
let localSession = try await client.getChatSession(runLocation: .localRun)
```

**Resume Existing Thread:**

```swift
// Pass existing thread ID to resume a conversation
let chatSession = try await client.getChatSession(messageThreadID: "existing-thread-id")

// Get conversation history
let messages = try await chatSession.getMessages()
for message in messages {
    print("\(message.role): \(message.content)")
}

// Add new message and continue
let userMsg = Message(role: .user, content: "Tell me more")
try await chatSession.addMessage(message: userMsg)
let response = try await chatSession.generateNewMessage()
```

**In-Memory Chat Sessions:**

For temporary conversations without cloud persistence:

```swift
// Memory-only session (no cloud storage)
let memorySession = try await client.getMemoryChatSession()

// Add messages (stored in memory only)
try await memorySession.addMessage(message: Message(role: .user, content: "Hello"))
let response = try await memorySession.generateNewMessage()

// Messages are lost when session is deallocated
```

#### Completion Sessions

Completion sessions provide stateless text generation without persistent threads. Ideal for one-off completions.

**Basic Usage:**

```swift
// Get a completion session
let completionSession = try await client.getCompletionSession()

// Generate completion
let completion = try await completionSession.generateCompletion(
    from: "Write a haiku about coding"
)
print(completion.response)

// Free memory when done
await completionSession.unload()
```

**With Streaming:**

```swift
let completionSession = try await client.getCompletionSession()

let completion = try await completionSession.generateCompletion(
    from: "Explain quantum computing",
    chatStatusStream: { token, status in
        switch status {
        case .streaming_tokens:
            if let token = token {
                print(token, terminator: "")
            }
        case .cloud_fallback:
            print("\nUsing cloud AI...")
        default:
            break
        }
    }
)
```

**Force Cloud or Local:**

```swift
// Force cloud execution
let cloudCompletion = try await client.getCompletionSession(runLocation: .cloudRun)

// Force local execution
let localCompletion = try await client.getCompletionSession(runLocation: .localRun)
```

#### Thread Management (Legacy API)

For backward compatibility, direct thread management APIs are still available:

```swift
// Delete thread
client.deleteMessageThread(id: "thread-id", success: { id in
    print("Deleted: \(id)")
}, error: { _ in })

// Get thread with messages
await client.getMessageThread(id: "thread-id", success: { thread in
    print("Messages: \(thread.messages.count)")
}, error: { _ in })

// Get specific message
await client.getMessage(id: "message-id", success: { message in
    print("Content: \(message.content)")
}, error: { _ in })
```

---

### 5. Document Management

Store, retrieve, and search documents for use as AI context (RAG, knowledge base, etc.).

#### Create a Document

```swift
do {
    try await client.createDocument(
        content: "Document content",
        metadata: "TITLE: Example Document\nAUTHOR: John Doe",
        searchScope: "knowledge-base",
        success: { document in
            print("Document created: \(document.id)")
        },
        error: { error in
            print("Failed to create document: \(error)")
        }
    )
} catch {
    print("Create document failed: \(error)")
}
```

Note: The document data should be considered _public_ to all agents in the App context and immutable.

#### Create a Document in a Private Store

You can create documents within private document stores for enhanced security and isolation.

```swift
do {
    try await client.createDocument(
        content: "Private document content",
        metadata: "TITLE: Private Document\nCLASSIFICATION: Confidential",
        searchScope: "private-knowledge",
        privateDocumentStoreID: "store-id",
        success: { document in
            print("Private document created: \(document.id)")
        },
        error: { error in
            print("Failed to create private document: \(error)")
        }
    )
} catch {
    print("Create private document failed: \(error)")
}
``` 

#### Get a Document

```swift
client.getDocument(id: "doc-id", success: { document in
    print("Document: \(document.content)")
}, error: { error in
    print("Failed to get document: \(error)")
})
```

#### Search Documents

```swift
await client.searchDocuments(
    query: "supernova explosion",
    searchScope: "astronomy",
    maxResults: 5,
    success: { results in
        for chunk in results.documentChunks {
            print("Found relevant content: \(chunk.contentChunk)")
        }
    },
    error: { error in
        print("Search failed: \(error)")
    }
)
```

---

### 6. Private Document Stores

Private Document Stores provide secure, isolated document storage with server-generated IDs for enhanced security. Unlike public documents, private stores are only accessible by their unique ID and provide complete isolation between different contexts.


#### Create a Private Document Store

```swift
await client.createPrivateDocumentStore(name: "My Private Documents") { store in
    // Store the ID securely - this is the only way to access the store
    let storeId = store.id
    print("Created private store: \(storeId)")
} error: { error in
    print("Failed to create private store: \(error)")
}
```

#### Delete a Private Document Store

```swift
await client.deletePrivateDocumentStore(id: "store-id") {
    print("Private document store deleted successfully")
} error: { error in
    print("Failed to delete private store: \(error)")
}
```

**Important Security Notes:**
- Private document store IDs are server-generated for enhanced security
- Once created, stores can only be accessed via their unique ID
- There is no API to list private document stores (security by design)
- Deleting a store permanently removes all documents within it
- The `name` parameter is used for identification in the [FreeToken console](https://app.freetoken.ai)

#### Integration with RAG and AI Context

Private document stores seamlessly integrate with the AI system for Retrieval-Augmented Generation:

- **Message Threads**: Include private documents in AI conversations
- **Tool Calls**: The `article_lookup` tool automatically searches private stores when provided
- **Search Operations**: Search across public and private documents simultaneously
- **Automatic Context**: Private documents become part of the AI's knowledge base for enhanced responses

---

### 7. Encryption

Enable client-side encryption/decryption for sensitive data. When enabled, all messages and documents will be encrypted before sending to the server and decrypted when received.
```swift
// Built-in key generation (recommended for most apps)
// Generate keys (only returned once) for each scope and persist them securely.
let sharedPublicKey = FreeToken.shared.enableEncryption(scope: .sharedPublic)
let userPrivateKey = FreeToken.shared.enableEncryption(scope: .userPrivate)

// Persist securely — Keychain is recommended. Example (insecure demonstration only):
UserDefaults.standard.set(sharedPublicKey, forKey: "FTSharedPublicKey")
UserDefaults.standard.set(userPrivateKey, forKey: "FTUserPrivateKey")

// Later — initialize the client with the persisted keys
do {
    let sharedKey = UserDefaults.standard.string(forKey: "FTSharedPublicKey")
    let privateKey = UserDefaults.standard.string(forKey: "FTUserPrivateKey")

    let client = try FreeToken.shared.configure(
        appToken: "your-api-key",
        baseURL: nil,
        sharedPublicEncryptionKey: sharedKey,
        userPrivateEncryptionKey: privateKey,
        logLevel: .info
    )
    // client is now configured with the built-in encryption keys
} catch {
    print("Failed to configure FreeToken: \(error)")
}
```

Built-in encryption details:

- Algorithm: AES-GCM (authenticated encryption).
- Key size: 256-bit symmetric keys (generated using CryptoKit's `SymmetricKey(size: .bits256)`).
- Format: Keys are returned as Base64-encoded bytes; pass the Base64 string to `configure(...)` via `sharedPublicEncryptionKey` and `userPrivateEncryptionKey` or call `setEncryptionKey(...)` internally.
- Scope usage: use `.sharedPublic` for public-document encryption (documents shared among agents) and `.userPrivate` for messages and private-document-store encryption.
- Security notes: The generated key string is only returned at creation time — persist it securely (Keychain). Do NOT store long-lived keys in plaintext or insecure stores like UserDefaults in production.

If you need a custom encryption implementation (for example to integrate with a proprietary KMS or hardware-backed keys), you can register encryption/decryption closures instead:

```swift
try FreeToken.shared.enableCustomEncryption(encrypt: { text, scope in
    // Your encryption logic here (e.g. call into your KMS)
    return "encryptedString"
}, decrypt: { text, scope in
    // Your decryption logic here
    return "decryptedString"
})
```

Note: When you enable custom encryption the SDK will call your closures for encrypt/decrypt operations. Use the custom hook if you must integrate external hardware or KMS; otherwise prefer the built-in AES-GCM keys for simplicity and compatibility.

---

### 8. Web Search

Perform web searches and retrieve results for use in AI or user-facing features.  This is the same method that is used by the AI to search the web for relevant information when generating responses.

```swift
await client.webSearch(
    query: "latest AI news",
    resultCount: 3,
    success: { results in
        for result in results {
            print("Web result: \(result.title) - \(result.url)")
        }
    },
    error: { error in
        print("Web search failed: \(error)")
    }
)
```

Note: You must setup the web search with an API key in the [FreeToken console](https://app.freetoken.ai) before using this feature.

---

### 9. Tool Definitions

Register custom tool definitions for function calling:

```swift
// Register multiple tool definitions at once
await client.registerToolDefinitions([toolDef1, toolDef2])

// Add a single tool definition from JSON
await client.addToolDefinition(
    name: "weather_tool",
    definitionJSON: "{\"description\": \"Get weather info\"}"
)

// Remove all tool definitions
await client.removeAllToolDefinitions()
```

---

### 10. Model and Cache Management

Reset caches and manage model storage. Model loading/unloading is now handled automatically by sessions (see section 4).

```swift
// Clear all model caches and persisted sessions
try await client.resetModelCaches()

// Clear only the embedding model cache
try await client.resetEmbeddingModelCache()

// Delete specific model cache
await client.deleteAIModelCache(modelCode: "model-name")

// Delete all model caches
await client.deleteAIModelCache()
```

**Note:** Model loading and unloading is now managed through session objects. Use `session.load()` and `session.unload()` on `ChatSession` or `CompletionSession` instances.

---

### 11. Stopping Local Generation

Stop any running local AI generation. Useful when your app goes into the background or you want to cancel a long-running operation.

```swift
await client.stopLocalGeneration()
```

---

### 12. Additional APIs

#### List Available AI Models

```swift
await client.listAIModels(
    success: { models in
        for model in models {
            print("Model: \(model.name) - \(model.code)")
        }
    },
    error: { error in
        print("Failed to list models: \(error)")
    }
)
```

#### Get AI Model Details

```swift
await client.getAIModel(
    modelCode: "model-code",
    success: { model in
        print("Model details: \(model.name)")
    },
    error: { error in
        print("Failed to get model: \(error)")
    }
)
```

#### Check if Model is Available for Device

Check if a specific AI model can run on the current device:

```swift
do {
    let isAvailable = try await client.isModelAvailableForDevice(modelCode: "llama-3.2-1b")
    if isAvailable {
        print("This device can run the model locally")
    } else {
        print("This model is not available for this device")
    }
} catch {
    print("Failed to check model availability: \(error)")
}

// Check default model availability
let defaultAvailable = try await client.isModelAvailableForDevice(modelCode: nil)
```

#### Get Available Models for Device

Get a list of all AI models that can run on the current device (includes both local models supported by this device and all cloud-only models):

```swift
do {
    let availableModels = try await client.availableAIModelsForDevice()
    for model in availableModels {
        if model.cloudOnly {
            print("Cloud model: \(model.name)")
        } else {
            print("Local model: \(model.name)")
        }
    }
} catch {
    print("Failed to get available models: \(error)")
}
```

#### Count Tokens

Use a chat session to count tokens:

```swift
let chatSession = try await client.getChatSession()
let tokenCount = try await chatSession.countTokens(for: "Your text to count tokens")
print("Token count: \(tokenCount)")
```

**Note:** Token counting is now performed through session objects for better model-specific accuracy.

#### Local Chat (Advanced)

For more control over local AI conversations:

```swift
await client.localChat(
    messages: [
        Message(role: .system, content: "You are a helpful assistant"),
        Message(role: .user, content: "Hello!")
    ],
    uniqueID: "chat-session-id",
    modelCode: "model-code",
    success: { response in
        print("AI response: \(response.content)")
    },
    error: { error in
        print("Chat failed: \(error)")
    }
)
```

---

## Learn more

Full developer guides, walkthroughs, and advanced integration patterns are available at https://docs.freetoken.ai.

---

## License

See [LICENSE.md](LICENSE.md).

