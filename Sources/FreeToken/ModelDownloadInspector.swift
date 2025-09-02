import Foundation

/// Direct filesystem-based download state inspector that does NOT create or consult DownloadManager sessions.
/// Uses `ModelIntegrityChecker` to perform one-time hash verification; subsequent calls rely on size/existence.
final class ModelDownloadInspector: @unchecked Sendable {
    private let repo: String
    private let modelFileName: String?
    private let mmprojFileName: String?
    private let integrityChecker = ModelIntegrityChecker()
    private var integrityResult: ModelIntegrityChecker.IntegrityResult = .unverified
    private var validatedFileSizes: [String: Int64] = [:]
    private var hashesValidatedOnce: Bool = false
    
    init(repo: String, modelFileName: String?, mmprojFileName: String?) {
        self.repo = repo
        self.modelFileName = modelFileName
        self.mmprojFileName = mmprojFileName
    }
    
    /// Compute the model base directory (platform aware).
    private func modelDirectory() -> URL {
#if os(iOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FreeToken")
            .appendingPathComponent("Models")
#else
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".FreeToken")
            .appendingPathComponent("Models")
#endif
        return base.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
    }
    
    private func expectedNames() -> [String] {
        var names: [String] = []
        if let m = modelFileName { names.append(m) }
        if let v = mmprojFileName { names.append(v) }
        return names
    }
    
    /// Derive simplified ModelDownloadState purely from filesystem + integrity status.
    func getState() async -> FreeToken.ModelDownloadState {
        let expected = expectedNames()
        let dir = modelDirectory()
        if expected.isEmpty { return .notDownloaded }
        
        // Run integrity checker (quick path if already validated)
        let (result, sizeMap, hashed) = await integrityChecker.verify(
            repo: repo,
            directory: dir,
            expectedNames: expected,
            priorValidatedSizes: validatedFileSizes,
            hashesValidatedOnce: hashesValidatedOnce
        )
        integrityResult = result
        validatedFileSizes = sizeMap
        hashesValidatedOnce = hashed || hashesValidatedOnce
        
        func anyFileExists() -> Bool {
            for name in expected {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return true }
            }
            return false
        }
        
        switch result {
        case .valid:
            return .downloaded
        case .missing:
            return anyFileExists() ? .downloading : .notDownloaded
        case .sizeMismatch:
            return .downloading
        case .hashMismatch:
            return .failed(error: "Model files invalid (hash mismatch)")
        case .networkError:
            // If we previously had a valid run, allow downloaded, else notDownloaded
            if case .valid = integrityResult { return .downloaded }
            return anyFileExists() ? .downloading : .notDownloaded
        case .unverified:
            return .notDownloaded
        }
    }
}
