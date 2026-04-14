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
    typealias ProgressHandler = @Sendable @MainActor (String) -> Void

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

    func up(filePath: String, projectName: String?, detached: Bool, progress: ProgressHandler? = nil) async throws {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let composeDir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path

        await emit("Compose up: \(name)\nFile: \(filePath)", to: progress)

        if let networks = file.networks {
            for (networkName, _) in networks.sorted(by: { $0.key < $1.key }) {
                let args = ["container", "network", "create", "\(name)-\(networkName)"]
                let _ = try? await runLogged(args, progress: progress)
            }
        }

        if let volumes = file.volumes {
            for (volumeName, _) in volumes.sorted(by: { $0.key < $1.key }) {
                let args = ["container", "volume", "create", "\(name)-\(volumeName)"]
                let _ = try? await runLogged(args, progress: progress)
            }
        }

        let orderedServices = try topologicalSort(services: file.services)
        let declaredVolumes = Set(file.volumes?.map { $0.key } ?? [])

        for serviceName in orderedServices {
            guard let service = file.services[serviceName] else { continue }
            await emit("\n==> Service: \(serviceName)", to: progress)
            try await runService(
                serviceName: serviceName,
                service: service,
                projectName: name,
                composeDir: composeDir,
                declaredVolumes: declaredVolumes,
                detached: detached,
                progress: progress
            )
        }

        await emit("\nCompose up finished.", to: progress)
    }

    private func buildServiceImage(serviceName: String, build: ComposeBuild, projectName: String, composeDir: String, progress: ProgressHandler? = nil) async throws -> String {
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

        let (code, output) = try await runLogged(args, progress: progress)
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

    private func runService(
        serviceName: String,
        service: ComposeService,
        projectName: String,
        composeDir: String,
        declaredVolumes: Set<String>,
        detached: Bool,
        progress: ProgressHandler?
    ) async throws {
        let resolvedImage: String
        if let image = service.image, !image.isEmpty {
            resolvedImage = image
            await emit("Using image: \(image)", to: progress)
        } else if let build = service.build {
            resolvedImage = try await buildServiceImage(
                serviceName: serviceName,
                build: build,
                projectName: projectName,
                composeDir: composeDir,
                progress: progress
            )
        } else {
            throw ComposeError.missingImage(serviceName)
        }

        let containerName = service.containerName ?? "\(projectName)-\(serviceName)-1"
        var args = ["container", "run"]
        if detached {
            args.append("-d")
        }
        args += ["--name", containerName]

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
                let resolved = resolveVolume(volume, projectName: projectName, composeDir: composeDir, declaredVolumes: declaredVolumes)
                args += ["-v", resolved]
            }
        }

        if let networks = service.networks {
            for n in networks {
                args += ["--network", "\(projectName)-\(n)"]
            }
        }

        if let labels = service.labels {
            for (k, v) in labels.sorted(by: { $0.key < $1.key }) {
                args += ["-l", "\(k)=\(v)"]
            }
        }
        args += ["-l", "com.docker.compose.project=\(projectName)"]
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

        let (code, output) = try await runLogged(args, progress: progress)
        if code != 0 {
            throw ComposeError.runFailed(serviceName, output)
        }
    }

    // MARK: - Down

    func down(filePath: String, projectName: String?, progress: ProgressHandler? = nil) async throws {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        await emit("Compose down: \(name)\nFile: \(filePath)", to: progress)

        let orderedServices = try topologicalSort(services: file.services).reversed()
        for serviceName in orderedServices {
            let containerName = file.services[serviceName]?.containerName ?? "\(name)-\(serviceName)-1"
            let _ = try? await runLogged(["container", "delete", "-f", containerName], progress: progress)
        }

        if let networks = file.networks {
            for (networkName, _) in networks.sorted(by: { $0.key < $1.key }) {
                let _ = try? await runLogged(["container", "network", "delete", "\(name)-\(networkName)"], progress: progress)
            }
        }

        if let volumes = file.volumes {
            for (volumeName, _) in volumes.sorted(by: { $0.key < $1.key }) {
                let _ = try? await runLogged(["container", "volume", "delete", "\(name)-\(volumeName)"], progress: progress)
            }
        }

        await emit("\nCompose down finished.", to: progress)
    }

    func restart(filePath: String, projectName: String?, serviceName: String, progress: ProgressHandler? = nil) async throws {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let composeDir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        let declaredVolumes = Set(file.volumes?.map { $0.key } ?? [])

        guard let service = file.services[serviceName] else {
            throw ComposeError.serviceNotFound(serviceName)
        }

        await emit("Restart service: \(serviceName)", to: progress)
        let containerName = service.containerName ?? "\(name)-\(serviceName)-1"
        let _ = try? await runLogged(["container", "delete", "-f", containerName], progress: progress)
        try await runService(
            serviceName: serviceName,
            service: service,
            projectName: name,
            composeDir: composeDir,
            declaredVolumes: declaredVolumes,
            detached: true,
            progress: progress
        )
        await emit("\nRestart finished for \(serviceName).", to: progress)
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

    func logs(filePath: String, projectName: String?, serviceName: String? = nil, tail: Int?) async throws -> [(service: String, logs: String)] {
        let file = try parse(filePath: filePath)
        let name = projectName ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

        var results: [(service: String, logs: String)] = []
        for (currentServiceName, service) in file.services.sorted(by: { $0.key < $1.key }) {
            guard serviceName == nil || serviceName == currentServiceName else { continue }
            let containerName = service.containerName ?? "\(name)-\(currentServiceName)-1"
            var args = ["container", "logs"]
            if let tail = tail { args += ["-n", "\(tail)"] }
            args.append(containerName)
            let (code, output) = try await bridge.runCLI(args)
            if code == 0 {
                results.append((service: currentServiceName, logs: output))
            }
        }
        return results
    }

    private func runLogged(_ args: [String], progress: ProgressHandler?) async throws -> (exitCode: Int32, output: String) {
        await emit("$ \(formatCommand(args))", to: progress)
        let result = try await bridge.runCLI(args)
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await emit(trimmed, to: progress)
        }
        if result.exitCode != 0 {
            await emit("exit code: \(result.exitCode)", to: progress)
        }
        return result
    }

    private func emit(_ line: String, to progress: ProgressHandler?) async {
        guard let progress else { return }
        await progress(line)
    }

    private func formatCommand(_ args: [String]) -> String {
        args.map { arg in
            if arg.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) {
                let escaped = arg.replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            return arg
        }.joined(separator: " ")
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
    case serviceNotFound(String)

    var description: String {
        switch self {
        case .missingImage(let s): return "Service '\(s)' has no image specified"
        case .runFailed(let s, let m): return "Service '\(s)' failed: \(m)"
        case .circularDependency(let s): return "Circular dependency detected: \(s)"
        case .parseFailed(let m): return "Parse error: \(m)"
        case .serviceNotFound(let s): return "Service '\(s)' not found in compose file"
        }
    }
}
