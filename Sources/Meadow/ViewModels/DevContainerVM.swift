import Foundation

struct DevContainerSpec: Codable {
    let name: String?
    let image: String?
    let dockerFile: String?
    let build: BuildConfig?
    let forwardPorts: [PortValue]?
    let portsAttributes: [String: PortAttributes]?
    let containerEnv: [String: String]?
    let mounts: [String]?
    let workspaceMount: String?
    let workspaceFolder: String?
    let runArgs: [String]?
    let initializeCommand: String?
    let postCreateCommand: String?
    let postStartCommand: String?

    struct BuildConfig: Codable {
        let dockerfile: String?
        let context: String?
        let args: [String: String]?
    }

    // Port values can be Int or String in devcontainer.json
    enum PortValue: Codable {
        case int(Int)
        case string(String)

        var portNumber: UInt16? {
            switch self {
            case .int(let i): return UInt16(i)
            case .string(let s): return UInt16(s)
            }
        }

        init(from decoder: Decoder) throws {
            if let i = try? decoder.singleValueContainer().decode(Int.self) {
                self = .int(i)
            } else {
                self = .string(try decoder.singleValueContainer().decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let i): try container.encode(i)
            case .string(let s): try container.encode(s)
            }
        }
    }

    struct PortAttributes: Codable {
        let label: String?
        let onAutoForward: String?
    }
}

@Observable
@MainActor
final class DevContainerVM {
    var projectPath = ""
    var spec: DevContainerSpec?
    var isRunning = false
    var errorMessage: String?
    var detectedConfigs: [URL] = []
    var isLaunching = false

    func scanProject(at path: String) {
        projectPath = path
        detectedConfigs = []
        spec = nil
        errorMessage = nil

        let devcontainerDir = path + "/.devcontainer"
        let fm = FileManager.default

        guard fm.fileExists(atPath: devcontainerDir) else {
            errorMessage = "No .devcontainer directory found"
            return
        }

        // Look for devcontainer.json files
        if let contents = try? fm.contentsOfDirectory(atPath: devcontainerDir) {
            for file in contents {
                if file.hasSuffix(".json") {
                    detectedConfigs.append(URL(fileURLWithPath: devcontainerDir + "/" + file))
                }
            }
        }

        // Auto-load devcontainer.json if it exists
        let defaultConfig = URL(fileURLWithPath: devcontainerDir + "/devcontainer.json")
        if fm.fileExists(atPath: defaultConfig.path) {
            loadConfig(url: defaultConfig)
        } else if let first = detectedConfigs.first {
            loadConfig(url: first)
        }
    }

    func loadConfig(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            spec = try JSONDecoder().decode(DevContainerSpec.self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to parse devcontainer.json: \(error.localizedDescription)"
            spec = nil
        }
    }

    func buildAndRun() async {
        guard let spec else {
            errorMessage = "No devcontainer.json loaded"
            return
        }

        guard let image = spec.image, !image.isEmpty else {
            errorMessage = "No image specified in devcontainer.json"
            return
        }

        isLaunching = true
        errorMessage = nil

        var args = ["container", "run", "-d"]

        // Name
        if let name = spec.name {
            args += ["--name", name.lowercased().replacingOccurrences(of: " ", with: "-")]
        }

        // Ports
        if let ports = spec.forwardPorts {
            for port in ports {
                if let num = port.portNumber {
                    args += ["-p", "\(num):\(num)"]
                }
            }
        }

        // Environment
        if let env = spec.containerEnv {
            for (key, value) in env {
                args += ["-e", "\(key)=\(value)"]
            }
        }

        // Mounts
        if let mounts = spec.mounts {
            for mount in mounts {
                args += ["-v", mount]
            }
        }

        // Workspace mount
        if let workspaceMount = spec.workspaceMount, !workspaceMount.isEmpty {
            args += ["-v", workspaceMount]
        }

        // Extra run args
        if let runArgs = spec.runArgs {
            args += runArgs
        }

        args.append(image)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLaunching = false
    }
}
