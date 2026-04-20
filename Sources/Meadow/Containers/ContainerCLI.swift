import Foundation

/// Locates Apple's `container` CLI on disk so GUI subprocesses find it even when
/// launched with a stripped PATH (Finder/Dock apps don't inherit `$PATH` from the
/// user's shell). Also reports installation status for the Settings UI.
enum ContainerCLI {
    /// Known install locations, highest priority first.
    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/container",    // Apple Silicon Homebrew
        "/usr/local/bin/container",       // Intel Homebrew / official .pkg
        "/opt/container/bin/container",   // Apple .pkg install target
        "/usr/bin/container"              // system (unlikely but covered)
    ]

    /// First existing executable path, or `nil` if the CLI isn't installed.
    static func resolve() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { resolve() != nil }

    /// Builds a ready-to-run `Process` pointing at the resolved `container` binary.
    /// Drops the leading "container" token if the caller included it (most
    /// existing code prepends it for use with `env`, so accept both shapes).
    static func makeProcess(_ args: [String]) throws -> Process {
        guard let binary = resolve() else {
            throw ContainerCLIError.notInstalled
        }
        let normalized = args.first == "container" ? Array(args.dropFirst()) : args
        let process = Process()
        process.executableURL = URL(filePath: binary)
        process.arguments = normalized
        return process
    }

    /// Runs the container CLI with the given arguments and returns (exit code, combined stdout+stderr).
    static func run(_ args: [String]) async throws -> (Int32, String) {
        let process = try makeProcess(args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

enum ContainerCLIError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Apple's `container` CLI is not installed. Open Settings → Container CLI to install."
        }
    }
}
