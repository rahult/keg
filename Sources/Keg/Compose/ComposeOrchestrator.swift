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
        networks = try? container.decodeIfPresent([String: ComposeNetwork].self, forKey: .networks)
        volumes = try? container.decodeIfPresent([String: ComposeVolume].self, forKey: .volumes)
    }
}

struct ComposeService: Codable {
    let image: String?
    let build: ComposeBuild?
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
        build = try? container.decodeIfPresent(ComposeBuild.self, forKey: .build)
        command = try? container.decodeIfPresent(String.self, forKey: .command)
        entrypoint = try? container.decodeIfPresent(String.self, forKey: .entrypoint)

        if let envMap = try? container.decodeIfPresent([String: String].self, forKey: .environment) {
            environment = envMap.map { "\($0.key)=\($0.value)" }
        } else {
            environment = try? container.decodeIfPresent([String].self, forKey: .environment)
        }

        envFile = try? container.decodeIfPresent([String].self, forKey: .envFile)
        ports = try? container.decodeIfPresent([String].self, forKey: .ports)
        volumes = try? container.decodeIfPresent([String].self, forKey: .volumes)

        if let arr = try? container.decodeIfPresent([String].self, forKey: .dependsOn) {
            dependsOn = arr
        } else if let map = try? container.decodeIfPresent([String: ComposeDependsOnConfig].self, forKey: .dependsOn) {
            dependsOn = map.map(\.key)
        } else {
            dependsOn = nil
        }

        if let arr = try? container.decodeIfPresent([String].self, forKey: .networks) {
            networks = arr
        } else if let map = try? container.decodeIfPresent([String: ComposeNetwork].self, forKey: .networks) {
            networks = map.map(\.key)
        } else {
            networks = nil
        }

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

struct ComposeBuild: Codable {
    let context: String?
    let dockerfile: String?
    let target: String?
    let args: [String: String]?

