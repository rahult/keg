import Foundation
import KegCLICore

/// Installs the bundled `keg` companion CLI onto PATH and reports its
/// state. Location rules live in KegCLICore so the CLI's own `keg install`
/// and this Settings button always agree.
@Observable
@MainActor
final class KegCLIInstaller {
    enum State: Equatable {
        /// keg is reachable at a PATH location.
        case installed(linkPath: String, needsPATHSetup: Bool)
        /// The binary ships in the bundle but nothing is installed yet.
        case notInstalled
        /// No CLI binary is present (dev runs without a bundled app).
        case unavailable
    }

    private(set) var state: State = .notInstalled
    private(set) var isWorking = false
    private(set) var lastError: String?

    /// The bundled CLI binary: Contents/SharedSupport/bin/keg inside an app
    /// bundle (NOT MacOS — that path collides with the Keg binary on
    /// case-insensitive filesystems), or the sibling `kegcli` build artifact
    /// when running straight from swift build.
    static func bundledBinaryPath() -> String? {
        if let sharedSupport = Bundle.main.sharedSupportURL {
            let bundled = sharedSupport.appendingPathComponent("bin/keg")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled.path
            }
        }
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let devArtifact = executableDir?.appendingPathComponent("kegcli")
        if let devArtifact, FileManager.default.isExecutableFile(atPath: devArtifact.path) {
            return devArtifact.path
        }
        return nil
    }

    init() {
        refresh()
    }

    func refresh() {
        if let link = KegCLIInstall.installedLink() {
            state = .installed(linkPath: link.linkPath, needsPATHSetup: link.needsPATHSetup)
        } else if Self.bundledBinaryPath() != nil {
            state = .notInstalled
        } else {
            state = .unavailable
        }
    }

    /// The shell line to show when the user-level fallback directory was
    /// used (it is not on PATH until the user adds it).
    var pathHint: String? {
        guard case .installed(_, let needsPATH) = state, needsPATH else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"]
            .map { $0.components(separatedBy: "/").last ?? "zsh" } ?? "zsh"
        return KegCLIInstall.pathHint(
            for: KegCLIInstall.Location(directory: KegCLIInstall.userBinDirectory, needsPATHSetup: true),
            shell: shell
        )
    }

    func install() {
        guard let binary = Self.bundledBinaryPath() else {
            lastError = "keg CLI binary not found in the app bundle"
            return
        }
        guard let location = KegCLIInstall.preferredLocation() else {
            lastError = "No writable install location found"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try KegCLIInstall.install(binaryPath: binary, into: location)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try KegCLIInstall.uninstall()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
