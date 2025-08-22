//
//  DownloadSession.swift
//  FreeToken
//
//  Created by DownloadSession Implementation on 8/19/25.
//

import Foundation

extension FreeToken {
    
    /// Represents a group of related downloads that can be tracked collectively
    class DownloadSession: @unchecked Sendable {
        
        // MARK: - Core Properties
        
        /// Unique identifier for this download session
        let id: String
        
        /// When this session was created
        let createdAt: Date
        
        /// Current state of the entire session
        var state: SessionState = .pending
        
        /// All downloads in this session
        var downloads: [DownloadItem] = []
        
        /// Called when the entire session completes (success or failure)
        var completionHandler: (@Sendable (Result<Void, Error>) -> Void)?
        
        /// Progress handler called when collective progress changes
        var progressHandler: (@Sendable (Double) -> Void)?
        
        /// Queue on which progress/completion handlers are invoked (default .main unless overridden by manager)
        let progressCallbackQueue: DispatchQueue

        /// Last progress value reported to progressHandler (to suppress duplicate 0.0 bursts)
        private var lastReportedProgress: Double = -1.0

        // Emission diagnostics (attempted = delivered + suppressed)
        private var emissionsAttempted: Int = 0
        private var emissionsDelivered: Int = 0
        private var emissionsSuppressed: Int = 0
        
        // MARK: - Thread Safety
        
        private let sessionQueue = DispatchQueue(label: "ai.freetoken.downloadSession", attributes: .concurrent)

        // Debug flag to trace progress emission decisions
        var enableProgressDebug: Bool = true

        /// Force-set session to completed progress state (1.0) and emit a single final progress callback.
        /// Used when all files are already present before starting any network tasks to prevent a 0->1 burst.
        internal func markFullyCompletedAndFlushProgress() {
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                // Only act if handler still present
                guard let handler = self.progressHandler else { return }
                self.lastReportedProgress = 1.0
                if self.enableProgressDebug {
                    FreeToken.shared.logger("🧪S flush final progress=1.0 session=\(self.id) (pre-existing files)", .debug)
                }
        self.progressCallbackQueue.async { handler(1.0) }
                // Clear to prevent subsequent spurious emissions
                self.progressHandler = nil
            }
        }
        
        // MARK: - Initialization
        
        /// Create a new download session.
        /// - Parameters:
        ///   - id: Unique session identifier
        ///   - createdAt: Creation timestamp (defaults to now)
        ///   - progressCallbackQueue: Queue used to invoke progress & completion handlers (defaults to .main)
        init(id: String, createdAt: Date = Date(), progressCallbackQueue: DispatchQueue = .main) {
            self.id = id
            self.createdAt = createdAt
            self.progressCallbackQueue = progressCallbackQueue
            // Tag queue for reentrancy detection
            Self.setupQueueSpecific(for: sessionQueue)
        }
        
        // MARK: - Public Computed Properties
        
        /// Collective progress of all downloads with known file sizes (0.0 to 1.0)
        /// 
        /// Uses URLSession tasks as source of truth when available for maximum accuracy,
        /// falls back to stored values for completed/failed downloads. Downloads with
        /// unknown file sizes are excluded from progress calculation.
        /// 
        /// - Returns: Progress value from 0.0 (not started) to 1.0 (all known-size downloads complete)
        /// - Note: Returns 0.0 if no downloads have known file sizes
        var collectiveProgress: Double {
            // If we're already on the session queue (barrier or sync), compute directly to avoid deadlock
            if DispatchQueue.getSpecific(key: Self.queueSpecificKey) != nil {
                return computeCollectiveProgressUnlocked()
            }
            return sessionQueue.sync { computeCollectiveProgressUnlocked() }
        }

        /// Internal, non-thread-safe collective progress calculation. Caller must ensure proper synchronization.
        private func computeCollectiveProgressUnlocked() -> Double {
            // Defensive fast paths
            guard !downloads.isEmpty else { return 0.0 }

            // Filter downloads with known sizes
            let known = downloads.filter { $0.bytesExpected > 0 }
            guard !known.isEmpty else { return 0.0 }

            var written: Int64 = 0
            var expected: Int64 = 0
            for d in known {
                if let task = d.task {
                    let recv = max(0, task.countOfBytesReceived)
                    written += recv
                    let exp = task.countOfBytesExpectedToReceive
                    expected += exp > 0 ? exp : max(0, d.bytesExpected)
                } else {
                    written += max(0, d.bytesWritten)
                    expected += max(0, d.bytesExpected)
                }
            }
            guard expected > 0 else { return 0.0 }
            let progress = Double(written) / Double(expected)
            return min(1.0, max(0.0, progress))
        }
        
        /// Safely calculate collective progress without deadlock issues
        func getCollectiveProgress(completion: @escaping @Sendable (Double) -> Void) {
            sessionQueue.async { [weak self] in
                guard let self = self else { completion(0.0); return }
                // If handler was cleared, abort (avoids post-completion bursts)
                guard self.progressHandler != nil else { return }
                completion(self.computeCollectiveProgressUnlocked())
            }
        }
        
