# FreeToken Swift Client

The FreeToken Swift client provides seamless AI integration for iOS/macOS apps, supporting both on-device and cloud AI, privacy mode, document search, and more.

---

## Features

- **On-device and Cloud AI**: Automatic fallback between local and cloud inference.
- **Privacy Mode**: End-to-end encryption for sensitive data. All data stored by FreeToken is encrypted by you with your own encryption keys and algorithms.
- **Document Indexing & Search**: Store and retrieve context for Retrieval-Augmented Generation (RAG).
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

Set up the FreeToken client with your API key.  
_Always call this before any other FreeToken operations._

```swift
import FreeToken

let client = FreeToken.shared.configure(
    appToken: "your-api-key"
)
```

---

### 2. Device Registration

Register the device with FreeToken Cloud to determine AI capabilities and enable secure communication.

```swift
client.registerDeviceSession(scope: "my-app-v1") {
    // Successfully registered
} error: { error in
    print("Failed to register device: \(error)")
}
```

_Note:_ The scope parameter can be used for testing message prompts through configuring the "agent routing" on the App in the FreeToken dashboard.  You may want to elect to create a unique scope by appending a letter or number to the end of the scope string, such as "my-app-v1-a". This would allow route all "a" clients to a different agent for A/B testing.

---

### 3. Download AI Model

Download the AI model for on-device inference.  
_If the device is not capable, FreeToken will automatically use cloud fallback for AI if the App is configured for Compatability mode on the FreeToken dashboard._

```swift
client.downloadAIModel { isModelDownloaded in
    // Ready for use whether on-device or cloud
    if isModelDownloaded {
        // Device supports on-device AI
    } else {
        // Fallback to cloud/compatibility mode if supported
    }
} error: { error in
    print("Download failed: \(error)")
} progressPercent: { progress in
    print("Download progress: \(progress)%")
}
```

Note: The `isModelDownloaded` boolean indicates whether the model was successfully downloaded and is ready for use on-device. If false, the app will use cloud AI if configured for Compatability mode. _This is a heads-up to your app whether it's capable of on-device AI or not._

---

### 4. Message Threading

Create, manage, and interact with threaded conversations for chat or context-based AI.

#### Create a Thread

```swift
client.createMessageThread(
    pinnedContext: "Initial context",
    agentScope: "agent-scope"
) { messageThread in
    // Save messageThread.id for future use
} error: { error in
    print("Failed to create thread: \(error)")
}
```

Note: Make sure to save the the `messageThread.id` for future operations like adding messages or running the thread.  This will be the *ONLY* time you are provided this ID, so store it securely in your app's state or database.

#### Add a Message

```swift
let message = Message(role: .user, content: "What is a nova?")

await client.addMessageToThread(
    messageThreadID: "thread-id",
    message: message,
    success: { message in
        print("Message added: \(message.content)")
    },
    error: { error in
        print("Failed to add message: \(error)")
    }
)
```

#### Run a Thread (Automatic Local/Cloud Selection)

`runMessageThread` will automatically use the best available AI (local or cloud) based on your configuration and device capabilities.

```swift
await client.runMessageThread(
    id: "thread-id",
    success: { response in
        print("AI response: \(response.resultMessage.content)")
    },
    error: { error in
        print("Failed to run thread: \(error)")
    }
)
```
Note: If you configure *Compatability mode with Turbo mode*, the client will automatically use the cloud until the model is downloaded and ready for on-device use. This provides a better user experience allowing immediate interaction with the AI while still preparing for on-device capabilities.

Additionally, there are _many_ additional options to message threads, such as _forcing a cloud run_, _streaming tokens_ back to your app, _scoping RAG document searches_, and more. 

#### Delete, Get, and Inspect Threads

Basic thread management operations allow you to delete threads, retrieve threads with messages, and fetch individual messages.

```swift
client.deleteMessageThread(id: "thread-id", success: { id in
    print("Deleted thread: \(id)")
}, error: { error in
    print("Failed to delete thread: \(error)")
})

client.getMessageThread(id: "thread-id", success: { thread in
    print("Loaded thread with \(thread.messages.count) messages")
}, error: { error in
    print("Failed to load thread: \(error)")
})

client.getMessage(id: "message-id", success: { message in
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

Note: You can pass a `modelCode` to specify what particular model to use, if it's not currently available on the device, it will automatically push the request to the cloud. This is useful when you need a larger model or specialized model for specific tasks.  Model codes are available in the FreeToken dashboard under the "Models" section.

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

#### Chat Completion

This method does not require a message thread and can be used for simple chat interactions. This is the underlying method used by `runMessageThread` for cloud chat completion.

```swift
let messages = [
    Message(role: .user, content: "Hello!")
]

client.generateCloudChatCompletion(
    messages: messages,
    modelCode: "cloud-model-code",
    success: { message in
        print("Chat AI: \(message.content)")
    },
    error: { error in
        print("Chat completion failed: \(error)")
    }
)
```

---

### 6. Document Management

Store, retrieve, and search documents for use as AI context (RAG, knowledge base, etc.).

#### Create a Document

```swift
client.createDocument(
    content: "Document content",
    metadata: "{\"title\": \"Example Document\", \"author\": \"John Doe\"}",
    searchScope: "knowledge-base",
    success: { document in
        print("Document created: \(document.id)")
    },
    error: { error in
        print("Failed to create document: \(error)")
    }
)
```

Note: The document data should be considered _public_ to all agents in the App context and immutable. 

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
client.searchDocuments(
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

### 7. Privacy Mode

Enable encryption/decryption for privacy-sensitive data.

```swift
try client.privacyModeEncryption(
    encrypt: { text in
        // Your encryption logic here
        return encryptedText
    },
    decrypt: { text in
        // Your decryption logic here
        return decryptedText
    }
)
```

Note: In Privacy mode, you _MUST_ define your own encryption and decryption logic before running the client.

---

### 8. Web Search

Perform web searches and retrieve results for use in AI or user-facing features.  This is the same method that is used by the AI to search the web for relevant information when generating completions or responses.

```swift
client.webSearch(
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

Note: You must setup the web search with an API key in the FreeToken dashboard before using this feature.

---

### 9. Model and Cache Management

Reset caches or manage model memory.

```swift
try client.resetAIModelCache() // Clears local AI model cache
try client.resetEmbeddingModelCache() // Clears embedding model cache

client.loadModel(success: {
    print("Model loaded")
}, error: { error in
    print("Failed to load model: \(error)")
})
```

---

### 10. Stopping Local Generation

Stop any running local AI generation. Useful when your app goes into the background or you want to cancel a long-running operation.

```swift
await client.stopLocalGeneration()
```

---

## License

See [LICENSE.md](LICENSE.md).

