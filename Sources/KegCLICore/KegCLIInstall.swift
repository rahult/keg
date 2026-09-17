import Foundation

/// Where the `keg` binary can be exposed on PATH, and how. Shared by the
/// CLI's own `keg install` and the app's Settings button so both pick the
/// same location and print the same PATH hint.
///
/// Preference order mirrors what users expect from Docker Desktop-style
/// tools: the system/local bin first (no PATH setup), Homebrew's prefix
/// next, and finally a user-level directory that always works but needs a
/// one-line PATH addition.
public enum KegCLIInstall {
    public static let commandName = "keg"
    public static let userBinDirectory = NSHomeDirectory() + "/.keg/bin"

    public struct Location: Equatable, Sendable {
        public let directory: String
        /// True when the directory is on the user's PATH via common shell
        /// config heuristics (best effort — PATH may be set elsewhere).
        public let needsPATHSetup: Bool

        public init(directory: String, needsPATHSetup: Bool) {
            self.directory = directory
            self.needsPATHSetup = needsPATHSetup
        }

        public var linkPath: String { directory + "/" + commandName }
    }

    /// All candidate install directories in preference order.
    public static let candidateDirectories = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        userBinDirectory,
    ]

    /// Picks the first candidate that exists and is writable, without ever
    /// prompting for privileges. `environment` is injected for tests.
    public static func preferredLocation(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> Location? {
        for directory in candidateDirectories {
            let isUserDir = directory == userBinDirectory
            if isUserDir || (fileExists(directory) && isWritable(directory)) {
                return Location(directory: directory, needsPATHSetup: isUserDir)
            }
        }
        return nil
    }

    /// The export line a shell needs when the user-level fallback was used.
    public static func pathHint(for location: Location, shell: String = "zsh") -> String {
        guard location.needsPATHSetup else { return "" }
        switch shell.lowercased() {
        case "fish":
            return "fish_add_path \(location.directory)"
        case "tcsh":
            return "set path = (\(location.directory) $path)"
        default:
            return "export PATH=\"\(location.directory):$PATH\""
        }
    }

    /// Resolves the real binary behind a possible symlink chain — when the
    /// CLI runs from /usr/local/bin/keg, the target lives inside Keg.app.
    public static func resolveRealBinary(arg0: String) -> String {
        let url = URL(fileURLWithPath: arg0).resolvingSymlinksInPath()
        return url.path
    }

    /// Where `keg` is currently installed, if anywhere: the first candidate
    /// holding a file (any kind) named `keg`.
    public static func installedLink(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Location? {
        for directory in candidateDirectories {
            let path = directory + "/" + commandName
            if fileExists(path) {
                return Location(directory: directory, needsPATHSetup: directory == userBinDirectory)
            }
        }
        return nil
    }

    /// Creates the symlink (or replaces a stale one). Throws with a
    /// human-readable message on failure.
    @discardableResult
    public static func install(
        binaryPath: String,
        into location: Location,
        fileManager: FileManager = .default
    ) throws -> String {
        if !fileManager.fileExists(atPath: location.directory) {
            try fileManager.createDirectory(atPath: location.directory, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: location.linkPath) {
            try fileManager.removeItem(atPath: location.linkPath)
        }
        try fileManager.createSymbolicLink(atPath: location.linkPath, withDestinationPath: binaryPath)
        return location.linkPath
    }

    /// Removes an installed `keg` link. Throws when nothing is installed.
    @discardableResult
    public static func uninstall(fileManager: FileManager = .default) throws -> String {
        guard let location = installedLink(fileExists: { fileManager.fileExists(atPath: $0) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "keg is not installed in any known location",
            ])
        }
        try fileManager.removeItem(atPath: location.linkPath)
        return location.linkPath
    }
}
