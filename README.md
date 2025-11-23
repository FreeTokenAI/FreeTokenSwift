![FreeToken header](./github-header.png)

The FreeToken Swift SDK provides seamless AI integration for iOS/macOS apps, supporting both on-device and cloud AI with automatic routing, document search (RAG), and more.

For complete documentation, visit: https://docs.freetoken.ai

---

## Features

- **Hybrid AI**: Automatic routing between on-device and cloud inference
- **Session-Based API**: Modern session management with automatic memory handling
- **Message Threading**: Persistent conversations synced to the cloud
- **RAG (Document Search)**: Built-in document indexing and retrieval
- **Tool/Function Calling**: Let AI call your app's functions
- **Vision Support**: Multi-modal AI with image understanding
- **Client-Side Encryption**: Optional encryption for sensitive data
- **Streaming**: Real-time token streaming and progress callbacks

---

## Requirements

- iOS 17+ or macOS 15+
- Swift Package Manager

---

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/FreeTokenAI/FreeTokenSwift.git", from: "1.0.0")
]
```

---

## Quick Start

### 1. Configuration

```swift
import FreeToken

try FreeToken.shared.configure(appToken: "your-api-key")
```

Get your API key from the [FreeToken Console](https://console.freetoken.ai).

---

### 2. Device Registration

```swift
await FreeToken.shared.registerDeviceSession(scope: "my-app-v1") {
    print("Device registered")
} error: { error in
    print("Registration failed: \(error)")
}
```

This determines device AI capabilities and initializes models.

---

### 3. Download AI Model

```swift
await FreeToken.shared.downloadAIModel(
    success: { state in
        switch state {
        case .downloaded:
            print("Model ready for local AI")
        case .aiNotSupported:
            print("Device will use cloud AI")
        }
    },
    error: { error in
        print("Download failed: \(error)")
    },
    progressPercent: { progress in
        print("Progress: \(Int(progress * 100))%")
    }
)
```

---

## Usage Examples

### Chat Session (Recommended)

The session-based API provides the best experience with automatic resource management:

```swift
// Get a chat session
let session = try await FreeToken.shared.getChatSession()

// Create a thread for the conversation
let thread = try await session.createMessageThread()
print("Thread ID: \(thread.id)")  // Save this for later

// Add a user message
let userMsg = FreeToken.Message(role: .user, content: "What is quantum computing?")
try await session.addMessage(message: userMsg)

// Generate AI response with streaming
let response = try await session.generateNewMessage(
    chatStatusStream: { token, status in
        if let token = token {
            print(token, terminator: "")  // Stream tokens as they arrive
        }
    }
)

print("\n\nComplete response: \(response.content)")

// Unload model when done (important for memory management)
await session.unload()
```

---

### Completion Session (Stateless)

For simple text generation without persistent threads:

```swift
let session = try await FreeToken.shared.getCompletionSession()

let completion = try await session.generateCompletion(
    from: "Write a haiku about coding",
    chatStatusStream: { token, _ in
        if let token = token {
            print(token, terminator: "")
        }
    }
)

print("\n\nTokens used: \(completion.tokenUsage?.totalTokens ?? 0)")
await session.unload()
```

---

### Chat with Document Search (RAG)

Integrate document retrieval into AI responses:

```swift
// First, create and index documents
await FreeToken.shared.createDocument(
    content: "Your documentation content here...",
    metadata: "category: manual",
    searchScope: "product-docs",
    success: { doc in
        print("Document created: \(doc.id)")
    },
    error: { _ in }
)

// Use documents in chat
let session = try await FreeToken.shared.getChatSession()
let thread = try await session.createMessageThread()

let userMsg = FreeToken.Message(role: .user, content: "How do I install the product?")
try await session.addMessage(message: userMsg)

// AI will search documents and use them for context
let response = try await session.generateNewMessage(
    documentSearchScope: "product-docs"
)

print("AI response with context: \(response.content)")
```

---

### Tool/Function Calling

Let AI call your app's functions:

```swift
// 1. Register a tool definition
let weatherTool = """
{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
            "type": "object",
            "properties": {
                "location": {
                    "type": "string",
                    "description": "City name"
                }
            },
            "required": ["location"]
        }
    }
}
"""

await FreeToken.shared.addToolDefinition(
    name: "get_weather",
    definitionJSON: weatherTool
)

// 2. Handle tool calls during generation
let session = try await FreeToken.shared.getChatSession()
let thread = try await session.createMessageThread()

let userMsg = FreeToken.Message(role: .user, content: "What's the weather in San Francisco?")
try await session.addMessage(message: userMsg)

let response = try await session.generateNewMessage(
    toolUseHandler: { toolCalls in
        var results: [String] = []
        for call in toolCalls {
            if call.name == "get_weather" {
                let location = call.arguments["location"] ?? "Unknown"
                // Call your actual weather API here
                results.append("Temperature in \(location): 72°F, sunny")
            }
        }
        return results.joined(separator: "\n")
    }
)

print("AI: \(response.content)")
```

---

### Vision (Image Understanding)

Send images to vision-capable models:

```swift
let session = try await FreeToken.shared.getChatSession()
let thread = try await session.createMessageThread()

// Prepare image
let image = UIImage(named: "photo")!
let imageData = image.pngData()!
let attachment = FreeToken.MessageAttachment.image(imageData, filename: "photo.png")

