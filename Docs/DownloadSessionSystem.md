# FreeToken Download Session System

## Overview

The FreeToken Download Session System provides a powerful, session-based download management solution with collective progress tracking, automatic recovery after app termination, and full background download support for iOS and macOS apps.

### Key Features

- **Session-Based Downloads**: Group related downloads for collective progress tracking
- **Background Support**: Full iOS/macOS background download integration
- **Automatic Recovery**: Sessions persist and recover after app restart/termination
- **Real-Time Progress**: Collective progress tracking across multiple downloads
- **Thread Safety**: Fully concurrent with proper queue management
- **Memory Efficient**: URLSession tasks as source of truth, minimal persistence
- **Cross-Platform**: iOS, macOS, tvOS, watchOS, and visionOS support
- **Error Recovery**: Developer-friendly error messages with actionable suggestions

## Architecture

The system uses a **hybrid approach** combining URLSession tasks as the source of truth for active downloads with minimal metadata persistence for recovery:

### Core Components

- **DownloadManager**: Main singleton managing all download operations
- **DownloadSession**: Groups related downloads with collective progress tracking
- **DownloadItem**: Individual download tracking with state management
- **SessionMetadata**: Persistence layer for session recovery
- **SessionStorage**: Thread-safe storage management

### Design Principles

1. **URLSession Tasks as Source of Truth**: Live progress comes from `task.countOfBytesReceived`
2. **Minimal Persistence**: Only save completion states, not live progress data  
3. **Automatic Recovery**: Match persisted URLs to active URLSession tasks on restart
4. **Session-Based Organization**: Group downloads for lifecycle management
5. **Background Integration**: Proper iOS AppDelegate integration

## Core Concepts

### Sessions

A **session** groups multiple related downloads together:
- Shared lifecycle and progress tracking
- Collective completion/failure handling  
- Automatic persistence for recovery
- Configurable session limits (default: 10 concurrent)

### Progress Calculation

Progress is calculated using a **weighted average** based on file sizes:
- Downloads with known sizes contribute to collective progress
- Unknown-size downloads are excluded from calculations
- Uses URLSession tasks when available, falls back to stored values

### State Management

**Session States**:
- `pending`: Not started
- `downloading`: At least one download active  
- `completed`: All downloads successful
- `failed`: All downloads failed
- `partial`: Mix of completed/failed/pending

**Download States**:
- `pending`: Queued but not started
- `downloading`: Currently downloading
- `completed`: Successfully finished
- `failed`: Failed (may be resumable)
- `cancelled`: Cancelled by user

## Integration Guide

### Basic Setup

The download manager is automatically available through the FreeToken singleton, and key methods are exposed as static convenience methods:

```swift
import FreeToken

// Access the download manager
let downloadManager = FreeToken.DownloadManager.shared

// Key static convenience methods for easy integration:
FreeToken.attachDownloadSession()  // Attach download session
FreeToken.handleBackgroundDownloads(identifier: identifier, completionHandler: completionHandler)  // Handle background downloads
```

### iOS AppDelegate Integration

For background downloads to work properly on iOS, you need to integrate with your AppDelegate:

```swift
import UIKit
import FreeToken

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication, 
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Initialize FreeToken and attach download session
        // This ensures background downloads can resume
        FreeToken.attachDownloadSession()
        return true
    }
    
    // REQUIRED: Handle background download completion
    func application(_ application: UIApplication,
                   handleEventsForBackgroundURLSession identifier: String,
                   completionHandler: @escaping () -> Void) {
        // One-line integration with FreeToken
        FreeToken.handleBackgroundDownloads(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
```

### macOS AppDelegate Integration

macOS handles background sessions differently:

```swift
import Cocoa
import FreeToken

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Initialize FreeToken and attach download session
        FreeToken.attachDownloadSession()
    }
    
    // macOS doesn't require special background session handling
    // Background downloads continue automatically
}
```

### SwiftUI App Integration

For SwiftUI apps using the App protocol:

