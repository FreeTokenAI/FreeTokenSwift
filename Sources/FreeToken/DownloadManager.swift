//
//  DownloadManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 8/18/25.
//


import Foundation
import CryptoKit

extension FreeToken {
    public class DownloadManager: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        public static let shared = DownloadManager()
        
        private var session: URLSession!
        private let sessionIdentifier = "ai.freetoken.downloadManager"
        
        /// Resume data expiration interval in seconds (default: 24 hours)
        /// Downloads can be resumed within this timeframe after interruption
        public var resumeDataExpirationInterval: TimeInterval = 86400 // 24 hours
        
        /// Maximum number of concurrent download sessions allowed (default: 10)
        /// Prevents unbounded session growth and memory issues
        public var maxConcurrentSessions: Int = 10
        
        // Track completion handlers for individual direct (non-session) downloads
        private var completionHandlers: [URL: (Result<URL, Error>) -> Void] = [:]
        private var activeDownloads: [URL: URLSessionDownloadTask] = [:]
        
        // Session-based download management
        private var activeSessions: [String: DownloadSession] = [:]
        private var urlToSessionMap: [URL: String] = [:]
        private let sessionQueue = DispatchQueue(label: "ai.freetoken.downloadManager.sessions", attributes: .concurrent)
        
        private let progressQueue = DispatchQueue(label: "ai.freetoken.downloadManager.progress", attributes: .concurrent)
        
        
        // Persistent state storage
        private let persistentStateKey = "ai.freetoken.downloadManager.state"
        private let resumeDataKey = "ai.freetoken.downloadManager.resumeData"
        
        // Background download handling (iOS-specific)
#if os(iOS)
        private var backgroundCompletionHandler: (() -> Void)?
        
        // Background completion callbacks
        /// Called when a download session completes while app is backgrounded
        public var onBackgroundSessionCompletion: ((String) -> Void)?
        
        /// Called when all background downloads finish processing
        public var onAllBackgroundDownloadsComplete: (() -> Void)?
#endif
        
        private override init() {
            super.init()
            attachSession()
        }

        // MARK: - Base Root Directory Helpers (Relative Path Persistence)

        /// Returns the stable root directory under which all managed downloads live.
        /// On iOS-family platforms this is the current sandbox's Application Support directory;
        /// on macOS it's the user's home directory. All persisted destination paths are stored
        /// relative to this root so they remain valid across sandbox UUID changes (iOS) or
        /// application reinstalls.
        static func baseRootDirectory() -> String {
#if os(iOS)
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
#else
            return FileManager.default.homeDirectoryForCurrentUser.path
#endif
        }

        /// Convert an absolute on-disk path to a relative path (if it resides inside the base root).
        /// If the path is outside the base root, the original absolute path is returned to avoid
        /// accidental relocation on restore.
        static func relativePathForPersistence(absolutePath: String) -> String {
            let base = baseRootDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanedAbs = absolutePath
            if cleanedAbs.hasPrefix(base + "/") {
                return String(cleanedAbs.dropFirst(base.count + 1))
            }
            // Common iOS case: full sandbox path containing Application Support – strip up to and including it.
            if let range = cleanedAbs.range(of: "Application Support/") {
                let after = cleanedAbs[range.upperBound...]
                return String(after)
            }
            return cleanedAbs
        }

        /// Produce an absolute path from a persisted path value. If the persisted path was
        /// already absolute (legacy metadata) but belongs to an old sandbox, we attempt to
        /// relocate it by trimming everything before the first "Application Support/" (iOS) or
        /// the first ".FreeToken" component (macOS) and re-attaching to the current base root.
        static func absolutePathFromPersisted(_ persisted: String) -> String {
            // If already absolute and appears to live inside current sandbox/home, trust it.
            if persisted.hasPrefix("/") {
                // iOS sandbox UUID may have changed; attempt repair.
#if os(iOS)
                if persisted.contains("Application Support/") {
                    // Extract relative portion after Application Support/
                    if let range = persisted.range(of: "Application Support/") {
                        let relative = String(persisted[range.upperBound...])
                        return (baseRootDirectory() as NSString).appendingPathComponent(relative)
                    }
                }
                return persisted // fallback
#else
                if let range = persisted.range(of: ".FreeToken") { // keep from .FreeToken forward
                    let tail = String(persisted[range.lowerBound...])
                    return (baseRootDirectory() as NSString).appendingPathComponent(tail)
                }
                return persisted
#endif
            }
            // Relative path – append to base root.
            return (baseRootDirectory() as NSString).appendingPathComponent(persisted)
        }
        
        /// Attaches or reattaches the background URL session with the predefined identifier.
        /// This should be called early in app launch to ensure background downloads can resume
        /// and pending delegate callbacks are received.
        func attachSession() {
            let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            config.waitsForConnectivity = true
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            FreeToken.shared.logger("✅ Background URLSession attached (entitlement check will happen on first download)", .info)
            
            // Clean up expired resume data
            cleanupExpiredResumeData()
            
            // Clean up old session metadata
            SessionStorage.cleanupOldSessions()
            
            // Recover download sessions
            recoverSessions()
            
            // Recover any existing download tasks after session reattachment (legacy support)
            recoverExistingTasks()
        }
        
        /// Starts or reattaches a direct single-file download (legacy simple API without progress callback).
        /// For grouped progress use a `DownloadSession` instead.
        func startDownload(
            url: URL,
            completion: @escaping @Sendable (Result<URL, Error>) -> Void
        ) {
            // Check if we already have an active download for this URL
            if activeDownloads[url] != nil {
                FreeToken.shared.logger("Reattaching to existing in-memory task for: \(url.absoluteString)", .info)
                completionHandlers[url] = completion
                // (Per-file progress callback removed)
                return
            }
            
            // Check if the session has an existing task for this URL (after app relaunch)
            session.getAllTasks { [weak self] tasks in
                guard let self = self else { return }
                
                // Look for existing download task with matching URL
                for task in tasks {
                    if let downloadTask = task as? URLSessionDownloadTask,
                       let taskURL = downloadTask.originalRequest?.url,
                       taskURL == url {
                        
                        FreeToken.shared.logger("Found existing session task for: \(url.absoluteString)", .info)
                        self.activeDownloads[url] = downloadTask
                        self.completionHandlers[url] = completion
                        // (Per-file progress callback removed)
                        return
                    }
                }
                
                // No existing task found, check for resume data before creating new task
                if let resumeState = self.loadResumeData(for: url) {
                    FreeToken.shared.logger("🔄 Resuming download from \(resumeState.lastProgress * 100)% for: \(url.absoluteString)", .info)
                    let resumeTask = self.session.downloadTask(withResumeData: resumeState.resumeData)
                    resumeTask.resume()
                    self.activeDownloads[url] = resumeTask
                    self.completionHandlers[url] = completion
                    
                    // (Per-file progress callback removed)
                    
                    // Remove resume data since we're now actively downloading
                    self.removeResumeData(for: url)
                    
                    // Save current state
                    self.savePersistentState(for: url, progress: resumeState.lastProgress)
                } else {
                    // No resume data, create a fresh download
                    FreeToken.shared.logger("🆕 Starting new download task for: \(url.absoluteString)", .info)
                    let newTask = self.session.downloadTask(with: url)
                    newTask.resume()
                    self.activeDownloads[url] = newTask
                    self.completionHandlers[url] = completion
                    
                    // Save initial state for resume logic
                    self.savePersistentState(for: url, progress: 0.0)
                }
            }
        }
        
        // MARK: URLSessionDownloadDelegate
        
        public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
            guard let url = downloadTask.originalRequest?.url else { return }
            
            do {
                let fileManager = FileManager.default
                
                // Get the destination path from the session download item
                let sessionInfo = sessionQueue.sync {
                    return (sessionID: urlToSessionMap[url], session: activeSessions[urlToSessionMap[url] ?? ""])
                }
                
                let destinationURL: URL
                if let downloadSession = sessionInfo.session,
                   let downloadItem = downloadSession.getDownload(for: url) {
                    // Use the destination path set during session creation (may be custom directory)
                    destinationURL = URL(fileURLWithPath: downloadItem.destinationPath)
                    FreeToken.shared.logger("📍 Using session-defined destination path: \(destinationURL.path)", .debug)
                } else {
                    // Fallback to default Documents directory for non-session downloads
                    FreeToken.shared.logger("⚠️ No session found for \(url.absoluteString), using default Documents directory", .warning)
                    destinationURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(url.lastPathComponent)
                }
                
                // Create parent directory if needed
                let parentDirectory = destinationURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentDirectory.path) {
                    FreeToken.shared.logger("📂 Creating parent directory: \(parentDirectory.path)", .debug)
                    try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
                }
                
                var finalDestinationURL = destinationURL

                // Capture initial intent for diagnostics
                FreeToken.shared.logger("📥 Download temp file ready. Initial destinationPath=\(destinationURL.path)", .debug)

                // If the CDN produced a hashed filename, prefer the server's suggested filename (e.g., original repo path file)
                if let suggested = downloadTask.response?.suggestedFilename,
                    !suggested.isEmpty,
                    suggested != destinationURL.lastPathComponent {
                        let candidate = destinationURL.deletingLastPathComponent().appendingPathComponent(suggested)
                        FreeToken.shared.logger("🔄 Considering suggested filename: \(suggested) ⇒ \(candidate.path)", .debug)
                        finalDestinationURL = candidate
                }

