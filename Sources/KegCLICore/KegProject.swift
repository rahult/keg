import Foundation
import Yams

// MARK: - Errors

/// One failure with the service/field context an agent or human needs to
/// fix the file without reading the parser.
public struct KegProjectError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Schema

public struct KegBuild: Sendable, Equatable {
    public var context: String
    public var dockerfile: String?
    public var args: [String: String]

    public init(context: String, dockerfile: String? = nil, args: [String: String] = [:]) {
        self.context = context
        self.dockerfile = dockerfile
        self.args = args
    }
}

public struct KegPortMapping: Sendable, Equatable {
    public var hostIP: String?
    public var hostPort: UInt16
    public var containerPort: UInt16
    public var proto: String

    public init(hostIP: String? = nil, hostPort: UInt16, containerPort: UInt16, proto: String = "tcp") {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    public var url: String { "http://127.0.0.1:\(hostPort)" }
}

public struct KegService: Sendable, Equatable {
    public var image: String?
    public var build: KegBuild?
    public var ports: [KegPortMapping]
    public var environment: [String: String]
    public var envFile: String?
    public var volumes: [String]
    public var command: [String]
    public var entrypoint: [String]
    public var workdir: String?
    public var platform: String?
    public var restart: String?
    public var dependsOn: [String]
    public var labels: [String: String]

    public init() {
        image = nil
        build = nil
        ports = []
        environment = [:]
        envFile = nil
        volumes = []
        command = []
        entrypoint = []
        workdir = nil
        platform = nil
        restart = nil
        dependsOn = []
        labels = [:]
    }
}

public struct KegProjectConfig: Sendable, Equatable {
    public var name: String
    public var services: [String: KegService]
    /// Directory holding keg.yaml — relative binds and builds resolve here.
    public var directory: String

    public init(name: String, services: [String: KegService], directory: String) {
        self.name = name
        self.services = services
        self.directory = directory
    }

    public static let fileName = "keg.yaml"
    public static let altFileName = "keg.yml"

