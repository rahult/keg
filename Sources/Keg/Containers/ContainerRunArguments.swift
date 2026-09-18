import Foundation

/// Builds the `container run` argument vector shared by the Run and
/// Edit & Recreate sheets. All list fields take comma/space-free entries;
/// splitting raw user text happens at the call site.
enum ContainerRunArguments {
    static func build(
        name: String?,
        env: [String],
        ports: [String],
        volumes: [String],
        cpus: Int?,
        memory: String?,
        detached: Bool = true,
        image: String,
        command: String
    ) -> [String] {
        var args = ["container", "run"]
        if detached {
            args.append("-d")
        }
        if let name, !name.isEmpty {
            args += ["--name", name]
        }
        for entry in env where !entry.isEmpty {
            args += ["-e", entry]
        }
        for mapping in ports where !mapping.isEmpty {
            args += ["-p", mapping]
        }
        for mount in volumes where !mount.isEmpty {
            args += ["-v", mount]
        }
        if let cpus {
            args += ["--cpus", "\(cpus)"]
        }
        if let memory, !memory.isEmpty {
            args += ["--memory", memory]
        }
        args.append(image)
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            args += trimmed.split(separator: " ").map(String.init)
        }
        return args
    }

    /// Splits a comma-separated user text field into trimmed, non-empty entries.
    static func splitList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Splits a volumes text field into run-ready entries: `~` is expanded to
    /// the user's home folder because the `container` CLI rejects relative
    /// and tilde paths silently confusingly (it just fails the run).
    static func splitVolumes(_ text: String) -> [String] {
        splitList(text).map(expandTilde)
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Plain-language problems with a volumes text field, worst first. Empty
    /// array = fine to run. Apple's `container` CLI only supports bind mounts
    /// of real Mac folders (no Docker-style named volumes), and its own error
    /// for a bad `-v` is a raw failure — so validate here in human terms.
    static func volumeMountProblems(_ text: String) -> [String] {
        splitList(text).compactMap { problem(forVolume: $0) }
    }

    private static func problem(forVolume entry: String) -> String? {
        let parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            return "Volumes: “\(entry)” needs two paths — a folder on your Mac, then where it lands in the container (e.g. \(NSHomeDirectory())/site:/usr/share/nginx/html)."
        }
        let host = parts[0]
        let container = parts[1]

        if !host.hasPrefix("/") && !host.hasPrefix("~") {
            if !host.contains("/") {
                return "Volumes: “\(host)” looks like a Docker named volume. Keg shares real folders from your Mac instead — use a path like \(NSHomeDirectory())/\(host):\(container)."
            }
            return "Volumes: “\(host)” should be an absolute Mac path (start with / or ~), or use Choose Folder."
        }
        if !container.hasPrefix("/") {
            return "Volumes: the container path “\(container)” must be absolute — e.g. \(host):/data."
        }
        return nil
    }

    /// Human memory string ("1G", "512M") for a byte count, matching the
    /// units the `container` CLI accepts.
    static func formatMemory(_ bytes: UInt64) -> String {
        switch bytes {
        case let n where n >= 1 << 30 && n % (1 << 30) == 0: return "\(n >> 30)G"
        case let n where n >= 1 << 20 && n % (1 << 20) == 0: return "\(n >> 20)M"
        case let n where n >= 1 << 10 && n % (1 << 10) == 0: return "\(n >> 10)K"
        default: return "\(bytes)"
        }
    }
}