```swift
import SwiftUI
import FreeToken

@main
struct MyApp: App {
    
    init() {
        // Initialize download session on app startup
        FreeToken.attachDownloadSession()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // iOS only: Handle background downloads
        #if os(iOS)
        .backgroundTask(.urlSession("ai.freetoken.downloadManager")) {
            // Background downloads are handled automatically by FreeToken
        }
        #endif
    }
}
```

## API Reference

### Creating Sessions with Builder Pattern (Recommended)

The builder pattern provides the most flexible and readable way to create download sessions, especially when using SHA-256 verification:

```swift
// Create a session with hash verification and progress tracking
let session = try FreeToken.createDownloadSession()
    .sessionID("model-downloads-v2")
    .addDownload(url: URL(string: "https://example.com/model1.bin")!, 
                 sha256: "a1b2c3d4e5f6789...")
    .addDownload(url: URL(string: "https://example.com/model2.bin")!, 
                 sha256: "f6e5d4c3b2a1987...")
    .addDownload(url: URL(string: "https://example.com/config.json")!)  // No verification
    .progress { progress in
        // Called whenever collective progress changes
        DispatchQueue.main.async {
            print("Session progress: \(Int(progress * 100))%")
            // Update UI: progress bars, labels, etc.
        }
    }
    .completion { result in
        switch result {
        case .success:
            print("All downloads completed and verified!")
        case .failure(let error):
            if let ftError = error as? FreeToken.FreeTokenError,
               case .downloadHashVerificationFailed(let url, let expected, let actual) = ftError {
                print("Hash mismatch for \(url): expected \(expected), got \(actual)")
            }
        }
    }
    .build()

// Start the downloads - progress callbacks will automatically fire
let success = FreeToken.DownloadManager.shared.startSessionDownloads(sessionID: session.id)
```

### Creating Sessions (Legacy Method)

```swift
// Create a session with multiple URLs
let urls = [
    URL(string: "https://example.com/file1.zip")!,
    URL(string: "https://example.com/file2.pdf")!,
    URL(string: "https://example.com/file3.json")!
]

do {
    let session = try downloadManager.createSession(
        urls: urls,
        sessionID: "my-downloads", // Optional custom ID
        completion: { result in
            switch result {
            case .success:
                print("All downloads completed successfully!")
            case .failure(let error):
                print("Session failed: \(error)")
            }
        }
    )
} catch {
    print("Failed to create session: \(error)")
}
```

### Starting Downloads

```swift
// Start all downloads in a session with progress tracking
let success = downloadManager.startSessionDownloads(
    sessionID: "my-downloads"
) { progress in
    // Handlers are invoked on a configurable per-session queue (defaults to `.main`).
    // For UI updates, explicitly dispatch to the main queue to be explicit and avoid
    // depending on the session's configuration:
    DispatchQueue.main.async {
        print("Session progress: \(Int(progress * 100))%")
        // Update progress bar, etc.
    }
}

if !success {
    print("Session not found or already completed")
}
```

### Monitoring Progress

```swift
// Get real-time progress for a specific session
if let session = downloadManager.getSession(id: "my-downloads") {
    print("Current progress: \(session.collectiveProgress)")
    print("Downloaded bytes: \(session.downloadedBytes)")
    print("Total bytes: \(session.totalBytes)")
    print("Active downloads: \(session.activeCount)")
    print("Completed: \(session.completedCount)")
    print("Failed: \(session.failedCount)")
}

// Get detailed progress information
let details = session.getProgressDetails()
print("Session state: \(details.state)")
print("Unknown size downloads: \(details.unknownSizeCount)")
```

### Session Recovery

Sessions automatically persist and recover after app restart:

```swift
// Recover a session after app restart
if let session = downloadManager.recoverSession(id: "my-downloads") {
    print("Session recovered with \(session.completedCount) completed downloads")
    print("Current progress: \(Int(session.collectiveProgress * 100))%")
    
    // Resume downloading if not complete
    if !session.isCompleted {
        downloadManager.startSessionDownloads(sessionID: "my-downloads")
    }
} else {
    print("No session found to recover")
}
```

### Session Management

