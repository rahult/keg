import Foundation
import Yams

// MARK: - Compose File Types

struct ComposeFile: Codable {
    let version: String?
    let services: [String: ComposeService]
    let networks: [String: ComposeNetwork]?
    let volumes: [String: ComposeVolume]?

    enum CodingKeys: String, CodingKey {
        case version, services, networks, volumes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        services = (try? container.decode([String: ComposeService].self, forKey: .services)) ?? [:]
        networks = try container.decodeIfPresent([String: ComposeNetwork].self, forKey: .networks)
        volumes = try container.decodeIfPresent([String: ComposeVolume].self, forKey: .volumes)
    }
}

struct ComposeService: Codable {
    let image: String?
    let build: String?
    let command: String?
    let entrypoint: String?
    let environment: [String]?
    let envFile: [String]?
    let ports: [String]?
    let volumes: [String]?
    let dependsOn: [String]?
    let networks: [String]?
    let labels: [String: String]?
    let restart: String?
    let workingDir: String?
    let containerName: String?
    let hostname: String?
    let privileged: Bool?
    let stdinOpen: Bool?
    let tty: Bool?
    let healthcheck: ComposeHealthcheck?
    let deploy: ComposeDeploy?

    enum CodingKeys: String, CodingKey {
        case image, build, command, entrypoint, environment, ports, volumes
        case dependsOn, networks, labels, restart, workingDir, containerName, hostname
        case privileged, tty, healthcheck, deploy
        case envFile = "env_file"
        case stdinOpen = "stdin_open"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        build = try container.decodeIfPresent(String.self, forKey: .build)
        command = try? container.decodeIfPresent(String.self, forKey: .command)
        entrypoint = try? container.decodeIfPresent(String.self, forKey: .entrypoint)

        // Environment can be map or array
        if let envMap = try? container.decodeIfPresent([String: String].self, forKey: .environment) {
            environment = envMap.map { "\($0.key)=\($0.value)" }
        } else {
            environment = try? container.decodeIfPresent([String].self, forKey: .environment)
        }

        envFile = try? container.decodeIfPresent([String].self, forKey: .envFile)
        ports = try? container.decodeIfPresent([String].self, forKey: .ports)
        volumes = try? container.decodeIfPresent([String].self, forKey: .volumes)

        // depends_on can be array or map
        if let arr = try? container.decodeIfPresent([String].self, forKey: .dependsOn) {
            dependsOn = arr
        } else if let _ = try? container.decodeIfPresent([String: ComposeDependsOnConfig].self, forKey: .dependsOn) {
            dependsOn = nil // extract keys later if needed
        } else {
            dependsOn = nil
        }

        networks = try? container.decodeIfPresent([String].self, forKey: .networks)
        labels = try? container.decodeIfPresent([String: String].self, forKey: .labels)
        restart = try? container.decodeIfPresent(String.self, forKey: .restart)
        workingDir = try? container.decodeIfPresent(String.self, forKey: .workingDir)
        containerName = try? container.decodeIfPresent(String.self, forKey: .containerName)
        hostname = try? container.decodeIfPresent(String.self, forKey: .hostname)
        privileged = try? container.decodeIfPresent(Bool.self, forKey: .privileged)
        stdinOpen = try? container.decodeIfPresent(Bool.self, forKey: .stdinOpen)
        tty = try? container.decodeIfPresent(Bool.self, forKey: .tty)
        healthcheck = try? container.decodeIfPresent(ComposeHealthcheck.self, forKey: .healthcheck)
        deploy = try? container.decodeIfPresent(ComposeDeploy.self, forKey: .deploy)
    }
}

struct ComposeHealthcheck: Codable {
    let test: [String]?
    let interval: String?
    let timeout: String?
    let retries: Int?
    let startPeriod: String?

    enum CodingKeys: String, CodingKey {
        case test, interval, timeout, retries
        case startPeriod = "start_period"
    }
}

struct ComposeDeploy: Codable {
    let resources: ComposeResources?

    struct ComposeResources: Codable {
        let limits: ComposeResourceLimit?
    }

    struct ComposeResourceLimit: Codable {
        let cpus: String?
        let memory: String?
    }
}

struct ComposeDependsOnConfig: Codable {
    let condition: String?
    let restart: Bool?
}

struct ComposeNetwork: Codable {
    let driver: String?
    let external: Bool?
}

struct ComposeVolume: Codable {
    let driver: String?
    let external: Bool?
    let driverOpts: [String: String]?

    enum CodingKeys: String, CodingKey {
        case driver, external
        case driverOpts = "driver_opts"
    }
}

// MARK: - Compose Orchestrator

