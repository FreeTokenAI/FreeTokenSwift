//
//  DownloadSessionMetadata.swift
//  FreeToken
//
//  Created by DownloadSession Implementation on 8/19/25.
//

import Foundation

extension FreeToken {
    
    // MARK: - Download Item
    
    /// Represents a single download within a session
    struct DownloadItem: Sendable {
        
        // MARK: - Core Properties
        
        /// The URL being downloaded
        let url: URL
        
    /// Where the downloaded file will be saved (mutable to allow post-download renaming)
    var destinationPath: String
        
        /// Expected SHA-256 hash for integrity verification (optional)
        let expectedSHA256: String?
        
        /// Current state of this download
        var state: DownloadState = .pending
        
        /// Bytes downloaded so far
        var bytesWritten: Int64 = 0
        
        /// Total bytes expected (may be unknown)
        var bytesExpected: Int64 = -1
        
        /// Reference to the active URLSessionDownloadTask (if any)
        /// Note: Not weak to ensure task retention for progress tracking
        internal var task: URLSessionDownloadTask?
        
        /// Completion information (set when download finishes)
        var completionInfo: CompletionInfo?
        
        /// When this download was created
        let createdAt: Date
        
        // MARK: - Computed Properties
        
        /// Whether this download has a known file size
        var hasKnownSize: Bool {
            return bytesExpected > 0
        }
        
        /// Progress as a percentage (0.0 to 1.0)
        var progress: Double {
            guard hasKnownSize else { return 0.0 }
            return Double(bytesWritten) / Double(bytesExpected)
        }
        
        /// Whether this download can be resumed
        var canResume: Bool {
            return state == .failed && completionInfo?.resumeData != nil
        }
        
        // MARK: - Initialization
        
        init(url: URL, destinationPath: String, expectedSHA256: String? = nil, createdAt: Date = Date()) {
            self.url = url
            self.destinationPath = destinationPath
            self.expectedSHA256 = expectedSHA256
            self.createdAt = createdAt
        }
    }
    
    // MARK: - Download State
    
    /// Possible states for an individual download
    enum DownloadState: String, CaseIterable, Codable, Sendable {
        case pending        /// Queued but not started
        case downloading    /// Currently downloading
        case completed      /// Successfully completed
        case failed         /// Failed (may be resumable)
        case cancelled      /// Cancelled by user
    }
    
    // MARK: - Completion Info
    
    /// Information about a completed (or failed) download
    struct CompletionInfo: Codable, Sendable {
        
        /// When the download finished
        let completedAt: Date
        
        /// Total bytes that were downloaded
        let totalBytes: Int64
        
        /// Final state
        let finalState: DownloadState
        
        /// Error information (if failed)
        let errorInfo: ErrorInfo?
        
        /// Resume data (if available for failed downloads)
        let resumeData: Data?
        
        /// Path to the completed file (if successful)
        let filePath: String?
        
        /// Actual SHA-256 hash of the downloaded file (if computed)
        let actualSHA256: String?
        
        /// Whether hash verification was performed and passed
        let hashVerified: Bool?
        
        init(state: DownloadState, 
             totalBytes: Int64,
             filePath: String? = nil,
             errorInfo: ErrorInfo? = nil,
             resumeData: Data? = nil,
             actualSHA256: String? = nil,
             hashVerified: Bool? = nil) {
            self.completedAt = Date()
            self.finalState = state
            self.totalBytes = totalBytes
            self.filePath = filePath
            self.errorInfo = errorInfo
            self.resumeData = resumeData
            self.actualSHA256 = actualSHA256
            self.hashVerified = hashVerified
        }
    }
    
    // MARK: - Error Info
    
    /// Information about download errors
    struct ErrorInfo: Codable, Sendable {
        let code: Int
        let domain: String
        let description: String
        let isResumable: Bool
        
