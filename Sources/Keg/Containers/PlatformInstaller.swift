import Foundation

/// Downloads Apple's signed `container` platform installer and sets it up
/// in the user's home directory — no administrator rights needed. Davit's
/// equivalent feature; Keg installs into `~/.keg/platform/bin`, which
/// `ContainerCLI` also resolves.
@Observable
@MainActor
final class PlatformInstaller {
    enum Phase: Equatable, Sendable {
        case idle
        case fetchingRelease
        case downloading(received: Int64, expected: Int64)
        case expanding
        case installing
        case done(version: String)
        case failed(String)
    }

    static let installDirectory = NSHomeDirectory() + "/.keg/platform/bin"

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .fetchingRelease, .downloading, .expanding, .installing: return true
        default: return false
        }
    }

    // MARK: - Release resolution

    struct ReleaseAsset: Sendable {
        let version: String
        let downloadURL: URL
    }

    /// Picks the signed installer asset from a GitHub releases API payload.
    /// Pure function so the selection logic is unit-testable.
    nonisolated static func selectInstallerAsset(releaseJSON data: Data) -> ReleaseAsset? {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable { let tag_name: String; let assets: [Asset] }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        guard let asset = release.assets.first(where: { $0.name.contains("installer-signed") && $0.name.hasSuffix(".pkg") }),
              let url = URL(string: asset.browser_download_url) else { return nil }
        return ReleaseAsset(version: release.tag_name, downloadURL: url)
    }

    // MARK: - Install

    func install() async {
        phase = .fetchingRelease
        do {
            let asset = try await fetchLatestRelease()
            phase = .downloading(received: 0, expected: 0)
            let pkgURL = try await download(asset)

            phase = .expanding
            let expandedDir = try expand(pkgURL)

            phase = .installing
            try installBinaries(from: expandedDir)
            try? FileManager.default.removeItem(at: expandedDir)
            try? FileManager.default.removeItem(at: pkgURL)

            phase = .done(version: asset.version)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseAsset {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/apple/container/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CocoaError(.coderReadCorrupt)
        }
        guard let asset = Self.selectInstallerAsset(releaseJSON: data) else {
            throw CocoaError(.coderValueNotFound)
        }
        return asset
    }

    /// Downloads with periodic progress callbacks (bytesReceived updates `phase`).
    private func download(_ asset: ReleaseAsset) async throws -> URL {
        let downloadsDir = FileManager.default.temporaryDirectory.appendingPathComponent("keg-installer-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        let destination = downloadsDir.appendingPathComponent(asset.downloadURL.lastPathComponent)

        let (bytes, response) = try await URLSession.shared.bytes(from: asset.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let expected = http.expectedContentLength > 0 ? http.expectedContentLength : -1
        var received: Int64 = 0

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for try await byte in bytes {
            try handle.write(contentsOf: [byte])
            received &+= 1
            if received % (512 * 1024) == 0 {
                phase = .downloading(received: received, expected: expected)
            }
        }
        phase = .downloading(received: received, expected: expected)
        return destination
    }

    /// Expands the pkg payload into a temp directory (no root required).
    private func expand(_ pkgURL: URL) throws -> URL {
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("keg-pkg-\(UUID().uuidString.prefix(6))")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/sbin/pkgutil")
        process.arguments = ["--expand-full", pkgURL.path, outputDir.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "pkgutil failed: \(String(data: data, encoding: .utf8) ?? "unknown error")"])
        }
        return outputDir
    }

    /// Copies the `container` and `container-apiserver` binaries out of the
    /// expanded payload into the user-level install directory.
    private func installBinaries(from expandedDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.installDirectory, withIntermediateDirectories: true)

        let names = ["container", "container-apiserver"]
        var installed: [String] = []
        for name in names {
            guard let match = try findBinary(named: name, in: expandedDir) else { continue }
            let target = Self.installDirectory + "/\(name)"
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.copyItem(atPath: match, toPath: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
            installed.append(name)
        }
        guard installed.contains("container") else {
            throw CocoaError(.coderValueNotFound, userInfo: [NSLocalizedDescriptionKey: "container binary not found in installer payload"])
        }
    }

    private func findBinary(named name: String, in directory: URL) throws -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in enumerator {
            guard url.lastPathComponent == name else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { return url.path }
        }
        return nil
    }
}