```swift
// Get all active sessions
let allSessions = downloadManager.getAllSessions()
print("Active sessions: \(allSessions.count)")

// Get session summary statistics
let summary = downloadManager.getSessionSummary()
print("Total sessions: \(summary.totalSessions)")
print("Overall progress: \(Int(summary.overallProgress * 100))%")
print("Success rate: \(summary.successRate)%")

// Remove completed session
downloadManager.removeSession(id: "my-downloads")
```

### Background Completion Handling

You can add custom logic when sessions complete in the background:

```swift
// Optional: Handle background session completion
DownloadManager.shared.onBackgroundSessionCompletion = { sessionID in
    print("Session \(sessionID) completed in background")
    
    // Process downloaded files
    if let session = downloadManager.getSession(id: sessionID) {
        for download in session.getDownloads() {
            if download.state == .completed {
                print("Process file: \(download.destinationPath)")
            }
        }
    }
    
    // Update UI, send notifications, etc.
    DispatchQueue.main.async {
        // Update your UI
    }
}

// Optional: Handle when all background downloads finish
DownloadManager.shared.onAllBackgroundDownloadsComplete = {
    print("All background downloads finished")
    // Perform final cleanup, analytics, etc.
}
```

## Hash Verification

### Overview

The download session system supports optional SHA-256 hash verification to ensure file integrity and authenticity. Hash verification helps detect:
- Corrupted downloads due to network issues
- Tampered files (man-in-the-middle attacks)
- Incomplete downloads that appear successful

### How It Works

1. **Provide Expected Hash**: When creating downloads, optionally specify the expected SHA-256 hash
2. **Automatic Verification**: After download completion, the system computes the actual file hash
3. **Comparison**: Expected vs actual hash comparison (case-insensitive)
4. **Failure Handling**: If hashes don't match, download is marked as failed with detailed error

### Hash Verification Features

- **Memory Efficient**: Uses streaming computation for large files (1MB chunks)
- **Optional**: Per-download basis - some files can have verification, others not
- **Persistent**: Expected hashes are saved in session metadata for recovery after app restart
- **Case Insensitive**: Hash comparison works regardless of case
- **Detailed Errors**: Provides both expected and actual hash values for debugging

### Usage Examples

```swift
// Single download with verification
let session = try FreeToken.createDownloadSession()
    .addDownload(url: modelURL, sha256: "a1b2c3d4e5f6...")
    .build()

// Mixed verification scenario
let session = try FreeToken.createDownloadSession()
    .addDownload(url: criticalFile, sha256: "secure_hash_here")  // Verified
    .addDownload(url: configFile)                               // Not verified
    .addDownload(url: dataFile, sha256: "another_hash")         // Verified
    .build()

// Bulk download with hash mapping
let downloads = [
    (url: URL(string: "https://example.com/file1.bin")!, sha256: "hash1"),
    (url: URL(string: "https://example.com/file2.bin")!, sha256: "hash2"),
    (url: URL(string: "https://example.com/file3.json")!, sha256: nil)  // No verification
]

```

### Getting Hash Verification Results

```swift
// Check verification results after completion
if let session = downloadManager.getSession(id: sessionID) {
    for download in session.getDownloads() {
        if let completion = download.completionInfo {
            if let hashVerified = completion.hashVerified {
                if hashVerified {
                    print("✅ \(download.url.lastPathComponent): Hash verified")
                } else {
                    print("❌ \(download.url.lastPathComponent): Hash verification FAILED")
                    print("Expected: \(download.expectedSHA256 ?? "none")")
                    print("Actual: \(completion.actualSHA256 ?? "unknown")")
                }
            } else {
                print("ℹ️ \(download.url.lastPathComponent): No hash verification requested")
            }
        }
    }
}
```

### Generating SHA-256 Hashes

To generate SHA-256 hashes for your files:

**Command Line (macOS/Linux):**
```bash
# For local files
shasum -a 256 yourfile.bin

# For remote files (download first)
curl -s https://example.com/file.bin | shasum -a 256
```

**Swift Code:**
```swift
import CryptoKit
import Foundation

func computeSHA256(url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
```

## Configuration Options

### Session Limits

```swift
// Configure maximum concurrent sessions (default: 10)
DownloadManager.shared.maxConcurrentSessions = 20

// Older sessions are automatically cleaned up when limit is reached
```