        init(from error: Error) {
            let nsError = error as NSError
            self.code = nsError.code
            self.domain = nsError.domain
            self.description = nsError.localizedDescription
            
            // Determine if error is resumable
            let resumableErrorCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff,
                NSURLErrorDataNotAllowed,
                NSURLErrorCancelled
            ]
            self.isResumable = resumableErrorCodes.contains(nsError.code)
        }
    }
    
    // MARK: - Session Metadata (for Persistence)
    
    /// Minimal data needed to persist and recover a download session
    internal struct SessionMetadata: Codable {
        
        /// Unique session identifier
        let id: String
        
        /// When the session was created
        let createdAt: Date
        
        /// Current session state
        var state: SessionState
        
        /// Metadata for each download in the session
        var downloads: [DownloadMetadata]
        
        /// When this metadata was last updated
        var lastUpdated: Date
        
        init(from session: DownloadSession) {
            self.id = session.id
            self.createdAt = session.createdAt
            self.state = session.state
            self.lastUpdated = Date()
            self.downloads = session.getDownloads().map { DownloadMetadata(from: $0) }
        }
    }
    
    // MARK: - Download Metadata (for Persistence)
    
    /// Minimal data needed to persist and recover a single download
    internal struct DownloadMetadata: Codable {
        
        /// The URL being downloaded
        let url: URL
        
        /// Destination path for the file
        let destinationPath: String
        
        /// Expected SHA-256 hash for verification
        let expectedSHA256: String?
        
        /// When this download was created
        let createdAt: Date
        
        /// Current state of the download
        var state: DownloadState
        
        /// Completion information (if finished)
        var completionInfo: CompletionInfo?
        
        init(from download: DownloadItem) {
            self.url = download.url
            self.destinationPath = download.destinationPath
            self.expectedSHA256 = download.expectedSHA256
            self.createdAt = download.createdAt
            self.state = download.state
            self.completionInfo = download.completionInfo
        }
        
        /// Convert back to a DownloadItem
        func toDownloadItem() -> DownloadItem {
            var item = DownloadItem(
                url: url,
                destinationPath: destinationPath,
                expectedSHA256: expectedSHA256,
                createdAt: createdAt
            )
            item.state = state
            item.completionInfo = completionInfo
            
            // Restore file size information for completed downloads
            if let completionInfo = completionInfo, state == .completed {
                item.bytesWritten = completionInfo.totalBytes
                item.bytesExpected = completionInfo.totalBytes
            }
            
            return item
        }
    }
    
    // MARK: - Session Storage
    
    /// Manages persistence of session metadata
    internal class SessionStorage {
        
        private static let keyPrefix = "ai.freetoken.downloadSession."
        
        /// Save session metadata to persistent storage
        static func save(_ metadata: SessionMetadata) {
            let key = keyPrefix + metadata.id
            
            do {
                let data = try JSONEncoder().encode(metadata)
                UserDefaults.standard.set(data, forKey: key)
                FreeToken.shared.logger("💾 Saved session metadata: \(metadata.id)", .info)
            } catch {
                FreeToken.shared.logger("❌ Failed to save session metadata: \(error)", .error)
            }
        }
        
        /// Load session metadata from persistent storage
        static func load(sessionID: String) -> SessionMetadata? {
            let key = keyPrefix + sessionID
            
            guard let data = UserDefaults.standard.data(forKey: key) else {
                return nil
            }
            
            do {
                let metadata = try JSONDecoder().decode(SessionMetadata.self, from: data)
                FreeToken.shared.logger("📂 Loaded session metadata: \(sessionID)", .info)
                return metadata
            } catch {
                FreeToken.shared.logger("❌ Failed to load session metadata: \(error)", .error)
                return nil
            }
        }
        
        /// Remove session metadata from persistent storage
        static func remove(sessionID: String) {
            let key = keyPrefix + sessionID
            UserDefaults.standard.removeObject(forKey: key)
            FreeToken.shared.logger("🗑️ Removed session metadata: \(sessionID)", .info)
        }
        
        /// Get all stored session IDs
        static func getAllSessionIDs() -> [String] {
            let keys = UserDefaults.standard.dictionaryRepresentation().keys
            return keys.compactMap { key in
                guard key.hasPrefix(keyPrefix) else { return nil }
                return String(key.dropFirst(keyPrefix.count))
            }
        }
        
        /// Clean up old session metadata (older than specified days)
        static func cleanupOldSessions(olderThanDays days: Int = 30) {
            let cutoffDate = Date().addingTimeInterval(-TimeInterval(days * 24 * 60 * 60))
            let sessionIDs = getAllSessionIDs()
            var removedCount = 0
            
            for sessionID in sessionIDs {
                if let metadata = load(sessionID: sessionID),
                   metadata.lastUpdated < cutoffDate {
                    remove(sessionID: sessionID)
                    removedCount += 1
                }
            }
            
            if removedCount > 0 {
                FreeToken.shared.logger("🧹 Cleaned up \(removedCount) old session(s)", .info)
            }
        }
    }
}