                // SAFEGUARD: If the computed final destination currently points to an existing directory
                // (e.g., a sanitized repo folder) we must not overwrite that directory. Instead, place
                // the file *inside* that directory using a safe filename (suggested, or lastPathComponent, or a fallback).
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: finalDestinationURL.path, isDirectory: &isDir), isDir.boolValue {
                    let suggested = downloadTask.response?.suggestedFilename
                    let safeName: String = suggested?.isEmpty == false ? suggested! : url.lastPathComponent.isEmpty ? "downloaded-file" : url.lastPathComponent
                    let adjusted = finalDestinationURL.appendingPathComponent(safeName)
                    FreeToken.shared.logger("⚠️ Destination path resolves to existing directory. Adjusting file target to \(adjusted.path)", .warning)
                    finalDestinationURL = adjusted
                }

                // Additional guard: If finalDestinationURL still has no file extension and suggested filename had one, append it.
                if finalDestinationURL.pathExtension.isEmpty,
                    let suggested = downloadTask.response?.suggestedFilename {
                    let suggestedExt = URL(fileURLWithPath: suggested).pathExtension
                    if !suggestedExt.isEmpty {
                        // Only adjust if the basename matches sanitized repo name (likely directory mis-detection)
                        let baseLast = finalDestinationURL.lastPathComponent
                        if baseLast == baseLast.replacingOccurrences(of: ".", with: "") { // crude check for no dots in base
                            let withExt = finalDestinationURL.appendingPathExtension(suggestedExt)
                            FreeToken.shared.logger("🛠️ Added missing extension '.\(suggestedExt)' to destination ⇒ \(withExt.path)", .debug)
                            finalDestinationURL = withExt
                        }
                    }
                }

                // Ensure parent directory exists for (potentially) adjusted path
                let finalParent = finalDestinationURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: finalParent.path) {
                    FreeToken.shared.logger("📂 Creating final parent directory: \(finalParent.path)", .debug)
                    try fileManager.createDirectory(at: finalParent, withIntermediateDirectories: true, attributes: nil)
                }
                FreeToken.shared.logger("📍 Final file destination decided: \(finalDestinationURL.path)", .debug)
                
                // Remove existing file if it exists at final destination
                if fileManager.fileExists(atPath: finalDestinationURL.path) {
                    FreeToken.shared.logger("⚠️ Removing existing file at destination: \(finalDestinationURL.path)", .warning)
                    try? fileManager.removeItem(at: finalDestinationURL)
                }
                
                FreeToken.shared.logger("📥 Moving downloaded file from \(location.path) to \(finalDestinationURL.path)", .info)
                try fileManager.moveItem(at: location, to: finalDestinationURL)
                
                FreeToken.shared.logger("✅ Download completed successfully for \(finalDestinationURL.lastPathComponent)", .info)
                
                // Enhanced logging for session recovery troubleshooting
                if let sessionID = sessionInfo.sessionID, sessionInfo.session == nil {
                    FreeToken.shared.logger("⚠️ Session \(sessionID) not found in activeSessions during didFinishDownloadingTo for \(url.lastPathComponent)", .warning)
                    FreeToken.shared.logger("📋 Available sessions: \(Array(activeSessions.keys).joined(separator: ", "))", .debug)
                }
                
                if let _ = sessionInfo.sessionID,
                   let downloadSession = sessionInfo.session {
                    let finalPath = finalDestinationURL.path // capture immutably for thread safety
                    downloadSession.updateDownload(for: url) { downloadItem in
                        // Update destination path if renamed
                        if finalPath != downloadItem.destinationPath {
                            downloadItem.destinationPath = finalPath
                        }
                        // Update final progress values from task before completion
                        if let task = downloadItem.task {
                            downloadItem.bytesWritten = task.countOfBytesReceived
                            if task.countOfBytesExpectedToReceive > 0 {
                                downloadItem.bytesExpected = task.countOfBytesExpectedToReceive
                            }
                        }
                        
                        // Perform hash verification if expected hash is provided
                        var actualHash: String?
                        var hashVerified: Bool?
                        var finalState: DownloadState = .completed
                        var errorInfo: ErrorInfo?
                        
                        if let expectedSHA256 = downloadItem.expectedSHA256 {
                            // Use the actual final file location for verification (after potential rename)
                            let verification = self.verifyFileHash(filePath: finalPath, expectedHash: expectedSHA256)
                            actualHash = verification.actualHash
                            hashVerified = verification.verified
                            
                            if !verification.verified {
                                finalState = .failed
                                FreeToken.shared.logger("❌ Hash verification failed for \(url.lastPathComponent)", .error)
                                let hashError = FreeTokenError.downloadHashVerificationFailed(
                                    url: url.absoluteString,
                                    expected: expectedSHA256,
                                    actual: verification.actualHash ?? "unknown"
                                )
                                errorInfo = ErrorInfo(from: hashError)
                            }
                        }
                        
                        downloadItem.state = finalState
                        downloadItem.completionInfo = CompletionInfo(
                            state: finalState,
                            totalBytes: downloadItem.bytesWritten,
                            filePath: finalPath,
                            errorInfo: errorInfo,
                            actualSHA256: actualHash,
                            hashVerified: hashVerified
                        )
                    }
                    
                    // Check if this was the last download and clear progress handler immediately
                    let downloads = downloadSession.getDownloads()
                    let allTerminal = downloads.allSatisfy { $0.state == .completed || $0.state == .failed }
                    if allTerminal && !downloads.isEmpty {
                        FreeToken.shared.logger("🔄 All downloads terminal - clearing progress handler for session: \(downloadSession.id)", .info)
                        downloadSession.progressHandler = nil
                    }
                    
                    // Save session metadata with completion
                    let metadata = SessionMetadata(from: downloadSession)
                    SessionStorage.save(metadata)
                    
                    // Check if session is now complete and trigger completion handler
                    checkAndTriggerSessionCompletion(session: downloadSession)
                }
                
                completionHandlers[url]?(.success(finalDestinationURL))
            } catch {
                FreeToken.shared.logger("❌ Failed to move downloaded file for \(url.absoluteString): \(error.localizedDescription)", .error)
                
                // Update session with failure if this URL belongs to one (thread-safe access)
                let sessionInfo = sessionQueue.sync {
                    return (sessionID: urlToSessionMap[url], session: activeSessions[urlToSessionMap[url] ?? ""])
                }
                
                if let _ = sessionInfo.sessionID,
                   let downloadSession = sessionInfo.session {
                    downloadSession.updateDownload(for: url) { downloadItem in
                        // Update final progress values from task before marking as failed
                        if let task = downloadItem.task {
                            downloadItem.bytesWritten = task.countOfBytesReceived
                            if task.countOfBytesExpectedToReceive > 0 {
                                downloadItem.bytesExpected = task.countOfBytesExpectedToReceive
                            }
                        }
                        
                        downloadItem.state = .failed
                        downloadItem.completionInfo = CompletionInfo(
                            state: .failed,
                            totalBytes: downloadItem.bytesWritten,
                            errorInfo: ErrorInfo(from: error)
                        )
                    }
                    
                    // Check if this was the last download and clear progress handler immediately
                    let downloads = downloadSession.getDownloads()
                    let allTerminal = downloads.allSatisfy { $0.state == .completed || $0.state == .failed }
                    if allTerminal && !downloads.isEmpty {
                        FreeToken.shared.logger("🔄 All downloads terminal - clearing progress handler for session: \(downloadSession.id)", .info)
                        downloadSession.progressHandler = nil
                    }
                    
                    // Save session metadata with failure
                    let metadata = SessionMetadata(from: downloadSession)
                    SessionStorage.save(metadata)
                    
                    // Check if session is now complete and trigger completion handler
                    checkAndTriggerSessionCompletion(session: downloadSession)
                }
                
                completionHandlers[url]?(.failure(error))
            }
            
            cleanupSuccess(for: url) // Use cleanupSuccess to remove resume data
        }
        
        public func urlSession(_ session: URLSession, task: URLSessionTask,
                               didCompleteWithError error: Error?) {
            guard let url = task.originalRequest?.url else { return }
            
            if let error = error {
                let nsError = error as NSError
                
                // Check if this is a resumable error (network issues, timeouts, etc.)
                let resumableErrorCodes: Set<Int> = [
                    NSURLErrorTimedOut,
                    NSURLErrorNetworkConnectionLost,
                    NSURLErrorNotConnectedToInternet,
                    NSURLErrorInternationalRoamingOff,
                    NSURLErrorDataNotAllowed,
                    NSURLErrorCancelled
                ]
                
                // Non-resumable errors (client/server errors)
                let nonResumableErrorCodes: Set<Int> = [
                    NSURLErrorBadURL,
                    NSURLErrorUnsupportedURL,
                    NSURLErrorHTTPTooManyRedirects,
                    NSURLErrorUserCancelledAuthentication,
                    NSURLErrorUserAuthenticationRequired,
                    NSURLErrorResourceUnavailable,
                    NSURLErrorBadServerResponse
                ]
                
                var resumeData: Data?
                
                if resumableErrorCodes.contains(nsError.code) {
                    FreeToken.shared.logger("⚠️ Download failed with resumable error for \(url.absoluteString): \(error.localizedDescription)", .warning)
                    
                    // Try to extract resume data from the error
                    if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        let currentProgress = loadPersistentProgress(for: url) ?? 0.0
                        let existingRetryCount = loadResumeData(for: url)?.retryCount ?? 0
                        
                        // Only save resume data if we haven't exceeded retry limit
                        if existingRetryCount < 3 {
                            saveResumeData(data, for: url, lastProgress: currentProgress, retryCount: existingRetryCount + 1)
                            FreeToken.shared.logger("💾 Saved resume data for \(url.absoluteString) (retry count: \(existingRetryCount + 1))", .info)
                            resumeData = data
                        } else {
                            FreeToken.shared.logger("❌ Exceeded retry limit for \(url.absoluteString), not saving resume data", .warning)
                        }
                    }
                } else if nonResumableErrorCodes.contains(nsError.code) {
                    FreeToken.shared.logger("🔴 Download failed with non-resumable error for \(url.absoluteString): \(error.localizedDescription)", .error)
                    // Remove any existing resume data for non-resumable errors
                    removeResumeData(for: url)
                } else {
                    // Unknown error code, treat as potentially resumable
                    FreeToken.shared.logger("❓ Download failed with unknown error code \(nsError.code) for \(url.absoluteString): \(error.localizedDescription)", .warning)
                    
                    if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        let currentProgress = loadPersistentProgress(for: url) ?? 0.0
                        saveResumeData(data, for: url, lastProgress: currentProgress)
                        resumeData = data
                    }
                }
                
                // Update session if this URL belongs to one (thread-safe access)
                let sessionInfo = sessionQueue.sync {
                    return (sessionID: urlToSessionMap[url], session: activeSessions[urlToSessionMap[url] ?? ""])
                }
                
                // Enhanced logging for session recovery troubleshooting
                if let sessionID = sessionInfo.sessionID, sessionInfo.session == nil {
                    FreeToken.shared.logger("⚠️ Session \(sessionID) not found in activeSessions during didCompleteWithError for \(url.lastPathComponent)", .warning)
                    FreeToken.shared.logger("📋 Available sessions: \(Array(activeSessions.keys).joined(separator: ", "))", .debug)
                }
                
                if let _ = sessionInfo.sessionID,
                   let downloadSession = sessionInfo.session {
                    let capturedResumeData = resumeData // Capture for use in concurrent code
                    downloadSession.updateDownload(for: url) { downloadItem in
                        // Update final progress values from task before marking as failed
                        if let task = downloadItem.task {
                            downloadItem.bytesWritten = task.countOfBytesReceived
                            if task.countOfBytesExpectedToReceive > 0 {
                                downloadItem.bytesExpected = task.countOfBytesExpectedToReceive
                            }
                        }
                        
                        downloadItem.state = .failed
                        downloadItem.completionInfo = CompletionInfo(
                            state: .failed,
                            totalBytes: downloadItem.bytesWritten,
                            errorInfo: ErrorInfo(from: error),
                            resumeData: capturedResumeData
                        )
                    }
                    
                    // Check if this was the last download and clear progress handler immediately
                    let downloads = downloadSession.getDownloads()
                    let allTerminal = downloads.allSatisfy { $0.state == .completed || $0.state == .failed }
                    if allTerminal && !downloads.isEmpty {
                        FreeToken.shared.logger("🔄 All downloads terminal - clearing progress handler for session: \(downloadSession.id)", .info)
                        downloadSession.progressHandler = nil
                    }
                    
                    // Save session metadata with failure
                    let metadata = SessionMetadata(from: downloadSession)
                    SessionStorage.save(metadata)
                    
                    // Check if session is now complete and trigger completion handler
                    checkAndTriggerSessionCompletion(session: downloadSession)
                }
                
                completionHandlers[url]?(.failure(error))
            }
            
            cleanup(for: url)
        }
        
        public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64,
                               totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
            guard let url = downloadTask.originalRequest?.url else { return }
            
            // Only calculate progress for downloads with known file sizes
            let progressValue: Double?
            if totalBytesExpectedToWrite > 0 {
                progressValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            } else {
                // Skip progress calculation for unknown file sizes - they're excluded from collective progress
                progressValue = nil
                FreeToken.shared.logger("📊 Download progress update skipped for unknown size file: \(url.lastPathComponent) (\(totalBytesWritten) bytes written)", .debug)
            }
            
            // Update session download progress if this URL belongs to a session (thread-safe access)
            let sessionInfo = sessionQueue.sync {
                return (sessionID: urlToSessionMap[url], session: activeSessions[urlToSessionMap[url] ?? ""])
            }
            
            // Enhanced logging for session recovery troubleshooting
            if let sessionID = sessionInfo.sessionID, sessionInfo.session == nil {
                FreeToken.shared.logger("⚠️ Session \(sessionID) not found in activeSessions during didWriteData for \(url.lastPathComponent)", .warning)
                FreeToken.shared.logger("📋 Available sessions: \(Array(activeSessions.keys).joined(separator: ", "))", .debug)
            }
            
            if let session = sessionInfo.session {
                
                // Skip progress updates for sessions that are already completed/failed
                if session.state == .completed || session.state == .failed {
                    return
                }
                session.updateDownload(for: url) { downloadItem in
                    downloadItem.bytesWritten = totalBytesWritten
                    downloadItem.bytesExpected = totalBytesExpectedToWrite
                    downloadItem.state = .downloading
                    // Store task reference for real-time progress calculations
                    downloadItem.task = downloadTask
                }
            }
            
            // Persist per-file progress for resume (still useful)
            if let progressValue = progressValue { savePersistentState(for: url, progress: progressValue) }
        }
        
        // Called when all background URL session events have been delivered
        public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            FreeToken.shared.logger("🔄 Background URL session finished events", .info)
            
            // Process any final session updates
            processBackgroundCompletedSessions()
            
            // Notify app that all background downloads have finished processing
            #if os(iOS)
            onAllBackgroundDownloadsComplete?()
            
            // Call the iOS system completion handler
            if let handler = backgroundCompletionHandler {
                DispatchQueue.main.async {
                    FreeToken.shared.logger("✅ Calling background completion handler", .info)
                    handler()
                    self.backgroundCompletionHandler = nil
                }
            } else {
                FreeToken.shared.logger("⚠️ No background completion handler to call", .warning)
            }
            #endif
            
            FreeToken.shared.logger("✅ All background downloads completed while app was suspended", .info)
        }
        
        // MARK: Helpers
        
        private func cleanup(for url: URL) {
            activeDownloads.removeValue(forKey: url)
            completionHandlers.removeValue(forKey: url)
            removePersistentState(for: url)
            
            // Clear task reference from session to prevent memory leaks
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self,
                      let sessionID = self.urlToSessionMap[url],
                      let session = self.activeSessions[sessionID] else { 
                    self?.urlToSessionMap.removeValue(forKey: url)
                    return 
                }
                
                session.updateDownload(for: url) { downloadItem in
                    downloadItem.task = nil
                }
                self.urlToSessionMap.removeValue(forKey: url)
            }
        }
        
        private func cleanupSuccess(for url: URL) {
            activeDownloads.removeValue(forKey: url)
            completionHandlers.removeValue(forKey: url)
            
            // Clear task reference from session to prevent memory leaks
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self,
                      let sessionID = self.urlToSessionMap[url],
                      let session = self.activeSessions[sessionID] else { return }
                
                session.updateDownload(for: url) { downloadItem in
                    downloadItem.task = nil
                }
            }
            removePersistentState(for: url)
            removeResumeData(for: url) // Remove resume data on successful completion
            
            // Update session completion if this URL belongs to one
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self,
                      let sessionID = self.urlToSessionMap[url],
                      let session = self.activeSessions[sessionID] else { return }
                
                session.updateDownload(for: url) { downloadItem in
                    downloadItem.state = .completed
                    downloadItem.completionInfo = CompletionInfo(
                        state: .completed,
                        totalBytes: downloadItem.bytesWritten,
                        filePath: nil // Will be set by caller
                    )
                }
                self.urlToSessionMap.removeValue(forKey: url)
            }
        }
        
        /// Recovers existing download tasks after session reattachment
        private func recoverExistingTasks() {
            session.getAllTasks { [weak self] tasks in
                guard let self = self else { return }
                
                FreeToken.shared.logger("Recovering \(tasks.count) existing tasks", .info)
                
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let url = downloadTask.originalRequest?.url else {
                        continue
                    }
                    
                    FreeToken.shared.logger("Recovered download task for: \(url.absoluteString)", .info)
                    self.activeDownloads[url] = downloadTask
                    
                    // Restore progress if we have persistent state
                    if let persistentProgress = self.loadPersistentProgress(for: url) {
                        FreeToken.shared.logger("Restored progress \(persistentProgress * 100)% for: \(url.absoluteString)", .info)
                        // We'll report this progress when handlers are reattached
                    }
                }

                // After reattaching raw tasks, run an existing-file check for each active session so
                // sessions that were fully downloaded while the app was terminated are immediately
                // reflected as completed and won't start redundant network work.
                self.sessionQueue.async { [weak self] in
                    guard let self = self else { return }
                    for session in self.activeSessions.values {
                        // Skip if session already marked completed
                        if session.state == .completed { continue }
                        self.checkExistingFiles(for: session)
                        if session.getDownloads().allSatisfy({ $0.state == .completed }) {
                            session.state = .completed
                            FreeToken.shared.logger("♻️ Recovered completed session: \(session.id) (all files present)", .info)
                            let metadata = SessionMetadata(from: session)
                            SessionStorage.save(metadata)
                        }
                    }
                }
            }
        }
        
        // MARK: Persistent State Management
        
        private struct DownloadItemState: Codable {
            let url: URL
            let lastProgress: Double
            let timestamp: Date
        }
        
        private struct ResumeDataState: Codable {
            let url: URL
            let resumeData: Data
            let timestamp: Date
            let lastProgress: Double
            let retryCount: Int
            let expirationInterval: TimeInterval
            
            // Resume data expires after the configured interval
            var isExpired: Bool {
                Date().timeIntervalSince(timestamp) > expirationInterval
            }
            
            // Convenience initializer with default expiration
            init(url: URL, resumeData: Data, timestamp: Date, lastProgress: Double, retryCount: Int, expirationInterval: TimeInterval = 86400) {
                self.url = url
                self.resumeData = resumeData
                self.timestamp = timestamp
                self.lastProgress = lastProgress
                self.retryCount = retryCount
                self.expirationInterval = expirationInterval
            }
        }
        
        private func savePersistentState(for url: URL, progress: Double) {
            var states = loadAllPersistentStates()
            states[url.absoluteString] = DownloadItemState(url: url, lastProgress: progress, timestamp: Date())
            
            if let data = try? JSONEncoder().encode(states) {
                UserDefaults.standard.set(data, forKey: persistentStateKey)
            }
        }
        
        private func loadPersistentProgress(for url: URL) -> Double? {
            let states = loadAllPersistentStates()
            return states[url.absoluteString]?.lastProgress
        }
        
        private func loadAllPersistentStates() -> [String: DownloadItemState] {
            guard let data = UserDefaults.standard.data(forKey: persistentStateKey),
                  let states = try? JSONDecoder().decode([String: DownloadItemState].self, from: data) else {
                return [:]
            }
            return states
        }
        
        private func removePersistentState(for url: URL) {
            var states = loadAllPersistentStates()
            states.removeValue(forKey: url.absoluteString)
            
            if let data = try? JSONEncoder().encode(states) {
                UserDefaults.standard.set(data, forKey: persistentStateKey)
            }
        }
        
        // MARK: Resume Data Management
        
        private func saveResumeData(_ resumeData: Data, for url: URL, lastProgress: Double, retryCount: Int = 0) {
            var resumeStates = loadAllResumeDataStates()
            resumeStates[url.absoluteString] = ResumeDataState(
                url: url,
                resumeData: resumeData,
                timestamp: Date(),
                lastProgress: lastProgress,
                retryCount: retryCount,
                expirationInterval: resumeDataExpirationInterval
            )
            
            if let data = try? JSONEncoder().encode(resumeStates) {
                UserDefaults.standard.set(data, forKey: resumeDataKey)
            }
        }
        
        private func loadResumeData(for url: URL) -> ResumeDataState? {
            let resumeStates = loadAllResumeDataStates()
            let state = resumeStates[url.absoluteString]
            
            // Check if expired
            if let state = state, state.isExpired {
                removeResumeData(for: url)
                return nil
            }
            
            return state
        }
        
        private func loadAllResumeDataStates() -> [String: ResumeDataState] {
            guard let data = UserDefaults.standard.data(forKey: resumeDataKey),
                  let states = try? JSONDecoder().decode([String: ResumeDataState].self, from: data) else {
                return [:]
            }
            return states
        }
        
        private func removeResumeData(for url: URL) {
            var resumeStates = loadAllResumeDataStates()
            resumeStates.removeValue(forKey: url.absoluteString)
            
            if let data = try? JSONEncoder().encode(resumeStates) {
                UserDefaults.standard.set(data, forKey: resumeDataKey)
            }
        }
        
        private func cleanupExpiredResumeData() {
            var resumeStates = loadAllResumeDataStates()
            let originalCount = resumeStates.count
            
            resumeStates = resumeStates.filter { !$0.value.isExpired }
            
            if resumeStates.count < originalCount {
                FreeToken.shared.logger("Cleaned up \(originalCount - resumeStates.count) expired resume data entries", .info)
                
                if let data = try? JSONEncoder().encode(resumeStates) {
                    UserDefaults.standard.set(data, forKey: resumeDataKey)
                }
            }
        }
        
        // MARK: Public Utility Methods
        
        /// Cancels a download for the specified URL
        func cancelDownload(for url: URL) {
            if let task = activeDownloads[url] {
                task.cancel()
                FreeToken.shared.logger("Cancelled download for: \(url.absoluteString)", .info)
            }
            cleanup(for: url)
        }
        
        /// Attempts to resume a previously failed download using stored resume data.
        /// (Per-file progress callback removed; rely on session-level progress.)
        /// - Parameters:
        ///   - url: The URL of the download to resume
        ///   - completion: Completion callback for the resumed download
        /// - Returns: True if resume data was found and download was resumed, false otherwise
        @discardableResult
        func resumeDownload(
            for url: URL,
            completion: @escaping @Sendable (Result<URL, Error>) -> Void
        ) -> Bool {
            // Check if already downloading
            if activeDownloads[url] != nil {
                FreeToken.shared.logger("⚠️ Download already active for: \(url.absoluteString)", .warning)
                return false
            }
            
            // Check for resume data
            guard let resumeState = loadResumeData(for: url) else {
                FreeToken.shared.logger("❌ No resume data found for: \(url.absoluteString)", .warning)
                return false
            }
            
            FreeToken.shared.logger("🔄 Explicitly resuming download from \(resumeState.lastProgress * 100)% for: \(url.absoluteString)", .info)
            
            let resumeTask = session.downloadTask(withResumeData: resumeState.resumeData)
            resumeTask.resume()
            activeDownloads[url] = resumeTask
            completionHandlers[url] = completion
            // (Per-file progress callback removed)
            
            // Remove resume data since we're now actively downloading
            removeResumeData(for: url)
            
            // Save current state
            savePersistentState(for: url, progress: resumeState.lastProgress)
            
            return true
        }
        
        /// Returns whether resume data is available for the specified URL
        func hasResumeData(for url: URL) -> Bool {
            return loadResumeData(for: url) != nil
        }
        
        /// Returns a list of URLs that have resume data available
        func getResumableDownloads() -> [URL] {
            let resumeStates = loadAllResumeDataStates()
            return resumeStates.compactMap { key, state in
                state.isExpired ? nil : state.url
            }
        }
        
        // MARK: Collective Progress Methods (Session-Based)
        
        /// Returns the overall progress of all active sessions as a weighted average
        /// - Returns: Progress value between 0.0 and 1.0, where 1.0 means all sessions are complete
        /// - Note: Only includes downloads with known file sizes in the calculation
        func collectiveProgress() -> Double {
            return sessionQueue.sync { [weak self] in
                guard let self = self else { return 0.0 }
                
                let sessions = Array(self.activeSessions.values)
                guard !sessions.isEmpty else { return 0.0 }
                
                var totalWeightedProgress: Double = 0.0
                var totalWeight: Double = 0.0
                
                // Calculate weighted progress across all sessions
                for session in sessions {
                    let sessionWeight = Double(session.totalBytes)
                    if sessionWeight > 0 {
                        totalWeightedProgress += session.collectiveProgress * sessionWeight
                        totalWeight += sessionWeight
                    }
                }
                
                return totalWeight > 0 ? totalWeightedProgress / totalWeight : 0.0
            }
        }
        
        /// Returns detailed progress information for all active sessions
        func collectiveProgressDetailed() -> (knownSizeProgress: Double, totalBytes: Int64, downloadedBytes: Int64, activeCount: Int, unknownSizeCount: Int) {
            return sessionQueue.sync { [weak self] in
                guard let self = self else { return (0.0, 0, 0, 0, 0) }
                
                let sessions = Array(self.activeSessions.values)
                var totalBytes: Int64 = 0
                var downloadedBytes: Int64 = 0
                var activeCount = 0
                var unknownSizeCount = 0
                
                for session in sessions {
                    totalBytes += session.totalBytes
                    downloadedBytes += session.downloadedBytes
                    activeCount += session.activeCount
                    unknownSizeCount += session.getDownloads().filter { !$0.hasKnownSize }.count
                }
                
                let progress = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0.0
                
                return (progress, totalBytes, downloadedBytes, activeCount, unknownSizeCount)
            }
        }
        
        /// Returns the total number of bytes downloaded across all active sessions
        func totalBytesDownloaded() -> Int64 {
            return sessionQueue.sync { [weak self] in
                guard let self = self else { return 0 }
                return self.activeSessions.values.reduce(0) { $0 + $1.downloadedBytes }
            }
        }
        
        /// Returns the number of active downloads across all sessions
        func activeDownloadCount() -> Int {
            return sessionQueue.sync { [weak self] in
                guard let self = self else { return 0 }
                return self.activeSessions.values.reduce(0) { $0 + $1.activeCount }
            }
        }
        
        /// Cancels all active downloads and clears both in-memory and persisted download state.
        /// This will cancel active URLSession tasks, clear session state in memory, and remove
        /// any persisted resume/persistent state and session metadata.
        public func cancelAllDownloads() {
            let group = DispatchGroup()
            
            // Cancel all active downloads with proper synchronization
            for (url, task) in activeDownloads {
                group.enter()
                task.cancel()
                FreeToken.shared.logger("Cancelled download for: \(url.absoluteString)", .info)
                
                // URLSession task cancellation is immediate, but we need to ensure
                // delegate methods won't be called after we clear session state
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    group.leave()
                }
            }
            
            // Wait for all cancellations to complete
            group.wait()
            
            // Now it's safe to clear state
            activeDownloads.removeAll()
            completionHandlers.removeAll()
            
            // Clear all sessions and session data
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                
                // Update all downloads in sessions to cancelled state
                for session in self.activeSessions.values {
                    for download in session.getDownloads() {
                        session.updateDownload(for: download.url) { downloadItem in
                            downloadItem.state = .cancelled
                        }
                    }
                }
                
                self.activeSessions.removeAll()
                self.urlToSessionMap.removeAll()
            }
            
            // Clear all persistent state
            UserDefaults.standard.removeObject(forKey: persistentStateKey)
            UserDefaults.standard.removeObject(forKey: resumeDataKey)
            
            // Clear session metadata
            let sessionIDs = SessionStorage.getAllSessionIDs()
            for sessionID in sessionIDs {
                SessionStorage.remove(sessionID: sessionID)
            }
            
            // Clean up any remaining stale handlers
            cleanupStaleHandlers()
        }
        
        /// Cleans up orphaned downloads (tasks that exist but have no handlers or sessions)
        func cleanupOrphanedDownloads() {
            session.getAllTasks { [weak self] tasks in
                guard let self = self else { return }
                
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let url = downloadTask.originalRequest?.url else {
                        continue
                    }
                    
                    // Check if task belongs to a session
                    let belongsToSession = self.sessionQueue.sync {
                        return self.urlToSessionMap[url] != nil
                    }
                    
                    // If we have a task but no handlers AND no session, it's orphaned
                          if self.activeDownloads[url] == nil && 
                              self.completionHandlers[url] == nil &&
                       !belongsToSession {
                        
                        FreeToken.shared.logger("⚠️ Found orphaned download task for: \(url.absoluteString), cancelling", .warning)
                        downloadTask.cancel()
                        self.removePersistentState(for: url)
                    }
                }
                
                // Clean up stale handlers after orphaned task cleanup
                DispatchQueue.main.async {
                    self.cleanupStaleHandlers()
                }
            }
        }

        /// Remove all persisted DownloadSession metadata and related persistent state from UserDefaults.
        /// This removes keys managed by the DownloadManager plus any stored session metadata saved via SessionStorage.
        public func removeAllPersistedDownloadSessions() {
            // Remove saved persistent manager state
            UserDefaults.standard.removeObject(forKey: persistentStateKey)
            UserDefaults.standard.removeObject(forKey: resumeDataKey)

            // Remove persisted session metadata saved under SessionStorage
            let sessionIDs = SessionStorage.getAllSessionIDs()
            if sessionIDs.isEmpty == false {
                FreeToken.shared.logger("🗑️ Removing \(sessionIDs.count) persisted download session(s)", .info)
                for sessionID in sessionIDs {
                    SessionStorage.remove(sessionID: sessionID)
                }
            }
        }
        
        /// Returns the current status of all downloads
        func getDownloadStatus() -> [URL: String] {
            var status: [URL: String] = [:]
            
            for (url, task) in activeDownloads {
                switch task.state {
                case .running:
                    status[url] = "running"
                case .suspended:
                    status[url] = "suspended"
                case .canceling:
                    status[url] = "canceling"
                case .completed:
                    status[url] = "completed"
                @unknown default:
                    status[url] = "unknown"
                }
            }
            
            return status
        }
        
        // MARK: - Session Management
        
        /// Create a new download session with the specified URLs
        /// - Parameters:
        ///   - urls: URLs to download in this session
        ///   - sessionID: Optional custom session ID (generates UUID if nil)
        ///   - completion: Called when all downloads in the session complete
        /// - Returns: The created download session
        /// Creates a new download session with multiple URLs
        /// 
        /// Groups related downloads together for collective progress tracking and session-based
        /// management. All downloads in a session share the same lifecycle and can be recovered
        /// together after app restart.
        /// 
        /// - Parameters:
        ///   - urls: Array of URLs to download in this session
        ///   - sessionID: Optional custom session identifier. If nil, generates UUID
        ///   - sha256Hashes: Optional dictionary mapping URLs to expected SHA-256 hashes for verification
        ///   - destinationDirectory: Optional directory where all files should be saved. If nil, uses Documents directory
        ///   - completion: Optional callback called when entire session completes or fails
        /// - Returns: The created `DownloadSession` for immediate use
        /// - Note: Session is automatically persisted for recovery after app restart
        func createSession(
            urls: [URL],
            sessionID: String? = nil,
            sha256Hashes: [URL: String] = [:],
            destinationDirectory: String? = nil,
            completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
        ) throws -> DownloadSession {
            let id = sessionID ?? UUID().uuidString
            
            FreeToken.shared.logger("📦 Creating download session: \(id) with \(urls.count) URLs", .info)
            if !sha256Hashes.isEmpty {
                FreeToken.shared.logger("🔐 Hash verification enabled for \(sha256Hashes.count) downloads", .info)
            }
            
            // Create and validate destination directory if provided (support relative paths).
            var expandedDestinationDirectory: String?
            if let destDir = destinationDirectory {
                var expanded = NSString(string: destDir).expandingTildeInPath
                if !expanded.hasPrefix("/") { // treat as relative to base root
                    expanded = (Self.baseRootDirectory() as NSString).appendingPathComponent(expanded)
                }
                expandedDestinationDirectory = expanded
                try createDirectoryIfNeeded(expanded)
                FreeToken.shared.logger("📁 Session destination directory (resolved): \(expanded)", .info)
            }
            
            // Enforce session limits
            let currentSessionCount = getAllSessions().count
            if currentSessionCount >= maxConcurrentSessions {
                // Try to clean up completed/failed sessions first
                enforceSessionLimits()
                
                // Check again after cleanup
                let updatedSessionCount = getAllSessions().count
                if updatedSessionCount >= maxConcurrentSessions {
                    FreeToken.shared.logger("❌ Session limit exceeded: \(updatedSessionCount)/\(maxConcurrentSessions)", .error)
                    throw FreeTokenError.downloadSessionLimitExceeded(maxConcurrentSessions)
                }
            }
            
            // Use a dedicated serial queue for progress callbacks to avoid main-thread batching delays during tests
            let progressQueue = DispatchQueue(label: "ai.freetoken.downloadSession.progressCallbacks.\(id)")
            let session = DownloadSession(id: id, progressCallbackQueue: progressQueue)
            session.completionHandler = completion
            
            // Add session to active sessions
            sessionQueue.async(flags: .barrier) { [weak self] in
                self?.activeSessions[id] = session
            }
            
            // Create download items for each URL
            for (index, url) in urls.enumerated() {
                let destinationPath: String
                if let sessionDir = expandedDestinationDirectory {
                    destinationPath = destinationPathPreservingStructure(for: url, baseDirectory: sessionDir)
                } else {
                    destinationPath = defaultDestinationPath(for: url)
                }
                
                // Validate destination path before creating download item
                do {
                    try validateDestinationPath(destinationPath)
                } catch {
                    FreeToken.shared.logger("❌ Destination validation failed for \(url.lastPathComponent): \(error)", .error)
                    throw error
                }
                
                let expectedSHA256 = sha256Hashes[url]
                let downloadItem = DownloadItem(url: url, destinationPath: destinationPath, expectedSHA256: expectedSHA256)
                session.addDownload(downloadItem)
                
                let hashInfo = expectedSHA256 != nil ? " (with SHA-256)" : ""
                FreeToken.shared.logger("  📄 [\(index + 1)/\(urls.count)] Added: \(url.lastPathComponent) → \(destinationPath)\(hashInfo)", .debug)
                
                // Map URL to session
                sessionQueue.async(flags: .barrier) { [weak self] in
                    self?.urlToSessionMap[url] = id
                }
            }
            
            // Before persisting, validate existing files so we can short-circuit if everything already exists
            checkExistingFiles(for: session)

            if session.getDownloads().allSatisfy({ $0.state == .completed }) {
                session.state = .completed
                let metadata = SessionMetadata(from: session)
                SessionStorage.save(metadata)
                FreeToken.shared.logger("🟢 Session \(id) already satisfied on disk (\(session.getDownloads().count) files). Skipping network.", .info)
                if let handler = session.completionHandler {
                    session.progressCallbackQueue.async { @Sendable in handler(.success(())) }
                }
                return session
            }

            // Persist initial session metadata (may include some completed downloads)
            let metadata = SessionMetadata(from: session)
            SessionStorage.save(metadata)
            
            FreeToken.shared.logger("✅ Download session created successfully: \(id)", .info)
            
            return session
        }
        
        // MARK: - Hash Verification
        
        /// Computes SHA-256 hash of a file using streaming to handle large files efficiently
        /// - Parameter filePath: Path to the file to hash
        /// - Returns: Lowercase hexadecimal SHA-256 hash string, or nil if file cannot be read
        private func computeSHA256(filePath: String) -> String? {
            guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
                FreeToken.shared.logger("❌ Cannot open file for hashing: \(filePath)", .error)
                return nil
            }
            defer { fileHandle.closeFile() }
            
            var hasher = SHA256()
            let chunkSize = 1024 * 1024 // 1MB chunks for memory efficiency
            
            while autoreleasepool(invoking: {
                let chunk = fileHandle.readData(ofLength: chunkSize)
                guard !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }) {}
            
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        
        /// Verifies a file against its expected SHA-256 hash
        /// - Parameters:
        ///   - filePath: Path to the file to verify
        ///   - expectedHash: Expected SHA-256 hash (case-insensitive)
        /// - Returns: Tuple containing verification result and actual hash
        private func verifyFileHash(filePath: String, expectedHash: String) -> (verified: Bool, actualHash: String?) {
            guard let actualHash = computeSHA256(filePath: filePath) else {
                return (verified: false, actualHash: nil)
            }
            
            let verified = actualHash.lowercased() == expectedHash.lowercased()
            FreeToken.shared.logger("🔐 Hash verification for \(URL(fileURLWithPath: filePath).lastPathComponent): \(verified ? "✅ PASS" : "❌ FAIL")", verified ? .info : .warning)
            
            return (verified: verified, actualHash: actualHash)
        }
        
        /// Creates a new session builder for fluent API construction
        /// - Returns: A new DownloadSessionBuilder instance
        func sessionBuilder() -> DownloadSessionBuilder {
            return DownloadSessionBuilder(downloadManager: self)
        }
        
        // MARK: - Directory Management
        
        /// Creates a directory if it doesn't exist, including intermediate directories
        /// - Parameter path: The directory path to create
        /// - Throws: FreeTokenError.downloadSessionDestinationNotWritable if directory cannot be created
        private func createDirectoryIfNeeded(_ path: String) throws {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    throw FreeTokenError.downloadSessionDestinationNotWritable("Path exists but is not a directory: \(path)")
                }
                
                // Directory exists, check if writable
                if !fileManager.isWritableFile(atPath: path) {
                    throw FreeTokenError.downloadSessionDestinationNotWritable("Directory is not writable: \(path)")
                }
                
                FreeToken.shared.logger("📁 Using existing directory: \(path)", .debug)
            } else {
                // Create directory with intermediate directories
                do {
                    try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
                    FreeToken.shared.logger("📁 Created directory: \(path)", .info)
                } catch {
                    FreeToken.shared.logger("❌ Failed to create directory: \(path) - \(error)", .error)
                    throw FreeTokenError.downloadSessionDestinationNotWritable("Cannot create directory: \(path) - \(error.localizedDescription)")
                }
            }
        }
        
        /// Checks existing files in destination directory and marks downloads as completed if valid
        /// - Parameter session: The download session to check files for
    internal func checkExistingFiles(for session: DownloadSession) {
            let downloads = session.getDownloads()
            var skippedCount = 0
            var redownloadCount = 0
            
            for download in downloads {
                let destinationPath = download.destinationPath
                
                FreeToken.shared.logger("🔍 Looking for downloaded file at destination path: \(destinationPath)", .info)
                if FileManager.default.fileExists(atPath: destinationPath) {
                    if let expectedSHA = download.expectedSHA256 {
                        // Has SHA - verify it
                        let verification = verifyFileHash(filePath: destinationPath, expectedHash: expectedSHA)
                        if verification.verified {
                            // File exists and SHA matches - mark as completed
                            FreeToken.shared.logger("✅ File exists with valid SHA: \(download.url.lastPathComponent)", .info)
                            session.updateDownload(for: download.url) { downloadItem in
                                downloadItem.state = .completed
                                downloadItem.completionInfo = CompletionInfo(
                                    state: .completed,
                                    totalBytes: self.getFileSize(destinationPath) ?? 0,
                                    filePath: destinationPath,
                                    actualSHA256: verification.actualHash,
                                    hashVerified: true
                                )
                            }
                            skippedCount += 1
                            FreeToken.shared.logger("✅ Skipping download - file exists with valid SHA: \(download.url.lastPathComponent)", .info)
                        } else {
                            // File exists but SHA doesn't match - will redownload
                            FreeToken.shared.logger("⚠️ File exists but SHA mismatch - will redownload: \(download.url.lastPathComponent)", .warning)
                            redownloadCount += 1
                        }
                    } else {
                        // No SHA - assume file is good if it exists
                        session.updateDownload(for: download.url) { downloadItem in
                            downloadItem.state = .completed
                            downloadItem.completionInfo = CompletionInfo(
                                state: .completed,
                                totalBytes: self.getFileSize(destinationPath) ?? 0,
                                filePath: destinationPath,
                                hashVerified: nil
                            )
                        }
                        skippedCount += 1
                        FreeToken.shared.logger("✅ Skipping download - file exists (no SHA to verify): \(download.url.lastPathComponent)", .info)
                    }
                } else {
                    // If file doesn't exist, it stays marked for download
                    FreeToken.shared.logger("📥 File does not exist, will download: \(download.url)", .info)
                }
                
            }
            
            if skippedCount > 0 || redownloadCount > 0 {
                FreeToken.shared.logger("📊 Existing files check: \(skippedCount) skipped, \(redownloadCount) marked for redownload, \(downloads.count - skippedCount - redownloadCount) new downloads", .info)
            }
        }
        
        /// Gets the file size in bytes for a given file path
        /// - Parameter path: File path to check
        /// - Returns: File size in bytes, or nil if file doesn't exist or can't be read
        private func getFileSize(_ path: String) -> Int64? {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                return attributes[.size] as? Int64
            } catch {
                return nil
            }
        }
        
        // MARK: - Session Management
        
        /// Get an existing download session by ID
        /// - Parameter sessionID: The session ID to retrieve
        /// - Returns: The download session if found
        func getSession(id sessionID: String) -> DownloadSession? {
            return sessionQueue.sync {
                return activeSessions[sessionID]
            }
        }
        
        /// Checks if a session exists with the given ID
        /// - Parameter sessionID: The session ID to check
        /// - Returns: True if the session exists, false otherwise
        func sessionExists(_ sessionID: String) -> Bool {
            return sessionQueue.sync {
                return activeSessions[sessionID] != nil
            }
        }
        
        /// Checks if a session is actively downloading (has transfers in progress)
        /// - Parameter sessionID: The session ID to check
        /// - Returns: True if the session is actively downloading, false if session doesn't exist or not downloading
        func isSessionDownloading(_ sessionID: String) -> Bool {
            return sessionQueue.sync {
                guard let session = activeSessions[sessionID] else { return false }
                return session.state == .downloading
            }
        }
        
        /// Gets the current state of a session
        /// - Parameter sessionID: The session ID to check
        /// - Returns: The session state, or nil if session doesn't exist
        func getSessionState(_ sessionID: String) -> SessionState? {
            return sessionQueue.sync {
                return activeSessions[sessionID]?.state
            }
        }
        
        /// Get all active download sessions
        /// - Returns: Array of all active sessions
        func getAllSessions() -> [DownloadSession] {
            return sessionQueue.sync {
                return Array(activeSessions.values)
            }
        }
        
        /// Remove a download session
        /// - Parameter sessionID: The session ID to remove
        func removeSession(id sessionID: String) {
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                
                // Remove URLs from mapping
                if let session = self.activeSessions[sessionID] {
                    for download in session.getDownloads() {
                        self.urlToSessionMap.removeValue(forKey: download.url)
                    }
                }
                
                // Remove session
                self.activeSessions.removeValue(forKey: sessionID)
            }
            
            // Remove persisted metadata
            SessionStorage.remove(sessionID: sessionID)
            
            FreeToken.shared.logger("🗑️ Removed download session: \(sessionID)", .info)
        }
        
        /// Recover all persisted download sessions
        private func recoverSessions() {
            let sessionIDs = SessionStorage.getAllSessionIDs()
            
            for sessionID in sessionIDs {
                if let recoveredSession = recoverSession(id: sessionID) {
                    sessionQueue.async(flags: .barrier) { [weak self] in
                        self?.activeSessions[sessionID] = recoveredSession
                    }
                    FreeToken.shared.logger("🔄 Recovered session: \(sessionID)", .info)
                }
            }
            
            FreeToken.shared.logger("📂 Recovered \(sessionIDs.count) download session(s)", .info)
        }
        
        /// Recover a specific download session by ID
        /// - Parameter sessionID: The session ID to recover
        /// - Returns: The recovered session if successful
        /// Recovers a download session after app restart
        /// 
        /// Matches persisted session metadata with active URLSession background tasks
        /// to restore session state and continue downloads where they left off.
        /// Validates completed downloads and marks missing files as failed.
        /// 
        /// - Parameter sessionID: The session identifier to recover
        /// - Returns: Recovered `DownloadSession` if found, `nil` if session doesn't exist
        /// - Note: Automatically called during app startup for all persisted sessions
        func recoverSession(id sessionID: String) -> DownloadSession? {
            guard let metadata = SessionStorage.load(sessionID: sessionID) else {
                FreeToken.shared.logger("❌ No metadata found for session: \(sessionID)", .warning)
                return nil
            }
            
            // Use a dedicated progress callback queue when recovering as well for consistency
            let progressQueue = DispatchQueue(label: "ai.freetoken.downloadSession.progressCallbacks.\(metadata.id)")
            let session = DownloadSession(id: metadata.id, createdAt: metadata.createdAt, progressCallbackQueue: progressQueue)
            session.state = metadata.state
            
            // Restore downloads from metadata
            for downloadMetadata in metadata.downloads {
                let downloadItem = downloadMetadata.toDownloadItem()
                session.addDownload(downloadItem)
                
                // Update URL mapping
                sessionQueue.async(flags: .barrier) { [weak self] in
                    self?.urlToSessionMap[downloadItem.url] = sessionID
                }
            }
            
            // Match with active URLSession tasks
            matchSessionWithActiveTasks(session: session)
            
            return session
        }
        
        /// Match a recovered session with active URLSession tasks
        /// - Parameter session: The session to match with active tasks
        private func matchSessionWithActiveTasks(session: DownloadSession) {
            self.session.getAllTasks { [weak self] tasks in
                guard let self = self else { return }
                
                let sessionDownloads = session.getDownloads()
                FreeToken.shared.logger("🔍 Matching session \(session.id) with \(tasks.count) active tasks", .info)
                
                // First, validate completed downloads still exist on disk
                self.validateCompletedDownloads(in: session)
                
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let taskURL = downloadTask.originalRequest?.url else {
                        continue
                    }
                    
                    // Find matching download in session
                    if let matchingDownload = sessionDownloads.first(where: { $0.url == taskURL }) {
                        FreeToken.shared.logger("✅ Matched task for: \(taskURL.absoluteString)", .info)
                        
                        // Update session download with current task progress
                        session.updateDownload(for: taskURL) { downloadItem in
                            // Get current progress from URLSession task (source of truth)
                            let bytesReceived = downloadTask.countOfBytesReceived
                            let bytesExpected = downloadTask.countOfBytesExpectedToReceive
                            
                            downloadItem.bytesWritten = bytesReceived
                            if bytesExpected > 0 {
                                downloadItem.bytesExpected = bytesExpected
                            }
                            
                            // Update state based on task state
                            switch downloadTask.state {
                            case .running:
                                downloadItem.state = .downloading
                            case .suspended:
                                downloadItem.state = .pending // Will resume when started
                            case .completed:
                                // Task completed but we're recovering - check completion status
                                if matchingDownload.state != .completed {
                                    downloadItem.state = .completed
                                }
                            case .canceling:
                                downloadItem.state = .cancelled
                            @unknown default:
                                // Keep existing state from metadata
                                break
                            }
                            
                            // Store task reference for future operations
                            downloadItem.task = downloadTask
                        }
                        
                        // Update active downloads map
                        self.activeDownloads[taskURL] = downloadTask
                        
                        FreeToken.shared.logger("📊 Restored progress: \(downloadTask.countOfBytesReceived)/\(downloadTask.countOfBytesExpectedToReceive) bytes for \(taskURL.absoluteString)", .info)
                    }
                }
                
                // Update session state based on matched tasks
                self.updateSessionStateFromTasks(session: session)
                
                // Save updated session metadata
                let updatedMetadata = SessionMetadata(from: session)
                SessionStorage.save(updatedMetadata)
                
                FreeToken.shared.logger("🔄 Session recovery complete for: \(session.id)", .info)
            }
        }
        
        /// Validate that completed downloads still exist on disk
        /// - Parameter session: The session to validate
        func validateCompletedDownloads(in session: DownloadSession) {
            let completedDownloads = session.getDownloads().filter { $0.state == .completed }
            
            for download in completedDownloads {
                guard let completionInfo = download.completionInfo,
                      let filePath = completionInfo.filePath else {
                    continue
                }
                
                let fileManager = FileManager.default
                
                if fileManager.fileExists(atPath: filePath) {
                    // File exists, verify size matches
                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: filePath)
                        if let fileSize = attributes[.size] as? Int64 {
                            if fileSize != completionInfo.totalBytes {
                                FreeToken.shared.logger("⚠️ File size mismatch for \(download.url.absoluteString): expected \(completionInfo.totalBytes), found \(fileSize)", .warning)
                                // Mark as failed to allow re-download
                                session.updateDownload(for: download.url) { downloadItem in
                                    downloadItem.state = .failed
                                    downloadItem.completionInfo = nil
                                }
                            }
                        }
                    } catch {
                        FreeToken.shared.logger("❌ Failed to check file attributes for \(filePath): \(error)", .error)
                        // Mark as failed to allow re-download
                        session.updateDownload(for: download.url) { downloadItem in
                            downloadItem.state = .failed
                            downloadItem.completionInfo = nil
                        }
                    }
                } else {
                    FreeToken.shared.logger("❌ Completed file missing: \(filePath)", .warning)
                    // Mark as failed to allow re-download
                    session.updateDownload(for: download.url) { downloadItem in
                        downloadItem.state = .failed
                        downloadItem.completionInfo = nil
                    }
                }
            }
        }
        
        /// Update session state based on current task states
        /// - Parameter session: The session to update
        private func updateSessionStateFromTasks(session: DownloadSession) {
            let downloads = session.getDownloads()
            let hasActiveDownloads = downloads.contains { $0.state == .downloading }
            let allCompleted = downloads.allSatisfy { $0.state == .completed }
            let allFailed = downloads.allSatisfy { $0.state == .failed }
            
            if allCompleted {
                session.state = .completed
            } else if allFailed {
                session.state = .failed
            } else if hasActiveDownloads {
                session.state = .downloading
            } else if downloads.contains(where: { $0.state == .completed || $0.state == .failed }) {
                session.state = .partial
            } else {
                session.state = .pending
            }
        }
        
        /// Check if session is complete and trigger completion handler if needed
        /// - Parameter session: The session to check for completion
        private func checkAndTriggerSessionCompletion(session: DownloadSession) {
            let downloads = session.getDownloads()
            
            // Check if all downloads are in terminal states (completed or failed)
            let allTerminal = downloads.allSatisfy { $0.state == .completed || $0.state == .failed }
            
            guard allTerminal && !downloads.isEmpty else {
                return // Not all downloads are done yet, or no downloads exist
            }
            
            let allCompleted = downloads.allSatisfy { $0.state == .completed }
            let allFailed = downloads.allSatisfy { $0.state == .failed }
            
            // Update session state
            if allCompleted {
                session.state = .completed
            } else if allFailed {
                session.state = .failed
            } else {
                session.state = .partial
            }
            
            // Save session metadata with final state
            let metadata = SessionMetadata(from: session)
            SessionStorage.save(metadata)
            
            // Trigger completion handler if one exists
            if let completionHandler = session.completionHandler {
                FreeToken.shared.logger("🎯 Triggering session completion handler for session: \(session.id) (state: \(session.state)) - all completed (\(allCompleted)), all failed (\(allFailed))", .info)
                
                if allCompleted {
                    FreeToken.shared.logger("✅ All downloads completed successfully for session: \(session.id)", .info)
                    completionHandler(.success(()))
                } else {
                    // Create an appropriate error for failed downloads
                    let failedCount = downloads.filter { $0.state == .failed }.count
                    let totalCount = downloads.count
                    let error = FreeTokenError.downloadSessionFailed(
                        sessionID: session.id,
                        failedCount: failedCount,
                        totalCount: totalCount
                    )
                    FreeToken.shared.logger("❌ Session failed with \(failedCount)/\(totalCount) downloads failed for session: \(session.id)", .info)
                    completionHandler(.failure(error))
                }
                
                // Clear both handlers to prevent multiple calls and unwanted progress callbacks
                session.completionHandler = nil
                session.progressHandler = nil
            }
        }
        
        /// Get default destination path for a URL
        private func defaultDestinationPath(for url: URL) -> String {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destinationURL = documentsPath.appendingPathComponent(url.lastPathComponent)
            return destinationURL.path
        }

        /// Build destination path preserving HuggingFace repository relative structure if applicable.
        /// Example: https://huggingface.co/owner/repo/resolve/main/text_encoder/config.json
        /// becomes <baseDirectory>/text_encoder/config.json (instead of flattening to config.json)
        private func destinationPathPreservingStructure(for url: URL, baseDirectory: String) -> String {
            // Attempt HuggingFace relative extraction
            if let relative = huggingFaceRelativePath(url) {
                let full = (baseDirectory as NSString).appendingPathComponent(relative)
                // Ensure intermediate directories exist
                let parent = URL(fileURLWithPath: full).deletingLastPathComponent().path
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: nil)
                return full
            }
            // Fallback: just last component
            let full = (baseDirectory as NSString).appendingPathComponent(url.lastPathComponent)
            return full
        }

        /// Extract relative path inside a HuggingFace repo from a resolve URL.
        /// Returns nil for non-HuggingFace URLs or if structure can't be determined.
        private func huggingFaceRelativePath(_ url: URL) -> String? {
            guard let host = url.host, host.contains("huggingface.co") else { return nil }
            // Path components without leading slash
            let comps = url.path.split(separator: "/")
            // Looking for .../<owner>/<repo>/resolve/<revision>/<relative path...>
            guard let resolveIndex = comps.firstIndex(of: "resolve") else { return nil }
            let revisionIndex = comps.index(after: resolveIndex)
            guard revisionIndex < comps.endIndex else { return nil }
            let relativeStart = comps.index(after: revisionIndex)
            guard relativeStart < comps.endIndex else { return nil } // no file path beyond revision
            let relComps = comps[relativeStart...]
            guard !relComps.isEmpty else { return nil }
            return relComps.joined(separator: "/")
        }
        
        /// Start downloads for all URLs in a session
        /// - Parameters:
        ///   - sessionID: The ID of the session to start downloads for
        ///   - progressHandler: Optional progress handler for the entire session
        /// - Returns: True if downloads were started, false if session not found
        @discardableResult
        /// Starts all downloads in the specified session
        /// 
        /// Initiates background downloads for all pending files in the session.
        /// Downloads that are already completed or failed are skipped.
        /// 
        /// - Parameters:
        ///   - sessionID: The session identifier to start downloads for
        ///   - progressHandler: Optional callback for real-time collective progress updates (0.0-1.0)
        /// - Returns: `true` if session was found and downloads started, `false` otherwise
    /// - Note: Progress handlers are invoked on a configurable per-session queue (defaults to `.main`).
    ///         If you need to update the UI, dispatch explicitly to the main queue.
        func startSessionDownloads(
            sessionID: String,
            progressHandler: (@Sendable (Double) -> Void)? = nil
        ) -> Bool {
            guard let downloadSession = getSession(id: sessionID) else {
                FreeToken.shared.logger("❌ Session not found: \(sessionID)", .error)
                return false
            }
            
            // Set progress handler if provided, but preserve existing handler if one exists
            if let progressHandler = progressHandler {
                downloadSession.progressHandler = progressHandler
            } else if downloadSession.progressHandler != nil {
                // Keep existing progress handler from builder or previous calls
                FreeToken.shared.logger("📊 Preserving existing progress handler for session: \(sessionID)", .debug)
            }
            
            // Check existing files first and skip downloads that are already complete
            checkExistingFiles(for: downloadSession)
            
            let downloads = downloadSession.getDownloads()
            guard !downloads.isEmpty else {
                FreeToken.shared.logger("⚠️ No downloads in session: \(sessionID)", .warning)
                return false
            }
            
            // Filter out downloads that are already completed (from existing file check)
            let pendingDownloads = downloads.filter { $0.state != .completed }
            
            if pendingDownloads.isEmpty {
                FreeToken.shared.logger("✅ All downloads already exist and verified for session: \(sessionID)", .info)
                // Emit a single final 1.0 progress and then delegate completion firing to
                // checkAndTriggerSessionCompletion to ensure a single authoritative call.
                downloadSession.markFullyCompletedAndFlushProgress()
                // Update session state to completed so the manager can pick it up
                downloadSession.state = .completed
                // Delegate to centralized completion checker
                checkAndTriggerSessionCompletion(session: downloadSession)
                return true
            }
            
            FreeToken.shared.logger("🚀 Starting \(pendingDownloads.count) downloads for session: \(sessionID) (\(downloads.count - pendingDownloads.count) already exist)", .info)
            
            // Start each pending download in the session
            for download in pendingDownloads {
                
                // Check for existing session task first, then update state when confirmed
                session.getAllTasks { [weak self] tasks in
                    guard let self = self else { return }
                    
                    // Look for existing task
                    var existingTask: URLSessionDownloadTask?
                    for task in tasks {
                        if let downloadTask = task as? URLSessionDownloadTask,
                           let taskURL = downloadTask.originalRequest?.url,
                           taskURL == download.url {
                            existingTask = downloadTask
                            break
                        }
                    }
                    
                    if let task = existingTask {
                        // Reattach to existing task and update state
                        FreeToken.shared.logger("🔗 Reattaching to existing task for: \(download.url.absoluteString)", .info)
                        downloadSession.updateDownload(for: download.url) { downloadItem in
                            downloadItem.state = .downloading
                        }
                        self.activeDownloads[download.url] = task
                    } else {
                        // Check for resume data
                        if let resumeState = self.loadResumeData(for: download.url) {
                            FreeToken.shared.logger("🔄 Resuming download for: \(download.url.absoluteString)", .info)
                            let resumeTask = self.session.downloadTask(withResumeData: resumeState.resumeData)
                            resumeTask.resume()
                            self.activeDownloads[download.url] = resumeTask
                            self.removeResumeData(for: download.url)
                            
                            // Update state after task is confirmed started
                            downloadSession.updateDownload(for: download.url) { downloadItem in
                                downloadItem.state = .downloading
                            }
                        } else {
                            // Create new download task
                            FreeToken.shared.logger("🆕 Starting new download for: \(download.url.absoluteString)", .info)
                            let newTask = self.session.downloadTask(with: download.url)
                            newTask.resume()
                            self.activeDownloads[download.url] = newTask
                            
                            // Update state after task is confirmed started
                            downloadSession.updateDownload(for: download.url) { downloadItem in
                                downloadItem.state = .downloading
                            }
                        }
                    }
                }
            }
            
            // Update session state to downloading
            downloadSession.state = .downloading
            
            // Save session metadata
            let metadata = SessionMetadata(from: downloadSession)
            SessionStorage.save(metadata)
            
            return true
        }
        
        // MARK: - Background Download Handling
        
        /// Handle background download events from iOS
        /// - Parameters:
        ///   - identifier: The background session identifier from iOS
        ///   - completionHandler: The completion handler that must be called when processing is done
        func handleBackgroundEvents(
            identifier: String,
            completionHandler: @escaping () -> Void
        ) {
            // Check if this is our background session
            guard identifier == sessionIdentifier else {
                FreeToken.shared.logger("🔄 Background session identifier '\(identifier)' doesn't match ours '\(sessionIdentifier)'. Calling completion handler.", .info)
                completionHandler()
                return
            }
            
            FreeToken.shared.logger("🔄 Handling background events for session: \(identifier)", .info)
            
            // Store the completion handler for later use (iOS-specific)
            #if os(iOS)
            backgroundCompletionHandler = completionHandler
            #else
            // On macOS, call completion handler immediately as background behavior is different
            completionHandler()
            #endif
            
            // Re-attach the session to receive any pending events
            attachSession()
            
            // Process any sessions that completed while backgrounded
            processBackgroundCompletedSessions()
        }
        
        /// Process sessions that may have completed while the app was backgrounded
        private func processBackgroundCompletedSessions() {
            let sessions = getAllSessions()
            
            for session in sessions {
                if session.isCompleted || session.hasFailed {
                    FreeToken.shared.logger("📦 Session \(session.id) completed in background (state: \(session.state))", .info)
                    
                    // Save updated session metadata
                    let metadata = SessionMetadata(from: session)
                    SessionStorage.save(metadata)
                    
                    // Notify about session completion (iOS-specific callback)
                    #if os(iOS)
                    onBackgroundSessionCompletion?(session.id)
                    #endif
                }
            }
        }
        
        // MARK: - Memory Management
        
        /// Clean up stale progress and completion handlers to prevent memory leaks
        /// Called automatically during cleanup operations
        private func cleanupStaleHandlers() {
            let activeURLs = Set(activeDownloads.keys)
            let originalCompletionCount = completionHandlers.count
            completionHandlers = completionHandlers.filter { activeURLs.contains($0.key) }
            let cleanedCompletion = originalCompletionCount - completionHandlers.count
            if cleanedCompletion > 0 {
                FreeToken.shared.logger("🧹 Cleaned up \(cleanedCompletion) stale completion handlers", .debug)
            }
        }
        
        // MARK: - Debug Utilities
        
        /// Print detailed information about all active sessions (debug builds only)
        /// Useful for troubleshooting session state and progress issues
        func debugPrintAllSessions() {
            #if DEBUG
            let sessions = getAllSessions()
            
            FreeToken.shared.logger("🔍 DEBUG: Active Sessions (\(sessions.count) total)", .info)
            FreeToken.shared.logger("=====================================", .info)
            
            for session in sessions {
                let progressInfo = session.getProgressDetails()
                
                FreeToken.shared.logger("📦 Session: \(session.id)", .info)
                FreeToken.shared.logger("  State: \(session.state)", .info)
                FreeToken.shared.logger("  Progress: \(String(format: "%.1f", progressInfo.overallProgress * 100))%", .info)
                FreeToken.shared.logger("  Downloads: \(progressInfo.completedCount) completed, \(progressInfo.activeCount) active, \(progressInfo.failedCount) failed", .info)
                FreeToken.shared.logger("  Bytes: \(progressInfo.downloadedBytes)/\(progressInfo.totalBytes)", .info)
                FreeToken.shared.logger("  Created: \(session.createdAt)", .info)
                
                if progressInfo.unknownSizeCount > 0 {
                    FreeToken.shared.logger("  ⚠️  \(progressInfo.unknownSizeCount) downloads have unknown size (excluded from progress)", .info)
                }
                
                FreeToken.shared.logger("", .info)
            }
            
            if sessions.isEmpty {
                FreeToken.shared.logger("  No active sessions", .info)
            }
            #endif
        }
        
        /// Get summary statistics for all sessions (always available)
        func getSessionSummary() -> SessionSummary {
            let sessions = getAllSessions()
            
            var totalSessions = 0
            var completedSessions = 0
            var failedSessions = 0
            var activeSessions = 0
            var totalDownloads = 0
            var completedDownloads = 0
            var failedDownloads = 0
            var totalBytes: Int64 = 0
            var downloadedBytes: Int64 = 0
            
            for session in sessions {
                totalSessions += 1
                
                switch session.state {
                case .completed:
                    completedSessions += 1
                case .failed:
                    failedSessions += 1
                case .downloading, .partial:
                    activeSessions += 1
                default:
                    break
                }
                
                let downloads = session.getDownloads()
                totalDownloads += downloads.count
                completedDownloads += session.completedCount
                failedDownloads += session.failedCount
                totalBytes += session.totalBytes
                downloadedBytes += session.downloadedBytes
            }
            
            return SessionSummary(
                totalSessions: totalSessions,
                completedSessions: completedSessions,
                failedSessions: failedSessions,
                activeSessions: activeSessions,
                totalDownloads: totalDownloads,
                completedDownloads: completedDownloads,
                failedDownloads: failedDownloads,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes
            )
        }
        
        /// Validate session integrity and clean up any inconsistencies
        /// Returns a report of any issues found and fixed
        func validateAndCleanupSessions() -> ValidationReport {
            var issues: [String] = []
            var fixes: [String] = []
            
            let sessions = getAllSessions()
            
            FreeToken.shared.logger("🔍 Validating \(sessions.count) sessions...", .info)
            
            for session in sessions {
                // Check for missing files in completed downloads
                let downloads = session.getDownloads()
                for download in downloads where download.state == .completed {
                    let fileExists = FileManager.default.fileExists(atPath: download.destinationPath)
                    if !fileExists {
                        issues.append("Session \(session.id): Completed download missing file at \(download.destinationPath)")
                        
                        // Fix: Mark as failed to allow re-download
                        session.updateDownload(for: download.url) { downloadItem in
                            downloadItem.state = .failed
                        }
                        fixes.append("Marked missing file as failed for re-download")
                    }
                }
                
                // Check for orphaned session metadata
                if downloads.isEmpty {
                    issues.append("Session \(session.id): Empty session found")
                    // Note: We don't auto-remove as it might be intentional
                }
                
                // Check for very old sessions (30+ days)
                let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
                if session.createdAt < thirtyDaysAgo && (session.isCompleted || session.hasFailed) {
                    issues.append("Session \(session.id): Old completed/failed session found (created: \(session.createdAt))")
                    // Note: Cleanup is handled by existing mechanisms
                }
            }
            
            FreeToken.shared.logger("✅ Session validation complete: \(issues.count) issues, \(fixes.count) fixes applied", .info)
            
            return ValidationReport(issues: issues, fixes: fixes)
        }
        
        // MARK: - Private Helper Methods
        
        /// Validate that a destination path is writable before starting download
        private func validateDestinationPath(_ path: String) throws {
            let fileURL = URL(fileURLWithPath: path)
            let parentDirectory = fileURL.deletingLastPathComponent()
            
            // Check if parent directory exists and is writable
            var isDirectory: ObjCBool = false
            let directoryExists = FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory)
            
            if !directoryExists {
                // Try to create the directory
                do {
                    try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
                    FreeToken.shared.logger("📁 Created destination directory: \(parentDirectory.path)", .debug)
                } catch {
                    FreeToken.shared.logger("❌ Failed to create destination directory: \(error)", .error)
                    throw FreeTokenError.downloadSessionDestinationNotWritable(path)
                }
            } else if !isDirectory.boolValue {
                throw FreeTokenError.downloadSessionDestinationNotWritable("Path exists but is not a directory: \(parentDirectory.path)")
            } else if !FileManager.default.isWritableFile(atPath: parentDirectory.path) {
                throw FreeTokenError.downloadSessionDestinationNotWritable("Directory is not writable: \(parentDirectory.path)")
            }
            
            // Check if target file already exists and can be overwritten
            if FileManager.default.fileExists(atPath: path) {
                if !FileManager.default.isDeletableFile(atPath: path) {
                    throw FreeTokenError.downloadSessionDestinationNotWritable("File exists and cannot be overwritten: \(path)")
                }
            }
        }
        
        /// Enforce session limits by removing oldest completed/failed sessions
        private func enforceSessionLimits() {
            let currentSessions = getAllSessions()
            let excessCount = currentSessions.count - maxConcurrentSessions
            
            if excessCount > 0 {
                // Find completed and failed sessions to remove (oldest first)
                let completedOrFailed = currentSessions
                    .filter { $0.isCompleted || $0.hasFailed }
                    .sorted { $0.createdAt < $1.createdAt }
                
                let sessionsToRemove = Array(completedOrFailed.prefix(excessCount))
                
                for session in sessionsToRemove {
                    removeSession(id: session.id)
                    SessionStorage.remove(sessionID: session.id)
                    FreeToken.shared.logger("🧹 Auto-removed old session to enforce limits: \(session.id)", .info)
                }
            }
        }
    }
}