### Resume Data Expiration

```swift
// Configure how long resume data is kept (default: 24 hours)
DownloadManager.shared.resumeDataExpirationInterval = 48 * 60 * 60 // 48 hours
```

## Code Examples

### Example 1: Model Download Session

```swift
import FreeToken

class ModelDownloadManager: ObservableObject {
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    
    private let downloadManager = DownloadManager.shared
    private let sessionID = "ai-models-v2"
    
    func downloadModels() {
        let modelURLs = [
            URL(string: "https://models.ai/base-model.bin")!,
            URL(string: "https://models.ai/embedding-model.bin")!,
            URL(string: "https://models.ai/tokenizer.json")!
        ]
        
        do {
            isDownloading = true
            
            let session = try downloadManager.createSession(
                urls: modelURLs,
                sessionID: sessionID
            ) { [weak self] result in
                DispatchQueue.main.async {
                    self?.isDownloading = false
                    switch result {
                    case .success:
                        print("✅ All models downloaded successfully!")
                        self?.onModelsReady()
                    case .failure(let error):
                        print("❌ Model download failed: \(error)")
                        self?.handleDownloadError(error)
                    }
                }
            }
            
            // Start downloads with progress tracking
            downloadManager.startSessionDownloads(
                sessionID: sessionID
            ) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.downloadProgress = progress
                }
            }
            
        } catch {
            print("Failed to create download session: \(error)")
            isDownloading = false
        }
    }
    
    func resumeDownloadsIfNeeded() {
        // Check for existing session on app startup
        if let session = downloadManager.recoverSession(id: sessionID) {
            if !session.isCompleted && !session.hasFailed {
                print("Resuming model downloads...")
                isDownloading = true
                downloadManager.startSessionDownloads(
                    sessionID: sessionID
                ) { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.downloadProgress = progress
                    }
                }
            }
        }
    }
    
    private func onModelsReady() {
        // Load models into AI system
        // Update UI to show models are available
    }
    
    private func handleDownloadError(_ error: Error) {
        // Show error to user
        // Offer retry option
    }
}
```

### Example 2: Document Sync Session

```swift
import FreeToken

class DocumentSyncManager {
    private let downloadManager = DownloadManager.shared
    private let sessionID = "document-sync"
    
    func syncDocuments(urls: [URL]) async throws {
        let session = try downloadManager.createSession(
            urls: urls,
            sessionID: sessionID
        )
        
        // Start downloads
        let success = downloadManager.startSessionDownloads(
            sessionID: sessionID
        ) { progress in
            print("Sync progress: \(Int(progress * 100))%")
        }
        
        guard success else {
            throw FreeTokenError.downloadSessionNotFound(sessionID)
        }
        
        // Wait for completion using async/await pattern
        return try await withCheckedThrowingContinuation { continuation in
            session.completionHandler = { result in
                continuation.resume(with: result)
            }
        }
    }
}
```

### Example 3: SwiftUI Progress View

