import CryptoKit
import Foundation
import Yams

// MARK: - Registry Index

/// The index document (`index.yaml`) at the root of a catalog registry.
/// The registry is a plain GitHub repo: `index.yaml` lists the app
/// definition files; each file is a full catalog YAML document (same format
/// as the bundled definitions). Checksums let the app skip unchanged
/// downloads and reject corrupted ones.
///
/// ```yaml
/// version: 1
/// updated: 2026-09-24
/// apps:
///   - id: memos
///     file: apps/memos.yaml
///     sha256: <hex of apps/memos.yaml>
/// ```
struct RemoteCatalogIndex: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let id: String
        let file: String
        var sha256: String?
    }

    var version: Int
    var updated: String?
    var apps: [Entry]
}

// MARK: - Sync

/// Fetches a catalog registry over HTTPS and mirrors it into a local cache
/// directory (`~/.keg/apps/remote-catalog/`). The cache commit point is the
/// cached `index.yaml`: it is written only after every listed app downloaded
/// (and checksum-verified) successfully, so a partial refresh can never
/// leave the app showing a half-updated catalog.
enum RemoteCatalogError: Error, CustomStringConvertible {
    case badStatus(Int, String)
    case emptyIndex
    case unsafePath(String)
    case checksumMismatch(String)

    var description: String {
        switch self {
        case .badStatus(let status, let url): return "Registry returned HTTP \(status) for \(url)"
        case .emptyIndex: return "The registry's index.yaml lists no apps"
        case .unsafePath(let path): return "Registry entry has an unsafe path: \(path)"
        case .checksumMismatch(let id): return "Checksum mismatch for \(id) — the downloaded file does not match the index"
        }
    }
}

enum RemoteCatalog {
    /// The registry the Apps section syncs from. Override with
    /// `defaults write dev.rahult.keg apps.catalogURL <url>` (any https URL
    /// or a file:// directory for offline testing).
    static let defaultBaseURL = URL(string: "https://raw.githubusercontent.com/rahult/keg-apps/main")!

    static var configuredBaseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: "apps.catalogURL"),
           let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) {
            return url
        }
        return defaultBaseURL
    }

    static var cacheDirectory: URL {
        URL(filePath: AppStoreManager.appsDirectory + "/remote-catalog")
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    struct SyncResult: Sendable {
        /// Entries that were downloaded fresh (new or changed).
        let downloaded: Int
        /// Total entries the index lists.
        let total: Int
        /// The index's human "updated" stamp, for display.
        let registryUpdated: String?
    }

    /// Mirrors the registry into `cacheDir`. Files already cached with a
    /// matching checksum are not re-downloaded.
    static func sync(
        base: URL,
        session: URLSession,
        cacheDir: URL
    ) async throws -> SyncResult {
        let indexData = try await get(base.appending(path: "index.yaml"), session: session)
        let index = try YAMLDecoder().decode(
            RemoteCatalogIndex.self,
            from: String(decoding: indexData, as: UTF8.self)
        )
        guard !index.apps.isEmpty else { throw RemoteCatalogError.emptyIndex }

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var downloaded = 0
        for entry in index.apps {
            let dest = try destination(for: entry.file, in: cacheDir)
            let cached = try? Data(contentsOf: dest)
            // No checksum in the index → only fetch files we don't have yet.
            if let cached, entry.sha256 == nil { continue }
            if let cached, let want = entry.sha256, sha256Hex(cached) == want.lowercased() { continue }

            let data = try await get(base.appending(path: entry.file), session: session)
            if let want = entry.sha256, sha256Hex(data) != want.lowercased() {
                throw RemoteCatalogError.checksumMismatch(entry.id)
            }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: dest, options: .atomic)
            downloaded += 1
        }

        // Commit point: a cached index means "this mirror is complete".
        try indexData.write(to: cacheDir.appending(path: "index.yaml"), options: .atomic)
        return SyncResult(downloaded: downloaded, total: index.apps.count, registryUpdated: index.updated)
    }

    /// Reads the cached mirror, if a complete one exists: the cached index
    /// paired with each listed file's contents. Anything on disk that the
    /// cached index does not list is ignored (leftover from an aborted
    /// refresh or a removed app).
    static func cachedFiles(cacheDir: URL) -> [(entry: RemoteCatalogIndex.Entry, yaml: String)] {
        guard let indexData = try? Data(contentsOf: cacheDir.appending(path: "index.yaml")),
              let index = try? YAMLDecoder().decode(RemoteCatalogIndex.self, from: String(decoding: indexData, as: UTF8.self))
        else { return [] }
        return index.apps.compactMap { entry in
            guard let dest = try? destination(for: entry.file, in: cacheDir),
                  let yaml = try? String(contentsOf: dest, encoding: .utf8) else { return nil }
            return (entry, yaml)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Helpers

    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            guard http.statusCode == 200 else {
                throw RemoteCatalogError.badStatus(http.statusCode, url.absoluteString)
            }
        }
        // Non-HTTP responses (file:// for offline testing) only reach here
        // when URLSession actually read the file — it throws otherwise.
        return data
    }

    /// Registry paths are mirrored under the cache directory; refuse
    /// anything that could climb out of it.
    private static func destination(for file: String, in cacheDir: URL) throws -> URL {
        guard !file.hasPrefix("/"), !file.contains(".."),
              file.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil else {
            throw RemoteCatalogError.unsafePath(file)
        }
        return cacheDir.appending(path: file)
    }
}
