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

### 4. Message Threading

Create, manage, and interact with threaded conversations for chat or context-based AI.

#### Create a Thread

```swift
await client.createMessageThread { messageThread in
    // Save messageThread.id for future use
    // Persist the ID as this is the only time the server returns it
} error: { error in
    print("Failed to create thread: \(error)")
}
```

Note: Make sure to save the `messageThread.id` for future operations like adding messages or running the thread. This will be the *ONLY* time you are provided this ID, so store it securely in your app's state or database.

#### Add a Message to a Message Thread

```swift
let message = Message(role: .user, content: "What is a supernova?")

await client.addMessageToThread(
    id: "thread-id",
    message: message,
    success: { message in
        print("Message added: \(message.content)")
    },
    error: { error in
        print("Failed to add message: \(error)")
    }
)
```

#### Run a Message Thread

`runMessageThread` will automatically use the best available AI (local or cloud) based on your configuration and device capabilities.  You can optionally override this by specifying `runLocation: .cloudRun` or `.localRun` as a parameter to this method.

```swift
await client.runMessageThread(
    id: "thread-id",
    success: { response in
        print("AI response: \(response.content)")
    },
    error: { error in
        print("Failed to run thread: \(error)")
    }
)
```

#### Run a Message Thread with Status Updates

You can monitor the progress of message thread execution using the `chatStatusStream` callback:

```swift
await client.runMessageThread(
    id: "thread-id",
    chatStatusStream: { token, status in
        switch status {
        case .starting:
            print("Starting AI operation...")
        case .sending_to_local_ai:
            print("Sending to local AI...")
        case .sending_to_cloud_ai:
            print("Sending to cloud AI...")
        case .streaming_tokens:
            if let token = token {
                print(token, terminator: "")
            }
        case .evaluating_tool_calls:
            print("Evaluating tool calls...")
        case .new_message_created:
            print("New message saved to thread")
        case .stream_ended:
            print("\nStream completed")
        case .failed:
            print("Operation failed")
        }
    },
    success: { response in
        print("\nFinal response: \(response.content)")
    },
    error: { error in
        print("Failed: \(error)")
    }
)
```

Available status cases:
- `.starting` - Initial status when the operation begins
- `.sending_to_local_ai` - Request is being sent to local on-device AI
- `.sending_to_cloud_ai` - Request is being sent to cloud AI  
- `.streaming_tokens` - AI is actively streaming response tokens (includes token parameter)
- `.evaluating_tool_calls` - AI is evaluating function/tool calls
- `.new_message_created` - A new message (AI response or tool result) has been saved to the thread
- `.stream_ended` - The response stream has completed successfully
- `.failed` - The operation has failed

#### Delete, Get, and Inspect Threads

Basic thread management operations allow you to delete threads, retrieve threads with messages, and fetch individual messages.

```swift
client.deleteMessageThread(id: "thread-id", success: { id in
    print("Deleted thread: \(id)")
}, error: { error in
    print("Failed to delete thread: \(error)")
})

await client.getMessageThread(id: "thread-id", success: { thread in
    print("Loaded thread with \(thread.messages.count) messages")
}, error: { error in
    print("Failed to load thread: \(error)")
})

await client.getMessage(id: "message-id", success: { message in
    print("Message: \(message.content)")
}, error: { error in
    print("Failed to get message: \(error)")
})
```

---

### 5. AI Completions

Generate text completions using local or cloud AI.  
`generateCompletion` will automatically select the best execution path based on device capability and configuration.

#### General Completion (Auto Local/Cloud)

```swift
await client.generateCompletion(
    prompt: "What is a nova?",
    success: { completion in
        print("AI says: \(completion.completion)")
    },
    error: { error in
        print("Completion failed: \(error)")
    }
)
```

#### Force Cloud or Local Completion

```swift
client.generateCloudCompletion(
    prompt: "Tell me a joke.",
    modelCode: "large-model",
    maxTokens: 50,
    success: { completion in
        print("Cloud AI: \(completion.completion)")
    },
    error: { error in
        print("Cloud completion failed: \(error)")
    }
)

await client.generateLocalCompletion(
    prompt: "Summarize: The sun is a star.",
    maxTokens: 20,
    success: { completion in
        print("Local AI: \(completion.completion)")
    },
    error: { error in
        print("Local completion failed: \(error)")
    }
)
```


---

### 6. Document Management

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

### 7. Private Document Stores

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

### 8. Encryption

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

### 9. Web Search

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

### 10. Tool Definitions

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

### 11. Model and Cache Management

Reset caches or manage model memory.

```swift
try await client.resetModelCaches() // Clears local AI model & embedding caches and removes persisted sessions

try await client.resetEmbeddingModelCache() // Clears only the embedding model cache

await client.deleteAIModelCache(modelCode: "model-name") // Delete specific model cache
await client.deleteAIModelCache() // Delete all model caches

await client.loadModel(
    modelCode: "model-name",
    success: { loaded in
        print("Model load state: \(loaded)")
    },
    error: { error in
        print("Failed to load model: \(error)")
    }
)

await client.unloadModel(modelCode: "model-name") // Unload a specific model from memory
```

---

### 12. Stopping Local Generation

Stop any running local AI generation. Useful when your app goes into the background or you want to cancel a long-running operation.

```swift
await client.stopLocalGeneration()
```

---

### 13. Additional APIs

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

```swift
do {
    let tokenCount = try await client.countTokens(
        text: "Your text to count tokens",
        modelCode: "model-code" // optional
    )
    print("Token count: \(tokenCount)")
} catch {
    print("Failed to count tokens: \(error)")
}
```

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