actor ComposeOrchestrator {
    private let bridge = ContainerBridge()

    struct ComposeProject: Sendable {
        let name: String
        let composeFile: ComposeFile
        let workDir: String
    }

    // MARK: - Parse

    func parse(filePath: String) throws -> ComposeFile {
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        return try YAMLDecoder().decode(ComposeFile.self, from: content)
    }

    // MARK: - Up

    func up(filePath: String, projectName: String?, detached: Bool) async throws {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        // Create networks
        if let networks = file.networks {
            for (networkName, _) in networks {
                let _ = try? await bridge.runCLI(["container", "network", "create", "\(name)-\(networkName)"])
            }
        }

        // Create volumes
        if let volumes = file.volumes {
            for (volumeName, _) in volumes {
                let _ = try? await bridge.runCLI(["container", "volume", "create", "\(name)-\(volumeName)"])
            }
        }

        // Resolve service order (topological sort based on depends_on)
        let orderedServices = try topologicalSort(services: file.services)

        for serviceName in orderedServices {
            guard let service = file.services[serviceName] else { continue }
            guard let image = service.image, !image.isEmpty else {
                throw ComposeError.missingImage(serviceName)
            }

            let containerName = service.containerName ?? "\(name)-\(serviceName)-1"

            // Build run args
            var args = ["container", "run", "-d", "--name", containerName]

            // Environment
            if let env = service.environment {
                for e in env {
                    args += ["-e", e]
                }
            }

            // Ports
            if let ports = service.ports {
                for p in ports {
                    args += ["-p", p]
                }
            }

            // Volumes
            if let vols = service.volumes {
                for v in vols {
                    // Replace named volumes with project-prefixed names
                    let resolved: String
                    if !v.contains(":") || v.firstMatch(of: /^[\w.-]+\//) != nil {
                        resolved = v // Host path, use as-is
                    } else if let volName = v.split(separator: ":").first, file.volumes?.keys.contains(String(volName)) == true {
                        resolved = "\(name)-\(v)" // Named volume
                    } else {
                        resolved = v
                    }
                    args += ["-v", resolved]
                }
            }

            // Network
            if let networks = service.networks {
                for n in networks {
                    args += ["--network", "\(name)-\(n)"]
                }
            }

            // Labels
            if let labels = service.labels {
                for (k, v) in labels {
                    args += ["-l", "\(k)=\(v)"]
                }
            }
            // Add compose labels
            args += ["-l", "com.docker.compose.project=\(name)"]
            args += ["-l", "com.docker.compose.service=\(serviceName)"]

            // Working dir
            if let wd = service.workingDir {
                args += ["-w", wd]
            }

            // Resource limits
            if let deploy = service.deploy, let limits = deploy.resources?.limits {
                if let cpus = limits.cpus {
                    args += ["--cpus", cpus]
                }
                if let memory = limits.memory {
                    args += ["--memory", memory]
                }
            }

            // Image
            args.append(image)

            // Command
            if let cmd = service.command {
                args += cmd.split(separator: " ").map(String.init)
            }

            let (code, output) = try await bridge.runCLI(args)
            if code != 0 {
                throw ComposeError.runFailed(serviceName, output)
            }
        }
    }

    // MARK: - Down

    func down(filePath: String, projectName: String?) async throws {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        // Stop and remove containers (reverse order)
        let orderedServices = try topologicalSort(services: file.services).reversed()
        for serviceName in orderedServices {
            let containerName = file.services[serviceName]?.containerName ?? "\(name)-\(serviceName)-1"
            let _ = try? await bridge.runCLI(["container", "delete", "-f", containerName])
        }

        // Remove networks
        if let networks = file.networks {
            for (networkName, _) in networks {
                let _ = try? await bridge.runCLI(["container", "network", "delete", "\(name)-\(networkName)"])
            }
        }

        // Remove volumes
        if let volumes = file.volumes {
            for (volumeName, _) in volumes {
                let _ = try? await bridge.runCLI(["container", "volume", "delete", "\(name)-\(volumeName)"])
            }
        }
    }

    // MARK: - PS

    func ps(filePath: String, projectName: String?) async throws -> [(name: String, service: String, state: String)] {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        var results: [(name: String, service: String, state: String)] = []
        for (serviceName, _) in file.services {
            let containerName = file.services[serviceName]?.containerName ?? "\(name)-\(serviceName)-1"
            let (code, output) = try await bridge.runCLI(["container", "list", "-a", "--format", "json"])
            if code == 0 {
                for line in output.split(separator: "\n") where line.contains(containerName) {
                    let state = line.contains("\"running\"") ? "running" : "stopped"
                    results.append((name: containerName, service: serviceName, state: state))
                }
            }
        }
        return results
    }

    // MARK: - Logs

    func logs(filePath: String, projectName: String?, tail: Int?) async throws -> [(service: String, logs: String)] {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        var results: [(service: String, logs: String)] = []
        for (serviceName, _) in file.services {
            let containerName = file.services[serviceName]?.containerName ?? "\(name)-\(serviceName)-1"
            var args = ["container", "logs"]
            if let tail = tail { args += ["-n", "\(tail)"] }
            args.append(containerName)
            let (code, output) = try await bridge.runCLI(args)
            if code == 0 {
                results.append((service: serviceName, logs: output))
            }
        }
        return results
    }

    // MARK: - Topological Sort

    private func topologicalSort(services: [String: ComposeService]) throws -> [String] {
        var visited = Set<String>()
        var visiting = Set<String>()
        var result = [String]()

        func visit(_ name: String) throws {
            guard services[name] != nil else { return }
            if visited.contains(name) { return }
            if visiting.contains(name) {
                throw ComposeError.circularDependency(name)
            }
            visiting.insert(name)

            if let deps = services[name]?.dependsOn {
                for dep in deps {
                    try visit(dep)
                }
            }

            visiting.remove(name)
            visited.insert(name)
            result.append(name)
        }

        for name in services.keys.sorted() {
            try visit(name)
        }

        return result
    }
}

enum ComposeError: Error, CustomStringConvertible {
    case missingImage(String)
    case runFailed(String, String)
    case circularDependency(String)
    case parseFailed(String)

    var description: String {
        switch self {
        case .missingImage(let s): return "Service '\(s)' has no image specified"
        case .runFailed(let s, let m): return "Service '\(s)' failed: \(m)"
        case .circularDependency(let s): return "Circular dependency detected: \(s)"
        case .parseFailed(let m): return "Parse error: \(m)"
        }
    }
}