    init(from decoder: Decoder) throws {
        if let stringValue = try? decoder.singleValueContainer().decode(String.self) {
            context = stringValue
            dockerfile = nil
            target = nil
            args = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        context = try? container.decodeIfPresent(String.self, forKey: .context)
        dockerfile = try? container.decodeIfPresent(String.self, forKey: .dockerfile)
        target = try? container.decodeIfPresent(String.self, forKey: .target)
        args = try? container.decodeIfPresent([String: String].self, forKey: .args)
    }

    enum CodingKeys: String, CodingKey {
        case context, dockerfile, target, args
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

    init(from decoder: Decoder) throws {
        if (try? decoder.singleValueContainer().decodeNil()) == true {
            driver = nil
            external = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driver = try? container.decodeIfPresent(String.self, forKey: .driver)
        external = try? container.decodeIfPresent(Bool.self, forKey: .external)
    }

    enum CodingKeys: String, CodingKey {
        case driver, external
    }
}

struct ComposeVolume: Codable {
    let driver: String?
    let external: Bool?
    let driverOpts: [String: String]?

    init(from decoder: Decoder) throws {
        if (try? decoder.singleValueContainer().decodeNil()) == true {
            driver = nil
            external = nil
            driverOpts = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driver = try? container.decodeIfPresent(String.self, forKey: .driver)
        external = try? container.decodeIfPresent(Bool.self, forKey: .external)
        driverOpts = try? container.decodeIfPresent([String: String].self, forKey: .driverOpts)
    }

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
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            return try YAMLDecoder().decode(ComposeFile.self, from: content)
        } catch {
            throw ComposeError.parseFailed(error.localizedDescription)
        }
    }

    // MARK: - Up

    func up(filePath: String, projectName: String?, detached: Bool) async throws {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let composeDir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path

        if let networks = file.networks {
            for (networkName, _) in networks {
                let _ = try? await bridge.runCLI(["container", "network", "create", "\(name)-\(networkName)"])
            }
        }

        if let volumes = file.volumes {
            for (volumeName, _) in volumes {
                let _ = try? await bridge.runCLI(["container", "volume", "create", "\(name)-\(volumeName)"])
            }
        }

        let orderedServices = try topologicalSort(services: file.services)

        for serviceName in orderedServices {
            guard let service = file.services[serviceName] else { continue }

            let resolvedImage: String
            if let image = service.image, !image.isEmpty {
                resolvedImage = image
            } else if let build = service.build {
                resolvedImage = try await buildServiceImage(
                    serviceName: serviceName,
                    build: build,
                    projectName: name,
                    composeDir: composeDir
                )
            } else {
                throw ComposeError.missingImage(serviceName)
            }

            let containerName = service.containerName ?? "\(name)-\(serviceName)-1"
            var args = ["container", "run", "-d", "--name", containerName]

            if let env = service.environment {
                for e in env {
                    args += ["-e", e]
                }
            }

            if let ports = service.ports {
                for p in ports {
                    args += ["-p", p]
                }
            }

            if let vols = service.volumes {
                for volume in vols {
                    let declaredVolumes = Set(file.volumes?.map { $0.key } ?? [])
                    let resolved = resolveVolume(volume, projectName: name, composeDir: composeDir, declaredVolumes: declaredVolumes)
                    args += ["-v", resolved]
                }
            }

            if let networks = service.networks {
                for n in networks {
                    args += ["--network", "\(name)-\(n)"]
                }
            }

            if let labels = service.labels {
                for (k, v) in labels {
                    args += ["-l", "\(k)=\(v)"]
                }
            }
            args += ["-l", "com.docker.compose.project=\(name)"]
            args += ["-l", "com.docker.compose.service=\(serviceName)"]

            if let wd = service.workingDir {
                args += ["-w", wd]
            }

            if let deploy = service.deploy, let limits = deploy.resources?.limits {
                if let cpus = limits.cpus { args += ["--cpus", cpus] }
                if let memory = limits.memory { args += ["--memory", memory] }
            }

            args.append(resolvedImage)

            if let cmd = service.command {
                args += ["sh", "-lc", cmd]
            }

            let (code, output) = try await bridge.runCLI(args)
            if code != 0 {
                throw ComposeError.runFailed(serviceName, output)
            }
        }
    }

    private func buildServiceImage(serviceName: String, build: ComposeBuild, projectName: String, composeDir: String) async throws -> String {
        let tag = "\(projectName)-\(serviceName):local"
        var args = ["container", "build", "--tag", tag]

        if let dockerfile = build.dockerfile, !dockerfile.isEmpty {
            let dockerfilePath = dockerfile.hasPrefix("/") ? dockerfile : URL(fileURLWithPath: composeDir).appendingPathComponent(dockerfile).path
            args += ["--file", dockerfilePath]
        }

        if let target = build.target, !target.isEmpty {
            args += ["--target", target]
        }

        if let buildArgs = build.args {
            for (key, value) in buildArgs {
                args += ["--build-arg", "\(key)=\(value)"]
            }
        }

        let contextPath: String
        if let context = build.context, !context.isEmpty {
            contextPath = context.hasPrefix("/") ? context : URL(fileURLWithPath: composeDir).appendingPathComponent(context).path
        } else {
            contextPath = composeDir
        }
        args.append(contextPath)

        let (code, output) = try await bridge.runCLI(args)
        if code != 0 {
            throw ComposeError.runFailed(serviceName, output)
        }
        return tag
    }

    private func resolveVolume(_ volume: String, projectName: String, composeDir: String, declaredVolumes: Set<String>) -> String {
        guard let source = volume.split(separator: ":", maxSplits: 1).first else { return volume }
        let sourceString = String(source)

        if declaredVolumes.contains(sourceString) {
            return volume.replacingOccurrences(of: sourceString, with: "\(projectName)-\(sourceString)", options: .anchored)
        }

        if sourceString.hasPrefix("/") || sourceString.hasPrefix("~/") || sourceString.hasPrefix(".") {
            let resolvedSource: String
            if sourceString.hasPrefix("~/") {
                resolvedSource = NSString(string: sourceString).expandingTildeInPath
            } else if sourceString.hasPrefix(".") {
                resolvedSource = URL(fileURLWithPath: composeDir).appendingPathComponent(sourceString).standardized.path
            } else {
                resolvedSource = sourceString
            }
            return volume.replacingOccurrences(of: sourceString, with: resolvedSource, options: .anchored)
        }

        return volume
    }

    // MARK: - Down

    func down(filePath: String, projectName: String?) async throws {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        let orderedServices = try topologicalSort(services: file.services).reversed()
        for serviceName in orderedServices {
            let containerName = file.services[serviceName]?.containerName ?? "\(name)-\(serviceName)-1"
            let _ = try? await bridge.runCLI(["container", "delete", "-f", containerName])
        }

        if let networks = file.networks {
            for (networkName, _) in networks {
                let _ = try? await bridge.runCLI(["container", "network", "delete", "\(name)-\(networkName)"])
            }
        }

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
        let (code, output) = try await bridge.runCLI(["container", "list", "-a", "--format", "json"])
        guard code == 0 else { return results }

        for (serviceName, service) in file.services {
            let containerName = service.containerName ?? "\(name)-\(serviceName)-1"
            for line in output.split(separator: "\n") where line.contains(containerName) {
                let state = line.contains("\"running\"") ? "running" : "stopped"
                results.append((name: containerName, service: serviceName, state: state))
            }
        }
        return results
    }

    // MARK: - Logs

    func logs(filePath: String, projectName: String?, tail: Int?) async throws -> [(service: String, logs: String)] {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        var results: [(service: String, logs: String)] = []
        for (serviceName, service) in file.services {
            let containerName = service.containerName ?? "\(name)-\(serviceName)-1"
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