        /// Total bytes expected across all downloads with known sizes
        /// Uses URLSession tasks as source of truth when available
        var totalBytes: Int64 {
            return sessionQueue.sync {
                var total: Int64 = 0
                for download in downloads.filter({ $0.hasKnownSize }) {
                    if let task = download.task {
                        let taskBytesExpected = task.countOfBytesExpectedToReceive
                        total += taskBytesExpected > 0 ? taskBytesExpected : download.bytesExpected
                    } else {
                        total += download.bytesExpected
                    }
                }
                return total
            }
        }
        
        /// Total bytes downloaded across all downloads
        /// Uses URLSession tasks as source of truth when available
        var downloadedBytes: Int64 {
            return sessionQueue.sync {
                var total: Int64 = 0
                for download in downloads {
                    if let task = download.task {
                        total += task.countOfBytesReceived
                    } else {
                        total += download.bytesWritten
                    }
                }
                return total
            }
        }
        
        /// Number of completed downloads
        var completedCount: Int {
            return sessionQueue.sync {
                return downloads.filter { $0.state == .completed }.count
            }
        }
        
        /// Number of failed downloads
        var failedCount: Int {
            return sessionQueue.sync {
                return downloads.filter { $0.state == .failed }.count
            }
        }
        
        /// Number of active downloads
        var activeCount: Int {
            return sessionQueue.sync {
                return downloads.filter { $0.state == .downloading }.count
            }
        }
        
        /// Whether all downloads have completed successfully
        var isCompleted: Bool {
            return sessionQueue.sync {
                return !downloads.isEmpty && downloads.allSatisfy { $0.state == .completed }
            }
        }
        
        /// Whether any downloads have failed
        var hasFailed: Bool {
            return sessionQueue.sync {
                return downloads.contains { $0.state == .failed }
            }
        }
        
        /// Whether this session is actively downloading (has active transfers)
        var isDownloading: Bool {
            return state == .downloading
        }
        
        // MARK: - Public Methods
        
        /// Reattach progress and completion handlers to an existing session
        /// 
        /// This is useful when your app restarts and you want to reconnect
        /// to an in-progress download session. Both handlers are optional.
        /// 
        /// - Parameters:
        ///   - progress: Optional progress handler (0.0 to 1.0)
        ///   - completion: Optional completion handler for session result
        func reattachHandlers(
            progress: (@Sendable (Double) -> Void)? = nil,
            completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
        ) {
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                
                if let progress = progress {
                    self.progressHandler = progress
                    FreeToken.shared.logger("📊 Reattached progress handler for session: \(self.id)", .debug)
                    
                    // Safely call progress handler without deadlock
                    self.getCollectiveProgress { currentProgress in
                        self.progressCallbackQueue.async {
                            progress(currentProgress)
                        }
                    }
                }
                
                if let completion = completion {
                    self.completionHandler = completion
                    FreeToken.shared.logger("📊 Reattached completion handler for session: \(self.id)", .debug)
                }
            }
        }
        
        /// Get detailed progress information for the session
        /// 
        /// Provides comprehensive statistics about the download session including
        /// progress, byte counts, completion status, and individual download states.
        /// Optimized to calculate all values in a single queue sync call for performance.
        /// 
        /// - Returns: `SessionProgressInfo` containing all session metrics
        /// - Note: Uses URLSession tasks as source of truth when available
        func getProgressDetails() -> SessionProgressInfo {
            return sessionQueue.sync {
                let unknownSizeDownloads = downloads.filter { !$0.hasKnownSize }
                
                // Calculate all values in one pass for performance
                var totalBytesWritten: Int64 = 0
                var totalBytesExpected: Int64 = 0
                var completedCount = 0
                var failedCount = 0
                var activeCount = 0
                
                for download in downloads {
                    // Use URLSession task as source of truth if available
                    if let task = download.task {
                        totalBytesWritten += task.countOfBytesReceived
                        
                        if download.hasKnownSize {
                            let taskBytesExpected = task.countOfBytesExpectedToReceive
                            totalBytesExpected += taskBytesExpected > 0 ? taskBytesExpected : download.bytesExpected
                        }
                    } else {
                        totalBytesWritten += download.bytesWritten
                        if download.hasKnownSize {
                            totalBytesExpected += download.bytesExpected
                        }
                    }
                    
                    // Count states
                    switch download.state {
                    case .completed:
                        completedCount += 1
                    case .failed:
                        failedCount += 1
                    case .downloading:
                        activeCount += 1
                    default:
                        break
                    }
                }
                
                let overallProgress = totalBytesExpected > 0 ? Double(totalBytesWritten) / Double(totalBytesExpected) : 0.0
                
                return SessionProgressInfo(
                    sessionID: id,
                    overallProgress: overallProgress,
                    totalBytes: totalBytesExpected,
                    downloadedBytes: totalBytesWritten,
                    completedCount: completedCount,
                    failedCount: failedCount,
                    activeCount: activeCount,
                    unknownSizeCount: unknownSizeDownloads.count,
                    state: state
                )
            }
        }
        
        /// Get all download items (thread-safe)
        func getDownloads() -> [DownloadItem] {
            return sessionQueue.sync { downloads }
        }
        
        /// Get download item for specific URL
        func getDownload(for url: URL) -> DownloadItem? {
            return sessionQueue.sync {
                downloads.first { $0.url == url }
            }
        }
        
        // MARK: - Internal Methods (for DownloadManager)
        
        /// Add a download to this session
        internal func addDownload(_ download: DownloadItem) {
            sessionQueue.async(flags: .barrier) { [weak self] in
                self?.downloads.append(download)
                self?.updateSessionState()
            }
        }
        
        /// Update a download in this session
        internal func updateDownload(for url: URL, update: @escaping @Sendable (inout DownloadItem) -> Void) {
            sessionQueue.async(flags: .barrier) { [weak self] in
                guard let self = self,
                      let index = self.downloads.firstIndex(where: { $0.url == url }) else { return }

                update(&self.downloads[index])
                self.updateSessionState()

                // Compute progress while we already hold exclusive access
                let progress = self.computeCollectiveProgressUnlocked()

                if let handler = self.progressHandler {
                    let delta = abs(progress - self.lastReportedProgress)
                    emissionsAttempted += 1
                    if delta > 0.0001 {
                        self.lastReportedProgress = progress
                        emissionsDelivered += 1
            self.progressCallbackQueue.async {
                            handler(progress)
                        }
                    } else {
                        emissionsSuppressed += 1
                    }
                } else {
                    // No handler registered; ignore emission silently
                }
            }
        }

        // MARK: - Diagnostics Access
        struct ProgressEmissionStats {
            let attempted: Int
            let delivered: Int
            let suppressed: Int
        }
        func getProgressEmissionStats() -> ProgressEmissionStats {
            return sessionQueue.sync { ProgressEmissionStats(attempted: emissionsAttempted, delivered: emissionsDelivered, suppressed: emissionsSuppressed) }
        }
        
        /// Update session state based on download states
        private func updateSessionState() {
            if downloads.isEmpty {
                state = .pending
            } else if downloads.allSatisfy({ $0.state == .completed }) {
                state = .completed
            } else if downloads.allSatisfy({ $0.state == .failed }) {
                state = .failed
            } else if downloads.contains(where: { $0.state == .downloading }) {
                state = .downloading
            } else if downloads.contains(where: { $0.state == .completed }) ||
                      downloads.contains(where: { $0.state == .failed }) {
                state = .partial
            } else {
                state = .pending
            }
        }
    }
}

