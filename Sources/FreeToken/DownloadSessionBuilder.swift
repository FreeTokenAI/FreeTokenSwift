//
//  DownloadSessionBuilder.swift
//  FreeToken
//
//  Created by DownloadSession Implementation on 8/19/25.
//

import Foundation

extension FreeToken {
    
    /// Builder pattern for creating download sessions with optional SHA-256 verification
    class DownloadSessionBuilder {
        
        // MARK: - Private Properties
        
        private var downloads: [(url: URL, sha256: String?)] = []
        private var sessionID: String?
    private var completion: (@Sendable (Result<Void, Error>) -> Void)?
        private var progressHandler: (@Sendable (Double) -> Void)?
        private var destinationDirectory: String?
        private let downloadManager: DownloadManager
        
        // MARK: - Initialization
        
        internal init(downloadManager: DownloadManager) {
            self.downloadManager = downloadManager
        }
        
        // MARK: - Builder Methods
        
        /// Set the session ID for this download session
        /// - Parameter id: Unique identifier for the session
        /// - Returns: Self for method chaining
        func sessionID(_ id: String) -> Self {
            self.sessionID = id
            return self
        }
        
        /// Set the completion handler for the entire session
        /// - Parameter handler: Called when all downloads complete or fail
        /// - Returns: Self for method chaining
    func completion(_ handler: @escaping @Sendable (Result<Void, Error>) -> Void) -> Self {
            self.completion = handler
            return self
        }
        
        /// Set the progress handler for real-time collective progress updates
        /// - Parameter handler: Called whenever the collective progress changes (0.0 to 1.0)
        /// - Returns: Self for method chaining
        func progress(_ handler: Optional<@Sendable (Double) -> Void>) -> Self {
            self.progressHandler = handler
            return self
        }
        
        /// Set the destination directory where all downloaded files will be saved
        /// - Parameter path: Directory path where files should be saved (supports tilde expansion)
        /// - Returns: Self for method chaining
        func destinationDirectory(_ path: String) -> Self {
            self.destinationDirectory = path
            return self
        }
        
        /// Add a download to this session
        /// - Parameters:
        ///   - url: The URL to download
        ///   - sha256: Optional SHA-256 hash for integrity verification
        /// - Returns: Self for method chaining
        func addDownload(url: URL, sha256: String? = nil) -> Self {
            downloads.append((url: url, sha256: sha256))
            return self
        }
        
        /// Add multiple downloads to this session
        /// - Parameter items: Array of (URL, optional SHA-256) tuples
        /// - Returns: Self for method chaining
        func addDownloads(_ items: [(url: URL, sha256: String?)]) -> Self {
            downloads.append(contentsOf: items)
            return self
        }
        
        /// Build and create the download session
        /// - Returns: The created DownloadSession
        /// - Throws: FreeTokenError if session creation fails
        func build() throws -> DownloadSession {
            guard !downloads.isEmpty else {
                throw FreeTokenError.downloadSessionInvalidState("Cannot create session with no downloads")
            }
            
            // Extract URLs for the legacy createSession method
            let urls = downloads.map { $0.url }
            let hashMap: [URL: String] = Dictionary(uniqueKeysWithValues: downloads.compactMap { item in
                guard let hash = item.sha256 else { return nil }
                return (item.url, hash)
            })
            
            let session = try downloadManager.createSession(
                urls: urls,
                sessionID: sessionID,
                sha256Hashes: hashMap,
                destinationDirectory: destinationDirectory,
                completion: completion
            )
            
            // Set the progress handler if provided
            if let progressHandler = progressHandler {
                session.progressHandler = progressHandler
                FreeToken.shared.logger("📊 Builder set progress handler for session: \(session.id)", .debug)
            }
            
            return session
        }
    }
}