```swift
import SwiftUI
import FreeToken

struct DownloadProgressView: View {
    @State private var progress: Double = 0.0
    @State private var isDownloading: Bool = false
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    
    private let sessionID = "app-resources"
    private let downloadManager = DownloadManager.shared
    
    var body: some View {
        VStack(spacing: 20) {
            if isDownloading {
                VStack {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    Text("\(Int(progress * 100))% Complete")
                        .font(.headline)
                    
                    Text("\(formatBytes(downloadedBytes)) / \(formatBytes(totalBytes))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Button(action: startDownloads) {
                Text(isDownloading ? "Downloading..." : "Start Downloads")
            }
            .disabled(isDownloading)
        }
        .onAppear {
            checkForExistingSession()
        }
    }
    
    private func startDownloads() {
        let urls = [
            URL(string: "https://assets.myapp.com/images.zip")!,
            URL(string: "https://assets.myapp.com/sounds.zip")!
        ]
        
        do {
            isDownloading = true
            
            let session = try downloadManager.createSession(
                urls: urls,
                sessionID: sessionID
            ) { result in
                DispatchQueue.main.async {
                    isDownloading = false
                    switch result {
                    case .success:
                        print("Downloads completed!")
                    case .failure(let error):
                        print("Downloads failed: \(error)")
                    }
                }
            }
            
            downloadManager.startSessionDownloads(
                sessionID: sessionID
            ) { newProgress in
                DispatchQueue.main.async {
                    progress = newProgress
                    updateBytesCounts()
                }
            }
            
        } catch {
            print("Failed to start downloads: \(error)")
            isDownloading = false
        }
    }
    
    private func checkForExistingSession() {
        if let session = downloadManager.recoverSession(id: sessionID) {
            if !session.isCompleted && !session.hasFailed {
                isDownloading = true
                progress = session.collectiveProgress
                updateBytesCounts()
                
                downloadManager.startSessionDownloads(
                    sessionID: sessionID
                ) { newProgress in
                    DispatchQueue.main.async {
                        progress = newProgress
                        updateBytesCounts()
                    }
                }
            }
        }
    }
    
    private func updateBytesCounts() {
        if let session = downloadManager.getSession(id: sessionID) {
            downloadedBytes = session.downloadedBytes
            totalBytes = session.totalBytes
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
```

## Best Practices

### Memory Management

1. **Use weak references** in completion handlers to avoid retain cycles:
   ```swift
   session.completionHandler = { [weak self] result in
       self?.handleCompletion(result)
   }
   ```

2. **Configure session limits** based on your app's needs:
   ```swift
   DownloadManager.shared.maxConcurrentSessions = 5 // For memory-constrained devices
   ```

3. **Clean up completed sessions** regularly:
   ```swift
   // Remove old completed sessions
   let sessions = downloadManager.getAllSessions()
   for session in sessions where session.isCompleted {
       downloadManager.removeSession(id: session.id)
   }
   ```

### Error Handling

1. **Always handle session creation errors**:
   ```swift
   do {
       let session = try downloadManager.createSession(urls: urls)
   } catch FreeTokenError.downloadSessionLimitExceeded(let limit) {
       print("Too many active sessions (limit: \(limit))")
       // Clean up old sessions or increase limit
   } catch FreeTokenError.downloadSessionDestinationNotWritable(let path) {
       print("Cannot write to: \(path)")
       // Check permissions or choose different destination
   } catch {
       print("Unexpected error: \(error)")
   }
   ```

2. **Handle session completion failures**:
   ```swift
   session.completionHandler = { result in
       switch result {
       case .success:
           // All downloads succeeded
           self.processDownloadedFiles()
       case .failure(let error):
           if let ftError = error as? FreeTokenError {
               switch ftError {
               case .downloadSessionFailed(let sessionID, let failed, let total):
                   print("Session \(sessionID): \(failed)/\(total) downloads failed")
                   // Retry failed downloads or show error
               default:
                   print("Session error: \(error)")
               }
           }
       }
   }
   ```

### Performance

1. **Use session IDs consistently** for recovery:
   ```swift
   let sessionID = "models-\(appVersion)" // Version-specific downloads
   ```

2. **Monitor progress efficiently**:
   ```swift
   // Use built-in progress handlers instead of polling
   downloadManager.startSessionDownloads(sessionID: sessionID) { progress in
       // This is called automatically when progress changes
       updateUI(progress: progress)
   }
   ```

3. **Validate file destinations** before creating sessions:
   ```swift
   // Check write permissions before starting downloads
   let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
   if !FileManager.default.isWritableFile(atPath: documentsPath.path) {
       // Handle permission error
   }
   ```

## Troubleshooting

### Common Issues

#### Downloads Not Resuming After App Restart

**Problem**: Downloads don't automatically resume when the app restarts.

**Solution**: Make sure you call `FreeToken.attachDownloadSession()` early in your app lifecycle:

```swift
// AppDelegate or SwiftUI App init
FreeToken.attachDownloadSession()

// Then recover existing sessions
let sessionIDs = ["models", "documents", "assets"]
for sessionID in sessionIDs {
    if let session = downloadManager.recoverSession(id: sessionID) {
        if !session.isCompleted {
            downloadManager.startSessionDownloads(sessionID: sessionID)
        }
    }
}
```