// MARK: - Queue Specific Key Setup

extension FreeToken.DownloadSession {
    private static let queueSpecificKey = DispatchSpecificKey<Void>()
    static func setupQueueSpecific(for queue: DispatchQueue) {
        queue.setSpecific(key: queueSpecificKey, value: ())
    }
}

// MARK: - Supporting Types

extension FreeToken {
    
    /// Possible states for a download session
    enum SessionState: String, CaseIterable, Codable {
        case pending        /// Not started
        case downloading    /// At least one download is active
        case completed      /// All downloads completed successfully
        case failed         /// All downloads failed
        case partial        /// Mix of completed, failed, and/or pending downloads
    }
    
    /// Detailed progress information for a session
    struct SessionProgressInfo {
        let sessionID: String
        let overallProgress: Double      /// 0.0 to 1.0
        let totalBytes: Int64           /// Total bytes for known-size downloads
        let downloadedBytes: Int64      /// Downloaded bytes for known-size downloads
        let completedCount: Int         /// Number of completed downloads
        let failedCount: Int            /// Number of failed downloads
        let activeCount: Int            /// Number of active downloads
        let unknownSizeCount: Int       /// Number of downloads with unknown size
        let state: SessionState         /// Current session state
    }
    
    
    /// Summary statistics for all download sessions
    struct SessionSummary {
        let totalSessions: Int
        let completedSessions: Int
        let failedSessions: Int
        let activeSessions: Int
        let totalDownloads: Int
        let completedDownloads: Int
        let failedDownloads: Int
        let totalBytes: Int64
        let downloadedBytes: Int64
        
        /// Overall progress across all sessions (0.0 to 1.0)
        var overallProgress: Double {
            return totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0.0
        }
        
        /// Success rate as a percentage (0.0 to 100.0)
        var successRate: Double {
            return totalDownloads > 0 ? Double(completedDownloads) / Double(totalDownloads) * 100.0 : 0.0
        }
    }
    
    /// Report from session validation and cleanup operations
    struct ValidationReport {
        let issues: [String]
        let fixes: [String]
        
        /// Whether any issues were found
        var hasIssues: Bool {
            return !issues.isEmpty
        }
        
        /// Whether any fixes were applied
        var hasFixes: Bool {
            return !fixes.isEmpty
        }
    }
}
