import Foundation

/// Editable platform defaults, backed by the `container` CLI's own TOML
/// config. Values are read from the effective configuration
/// (`container system property list`) and written back as a clean override
/// file at the first writable config location, so user edits survive
/// platform upgrades and stay reviewable as plain TOML.
@Observable
@MainActor
final class PlatformSettingsVM {
    struct Settings: Sendable {
        var containerCPUs: Int = 4
        var containerMemory: String = "1gb"
        var buildCPUs: Int = 2
        var buildMemory: String = "2048mb"
        var buildRosetta: Bool = true
        var buildImage: String = "ghcr.io/apple/container-builder-shim/builder:0.13.1"
        var machineCPUs: Int = 4
        var machineMemory: String = "8gb"
        var machineHomeMount: String = "ro"
        var machineVirtualization: Bool = false
        var registryDomain: String = "docker.io"
        // Advanced internals: shown read-only. A wrong kernel/vminit value
        // prevents every container from booting, so Keg doesn't edit them.
        var kernelBinaryPath: String = ""
        var kernelURL: String = ""
        var vminitImage: String = ""
    }

    /// Valid values for the machine home-mount policy (HostMountOption in
    /// the container runtime): read-only, read-write, or not mounted.
    nonisolated static let homeMountOptions = ["ro", "rw", "none"]

    var settings = Settings()
    var dnsDomains: [String] = []
    var configPath: String?
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var saveNotice: String?

    /// Locations the `container` CLI reads config from, first writable wins.
    /// Homebrew's opt path is user-writable; the pkg/system paths usually
    /// need root, in which case editing is disabled honestly.
    static let configCandidates: [String] = [
        "/opt/homebrew/opt/container/etc/container/config.toml",
        "/usr/local/opt/container/etc/container/config.toml",
        "/opt/container/etc/container/config.toml",
        "/etc/container/config.toml"
    ]

    var canEdit: Bool { configPath != nil }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard ContainerCLI.isInstalled else {
            errorMessage = "Container CLI is not installed"
            return
        }

        do {
            let (code, output) = try await ContainerCLI.run(["container", "system", "property", "list", "--format", "toml"])
            guard code == 0 else {
                errorMessage = output.isEmpty ? "Failed to read platform settings" : output
                return
            }
            settings = Self.parseTOML(output)
        } catch {
            errorMessage = error.localizedDescription
        }

        configPath = Self.writableConfigPath()
        await loadDNS()
    }

    func save() async {
        guard let path = configPath else {
            errorMessage = "No writable config location found. Install via Homebrew to enable editing."
            return
        }
        let homeMount = settings.machineHomeMount.lowercased()
        guard Self.homeMountOptions.contains(homeMount) else {
            errorMessage = "Home mount must be one of: \(Self.homeMountOptions.joined(separator: ", "))."
            return
        }
        isSaving = true
        errorMessage = nil
        saveNotice = nil
        defer { isSaving = false }

        let toml = """
        # Written by Keg. Overrides platform defaults; takes effect for new
        # containers/builds/machines. Delete this file to return to defaults.

        [container]
        cpus = \(settings.containerCPUs)
        memory = "\(settings.containerMemory)"

        [build]
        cpus = \(settings.buildCPUs)
        memory = "\(settings.buildMemory)"
        rosetta = \(settings.buildRosetta)
        image = "\(settings.buildImage)"

        [machine]
        cpus = \(settings.machineCPUs)
        memory = "\(settings.machineMemory)"
        homeMount = "\(homeMount)"
        virtualization = \(settings.machineVirtualization)

        [registry]
        domain = "\(settings.registryDomain)"

        """

        do {
            let url = URL(filePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try toml.write(to: url, atomically: true, encoding: .utf8)
            saveNotice = "Saved to \(path). Applies to new containers and builds."
        } catch {
            errorMessage = "Failed to write config: \(error.localizedDescription)"
        }
    }

    func loadDNS() async {
        guard let (code, output) = try? await ContainerCLI.run(["container", "system", "dns", "list"]) else {
            dnsDomains = []
            return
        }
        guard code == 0 else {
            dnsDomains = []
            return
        }
        dnsDomains = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func writableConfigPath() -> String? {
        let fm = FileManager.default
        for candidate in configCandidates {
            if fm.fileExists(atPath: candidate) {
                // Existing file: writable?
                if fm.isWritableFile(atPath: candidate) { return candidate }
                continue
            }
            // Missing file: is the parent directory writable (or creatable)?
            let dir = (candidate as NSString).deletingLastPathComponent
            if fm.fileExists(atPath: dir) {
                if fm.isWritableFile(atPath: dir) { return candidate }
            } else if createDirIfPossible(dir) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func createDirIfPossible(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Minimal TOML reader for the flat `[section] key = value` shape that
    /// `container system property list` emits.
    nonisolated static func parseTOML(_ text: String) -> Settings {
        var result = Settings()
        var section = ""
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch (section, key) {
            case ("container", "cpus"): result.containerCPUs = Int(value) ?? result.containerCPUs
            case ("container", "memory"): result.containerMemory = value
            case ("build", "cpus"): result.buildCPUs = Int(value) ?? result.buildCPUs
            case ("build", "memory"): result.buildMemory = value
            case ("build", "rosetta"): result.buildRosetta = (value == "true")
            case ("build", "image"): result.buildImage = value
            case ("machine", "cpus"): result.machineCPUs = Int(value) ?? result.machineCPUs
            case ("machine", "memory"): result.machineMemory = value
            case ("machine", "homeMount"):
                // The segmented picker only knows these three; snap anything
                // unexpected (future values, typos in a hand-edited file) to
                // read-only, the safest policy.
                result.machineHomeMount = Self.homeMountOptions.contains(value) ? value : "ro"
            case ("machine", "virtualization"): result.machineVirtualization = (value == "true")
            case ("registry", "domain"): result.registryDomain = value
            case ("kernel", "binaryPath"): result.kernelBinaryPath = value
            case ("kernel", "url"): result.kernelURL = value
            case ("vminit", "image"): result.vminitImage = value
            default: break
            }
        }
        return result
    }
}