    /// keg.yaml / keg.yml in `directory`, checked in that order.
    public static func find(in directory: String) -> String? {
        for candidate in [fileName, altFileName] {
            let path = URL(filePath: directory).appendingPathComponent(candidate).path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - Parsing

public enum KegProjectLoader {
    /// Load and validate a project from the directory containing keg.yaml.
    /// `environment` (shell env) feeds `${…}` interpolation, taking priority
    /// over the project's `.env` file — compose semantics.
    public static func load(
        directory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> KegProjectConfig {
        guard let path = KegProjectConfig.find(in: directory) else {
            throw KegProjectError(
                "no keg.yaml in \(directory) — run `keg project init` to scaffold one"
            )
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let dirURL = URL(filePath: path).deletingLastPathComponent()

        var env = DotEnvFile.load(url: dirURL.appendingPathComponent(".env"))
        for (key, value) in environment { env[key] = value }

        var config = try parse(text: text, directory: dirURL.path)
        config.name = Self.sanitizeName(config.name.isEmpty ? dirURL.lastPathComponent : config.name)
        if config.name.isEmpty {
            throw KegProjectError("project name is empty — set `name:` in keg.yaml")
        }
        for (serviceName, service) in config.services {
            config.services[serviceName] = try resolveService(
                service, name: serviceName, in: config, projectDir: dirURL,
                interpolation: env, fileManager: fileManager
            )
        }
        _ = try orderedServiceNames(in: config) // validates depends_on + cycles
        return config
    }

    /// Parse raw YAML into the raw config. Service values are still raw:
    /// not interpolated, relative binds unresolved.
    public static func parse(text: String, directory: String) throws -> KegProjectConfig {
        guard let loaded = try Yams.load(yaml: text) else {
            throw KegProjectError("keg.yaml is empty")
        }
        guard let root = loaded as? [String: Any] else {
            throw KegProjectError("keg.yaml must be a YAML mapping at the top level")
        }

        let name = Self.string(root["name"]) ?? ""
        let rawVersion = Self.string(root["version"])
        if let rawVersion, rawVersion != "1" {
            throw KegProjectError("unsupported keg.yaml version \(rawVersion) — this build understands version 1")
        }

        guard let rawServices = root["services"] as? [String: Any] else {
            throw KegProjectError("keg.yaml needs a `services:` mapping")
        }
        guard !rawServices.isEmpty else {
            throw KegProjectError("keg.yaml declares no services — add at least one under `services:`")
        }

        var services: [String: KegService] = [:]
        for (serviceName, rawService) in rawServices {
            guard Self.validServiceName(serviceName) else {
                throw KegProjectError(
                    "invalid service name “\(serviceName)” — use lowercase letters, digits, dashes and underscores"
                )
            }
            guard let serviceMap = rawService as? [String: Any] else {
                throw KegProjectError("service \(serviceName): must be a mapping")
            }
            services[serviceName] = try parseService(serviceMap, name: serviceName)
        }
        return KegProjectConfig(name: name, services: services, directory: directory)
    }

    private static func parseService(_ map: [String: Any], name: String) throws -> KegService {
        var service = KegService()

        if let image = string(map["image"]) {
            service.image = image
        }
        if let rawBuild = map["build"] {
            if let context = string(rawBuild) {
                service.build = KegBuild(context: context)
            } else if let buildMap = rawBuild as? [String: Any] {
                guard let context = string(buildMap["context"]) else {
                    throw KegProjectError("service \(name): build.context is required when build is a mapping")
                }
                service.build = KegBuild(
                    context: context,
                    dockerfile: string(buildMap["dockerfile"]),
                    args: stringMap(buildMap["args"])
                )
            } else {
                throw KegProjectError("service \(name): build must be a path string or a mapping")
            }
        }

        guard service.image != nil || service.build != nil else {
            throw KegProjectError("service \(name): needs either `image:` or `build:`")
        }

        if let rawPorts = map["ports"] {
            let specs = try stringList(rawPorts, what: "service \(name): ports")
            service.ports = try specs.map { try parsePort($0, service: name) }
        }

        if let rawEnv = map["environment"] {
            service.environment = try envPairs(rawEnv, what: "service \(name): environment")
        }
        service.envFile = string(map["env_file"])

        if let rawVolumes = map["volumes"] {
            service.volumes = try stringList(rawVolumes, what: "service \(name): volumes")
        }

        if let rawCommand = map["command"] {
            service.command = try commandTokens(rawCommand, what: "service \(name): command")
        }
        if let rawEntrypoint = map["entrypoint"] {
            service.entrypoint = try commandTokens(rawEntrypoint, what: "service \(name): entrypoint")
        }

        service.workdir = string(map["workdir"])
        service.platform = string(map["platform"])
        service.restart = string(map["restart"])

        if let rawDepends = map["depends_on"] {
            service.dependsOn = try stringList(rawDepends, what: "service \(name): depends_on")
        }
        if let rawLabels = map["labels"] {
            service.labels = try envPairs(rawLabels, what: "service \(name): labels")
        }

        return service
    }

    /// `"8080:80"`, `"127.0.0.1:8080:80"`, `"5353:53/udp"`. A bare
    /// `"80"` is rejected: the runtime only publishes with an explicit
    /// host port, so an unpinned publish would silently do nothing.
    public static func parsePort(_ spec: String, service: String) throws -> KegPortMapping {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        var proto = "tcp"
        var body = trimmed
        if let slash = trimmed.firstIndex(of: "/") {
            proto = String(trimmed[trimmed.index(after: slash)...]).lowercased()
            body = String(trimmed[..<slash])
            guard proto == "tcp" || proto == "udp" else {
                throw KegProjectError("service \(service): port “\(spec)” — protocol must be tcp or udp")
            }
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let hostIP: String?
        let hostPortText: String
        let containerPortText: String
        switch parts.count {
        case 2:
            hostIP = nil
            hostPortText = parts[0]
            containerPortText = parts[1]
        case 3:
            hostIP = parts[0]
            hostPortText = parts[1]
            containerPortText = parts[2]
        default:
            throw KegProjectError(
                "service \(service): port “\(spec)” — use \"host:container\" or \"ip:host:container\""
            )
        }
        guard let hostPort = UInt16(hostPortText), let containerPort = UInt16(containerPortText) else {
            throw KegProjectError("service \(service): port “\(spec)” — ports must be numbers 1–65535")
        }
        guard hostPort > 1024 else {
            throw KegProjectError(
                "service \(service): host port \(hostPort) must be above 1024 (unprivileged)"
            )
        }
        guard containerPort > 0 else {
            throw KegProjectError("service \(service): container port must be at least 1")
        }
        return KegPortMapping(hostIP: hostIP, hostPort: hostPort, containerPort: containerPort, proto: proto)
    }

    // MARK: Resolution (interpolation + path anchoring)

    private static func resolveService(
        _ service: KegService,
        name: String,
        in config: KegProjectConfig,
        projectDir: URL,
        interpolation: [String: String],
        fileManager: FileManager
    ) throws -> KegService {
        var resolved = service

        func interpolate(_ value: String, field: String) throws -> String {
            try Self.interpolate(value, vars: interpolation, context: "service \(name): \(field)")
        }

        if let image = resolved.image {
            resolved.image = try interpolate(image, field: "image")
        }
        if var build = resolved.build {
            build.context = try interpolate(build.context, field: "build.context")
            if let dockerfile = build.dockerfile {
                build.dockerfile = try interpolate(dockerfile, field: "build.dockerfile")
            }
            var resolvedArgs: [String: String] = [:]
            for (key, value) in build.args {
                resolvedArgs[key] = try interpolate(value, field: "build.args.\(key)")
            }
            build.args = resolvedArgs
            resolved.build = build
        }
        var resolvedEnv: [String: String] = [:]
        for (key, value) in resolved.environment {
            resolvedEnv[key] = try interpolate(value, field: "environment.\(key)")
        }
        if let envFile = resolved.envFile {
            let url = resolvePath(envFile, relativeTo: projectDir)
            guard fileManager.fileExists(atPath: url.path) else {
                throw KegProjectError("service \(name): env_file not found: \(url.path)")
            }
            for (key, value) in DotEnvFile.load(url: url) {
                resolvedEnv[key] = value
            }
        }
        resolved.environment = resolvedEnv

        var resolvedVolumes: [String] = []
        for volume in resolved.volumes {
            resolvedVolumes.append(try resolveVolume(volume, name: name, projectDir: projectDir))
        }
        resolved.volumes = resolvedVolumes

        var resolvedCommand: [String] = []
        for token in resolved.command {
            resolvedCommand.append(try interpolate(token, field: "command"))
        }
        resolved.command = resolvedCommand
        var resolvedEntrypoint: [String] = []
        for token in resolved.entrypoint {
            resolvedEntrypoint.append(try interpolate(token, field: "entrypoint"))
        }
        resolved.entrypoint = resolvedEntrypoint

        for dependency in resolved.dependsOn where config.services[dependency] == nil {
            throw KegProjectError(
                "service \(name): depends_on unknown service “\(dependency)”"
            )
        }

        return resolved
    }

    /// `./data:/data` → `<projectDir>/data:/data`. Named volumes pass
    /// through untouched; an optional `:ro` suffix rides along.
    static func resolveVolume(_ volume: String, name: String, projectDir: URL) throws -> String {
        let parts = volume.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else {
            throw KegProjectError(
                "service \(name): volume “\(volume)” — use \"source:target\" (optional :ro suffix)"
            )
        }
        let source = parts[0]
        let target = parts[1]
        guard target.hasPrefix("/") else {
            throw KegProjectError(
                "service \(name): volume “\(volume)” — container target must be an absolute path"
            )
        }
        let suffix = parts.count == 3 ? ":\(parts[2])" : ""
        if source.hasPrefix("/") {
            return "\(source):\(target)\(suffix)"
        }
        if source.hasPrefix("./") || source.hasPrefix("../") || source == "." || source == ".." {
            let absolute = resolvePath(source, relativeTo: projectDir).standardizedFileURL.path
            return "\(absolute):\(target)\(suffix)"
        }
        // Named volume — resolved by the runtime.
        guard source.first != "-", source.first != "." else {
            throw KegProjectError("service \(name): volume “\(volume)” — invalid volume source")
        }
        return "\(source):\(target)\(suffix)"
    }

    static func resolvePath(_ path: String, relativeTo dir: URL) -> URL {
        if path.hasPrefix("/") { return URL(filePath: path) }
        return dir.appendingPathComponent(path)
    }

    // MARK: Interpolation

    /// `${VAR}`, `${VAR:-fallback}`, `$VAR`. A variable with no value and
    /// no fallback is an error — silent empties look like runtime bugs.
    public static func interpolate(_ input: String, vars: [String: String], context: String) throws -> String {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            let char = input[index]
            guard char == "$" else {
                output.append(char)
                index = input.index(after: index)
                continue
            }
            let next = input.index(after: index)
            guard next < input.endIndex else {
                throw KegProjectError("\(context): trailing “$” with no variable name")
            }
            if input[next] == "{" {
                guard let close = input[next...].firstIndex(of: "}") else {
                    throw KegProjectError("\(context): unterminated “${” in “\(input)”")
                }
                let inner = String(input[input.index(after: next)..<close])
                let (name, fallback): (String, String?)
                if let colon = inner.range(of: ":-") {
                    name = String(inner[..<colon.lowerBound])
                    fallback = String(inner[colon.upperBound...])
                } else {
                    name = inner
                    fallback = nil
                }
                guard !name.isEmpty else {
                    throw KegProjectError("\(context): empty variable name in “\(input)”")
                }
                if let value = vars[name] {
                    output += value
                } else if let fallback {
                    output += fallback
                } else {
                    throw KegProjectError(
                        "\(context): ${\(name)} is not set — export it, add it to .env, or give it a ${\(name):-default}"
                    )
                }
                index = input.index(after: close)
            } else {
                // Bare $VAR — letters, digits, underscore.
                var end = next
                while end < input.endIndex,
                      input[end].isLetter || input[end].isNumber || input[end] == "_" {
                    end = input.index(after: end)
                }
                guard end != next else {
                    throw KegProjectError("\(context): “$” must start a variable name (\(input))")
                }
                let name = String(input[next..<end])
                guard let value = vars[name] else {
                    throw KegProjectError(
                        "\(context): $\(name) is not set — export it, add it to .env, or use ${\(name):-default}"
                    )
                }
                output += value
                index = end
            }
        }
        return output
    }

    // MARK: Ordering + naming

    /// Dependency order (Kahn). Also the depends_on + cycle validator.
    public static func orderedServiceNames(in config: KegProjectConfig) throws -> [String] {
        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for (name, service) in config.services {
            indegree[name] = service.dependsOn.count
            for dependency in service.dependsOn {
                dependents[dependency, default: []].append(name)
            }
        }
        // Deterministic order for stable output and stable up-sequence.
        let sortedNames = config.services.keys.sorted()
        var queue = sortedNames.filter { indegree[$0] == 0 }
        var ordered: [String] = []
        while !queue.isEmpty {
            let name = queue.removeFirst()
            ordered.append(name)
            for dependent in dependents[name] ?? [] {
                indegree[dependent]! -= 1
                if indegree[dependent] == 0 { queue.append(dependent) }
            }
            queue.sort()
        }
        guard ordered.count == config.services.count else {
            let stuck = sortedNames.filter { !ordered.contains($0) }
            throw KegProjectError(
                "circular depends_on involving: \(stuck.joined(separator: ", "))"
            )
        }
        return ordered
    }

    public static func validServiceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 63, let first = name.first else { return false }
        guard (first.isLowercase && first.isLetter) || first.isNumber else { return false }
        return name.allSatisfy { ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Compose-style: lowercase, characters outside [a-z0-9-] become dashes.
    public static func sanitizeName(_ raw: String) -> String {
        var cleaned = ""
        var lastDash = true
        for char in raw.lowercased() {
            let ok = (char.isLetter && char.isASCII && char.isLowercase) || char.isNumber
            if ok {
                cleaned.append(char)
                lastDash = false
            } else if !lastDash {
                cleaned.append("-")
                lastDash = true
            }
        }
        while cleaned.hasSuffix("-") { cleaned.removeLast() }
        return cleaned
    }

    /// Compose/keg app convention — the label is what groups containers
    /// in Keg's Compose screen, and `-1` is compose's first replica.
    public static func containerName(project: String, service: String) -> String {
        "\(project)-\(service)-1"
    }

    public static let projectLabel = "com.docker.compose.project"
    public static let serviceLabel = "com.docker.compose.service"

    public static func builtImageTag(project: String, service: String) -> String {
        "\(project)-\(service):local"
    }

    // MARK: YAML scalar helpers

    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let text as String: return text
        case let number as Int: return String(number)
        case let number as Double: return number.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(number)) : String(number)
        case let flag as Bool: return flag ? "true" : "false"
        default: return nil
        }
    }

    static func stringList(_ value: Any, what: String) throws -> [String] {
        if let list = value as? [Any] {
            return try list.map { item in
                guard let text = string(item) else {
                    throw KegProjectError("\(what): entries must be strings")
                }
                return text
            }
        }
        guard let text = string(value) else {
            throw KegProjectError("\(what): must be a list of strings")
        }
        return [text]
    }

    /// Map form (`KEY: value`) or list form (`KEY=value`).
    static func envPairs(_ value: Any, what: String) throws -> [String: String] {
        if let map = value as? [String: Any] {
            var result: [String: String] = [:]
            for (key, raw) in map {
                guard let text = string(raw) else {
                    throw KegProjectError("\(what).\(key): value must be a scalar")
                }
                result[key] = text
            }
            return result
        }
        if let list = value as? [Any] {
            var result: [String: String] = [:]
            for item in list {
                guard let entry = string(item), let equals = entry.firstIndex(of: "=") else {
                    throw KegProjectError(
                        "\(what): entries must look like KEY=value — to pull a value from your shell or .env, write KEY=${KEY}"
                    )
                }
                let key = String(entry[..<equals])
                guard !key.isEmpty else {
                    throw KegProjectError("\(what): empty key in “\(entry)”")
                }
                result[key] = String(entry[entry.index(after: equals)...])
            }
            return result
        }
        throw KegProjectError("\(what): must be a mapping or a list of KEY=value")
    }

    static func stringMap(_ value: Any?) -> [String: String] {
        guard let value, let map = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, raw) in map {
            result[key] = string(raw) ?? ""
        }
        return result
    }

    /// String form splits on whitespace (documented); list form is verbatim.
    static func commandTokens(_ value: Any, what: String) throws -> [String] {
        if let list = value as? [Any] {
            return try stringList(list, what: what)
        }
        guard let text = string(value) else {
            throw KegProjectError("\(what): must be a string or a list of strings")
        }
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
}

// MARK: - .env

public enum DotEnvFile {
    /// Minimal .env: KEY=VALUE lines, `#` comments, optional `export`,
    /// optional surrounding quotes. Values are kept raw (no interpolation
    /// inside .env — compose only interpolates the compose file itself).
    public static func load(url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                let first = value.first!, last = value.last!
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            result[key] = value
        }
        return result
    }
}
