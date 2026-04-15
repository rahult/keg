import Foundation
import Hummingbird

// MARK: - Container CLI Bridge

actor ContainerBridge {
    private var pendingContainers: [String: DockerContainerCreateRequest] = [:]

    func runCLI(_ args: [String]) async throws -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    func runCLIStreaming(_ args: [String]) async throws -> Process {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return process
    }

    func storePendingContainer(id: String, request: DockerContainerCreateRequest) {
        pendingContainers[id] = request
    }

    func getPendingContainer(id: String) -> DockerContainerCreateRequest? {
        pendingContainers.removeValue(forKey: id)
    }

    // MARK: - Container Operations

    func listContainers(all: Bool) async throws -> [DockerContainer] {
        var args = ["container", "list", "--format", "json"]
        if all { args.append("-a") }
        let (code, output) = try await runCLI(args)
        guard code == 0, let data = output.data(using: .utf8) else { return [] }

        if let entries = try? JSONDecoder().decode([ContainerListEntry].self, from: data) {
            return entries.map { $0.toDocker() }
        }
        return []
    }

    func createContainer(from request: DockerContainerCreateRequest, name: String?) async throws -> DockerContainerCreateResponse {
        let id = name ?? "keg-\(UUID().uuidString.prefix(12).lowercased())"
        // Store request for later use in start
        storePendingContainer(id: id, request: request)

        // Pull image if specified
        if let image = request.image, !image.isEmpty {
            let _ = try await runCLI(["container", "image", "pull", image])
        }

        return DockerContainerCreateResponse(id: id, warnings: [])
    }

    func startContainer(id: String) async throws {
        if let req = getPendingContainer(id: id) {
            // Build and run the container
            var args = ["container", "run", "-d"]

            if let name = req.name {
                args += ["--name", name]
            } else {
                args += ["--name", id]
            }

            if let env = req.env {
                for e in env {
                    args += ["-e", e]
                }
            }

            if let hostConfig = req.hostConfig {
                if let binds = hostConfig.binds {
                    for b in binds {
                        args += ["-v", b]
                    }
                }
                if let memory = hostConfig.memory, memory > 0 {
                    let mb = memory / (1024 * 1024)
                    args += ["--memory", "\(mb)M"]
                }
                if let portBindings = hostConfig.portBindings {
                    for (containerPort, bindings) in portBindings {
                        for binding in bindings {
                            let containerPortClean = containerPort.components(separatedBy: "/").first ?? containerPort
                            if let hostPort = binding.hostPort, let hostIP = binding.hostIP, hostIP != "0.0.0.0" {
                                args += ["-p", "\(hostIP):\(hostPort):\(containerPortClean)"]
                            } else if let hostPort = binding.hostPort {
                                args += ["-p", "\(hostPort):\(containerPortClean)"]
                            }
                        }
                    }
                }
            }

            if let labels = req.labels {
                for (k, v) in labels {
                    args += ["-l", "\(k)=\(v)"]
                }
            }

            if let workingDir = req.workingDir {
                args += ["-w", workingDir]
            }

            if let image = req.image {
                args.append(image)
            }

            if let cmd = req.cmd {
                args += cmd
            }

            let (code, output) = try await runCLI(args)
            if code != 0 {
                throw DockerAPIError.containerStartFailed(output)
            }
        } else {
            // Container already created, just start it
            let (code, output) = try await runCLI(["container", "start", id])
            if code != 0 {
                throw DockerAPIError.containerStartFailed(output)
            }
        }
    }

    func stopContainer(id: String) async throws {
        let _ = try await runCLI(["container", "stop", id])
    }

    func killContainer(id: String) async throws {
        let _ = try await runCLI(["container", "kill", id])
    }

    func removeContainer(id: String, force: Bool) async throws {
        var args = ["container", "delete"]
        if force { args.append("-f") }
        args.append(id)
        let _ = try await runCLI(args)
    }

    func inspectContainer(id: String) async throws -> DockerContainerInspect {
        let (code, output) = try await runCLI(["container", "inspect", id])
        guard code == 0 else {
            throw DockerAPIError.containerNotFound(id)
        }

        // Parse the inspect output and convert to Docker format
        let data = output.data(using: .utf8) ?? Data()
        return try parseContainerInspect(data, id: id)
    }

    func containerLogs(id: String, tail: Int?, follow: Bool) async throws -> String {
        var args = ["container", "logs"]
        if let tail = tail {
            args += ["-n", "\(tail)"]
        }
        if follow {
            args.append("-f")
        }
        args.append(id)
        let (code, output) = try await runCLI(args)
        guard code == 0 else { return "" }
        return output
    }

    // MARK: - Image Operations

    func listImages() async throws -> [DockerImage] {
        let (code, output) = try await runCLI(["container", "image", "list", "--format", "json"])
        guard code == 0, let data = output.data(using: .utf8) else { return [] }

        if let entries = try? JSONDecoder().decode([ImageListEntry].self, from: data) {
            return entries.map { $0.toDocker() }
        }
        return []
    }

    func pullImage(from input: String) async throws {
        // Parse image reference from input like "fromImage=nginx:latest"
        var imageRef = input
        if input.hasPrefix("fromImage=") {
            imageRef = String(input.dropFirst("fromImage=".count))
        }

        let (code, output) = try await runCLI(["container", "image", "pull", imageRef])
        if code != 0 {
            throw DockerAPIError.imagePullFailed(output)
        }
    }

    func inspectImage(name: String) async throws -> DockerImage {
        let (code, output) = try await runCLI(["container", "image", "inspect", name])
        guard code == 0 else {
            throw DockerAPIError.imageNotFound(name)
        }
        return try parseImageInspect(output, name: name)
    }

    func removeImage(name: String) async throws {
        let _ = try await runCLI(["container", "image", "delete", name])
    }

    // MARK: - System

    func systemInfo() async throws -> DockerInfo {
        let (_, containerOutput) = try await runCLI(["container", "list", "--format", "json"])
        let (_, imageOutput) = try await runCLI(["container", "image", "list", "--format", "json"])

        let containerCount = countJSONArrayEntries(containerOutput)
        let imageCount = countJSONArrayEntries(imageOutput)

        return DockerInfo(
            id: UUID().uuidString,
            containers: containerCount,
            containersRunning: containerCount,
            containersStopped: 0,
            images: imageCount,
            operatingSystem: "macOS (Apple Container)",
            architecture: "arm64",
            kernelVersion: "Darwin",
            serverVersion: "keg-0.1.0",
            dockerRootDir: NSHomeDirectory() + "/.keg"
        )
    }

    func systemVersion() async throws -> DockerVersion {
        let (_, output) = try await runCLI(["container", "system", "version", "--format", "json"])
        let apiVersion = output.contains("\"version\"") ? "1.45" : "1.45"

        return DockerVersion(
            version: "0.1.0",
            apiVersion: apiVersion,
            minAPIVersion: "1.24",
            gitCommit: "keg",
            goVersion: "swift",
            os: "darwin",
            arch: "arm64",
            kernelVersion: "Darwin",
            buildTime: ""
        )
    }

    // MARK: - Parsing Helpers

    private func parseContainerInspect(_ data: Data, id: String) throws -> DockerContainerInspect {
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = jsonArray.first else {
            throw DockerAPIError.containerNotFound(id)
        }

        let cfg = entry["configuration"] as? [String: Any]
        let status = (entry["status"] as? String) ?? ""
        let networks = (entry["networks"] as? [[String: Any]]) ?? []
        let firstNet = networks.first

        let state = DockerContainerState(
            status: status,
            running: status == "running",
            paused: false,
            restarting: false,
            dead: status == "stopped",
            pid: nil,
            exitCode: nil,
            startedAt: "",
            finishedAt: ""
        )

        let initProc = cfg?["initProcess"] as? [String: Any]
        let imgRef = (cfg?["image"] as? [String: Any])?["reference"] as? String

        return DockerContainerInspect(
            id: cfg?["id"] as? String ?? id,
            created: "",
            path: initProc?["executable"] as? String ?? "",
            args: initProc?["arguments"] as? [String] ?? [],
            state: state,
            image: imgRef ?? "",
            name: "/" + (cfg?["id"] as? String ?? id),
            config: DockerContainerConfig(
                image: imgRef,
                cmd: initProc?["arguments"] as? [String],
                env: initProc?["environment"] as? [String],
                labels: cfg?["labels"] as? [String: String],
                tty: initProc?["terminal"] as? Bool,
                openStdin: nil,
                workingDir: initProc?["workingDirectory"] as? String
            ),
            networkSettings: DockerInspectNetworkSettings(
                ipAddress: firstNet?["ipv4Address"] as? String,
                gateway: firstNet?["ipv4Gateway"] as? String,
                ports: nil,
                networks: nil
            )
        )
    }

    private func parseImageInspect(_ output: String, name: String) throws -> DockerImage {
        guard let data = output.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = jsonArray.first else {
            return DockerImage(id: "sha256:" + name, repoTags: [name], repoDigests: nil, created: 0, size: 0, labels: nil)
        }

        let descriptor = entry["descriptor"] as? [String: Any]
        let digest = descriptor?["digest"] as? String
        let size = (descriptor?["size"] as? Int).map { Int64($0) } ?? Int64(0)
        let annotations = descriptor?["annotations"] as? [String: String]
        let imgName = annotations?["com.apple.containerization.image.name"] ?? name

        return DockerImage(
            id: "sha256:" + (digest ?? name),
            repoTags: [imgName],
            repoDigests: digest.map { ["\(imgName)@\($0)"] },
            created: 0,
            size: size,
            labels: annotations
        )
    }
}

