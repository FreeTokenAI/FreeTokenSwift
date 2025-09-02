import Foundation
import CryptoKit

/// Minimal integrity checker for downloaded model files.
/// One-time SHA256 verification immediately after first successful download session completion.
/// Subsequent calls rely on existence + size checks only (unless those fail, in which case integrity becomes invalid).
struct ModelIntegrityChecker {
    struct FileMeta: Hashable {
        let name: String
        let size: Int64
        let sha256: String? // Optional if hub does not expose
    }
    
    enum IntegrityResult: Equatable {
        case unverified
        case valid(fileCount: Int)
        case missing([String])
        case sizeMismatch([String])
        case hashMismatch([String])
        case networkError(String)
    }
    
    private struct HFModelInfo: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
            let sha256: String?
        }
        let siblings: [Sibling]
    }
    
    /// Fetch file metadata list from Hugging Face Hub.
    func fetchRemoteFileMeta(repo: String) async throws -> [FileMeta] {
        // Construct URL (basic endpoint). We only need siblings, default endpoint returns them.
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(HFModelInfo.self, from: data)
        return decoded.siblings.compactMap { sib in
            guard let size = sib.size else { return nil }
            return FileMeta(name: sib.rfilename, size: size, sha256: sib.sha256)
        }
    }
    
    /// Perform initial full verification (includes hashing for files with sha256) OR quick size-only verification if already validated.
    /// - Parameters:
    ///   - repo: Hugging Face repository identifier (e.g. "TheBloke/Model")
    ///   - directory: Local directory containing model files.
    ///   - expectedNames: Subset of filenames we require (from config) – we filter remote list to these.
    ///   - priorValidatedSizes: If non-empty and hashesValidatedOnce true, perform only quick size/existence check.
    ///   - hashesValidatedOnce: Indicates hashing was already performed successfully before.
    func verify(
        repo: String,
        directory: URL,
        expectedNames: [String],
        priorValidatedSizes: [String: Int64],
        hashesValidatedOnce: Bool
    ) async -> (IntegrityResult, [String: Int64], Bool) {
        // Quick path after previous validation: just size/existence check.
        if hashesValidatedOnce, priorValidatedSizes.isEmpty == false {
            let quickResult = quickSizeCheck(directory: directory, sizeMap: priorValidatedSizes)
            switch quickResult {
            case .valid:
                return (.valid(fileCount: priorValidatedSizes.count), priorValidatedSizes, true)
            case .missing(let m):
                return (.missing(m), priorValidatedSizes, true)
            case .sizeMismatch(let s):
                return (.sizeMismatch(s), priorValidatedSizes, true)
            default:
                break // fall through (should not reach hashMismatch here)
            }
        }
        
        // Need remote metadata for first full verification.
        let remoteMeta: [FileMeta]
        do {
            remoteMeta = try await fetchRemoteFileMeta(repo: repo)
        } catch {
            return (.networkError(error.localizedDescription), priorValidatedSizes, hashesValidatedOnce)
        }
        
        // Filter to expected names (if provided), else use all remote files.
        let targets: [FileMeta]
        if expectedNames.isEmpty {
            targets = remoteMeta
        } else {
            let remoteDict = Dictionary(uniqueKeysWithValues: remoteMeta.map { ($0.name, $0) })
            var tmp: [FileMeta] = []
            var stillMissing: [String] = []
            let fm = FileManager.default
            for name in expectedNames {
                if let meta = remoteDict[name] {
                    tmp.append(meta)
                } else {
                    // Remote metadata missing this file; if file exists locally, synthesize metadata from local size.
                    let localURL = directory.appendingPathComponent(name)
                    if let attrs = try? fm.attributesOfItem(atPath: localURL.path), let sz = attrs[.size] as? NSNumber {
                        tmp.append(FileMeta(name: name, size: sz.int64Value, sha256: nil))
                    } else {
                        stillMissing.append(name)
                    }
                }
            }
            if stillMissing.isEmpty == false {
                return (.missing(stillMissing), priorValidatedSizes, hashesValidatedOnce)
            }
            targets = tmp
        }
        if targets.isEmpty { // Defensive: should not treat empty as valid
            return (.missing(expectedNames), priorValidatedSizes, hashesValidatedOnce)
        }
        
        // Existence + size pass
        var missing: [String] = []
        var sizeMismatch: [String] = []
        var sizeMap: [String: Int64] = [:]
        let fm = FileManager.default
        for meta in targets {
            let fileURL = directory.appendingPathComponent(meta.name)
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path) else {
                missing.append(meta.name)
                continue
            }
            if let fileSize = attrs[.size] as? NSNumber {
                let sz = fileSize.int64Value
                if sz != meta.size { sizeMismatch.append(meta.name) }
                else { sizeMap[meta.name] = sz }
            } else {
                missing.append(meta.name)
            }
        }
        if missing.isEmpty == false { return (.missing(missing), priorValidatedSizes, hashesValidatedOnce) }
        if sizeMismatch.isEmpty == false { return (.sizeMismatch(sizeMismatch), priorValidatedSizes, hashesValidatedOnce) }
        
        // Hash only if we have not hashed before and at least one file exposes sha256.
        var performedHashing = hashesValidatedOnce
        if !hashesValidatedOnce {
            for meta in targets {
                guard let expectedHash = meta.sha256?.lowercased(), !expectedHash.isEmpty else { continue }
                let fileURL = directory.appendingPathComponent(meta.name)
                do {
                    let computed = try sha256FileHex(url: fileURL)
                    if computed != expectedHash {
                        return (.hashMismatch([meta.name]), priorValidatedSizes, hashesValidatedOnce)
                    }
                } catch {
                    return (.hashMismatch([meta.name]), priorValidatedSizes, hashesValidatedOnce)
                }
            }
            performedHashing = true
        }
        return (.valid(fileCount: targets.count), sizeMap, performedHashing)
    }
    
    private func quickSizeCheck(directory: URL, sizeMap: [String: Int64]) -> IntegrityResult {
        let fm = FileManager.default
        var missing: [String] = []
        var sizeMismatch: [String] = []
        for (name, size) in sizeMap {
            let fileURL = directory.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path) else {
                missing.append(name)
                continue
            }
            if let currentSize = attrs[.size] as? NSNumber, currentSize.int64Value != size {
                sizeMismatch.append(name)
            }
        }
        if missing.isEmpty == false { return .missing(missing) }
        if sizeMismatch.isEmpty == false { return .sizeMismatch(sizeMismatch) }
        return .valid(fileCount: sizeMap.count)
    }
    
    private func sha256FileHex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: { () -> Bool in
            do {
                if let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    return true
                }
                return false
            } catch {
                return false
            }
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
