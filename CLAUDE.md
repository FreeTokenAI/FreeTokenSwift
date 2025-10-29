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

Required before using AI features. Determines device capabilities and downloads appropriate models.

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
    forceRedownload: false,
    progressCallback: { progress in
        print("Progress: \(Int(progress * 100))%")
    },
    success: {
        print("Model ready")
    },
    error: { error in
        print("Download failed: \(error)")
    }
)
```

---

## API Reference

### Message Threading & Chat

Message threads provide persistent, context-aware conversations.

#### Create Thread

```swift
await FreeToken.shared.createMessageThread(
    success: { thread in
        print("Created thread: \(thread.id)")
        // IMPORTANT: Save thread.id for future use
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Add Message to Thread

```swift
let message = FreeToken.Message(role: .user, content: "What is a supernova?")

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

#### Run Thread (Execute AI)

```swift
await FreeToken.shared.runMessageThread(
    id: threadId,
    modelCode: nil,  // Optional: override default model
    outputStream: { token in
        print(token, terminator: "")  // Real-time token streaming
    },
    chatStatusStream: { status in
        switch status {
        case .starting:
            print("Starting...")
        case .sending_to_local_ai:
            print("Processing locally...")
        case .sending_to_cloud_ai:
            print("Processing in cloud...")
        case .streaming_tokens:
            print("Streaming response...")
        case .evaluating_tool_calls:
            print("Calling tools...")
        case .new_message_created:
            print("Message saved")
        case .stream_ended:
            print("Complete!")
        case .failed:
            print("Failed")
        }

        // Throw to cancel generation
        if shouldCancel {
            throw CancellationError()
        }
    },
    success: { response in
        print("Final response: \(response.content)")
    },
    error: { error in
        if case .generationCancelled = error {
            print("Generation cancelled by user")
        }
    }
)
```

#### Get Thread Details

```swift
await FreeToken.shared.getMessageThread(
    id: threadId,
    success: { thread in
        print("Thread: \(thread.displayName)")
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

### AI Completions

Generate text without persistent threads.

#### General Completion (Auto Local/Cloud)

```swift
await FreeToken.shared.generateCompletion(
    prompt: "Write a poem about coding",
    tokenStream: { token in
        print(token, terminator: "")

        // Cancel by throwing
        if shouldCancel {
            throw CancellationError()
        }
    },
    success: { completion in
        print("Response: \(completion.response)")
        print("Tokens used: \(completion.tokenUsage)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Force Local Completion

```swift
await FreeToken.shared.generateLocalCompletion(
    prompt: "Explain quantum computing",
    modelCode: "llama-3.2-1b",
    aiRunConfig: AIRunConfig(temperature: 0.8),
    tokenStream: { token in
        print(token, terminator: "")
    },
    success: { completion in
        print("Local response: \(completion.response)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Force Cloud Completion

```swift
await FreeToken.shared.generateCloudCompletion(
    prompt: "Generate a business plan",
    modelCode: "gpt-4",
    aiRunConfig: nil,
    tokenStream: nil,
    success: { completion in
        print("Cloud response: \(completion.response)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Local Chat (Advanced)

For direct multi-turn conversations with local AI:

```swift
let messages = [
    FreeToken.Message(role: .system, content: "You are a helpful assistant"),
    FreeToken.Message(role: .user, content: "What is Swift?")
]

let response = try await FreeToken.shared.localChat(
    modelCode: nil,
    messages: messages,
    runIdentifier: "chat-session-1",  // Optional session ID
    aiRunConfig: AIRunConfig(temperature: 0.7, disableThinking: false),
    outputStream: { token in
        print(token, terminator: "")
    }
)

print("Assistant: \(response.content)")
```

**Disabling Thinking for Faster Responses:**

```swift
// For simple queries, disable thinking to get faster, more direct answers
let quickConfig = AIRunConfig(
    temperature: 0.7,
    disableThinking: true  // Skip internal reasoning for speed
)

let quickResponse = try await FreeToken.shared.localChat(
    modelCode: nil,
    messages: [
        FreeToken.Message(role: .user, content: "What's 2+2?")
    ],
    runIdentifier: "quick-session",
    aiRunConfig: quickConfig,
    outputStream: { token in
        print(token, terminator: "")
    }
)
```

---

### Model Management

#### List Available Models

```swift
await FreeToken.shared.listAIModels(
    success: { models in
        for model in models {
            print("\(model.code): \(model.name)")
            print("  Platform: \(model.platform)")
            print("  Vision: \(model.capabilities.imageToText)")
        }
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Get Model Details

```swift
await FreeToken.shared.getAIModel(
    modelCode: "llama-3.2-1b",
    success: { model in
        print("Model: \(model.name)")
        print("Size: \(model.modelSize) bytes")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Check Model Availability for Device

```swift
// Check specific model
let isAvailable = try await FreeToken.shared.isModelAvailableForDevice(
    modelCode: "llama-3.2-1b"
)

if isAvailable {
    print("This device can run the model locally")
}

// Get all available models for this device
let availableModels = try await FreeToken.shared.availableAIModelsForDevice()
for model in availableModels {
    if model.cloudOnly {
        print("Cloud model: \(model.name)")
    } else {
        print("Local model: \(model.name)")
    }
}
```

#### Download Model

```swift
await FreeToken.shared.downloadAIModel(
    modelCode: "llama-3.2-1b",
    forceRedownload: false,
    progressCallback: { progress in
        print("Progress: \(Int(progress * 100))%")
    },
    success: {
        print("Model downloaded")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Load/Unload Model

```swift
// Load into memory
await FreeToken.shared.loadModel(
    modelCode: "llama-3.2-1b",
    success: { state in
        print("Model state: \(state)")
    },
    error: { error in
        print("Error: \(error)")
    }
)

// Unload from memory
await FreeToken.shared.unloadModel(modelCode: "llama-3.2-1b")
```

#### Prewarm Model (Performance)

Pre-load model before expected use for faster first response:

```swift
await FreeToken.shared.prewarmAIFor(
    runIdentifier: "session-1",
    modelCode: nil,
    runConfig: AIRunConfig(temperature: 0.7),
    toolAccess: [.allowAll],
    success: {
        print("AI prewarmed and ready")
    },
    error: { error in
        print("Error: \(error)")
    }
)

// Later, use same runIdentifier
await FreeToken.shared.runMessageThread(
    id: threadId,
    runIdentifier: "session-1",  // Same ID = instant start
    success: { response in
        print("Fast response: \(response.content)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

---

### Document Management (RAG)

Retrieval Augmented Generation allows AI to search your documents for context.

#### Create Private Document Store

```swift
await FreeToken.shared.createPrivateDocumentStore(
    name: "User Personal Docs",
    success: { store in
        print("Store created: \(store.id)")
        // IMPORTANT: Save store.id securely
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Create Public Document

```swift
await FreeToken.shared.createDocument(
    name: "Product Manual",
    content: "Long document content here...",
    searchScope: "product-docs",
    documentType: .publicDocument,
    metadata: ["version": "2.0", "category": "manual"],
    success: { document in
        print("Document created: \(document.id)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Create Private Document

```swift
await FreeToken.shared.createDocument(
    name: "Private Notes",
    content: "Sensitive content...",
    searchScope: "user-notes",
    documentType: .privateDocument(storeId: storeId),
    metadata: ["author": "User", "date": "2025-01-15"],
    success: { document in
        print("Private document created: \(document.id)")
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
    privateDocumentStoreIds: ["store-id-1", "store-id-2"],  // Optional
    maxResults: 10,
    success: { results in
        print("Found \(results.totalCount) documents")
        for chunk in results.chunks {
            print("Document: \(chunk.documentName)")
            print("Content: \(chunk.content)")
            print("Relevance: \(chunk.relevanceScore)")
        }
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Run Thread with Document Search

```swift
// Search public documents
await FreeToken.shared.runMessageThread(
    id: threadId,
    documentSearchScope: "sales-docs",
    success: { response in
        print("Response with RAG: \(response.content)")
    },
    error: { error in
        print("Error: \(error)")
    }
)

// Search private documents
await FreeToken.shared.runMessageThread(
    id: threadId,
    documentSearchScope: "manuals",
    privateDocumentStoreIds: ["store-id-1", "store-id-2"],
    success: { response in
        print("Response: \(response.content)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

---

### Tool/Function Calling

Enable AI to call functions in your app.

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
                    "description": "Temperature format",
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

#### Handle Tool Calls in Thread

```swift
await FreeToken.shared.runMessageThread(
    id: threadId,
    success: { response in
        print("Response: \(response.content)")
    },
    error: { error in
        print("Error: \(error)")
    },
    toolCallback: { toolCalls in
        // Handle each tool call
        return toolCalls.map { toolCall in
            if toolCall.name == "get_current_weather" {
                let location = toolCall.arguments["location"] ?? "Unknown"
                let format = toolCall.arguments["format"] ?? "celsius"

                // Call your weather API
                return "The weather in \(location) is 20 degrees \(format)."
            }
            return ""
        }.joined(separator: "\n\n")
    }
)
```

#### Tool Access Control

Restrict which tools can be used in a thread:

```swift
await FreeToken.shared.createMessageThread(
    toolAccess: [
        .allowAll,                                    // Allow all tools
        .denyAll,                                     // Deny all tools
        .allowSpecific(["get_weather", "calculator"]), // Allow specific
        .denySpecific(["dangerous_tool"])             // Deny specific
    ],
    success: { thread in
        print("Thread created with tool restrictions")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Remove All Tools

```swift
await FreeToken.shared.removeAllToolDefinitions()
```

---

### Vision Support (Multi-Modal)

Send images to vision-capable AI models.

#### Analyze Image

```swift
// 1. Prepare image
let imageData = UIImage(named: "photo")!.pngData()!
let attachment = FreeToken.MessageAttachment.image(imageData, filename: "photo.png")

// 2. Create message with image
let message = FreeToken.Message(
    role: .user,
    content: "What's in this image?",
    attachments: [attachment]
)

// 3. Add to thread
await FreeToken.shared.addMessageToThread(
    id: threadId,
    message: message,
    success: { message in
        print("Message with image added")
    },
    error: { error in
        print("Error: \(error)")
    }
)

// 4. Run with vision model
await FreeToken.shared.runMessageThread(
    id: threadId,
    modelCode: "llama_4_scout_cloud",  // Vision-capable model
    success: { response in
        print("AI analysis: \(response.content)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

#### Multiple Images

```swift
let attachment1 = FreeToken.MessageAttachment.image(image1Data, filename: "photo1.png")
let attachment2 = FreeToken.MessageAttachment.image(image2Data, filename: "photo2.png")

let message = FreeToken.Message(
    role: .user,
    content: "Compare these two images",
    attachments: [attachment1, attachment2]
)
```

**Note**: Vision currently works with cloud models only. Local vision support coming soon.

---

### Encryption

Client-side encryption for messages and documents.

#### Generate Encryption Keys

```swift
// Generate keys (only returned once - store securely!)
let userPrivateKey = FreeToken.shared.enableEncryption(scope: .userPrivate)
let publicKey = FreeToken.shared.enableEncryption(scope: .sharedPublic)

// Store in Keychain (recommended) or secure storage
// WARNING: Keys are only returned once!
```

#### Configure with Encryption

```swift
try FreeToken.shared.configure(
    appToken: "your-api-key",
    sharedPublicEncryptionKey: publicKey,
    userPrivateEncryptionKey: userPrivateKey,
    logLevel: .info
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

**Encryption Scopes**:
- `.sharedPublic`: For public documents (shared across app users)
- `.userPrivate`: For messages and private document stores

**What's Encrypted**:
- Messages (with user private key)
- Private documents (with user private key)
- Public documents (with shared public key)

**Not Encrypted**:
- Web search queries
- Cloud AI inference requests
- Telemetry data

---

### Web Search

Perform web searches (requires configuration in console):

```swift
await FreeToken.shared.webSearch(
    query: "latest AI news",
    resultCount: 5,
    success: { results in
        for result in results {
            print("\(result.title)")
            print("\(result.url)")
            print("\(result.snippet)")
        }
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

---

### Utilities

#### Count Tokens

```swift
let tokenCount = try await FreeToken.shared.countTokens(
    text: "Your text here",
    modelCode: "llama-3.2-1b"  // Optional
)
print("Token count: \(tokenCount)")
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

#### Reset & Cleanup

```swift
// Reset device registration
try await FreeToken.shared.resetDevice()

// Delete model caches
await FreeToken.shared.deleteAIModelCache(modelCode: "llama-3.2-1b")  // Specific
await FreeToken.shared.deleteAIModelCache()  // All models

// Reset all caches
try await FreeToken.shared.resetModelCaches()
try await FreeToken.shared.resetEmbeddingModelCache()
```

#### Stop Local Generation

```swift
await FreeToken.shared.stopLocalGeneration()
```

---

## Common Patterns

### Complete Chat Flow

```swift
// 1. Configure
try FreeToken.shared.configure(appToken: "api-key")

// 2. Register device
await FreeToken.shared.registerDeviceSession(scope: "my-app-v1") {
    print("Registered")
} error: { _ in }

// 3. Download model
await FreeToken.shared.downloadAIModel { _ in } error: { _ in }

// 4. Create thread
var threadId: String?
await FreeToken.shared.createMessageThread { thread in
    threadId = thread.id
} error: { _ in }

// 5. Add message
let message = FreeToken.Message(role: .user, content: "Hello!")
await FreeToken.shared.addMessageToThread(id: threadId!, message: message) { _ in
    print("Message added")
} error: { _ in }

// 6. Run AI
await FreeToken.shared.runMessageThread(
    id: threadId!,
    outputStream: { token in
        print(token, terminator: "")
    },
    success: { response in
        print("\nResponse: \(response.content)")
    },
    error: { error in
        print("Error: \(error)")
    }
)
```

### Using Multiple Models

```swift
// Download specific model
await FreeToken.shared.downloadAIModel(
    modelCode: "gemma3n_e2b_it",
    success: { _ in
        print("Model downloaded")
    },
    error: { _ in }
)

// Use specific model for completion
await FreeToken.shared.generateCompletion(
    prompt: "Hello",
    modelCode: "gemma3n_e2b_it",
    success: { completion in
        print(completion.response)
    },
    error: { _ in }
)
```

### Cloud-Only Models

```swift
// No download needed for cloud-only models
await FreeToken.shared.generateCompletion(
    prompt: "Complex reasoning task",
    modelCode: "deepseek_r1_0528_cloud",
    success: { completion in
        print(completion.response)
    },
    error: { _ in }
)
```

---

## Data Structures

### Message

```swift
public class Message {
    let id: String
    let role: MessageRole  // .system, .user, .assistant, .tool
    let content: String
    let attachments: [MessageAttachment]?  // For images
    let toolCalls: [ToolCall]?
    let tokenUsage: TokenUsage?

    init(role: MessageRole, content: String)
    init(role: MessageRole, content: String, attachments: [MessageAttachment])
}
```

### AIRunConfig

```swift
public struct AIRunConfig {
    let temperature: Float?       // 0.0-2.0, controls randomness
    let maxTokens: Int?           // Maximum tokens to generate
    let topP: Float?              // 0.0-1.0, nucleus sampling
    let topK: Int?                // Top-k sampling
    let repeatPenalty: Float?     // Penalty for repetition
    let systemPrompt: String?     // Override system prompt
    let seed: Int?                // For reproducible outputs
    let disableThinking: Bool?    // Disable model thinking by appending <think></think> to assistant messages
}
```

**Note about `disableThinking`**: When set to `true`, the SDK automatically appends `<think></think>` to all assistant role messages during template generation. This instructs compatible models to skip their internal reasoning process and provide direct answers. This feature is useful for:
- Faster response times when detailed reasoning isn't needed
- Reducing token usage on models with verbose thinking patterns
- Getting concise answers for simple queries

Example:
```swift
let config = AIRunConfig(
    temperature: 0.7,
    disableThinking: true  // Skip model thinking for faster responses
)

await FreeToken.shared.runMessageThread(
    id: threadId,
    aiRunConfig: config,
    success: { response in
        print("Direct answer: \(response.content)")
    }
)
```

### TokenUsage

```swift
public struct TokenUsage {
    let promptTokens: Int         // Input tokens
    let completionTokens: Int     // Output tokens
    let totalTokens: Int          // Total
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
}
```

---

## Error Handling

Common errors from `FreeTokenError`:

- `.clientNotConfigured` - Call `configure()` first
- `.deviceNotRegistered` - Call `registerDeviceSession()` first
- `.aiModelNotDownloaded` - Download model first
- `.aiModelNotLoaded` - Model not in memory
- `.isCloudOnlyModel` - Cannot run locally
- `.generationCancelled` - User cancelled generation
- `.visionModelRequired` - Images sent to non-vision model

---

## Best Practices

1. **Save IDs**: Thread IDs and document store IDs are only returned once
2. **Prewarm models**: Use `prewarmAIFor()` before expected AI usage
3. **Use message threads**: Prefer `runMessageThread()` over `localChat()` for better performance
4. **Secure encryption keys**: Store in Keychain, never in UserDefaults
5. **Check device capabilities**: Use `isModelAvailableForDevice()` before downloading
6. **Handle cancellation**: Support user cancellation via throwing in stream closures
7. **Monitor status**: Use `chatStatusStream` for UX feedback
8. **Control thinking**: Use `disableThinking: true` in `AIRunConfig` for simple queries where speed is more important than detailed reasoning, or when you need concise, direct answers

---

## Testing

Run tests from command line:

```bash
# All tests
swift test

# Specific test
swift test --filter testLocalCompletion

# Build only
swift build
```

---

## Additional Resources

- **Full Documentation**: [docs.freetoken.ai](https://docs.freetoken.ai)
- **Console**: [console.freetoken.ai](https://console.freetoken.ai)
- **GitHub**: [github.com/FreeTokenAI/FreeTokenSwift](https://github.com/FreeTokenAI/FreeTokenSwift)
