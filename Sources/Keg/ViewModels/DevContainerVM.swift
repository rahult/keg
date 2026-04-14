import Foundation

@Observable
@MainActor
final class DevContainerVM {
    var projectDirectory = ""
    var spec: DevContainerSpec?
    var isLoading = false
    var isRunning = false
    var errorMessage: String?
    var output = ""
    var devcontainerPath: String?

    /// Config summary for display
    struct ConfigSummary {
        let name: String
        let image: String
        let ports: [String]
        let envCount: Int
        let mountCount: Int
        let hasPostCreateCommand: Bool
        let hasFeatures: Bool
    }

    var summary: ConfigSummary? {
        guard let spec else { return nil }
        return ConfigSummary(
            name: spec.name ?? "Unnamed",
            image: spec.resolvedImage ?? spec.dockerFile ?? "Unknown",
            ports: (spec.forwardPorts ?? []).map(\.displayValue),
            envCount: (spec.containerEnv ?? [:]).count + (spec.remoteEnv ?? [:]).count,
            mountCount: (spec.mounts ?? []).count,
            hasPostCreateCommand: spec.postCreateCommand != nil || spec.postStartCommand != nil,
            hasFeatures: !(spec.features ?? [:]).isEmpty
        )
    }

    /// Auto-detect devcontainer.json in a project directory
    func detectDevContainer(in directory: String) {
        projectDirectory = directory
        errorMessage = nil
        spec = nil
        devcontainerPath = nil

        let fm = FileManager.default
        let candidates = [
            "\(directory)/.devcontainer/devcontainer.json",
            "\(directory)/.devcontainer.json",
        ]

        for path in candidates {
            if fm.fileExists(atPath: path) {
                devcontainerPath = path
                parseDevContainer(at: path)
                return
            }
        }

        errorMessage = "No devcontainer.json found in \(directory)"
    }

    /// Parse a specific devcontainer.json file
    func parseDevContainer(at path: String) {
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            spec = try decoder.decode(DevContainerSpec.self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to parse devcontainer.json: \(error.localizedDescription)"
            spec = nil
        }
    }

    /// Generate `container run` CLI arguments from the spec
    func generateRunArgs() -> [String] {
        guard let spec else { return [] }

        var args = ["container", "run", "-d"]

        // Container name
        if let name = spec.name {
            let sanitized = name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "_", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            args += ["--name", sanitized]
        }

        // Environment variables
        if let env = spec.containerEnv {
            for (key, value) in env {
                args += ["-e", "\(key)=\(value)"]
            }
        }
        if let env = spec.remoteEnv {
            for (key, value) in env {
                args += ["-e", "\(key)=\(value)"]
            }
        }

        // Port forwarding
        if let ports = spec.forwardPorts {
            for port in ports {
                let portStr = port.displayValue
                if let _ = Int(portStr) {
                    args += ["-p", "\(portStr):\(portStr)"]
                } else {
                    // hostPort:containerPort format already
                    args += ["-p", portStr]
                }
            }
        }

        // Mounts
        if let mounts = spec.mounts {
            for mount in mounts {
                // Parse mount string: type=bind,source=...,target=...
                if mount.hasPrefix("type=") {
                    // Extract source and target from bind mount spec
                    let parts = mount.split(separator: ",").map(String.init)
                    var source = ""
                    var target = ""
                    for part in parts {
                        if part.hasPrefix("source=") {
                            source = String(part.dropFirst("source=".count))
                        } else if part.hasPrefix("target=") {
                            target = String(part.dropFirst("target=".count))
                        }
                    }
                    if !source.isEmpty && !target.isEmpty {
                        args += ["-v", "\(source):\(target)"]
                    }
                } else {
                    // Assume simple host-path:container-path format
                    args += ["-v", mount]
                }
            }
        }

        // Workspace mount
        if let workspaceMount = spec.workspaceMount {
            args += ["-v", workspaceMount]
        } else if !projectDirectory.isEmpty, spec.workspaceFolder != nil {
            args += ["-v", "\(projectDirectory):\(spec.workspaceFolder!)"]
        }

        // Extra run args from spec
        if let runArgs = spec.runArgs {
            args += runArgs
        }

        // Image
        if let image = spec.resolvedImage {
            args.append(image)
        } else if let dockerfile = spec.dockerFile {
            // Need to build first — append a placeholder
            args.append("devcontainer-built:latest")
        }

        return args
    }

    /// Build image from Dockerfile if needed, then run
    func openInContainer() {
        guard let spec else {
            errorMessage = "No devcontainer.json loaded"
            return
        }

        isRunning = true
        output = ""
        errorMessage = nil

        Task {
            do {
                // If Dockerfile-based, build first
                if spec.usesDockerfile {
                    let dockerfilePath = spec.dockerFile ?? spec.build?.dockerfile ?? "Dockerfile"
                    let context = spec.build?.context ?? spec.context ?? projectDirectory
                    let tag = spec.build?.tag ?? "devcontainer-\(spec.name?.lowercased().replacingOccurrences(of: " ", with: "-") ?? "latest")"

                    output += "Building image from \(dockerfilePath)...\n"
                    let (buildCode, buildOut) = try await runCLI([
                        "container", "build",
                        "--file", dockerfilePath.hasPrefix("/") ? dockerfilePath : "\(projectDirectory)/\(dockerfilePath)",
                        "--tag", tag,
                        context
                    ])
                    output += buildOut + "\n"
                    if buildCode != 0 {
                        errorMessage = "Build failed (exit code \(buildCode))"
                        isRunning = false
                        return
                    }
                }

                // Run container
                var args = generateRunArgs()
                if spec.usesDockerfile {
                    // Replace the placeholder image with the built tag
                    let tag = spec.build?.tag ?? "devcontainer-\(spec.name?.lowercased().replacingOccurrences(of: " ", with: "-") ?? "latest")"
                    if let idx = args.lastIndex(of: "devcontainer-built:latest") {
                        args[idx] = tag
                    }
                }

                output += "Running container...\n"
                let (runCode, runOut) = try await runCLI(args)
                output += runOut + "\n"

                if runCode != 0 {
                    errorMessage = "Container run failed (exit code \(runCode))"
                } else {
                    output += "\n✅ Container started!\n"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runCLI(_ args: [String]) async throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
