# FreeToken Swift SDK - AI Assistant Guide

This guide helps AI assistants (like Claude Code) integrate FreeToken into Swift projects. FreeToken provides hybrid AI capabilities with both on-device and cloud inference, document search (RAG), message threading, and function calling.

## Requirements

- **iOS 17+** or **macOS 15+** (also supports watchOS 11+, tvOS 18+, visionOS 2+)
- **Swift Package Manager**
- **FreeToken API Key** from [console.freetoken.ai](https://console.freetoken.ai)

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/FreeTokenAI/FreeTokenSwift.git", from: "1.0.0")
]
```

## Core Concepts

- **Hybrid AI**: Automatically routes requests between on-device and cloud AI based on device capabilities
- **Session-Based API**: Modern session management for chat and completion workflows with automatic memory management
- **Message Threads**: Persistent conversation threads stored in the cloud with local caching
- **RAG (Retrieval Augmented Generation)**: Document search integrated into AI responses
- **Tool Calling**: AI can call functions in your app to retrieve context or perform actions
- **Encryption**: Optional client-side encryption for messages and documents

## Quick Start

### 1. Configuration

```swift
import FreeToken

// Basic configuration
try FreeToken.shared.configure(appToken: "your-api-key")

// With encryption (optional)
try FreeToken.shared.configure(
    appToken: "your-api-key",
    sharedPublicEncryptionKey: "public-key",  // For public documents
    userPrivateEncryptionKey: "private-key",  // For messages & private docs
    logLevel: .info
)
```

### 2. Device Registration

Required before using AI features. Determines device capabilities and initializes models.

```swift
await FreeToken.shared.registerDeviceSession(
    scope: "my-app-v1",
    success: {
        print("Device registered successfully")
    },
    error: { error in
        print("Registration failed: \(error)")
    }
)
```

### 3. Download AI Model

```swift
await FreeToken.shared.downloadAIModel(
    modelCode: nil,  // Use default model
    success: { state in
        switch state {
        case .downloaded:
            print("Model ready for local inference")
        case .aiNotSupported:
            print("Device not capable - will use cloud")
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

## API Reference

### Session-Based Chat API

The session-based API provides better resource management, preloading, and stateful conversation handling.

#### Get Chat Session

Creates a new chat session with automatic local/cloud routing:

```swift
// Automatic routing (local preferred, cloud fallback)
let session = try await FreeToken.shared.getChatSession()

// Force cloud-only
let cloudSession = try await FreeToken.shared.getChatSession(
    runLocation: .cloudRun
)

// Force local-only
let localSession = try await FreeToken.shared.getChatSession(
    runLocation: .localRun
)

// With existing message thread
let session = try await FreeToken.shared.getChatSession(
    messageThreadID: "thread-id"
)

// With specific model
let session = try await FreeToken.shared.getChatSession(
    modelCode: "llama-3.2-1b"
)

// With tool access control
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.allowSpecific(["get_weather", "search_docs"])]
)
```

**Important:** `getChatSession()` automatically determines whether to use local or cloud execution based on:
- Model download status
- Device capabilities
- Available memory
- `runLocation` parameter

#### Create Message Thread

```swift
// Create a new thread for the session
let thread = try await session.createMessageThread()
print("Thread ID: \(thread.id)")  // Save this ID for future use
```

**Note:** Each chat session can only have one thread. Create new sessions for new conversations.

#### Add Message

```swift
// Add user message
let userMsg = FreeToken.Message(role: .user, content: "What is quantum computing?")
let addedMsg = try await session.addMessage(message: userMsg)
```

#### Generate AI Response

```swift
// Simple generation
let response = try await session.generateNewMessage()
print("AI: \(response.content)")

// With streaming
let response = try await session.generateNewMessage(
    chatStatusStream: { token, status in
        if let token = token {
            print(token, terminator: "")
        }

        switch status {
        case .starting:
            print("[Starting]")
        case .streaming_tokens:
            break  // Printing tokens above
        case .stream_ended:
            print("\n[Complete]")
        case .cloud_fallback:
            print("[Falling back to cloud]")
        default:
            print("[\(status.rawValue)]")
        }
    }
)

// With document search (RAG)
let response = try await session.generateNewMessage(
    documentSearchScope: "product-docs",
    privateDocumentStoreIDs: ["store-id-1"]
)

// With tool/function calling
let response = try await session.generateNewMessage(
    toolUseHandler: { toolCalls in
        var results: [String] = []
        for call in toolCalls {
            if call.name == "get_weather" {
                let location = call.arguments["location"] ?? "Unknown"
                results.append("Weather in \(location): 72°F, sunny")
            }
        }
        return results.joined(separator: "\n")
    }
)
```

**ChatStreamStatus Values:**
- `.starting` - Operation beginning
- `.sending_to_local_ai` - Using local AI
- `.sending_to_cloud_ai` - Using cloud AI
- `.streaming_tokens` - Receiving response tokens
- `.evaluating_tool_calls` - Processing tool calls
- `.new_message_created` - Message saved
- `.cloud_fallback` - Local failed, trying cloud
- `.stream_ended` - Complete
- `.failed` - Operation failed

**Cancellation:** Throw an error in `chatStatusStream` to cancel generation:

```swift
let response = try await session.generateNewMessage(
    chatStatusStream: { token, status in
        if shouldCancel {
            throw CancellationError()
        }
    }
)
```

#### Get Messages

```swift
let messages = try await session.getMessages()
for msg in messages {
    print("\(msg.role.rawValue): \(msg.content)")
}
```

#### Count Tokens

```swift
let tokenCount = try await session.countTokens(for: "Some text")
print("Tokens: \(tokenCount)")
```

**Note:** Token counting only works with local sessions. Cloud sessions will throw an error.

#### Memory Management

```swift
// Unload model from memory
await session.unload()

// Reload model
try await session.load()
```

**Best Practice:** Call `unload()` when done with a session to free memory, especially on iOS devices.

---

### Session-Based Completion API

For stateless text generation without persistent threads.

#### Get Completion Session

```swift
// Automatic routing
let session = try await FreeToken.shared.getCompletionSession()

// Force cloud
let cloudSession = try await FreeToken.shared.getCompletionSession(
    runLocation: .cloudRun
)

// With specific model
let session = try await FreeToken.shared.getCompletionSession(
    modelCode: "llama-3.2-1b"
)
```

#### Generate Completion

```swift
// Simple completion
let completion = try await session.generateCompletion(
    from: "Write a poem about coding"
)
print("Response: \(completion.response)")
print("Tokens used: \(completion.tokenUsage?.totalTokens ?? 0)")

// With streaming
let completion = try await session.generateCompletion(
    from: "Explain quantum physics",
    chatStatusStream: { token, status in
        if let token = token {
            print(token, terminator: "")
        }
    }
)

// Don't forget to unload when done
await session.unload()
```

---

### In-Memory Chat Session (Local Only)

For temporary conversations without cloud persistence.

```swift
let session = try await FreeToken.shared.getMemoryChatSession(
    modelCode: nil,  // Use default model
    runLocation: .automatic,
    toolAccess: [.allowAll],
    messages: [],  // Optional: pre-populate with messages
    systemInstructions: "You are a helpful assistant",
    runID: UUID().uuidString  // Optional: custom run ID
)

// Add message (stored in memory only)
let userMsg = FreeToken.Message(role: .user, content: "Hello!")
try await session.addMessage(message: userMsg)

// Generate response
let response = try await session.generateNewMessage()
print("AI: \(response.content)")

// Messages are NOT persisted to cloud
```

**Important:**
- Cannot call `createMessageThread()` on memory sessions
- Messages only exist in memory
- Use for temporary/privacy-sensitive conversations

---

### Legacy Message Thread API (Direct)

Direct message thread operations without sessions. Still supported but sessions are preferred.

#### Create Thread

```swift
await FreeToken.shared.createMessageThread(
    toolAccess: [.allowAll],
    success: { thread in
        print("Thread ID: \(thread.id)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Add Message to Thread

```swift
let message = FreeToken.Message(role: .user, content: "Hello!")
await FreeToken.shared.addMessageToThread(
    id: threadId,
    message: message,
    success: { message in
        print("Message added: \(message.id)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Get Thread

```swift
await FreeToken.shared.getMessageThread(
    id: threadId,
    success: { thread in
        print("Messages: \(thread.messages.count)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Delete Thread

```swift
FreeToken.shared.deleteMessageThread(
    id: threadId,
    success: { id in
        print("Deleted: \(id)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

---

### Model Management

#### List Available Models

```swift
let models = try await FreeToken.shared.listAIModels()
for model in models {
    print("\(model.code): \(model.name)")
    print("  Platform: \(model.platform)")
    print("  Vision: \(model.capabilities.imageToText)")
    print("  Cloud only: \(model.cloudOnly)")
}
```

#### Get Model Details

```swift
let model = try await FreeToken.shared.getAIModel(modelCode: "llama-3.2-1b")
print("Model: \(model.name)")
print("Memory required: \(model.memoryRequirement) bytes")
```

#### Check Device Compatibility

```swift
// Check specific model
let isAvailable = try await FreeToken.shared.isModelAvailableForDevice(
    modelCode: "llama-3.2-1b"
)

// Get all compatible models
let availableModels = try await FreeToken.shared.availableAIModelsForDevice()
for model in availableModels {
    print("Can run: \(model.name)")
}
```

#### Check Download State

```swift
let state = try await FreeToken.shared.getAIModelDownloadState(
    modelCode: "llama-3.2-1b"
)

switch state {
case .notDownloaded:
    print("Not downloaded")
case .downloading(let progress):
    print("Downloading: \(progress)%")
case .downloaded:
    print("Ready")
case .failed(let error):
    print("Failed: \(error)")
}
```

#### Delete Model Cache

```swift
// Delete specific model
await FreeToken.shared.deleteAIModelCache(modelCode: "llama-3.2-1b")

// Delete all models
await FreeToken.shared.deleteAIModelCache()
```

---

### Document Management (RAG)

#### Create Private Document Store

```swift
await FreeToken.shared.createPrivateDocumentStore(
    name: "User Personal Docs",
    success: { store in
        print("Store ID: \(store.id)")
        // Save store.id securely
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Create Document

```swift
// Public document
await FreeToken.shared.createDocument(
    content: "Document content...",
    metadata: "category: manual",
    searchScope: "product-docs",
    success: { document in
        print("Document created: \(document.id)")
    },
    error: { error in
        print("Error: \(error)")
    }
)

// Private document
await FreeToken.shared.createDocument(
    content: "Private notes...",
    metadata: "author: User",
    searchScope: "user-notes",
    privateDocumentStoreID: "store-id",
    success: { document in
        print("Private document created")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Search Documents

```swift
await FreeToken.shared.searchDocuments(
    query: "installation instructions",
    searchScope: "product-docs",
    privateDocumentStoreIds: ["store-id-1"],
    maxResults: 10,
    success: { results in
        print("Found \(results.documentChunks.count) chunks")
        for chunk in results.documentChunks {
            print("Document: \(chunk.documentID)")
            print("Content: \(chunk.contentChunk)")
        }
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Get Document

```swift
await FreeToken.shared.getDocument(
    id: "doc-id",
    success: { document in
        print("Content: \(document.content)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Delete Private Document Store

```swift
await FreeToken.shared.deletePrivateDocumentStore(
    id: "store-id",
    success: {
        print("Store deleted")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

---

### Tool/Function Calling

#### Register Tool Definition

```swift
let weatherTool = """
{
    "type": "function",
    "function": {
        "name": "get_current_weather",
        "description": "Get the current weather for a location",
        "parameters": {
            "type": "object",
            "properties": {
                "location": {
                    "type": "string",
                    "description": "City and country, e.g. San Francisco, CA"
                },
                "format": {
                    "type": "string",
                    "enum": ["celsius", "fahrenheit"]
                }
            },
            "required": ["location", "format"]
        }
    }
}
"""

await FreeToken.shared.addToolDefinition(
    name: "get_current_weather",
    definitionJSON: weatherTool
)
```

#### Handle Tool Calls

```swift
let response = try await session.generateNewMessage(
    toolUseHandler: { toolCalls in
        var results: [String] = []

        for call in toolCalls {
            if call.name == "get_current_weather" {
                let location = call.arguments["location"] ?? "Unknown"
                let format = call.arguments["format"] ?? "celsius"

                // Call your weather API
                let weather = getWeather(location: location, format: format)
                results.append("Temperature in \(location): \(weather)")
            }
        }

        return results.joined(separator: "\n\n")
    }
)
```

#### Tool Access Control

```swift
// Allow all tools
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.allowAll]
)

// Deny all tools
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.denyAll]
)

// Allow specific tools
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.allowSpecific(["get_weather", "search_docs"])]
)

// Deny specific tools
let session = try await FreeToken.shared.getChatSession(
    toolAccess: [.denySpecific(["dangerous_tool"])]
)
```

#### Remove All Tools

```swift
await FreeToken.shared.removeAllToolDefinitions()
```

---

### Vision Support (Multi-Modal)

Send images to vision-capable AI models.

```swift
// 1. Prepare image
let image = UIImage(named: "photo")!
let imageData = image.pngData()!
let attachment = FreeToken.MessageAttachment.image(
    imageData,
    filename: "photo.png",
    contentType: "image/png"
)

// 2. Create message with image
let message = FreeToken.Message(
    role: .user,
    content: "What's in this image?",
    attachments: [attachment]
)

// 3. Add to thread
try await session.addMessage(message: message)

// 4. Generate response with vision model
let response = try await session.generateNewMessage()
print("AI analysis: \(response.content)")
```

**Multiple Images:**

```swift
let attachment1 = FreeToken.MessageAttachment.image(image1Data, filename: "photo1.png")
let attachment2 = FreeToken.MessageAttachment.image(image2Data, filename: "photo2.png")

let message = FreeToken.Message(
    role: .user,
    content: "Compare these images",
    attachments: [attachment1, attachment2]
)
```

**Note:** Vision requires cloud models. The default model must support vision, or you need to specify a vision-capable model like `"llama_4_scout_cloud"`.

---

### Encryption

Client-side encryption for messages and documents.

#### Generate Encryption Keys

```swift
// Generate keys (only returned once - store securely!)
let userPrivateKey = FreeToken.shared.enableEncryption(scope: .userPrivate)
let publicKey = FreeToken.shared.enableEncryption(scope: .sharedPublic)

// Store in Keychain or secure storage
// WARNING: Keys are only returned once!
```

#### Configure with Encryption

```swift
try FreeToken.shared.configure(
    appToken: "your-api-key",
    sharedPublicEncryptionKey: publicKey,
    userPrivateEncryptionKey: userPrivateKey
)
```

#### Custom Encryption

```swift
try FreeToken.shared.enableCustomEncryption(
    encrypt: { text, scope in
        // Your encryption logic
        return encryptedText
    },
    decrypt: { text, scope in
        // Your decryption logic
        return decryptedText
    }
)
```

**Encryption Scopes:**
- `.sharedPublic`: For public documents
- `.userPrivate`: For messages and private documents

**What's Encrypted:**
- Messages (user private key)
- Private documents (user private key)
- Public documents (shared public key)

**Not Encrypted:**
- Web search queries
- Cloud AI requests
- Telemetry

---

### Web Search

```swift
await FreeToken.shared.webSearch(
    query: "latest AI news",
    resultCount: 5,
    success: { results in
        for result in results {
            print("\(result.title)")
            print("\(result.url ?? "")")
            print("\(result.snippet)")
        }
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

**Note:** Must configure web search in console with API key.

---

### Utilities

#### Reset & Cleanup

```swift
// Reset device registration
try await FreeToken.shared.resetDevice()

// Clear chat session caches
try await FreeToken.shared.resetChatCache()

// Reset all model caches
try await FreeToken.shared.resetModelCaches()

// Reset embedding model cache
try await FreeToken.shared.resetEmbeddingModelCache()
```

---

## Data Structures

### Message

```swift
public class Message {
    let id: String?
    let role: MessageRole  // .system, .user, .assistant, .tool
    let content: String
    let attachments: [MessageAttachment]?
    let createdAt: Date?
    var tokenUsage: TokenUsage?

    init(role: MessageRole, content: String, attachments: [MessageAttachment]? = nil)
}
```

### MessageRole

```swift
public enum MessageRole: String {
    case user
    case assistant
    case system
    case tool
}
```

### MessageAttachment

```swift
public class MessageAttachment {
    let id: String?
    let type: AttachmentType  // .image
    let data: Data
    let filename: String?
    let contentType: String

    static func image(_ imageData: Data, filename: String? = nil, contentType: String = "image/png") -> MessageAttachment
}
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

### Completion

```swift
public class Completion {
    let response: String
    let tokenUsage: TokenUsage?
}
```

### TokenUsage

```swift
public struct TokenUsage {
    let totalTokens: Int
    let tokensPerSecond: Float
    let inputTokens: Int
    let outputTokens: Int
    let modelCode: String
}
```

### ToolCall

```swift
struct ToolCall {
    let name: String
    let arguments: [String: String]
}
```

### ToolRunMask

```swift
public enum ToolRunMask {
    case allowAll
    case denyAll
    case allowSpecific([String])
    case denySpecific([String])
}
```

### ChatStreamStatus

```swift
public enum ChatStreamStatus: String {
    case starting
    case failed
    case streaming_tokens
    case stream_ended
    case sending_to_local_ai
    case sending_to_cloud_ai
    case evaluating_tool_calls
    case new_message_created
    case cloud_fallback
}
```

### RunLocation

```swift
public enum RunLocation: String {
    case automatic  // Prefer local, fallback to cloud
    case cloudRun   // Force cloud
    case localRun   // Force local (may throw if not available)
}
```

### ModelDownloadState

```swift
public enum ModelDownloadState {
    case notDownloaded
    case downloading(Double)  // Progress 0.0-1.0
    case downloaded
    case failed(Error)
}
```

### DownloadedState

```swift
public enum DownloadedState {
    case downloaded
    case aiNotSupported
}
```

### Document

```swift
public class Document {
    let id: String
    let documentType: DocumentType  // .privateDocument or .publicDocument
    let searchScope: String
    let metadata: String?
    let content: String
    let createdAt: Date
}
```

### DocumentChunk

```swift
public class DocumentChunk {
    let documentID: String
    let documentType: DocumentType
    let documentMetadata: String?
    let contentChunk: String
}
```

### DocumentSearchResults

```swift
public class DocumentSearchResults {
    let documentChunks: [DocumentChunk]
}
```

### WebSearchResult

```swift
public class WebSearchResult {
    let url: String?
    let title: String
    let snippet: String
    let description: String
    let age: String
    let thumbnail: String?
    let metadata: String
}
```

---

## Common Patterns

### Complete Chat Flow (Session-Based)

```swift
// 1. Configure
try FreeToken.shared.configure(appToken: "api-key")

// 2. Register device
await FreeToken.shared.registerDeviceSession(scope: "my-app-v1") {
    print("Registered")
} error: { _ in }

// 3. Download model
await FreeToken.shared.downloadAIModel(success: { _ in }) error: { _ in }

// 4. Get chat session
let session = try await FreeToken.shared.getChatSession()

// 5. Create thread
let thread = try await session.createMessageThread()

// 6. Add message
let userMsg = FreeToken.Message(role: .user, content: "Hello!")
try await session.addMessage(message: userMsg)

// 7. Generate response
let response = try await session.generateNewMessage(
    chatStatusStream: { token, status in
        if let token = token {
            print(token, terminator: "")
        }
    }
)

print("\n\nFinal response: \(response.content)")

// 8. Unload when done
await session.unload()
```

### Completion Flow

```swift
// Get completion session
let session = try await FreeToken.shared.getCompletionSession()

// Generate completion
let completion = try await session.generateCompletion(
    from: "Explain quantum computing",
    chatStatusStream: { token, _ in
        if let token = token {
            print(token, terminator: "")
        }
    }
)

print("\n\nTokens used: \(completion.tokenUsage?.totalTokens ?? 0)")

// Unload
await session.unload()
```

### Using Specific Models

```swift
// Download specific model
await FreeToken.shared.downloadAIModel(
    modelCode: "gemma3n_e2b_it",
    success: { _ in },
    error: { _ in }
)

// Use in session
let session = try await FreeToken.shared.getChatSession(
    modelCode: "gemma3n_e2b_it"
)
```

### Cloud-Only Models

```swift
// No download needed
let session = try await FreeToken.shared.getChatSession(
    modelCode: "deepseek_r1_0528_cloud",
    runLocation: .cloudRun
)
```

### Multi-Turn Conversation

```swift
let session = try await FreeToken.shared.getChatSession()
let thread = try await session.createMessageThread()

// Turn 1
try await session.addMessage(
    message: Message(role: .user, content: "What is AI?")
)
let response1 = try await session.generateNewMessage()

// Turn 2
try await session.addMessage(
    message: Message(role: .user, content: "How does it learn?")
)
let response2 = try await session.generateNewMessage()

// Get full history
let messages = try await session.getMessages()
```

---

## Error Handling

Common errors from `FreeTokenError`:

- `.clientNotConfigured` - Call `configure()` first
- `.deviceNotRegistered` - Call `registerDeviceSession()` first
- `.aiModelNotDownloaded` - Download model first
- `.messageThreadNotCreated` - Call `createMessageThread()` first
- `.deviceNotCapable` - Device can't run model locally
- `.notEnoughMemoryForModel` - Insufficient memory
- `.generationCancelled` - User cancelled via stream callback
- `.visionModelRequired` - Images sent to non-vision model
- `.cloudCompletionFailed` - Cloud AI error
- `.encryptionError` - Encryption/decryption failed

---

## Best Practices

1. **Use Sessions:** Prefer `getChatSession()` and `getCompletionSession()` over legacy APIs
2. **Memory Management:** Call `unload()` when done with sessions, especially on iOS
3. **Save IDs:** Thread IDs and document store IDs are only returned once
4. **Check Capabilities:** Use `isModelAvailableForDevice()` before downloading
5. **Handle Cancellation:** Support cancellation via throwing in stream closures
6. **Secure Keys:** Store encryption keys in Keychain, never UserDefaults
7. **Monitor Status:** Use `chatStatusStream` for UX feedback
8. **Automatic Fallback:** Use `runLocation: .automatic` for best UX

---

## Testing

```bash
# All tests
swift test

# Specific test
swift test --filter testChatSession

# Build only
swift build
```

---

## Additional Resources

- **Documentation**: [docs.freetoken.ai](https://docs.freetoken.ai)
- **Console**: [console.freetoken.ai](https://console.freetoken.ai)
- **GitHub**: [github.com/FreeTokenAI/FreeTokenSwift](https://github.com/FreeTokenAI/FreeTokenSwift)
