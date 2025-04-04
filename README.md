# FreeToken Swift Client

The FreeToken Swift client provides a seamless way to integrate AI capabilities into your iOS applications with both cloud and on-device support.

## Features

- On-device AI processing
- Cloud AI processing with automatic fallback
- Privacy-focused encryption mode
- Document indexing and search
- Message threading for conversations
- Function/tool calling support
- Local and cloud model management

## Installation

Add FreeToken to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/FractionalLabs/FreeToken-swift.git", from: "1.0.0")
]
```

## Basic Usage

### Configuration

Initialize and configure the FreeToken client:

```swift
import FreeToken

let client = FreeToken.shared.configure(
    appToken: "your-api-key",
    baseURL: URL(string: "https://api.example.com/")
)
```

### Device Registration

Register your device to determine AI capabilities:

```swift
client.registerDeviceSession(scope: "my-app-v1") {
    // Successfully registered
} error: { error in
    print("Failed to register device: \(error)")
}
```

### Download AI Model

Download the AI model for on-device processing:

```swift
client.downloadAIModel { isModelDownloaded in
    if isModelDownloaded {
        // Device has the capability to support AI
    } else {
        // Device can't support AI, but will run in Compatibility Mode.
    }
} error: { error in
    print("Download failed: \(error)")
} progressPercent: { progress in
    print("Download progress: \(progress)%")
    // Show this in your UI for users to see
}
```

## Message Threading

### Create Thread

Create a new message thread:

```swift
client.createMessageThread(
    pinnedContext: "Initial context",
    agentScope: "agent-scope"
) { messageThread in
    // Save messageThread.id for future reference
} error: { error in
    print("Failed to create thread: \(error)")
}
```

### Add Message

Add a message to an existing thread:

```swift
client.addMessageToThread(
    messageThreadID: "thread-id",
    role: "user",
    content: "What is a supernova?"
) { message in
    print("Message added: \(message.content)")
} error: { error in
    print("Failed to add message: \(error)")
}
```

### Run Thread

Process the message thread through AI:

```swift
client.runMessageThread(
    id: "thread-id"
) { response in
    print("AI response: \(response.resultMessage.content)")
} error: { error in
    print("Failed to run thread: \(error)")
} chatStatusStream: { token, status in
    if let token = token {
        print("Stream token: \(token)")
    }
    print("Status: \(status)")
}
```

## Document Management

### Create Document

Add searchable documents for AI context:

```swift
client.createDocument(
    content: "Document content",
    metadata: "TITLE: Example Document\nAUTHOR: John Doe",
    searchScope: "knowledge-base"
) { document in
    print("Document created: \(document.id)")
} error: { error in
    print("Failed to create document: \(error)")
}
```

### Search Documents

Search for relevant documents:

```swift
client.searchDocuments(
    query: "supernova explosion",
    searchScope: "astronomy",
    maxResults: 5
) { results in
    for chunk in results.documentChunks {
        print("Found relevant content: \(chunk.contentChunk)")
    }
} error: { error in
    print("Search failed: \(error)")
}
```

## Privacy Mode

Enable encryption for privacy-sensitive applications:

```swift
try client.privacyModeEncryption(
    encrypt: { text in
        // Your encryption logic
        return encryptedText
    },
    decrypt: { text in
        // Your decryption logic
        return decryptedText
    }
)
```

## Local Chat

Send direct messages to the on-device AI:

```swift
do {
    let response = try client.localChat(
        content: "What is a supernova?",
        role: "user"
    )
    print("AI response: \(response["content"] ?? "")")
} catch {
    print("Local chat failed: \(error)")
}
```

## Device Management

### Reset Device

Clear device registration and caches:

```swift
try client.resetDevice()
```

### Model Management

Load/unload the AI model from memory:

```swift
// Load model
client.loadModel(
    success: { isLoaded in
        print("Model loaded: \(isLoaded)")
    },
    error: { error in
        print("Failed to load model: \(error)")
    }
)

// Unload model
client.unloadModel()
```

## License

