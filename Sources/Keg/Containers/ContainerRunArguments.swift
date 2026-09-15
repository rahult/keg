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