// MARK: - Intermediate parsing types

private struct ContainerListEntry: Codable {
    let configuration: Configuration
    let status: String?

    struct Configuration: Codable {
        let id: String
        let image: ContainerImageRef?

        struct ContainerImageRef: Codable {
            let reference: String
        }
    }

    func toDocker() -> DockerContainer {
        DockerContainer(
            id: configuration.id,
            names: ["/" + configuration.id],
            image: configuration.image?.reference ?? "",
            imageID: "",
            command: "",
            created: 0,
            state: status == "running" ? "running" : "exited",
            status: status ?? "",
            ports: nil,
            labels: nil,
            networkSettings: nil
        )
    }
}

private struct ImageListEntry: Codable {
    let reference: String
    let digest: String?

    func toDocker() -> DockerImage {
        DockerImage(
            id: "sha256:" + (digest ?? reference),
            repoTags: [reference],
            repoDigests: digest.map { ["\(reference)@\($0)"] },
            created: 0,
            size: 0,
            labels: nil
        )
    }
}

// MARK: - Helpers

private func countJSONArrayEntries(_ output: String) -> Int {
    guard let data = output.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
        return 0
    }
    return array.count
}

// MARK: - Errors

enum DockerAPIError: Error, CustomStringConvertible {
    case containerNotFound(String)
    case imageNotFound(String)
    case containerStartFailed(String)
    case imagePullFailed(String)
    case badRequest(String)
    case webhookNotFound(String)

    var description: String {
        switch self {
        case .containerNotFound(let id): return "Container not found: \(id)"
        case .imageNotFound(let name): return "Image not found: \(name)"
        case .containerStartFailed(let msg): return "Container start failed: \(msg)"
        case .imagePullFailed(let msg): return "Image pull failed: \(msg)"
        case .badRequest(let msg): return "Bad request: \(msg)"
        case .webhookNotFound(let id): return "Webhook not found: \(id)"
        }
    }
}