// Send message with image
let message = FreeToken.Message(
    role: .user,
    content: "What's in this image?",
    attachments: [attachment]
)
try await session.addMessage(message: message)

// Get AI analysis
let response = try await session.generateNewMessage()
print("AI: \(response.content)")
```

**Note:** Vision requires cloud models. Configure a vision-capable model in the console.

---

### Managing Message Threads Directly

You can also manage threads without sessions:

```swift
// Create thread
await FreeToken.shared.createMessageThread { thread in
    print("Thread ID: \(thread.id)")
} error: { _ in }

// Add message
let msg = FreeToken.Message(role: .user, content: "Hello!")
await FreeToken.shared.addMessageToThread(id: threadId, message: msg) { _ in
    print("Message added")
} error: { _ in }

// Get thread with messages
await FreeToken.shared.getMessageThread(id: threadId) { thread in
    print("Messages: \(thread.messages.count)")
} error: { _ in }

// Delete thread
FreeToken.shared.deleteMessageThread(id: threadId) { _ in
    print("Deleted")
} error: { _ in }
```

---

## Advanced Features

### Encryption

Enable client-side encryption for messages and documents:

```swift
// Generate encryption keys (only returned once!)
let userKey = FreeToken.shared.enableEncryption(scope: .userPrivate)
let publicKey = FreeToken.shared.enableEncryption(scope: .sharedPublic)

// Store keys securely (Keychain recommended)

// Configure with encryption
try FreeToken.shared.configure(
    appToken: "your-api-key",
    sharedPublicEncryptionKey: publicKey,
    userPrivateEncryptionKey: userKey
)
```

---

### Model Management

```swift
// List available models
let models = try await FreeToken.shared.listAIModels()
for model in models {
    print("\(model.code): \(model.name)")
    print("  Cloud only: \(model.cloudOnly)")
}

// Check device compatibility
let isAvailable = try await FreeToken.shared.isModelAvailableForDevice(
    modelCode: "llama-3.2-1b"
)

// Download specific model
await FreeToken.shared.downloadAIModel(
    modelCode: "gemma3n_e2b_it",
    success: { _ in },
    error: { _ in }
)

// Use specific model in session
let session = try await FreeToken.shared.getChatSession(
    modelCode: "gemma3n_e2b_it"
)
```

---

### Run Location Control

Control whether to use local or cloud AI:

```swift
// Automatic (preferred local, cloud fallback)
let session = try await FreeToken.shared.getChatSession(
    runLocation: .automatic
)

// Force cloud
let cloudSession = try await FreeToken.shared.getChatSession(
    runLocation: .cloudRun
)

// Force local
let localSession = try await FreeToken.shared.getChatSession(
    runLocation: .localRun
)
```

---

### Tool Access Control

Control which tools AI can use:

```swift
// Allow all tools
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.allowAll]
)

// Allow only specific tools
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.allowSpecific(["get_weather", "search_docs"])]
)

// Deny specific tools
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.denySpecific(["dangerous_tool"])]
)
```

---

### Web Search

Perform web searches (requires console configuration):

```swift
await FreeToken.shared.webSearch(
    query: "latest AI news",
    resultCount: 5,
    success: { results in
        for result in results {
            print("\(result.title)")
            print("\(result.url ?? "")")
        }
    },
    error: { _ in }
)
```

---

## Best Practices

1. **Use Sessions**: Prefer `getChatSession()` and `getCompletionSession()` for better resource management
2. **Unload Models**: Call `session.unload()` when done, especially on iOS devices
3. **Save Thread IDs**: Thread IDs are only returned once - save them for future use
4. **Automatic Fallback**: Use `runLocation: .automatic` for the best user experience
5. **Monitor Streaming**: Use `chatStatusStream` to show progress to users
6. **Secure Encryption Keys**: Store keys in Keychain, never in UserDefaults

---

## Data Structures

### Message
```swift
FreeToken.Message(
    role: .user,           // .user, .assistant, .system, .tool
    content: "Hello!",
    attachments: nil       // Optional: [MessageAttachment]
)
```

### MessageThread
```swift
public class MessageThread {
    let id: String
    let messages: [Message]
    let createdAt: Date
    let updatedAt: Date
}
```

### ChatStreamStatus
Stream status updates during generation:
- `.starting` - Beginning
- `.sending_to_local_ai` - Using local AI
- `.sending_to_cloud_ai` - Using cloud AI
- `.streaming_tokens` - Receiving tokens
- `.cloud_fallback` - Falling back to cloud
- `.stream_ended` - Complete

---

## Error Handling

Common errors:

- `.clientNotConfigured` - Call `configure()` first
- `.deviceNotRegistered` - Call `registerDeviceSession()` first
- `.aiModelNotDownloaded` - Download model first
- `.messageThreadNotCreated` - Call `createMessageThread()` first
- `.deviceNotCapable` - Device cannot run model locally
- `.generationCancelled` - User cancelled generation

---

## Testing

```bash
# Run all tests
swift test

# Run specific test
swift test --filter testChatSession

# Build only
swift build
```

---

## Resources

- **Documentation**: [docs.freetoken.ai](https://docs.freetoken.ai)
- **Console**: [console.freetoken.ai](https://console.freetoken.ai)
- **GitHub**: [github.com/FreeTokenAI/FreeTokenSwift](https://github.com/FreeTokenAI/FreeTokenSwift)
- **Support**: support@freetoken.ai

---

## License

See [LICENSE](LICENSE) for details.