#### Background Downloads Not Working on iOS

**Problem**: Downloads don't continue when app goes to background.

**Solution**: Ensure proper AppDelegate integration:

```swift
func application(_ application: UIApplication,
               handleEventsForBackgroundURLSession identifier: String,
               completionHandler: @escaping () -> Void) {
    FreeToken.handleBackgroundDownloads(identifier: identifier, completionHandler: completionHandler)
}
```

#### Session Limit Exceeded

**Problem**: Cannot create new sessions due to limit.

**Solution**: Clean up old sessions or increase the limit:

```swift
// Option 1: Increase limit
DownloadManager.shared.maxConcurrentSessions = 20

// Option 2: Clean up completed sessions
let summary = downloadManager.getSessionSummary()
if summary.completedSessions > 0 {
    let sessions = downloadManager.getAllSessions()
    for session in sessions where session.isCompleted {
        downloadManager.removeSession(id: session.id)
    }
}
```

#### Progress Showing 0% Despite Active Downloads

**Problem**: Progress remains at 0% even when downloads are active.

**Solution**: This usually means downloads have unknown file sizes. Check if your URLs provide `Content-Length` headers:

```swift
// Check session details
let session = downloadManager.getSession(id: "my-session")
let details = session?.getProgressDetails()
print("Unknown size downloads: \(details?.unknownSizeCount ?? 0)")

// Unknown-size downloads don't contribute to progress percentage
// but you can still track bytes downloaded:
print("Bytes downloaded: \(session?.downloadedBytes ?? 0)")
```

### Debug Utilities

The system provides several debug utilities:

```swift
// Print detailed session information (debug builds only)
downloadManager.debugPrintAllSessions()

// Get summary statistics
let summary = downloadManager.getSessionSummary()
print("Sessions: \(summary.totalSessions), Success rate: \(summary.successRate)%")

// Validate and fix session integrity
let report = downloadManager.validateAndCleanupSessions()
if report.hasIssues {
    print("Found issues: \(report.issues)")
    if report.hasFixes {
        print("Applied fixes: \(report.fixes)")
    }
}

// NOTE: The library previously emitted very verbose per-update progress logs (prefixed with `🧪S progress`).
// Those verbose console lines have been removed to reduce log noise. If you need detailed emission
// diagnostics for testing or debugging, use the session-level API `DownloadSession.getProgressEmissionStats()`
// which returns counts of attempted/delivered/suppressed progress emissions.
```

### Error Codes

The system uses standardized error codes in the 8000 range:

- `8000`: Session not found
- `8001`: Session failed  
- `8002`: Invalid session state
- `8003`: Session recovery failed
- `8004`: Background processing failed
- `8005`: Destination not writable
- `8006`: Session limit exceeded
- `8007`: Hash verification failed

## Platform-Specific Notes

### iOS
- Supports full background download functionality
- Requires AppDelegate integration for background completion
- Background processing time is limited (~30 seconds)
- Background App Refresh must be enabled

### macOS  
- Background downloads work automatically
- No special AppDelegate handling required
- Longer background processing time available

### tvOS/watchOS/visionOS
- Background downloads supported with same iOS patterns
- May have different power/network constraints

## Migration Guide

If you're upgrading from the legacy download system:

### Before (Legacy)
```swift
// Old individual download approach
downloadManager.startDownload(url: url) { progress in
    // Individual progress only
} completion: { result in
    // Individual completion only
}
```

### After (Session-Based)
```swift
// New session-based approach
let session = try downloadManager.createSession(urls: [url])
downloadManager.startSessionDownloads(sessionID: session.id) { progress in
    // Collective progress across all downloads
}
```

### Benefits of Migration
- Collective progress tracking across multiple files
- Automatic persistence and recovery
- Better memory management
- Enhanced error handling with recovery suggestions
- Background download support

---

The FreeToken Download Session System provides a robust, production-ready solution for managing complex download scenarios in iOS and macOS applications. Its session-based approach, combined with automatic recovery and background support, makes it ideal for downloading AI models, app resources, documents, and other multi-file scenarios.
