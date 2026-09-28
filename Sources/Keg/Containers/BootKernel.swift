import Foundation

/// State of the container runtime's default boot kernel. Container 1.4
/// changed kernel management: pre-1.4 runtimes downloaded a default kernel
/// on first use, while 1.4+ requires an explicit
/// `container system kernel set` registration and fails every
/// `container run` with "default kernel not configured for architecture
/// arm64" until one exists — exactly where a Homebrew runtime upgrade
/// leaves an otherwise healthy install, with no hint outside the raw CLI
/// error.
enum BootKernelStatus: Equatable, Sendable {
    case unchecked
    /// Registered; payload is the effective binaryPath the runtime reports.
    case ok(binaryPath: String)
    /// The runtime supports registration but nothing is registered.
    case missing
    /// Pre-1.4 runtime: kernels auto-download on first use, nothing to manage.
    case legacyRuntime
    /// Couldn't determine (CLI absent, runtime not answering).
    case unknown
}

/// Pure helpers behind the boot-kernel status check, kept out of AppState so
/// they can be unit-tested without shelling out to the CLI.
enum BootKernel {
    /// The `[kernel]` section of `container system property list --format
    /// toml`. Empty strings mean the runtime exposes no such keys.
    static func parseRegistration(_ toml: String) -> (binaryPath: String, url: String) {
        var binaryPath = ""
        var url = ""
        var section = ""
        for rawLine in toml.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard section == "kernel" else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch parts[0] {
            case "binaryPath": binaryPath = value
            case "url": url = value
            default: break
            }
        }
        return (binaryPath, url)
    }

    /// Classification from the two facts the live check gathers: whether the
    /// runtime knows about kernel registration at all (`container system
    /// kernel` subcommand, 1.4+ only), and whether a default is registered.
    static func status(registrationSupported: Bool, binaryPath: String) -> BootKernelStatus {
        guard registrationSupported else { return .legacyRuntime }
        return binaryPath.isEmpty ? .missing : .ok(binaryPath: binaryPath)
    }
}
