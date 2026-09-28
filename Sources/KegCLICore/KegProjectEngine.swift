import Foundation

// MARK: - Create request (Docker API JSON shapes)

/// Mirrors the subset of Docker's container-create body Keg's socket
/// server consumes. CodingKeys match the daemon's PascalCase fields.
public struct KegContainerCreateRequest: Encodable, Sendable {
    public let image: String
    public let cmd: [String]?
    public let env: [String]
    public let labels: [String: String]
    public let entrypoint: [String]?
    public let workingDir: String?
    public let platform: String?
    public let hostConfig: HostConfig

    public struct HostConfig: Encodable, Sendable {
        public let portBindings: [String: [PortBinding]]
        public let binds: [String]?
        public let restartPolicy: RestartPolicy?

        public struct PortBinding: Encodable, Sendable {
            public let hostIP: String?
            public let hostPort: String?

            enum CodingKeys: String, CodingKey {
                case hostIP = "HostIp"
                case hostPort = "HostPort"
            }

            public init(hostIP: String?, hostPort: String?) {
                self.hostIP = hostIP
                self.hostPort = hostPort
            }
        }

        public struct RestartPolicy: Encodable, Sendable {
            public let name: String

            enum CodingKeys: String, CodingKey { case name = "Name" }

            public init(name: String) { self.name = name }
        }

        enum CodingKeys: String, CodingKey {
            case portBindings = "PortBindings"
            case binds = "Binds"
            case restartPolicy = "RestartPolicy"
        }

        public init(portBindings: [String: [PortBinding]], binds: [String]?, restartPolicy: RestartPolicy?) {
            self.portBindings = portBindings
            self.binds = binds
            self.restartPolicy = restartPolicy
        }
    }

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case cmd = "Cmd"
        case env = "Env"
        case labels = "Labels"
        case entrypoint = "Entrypoint"
        case workingDir = "WorkingDir"
        case platform = "Platform"
        case hostConfig = "HostConfig"
    }

    public init(
        image: String,
        cmd: [String]?,
        env: [String],
        labels: [String: String],
        entrypoint: [String]?,
        workingDir: String?,
        platform: String?,
        hostConfig: HostConfig
    ) {
        self.image = image
        self.cmd = cmd
        self.env = env
        self.labels = labels
        self.entrypoint = entrypoint
        self.workingDir = workingDir
        self.platform = platform
        self.hostConfig = hostConfig
    }

    /// The exact request a config service produces — also what tests assert
    /// against, so the wire shape can't drift from the schema silently.
    ///
    /// Commands run through a non-login `sh -c` with `exec`: the runtime
    /// does not apply the image's WORKDIR/PATH to relative command names
    /// (verified live — bare `httpd` fails to start), which is the same
    /// quirk ComposeOrchestrator solves with a non-login wrap. `exec` keeps
    /// signals flowing to the real process instead of the shell.
    public static func make(for service: KegService, name: String, project: String) -> KegContainerCreateRequest {
        var labels = service.labels
        labels[KegProjectLoader.projectLabel] = project
        labels[KegProjectLoader.serviceLabel] = name

        var cmd: [String]?
        if !service.command.isEmpty {
            let script = "exec " + service.command.map(shellQuote).joined(separator: " ")
            cmd = ["/bin/sh", "-c", script]
        } else {
            cmd = nil
        }

        var bindings: [String: [HostConfig.PortBinding]] = [:]
        for port in service.ports {
            let key = "\(port.containerPort)/\(port.proto)"
            bindings[key, default: []].append(
                HostConfig.PortBinding(hostIP: port.hostIP, hostPort: String(port.hostPort))
            )
        }

        let restartPolicy: HostConfig.RestartPolicy?
        if let restart = service.restart, ["always", "unless-stopped", "on-failure"].contains(restart) {
            restartPolicy = HostConfig.RestartPolicy(name: restart)
        } else {
            restartPolicy = nil
        }

        return KegContainerCreateRequest(
            image: service.image ?? KegProjectLoader.builtImageTag(project: project, service: name),
            cmd: cmd,
            env: service.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
            labels: labels,
            entrypoint: service.entrypoint.isEmpty ? nil : service.entrypoint,
            workingDir: service.workdir,
            platform: service.platform,
            hostConfig: HostConfig(
                portBindings: bindings,
                binds: service.volumes.isEmpty ? nil : service.volumes,
                restartPolicy: restartPolicy
            )
        )
    }

    static func shellQuote(_ token: String) -> String {
        let safe = token.allSatisfy { $0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0) }
        if safe { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Extended API calls

extension KegAPIClient {
    /// POST /containers/create. Long timeout: when the image isn't stored
    /// yet the server pulls it inline (up to 1200s server-side).
    public func createContainer(request: KegContainerCreateRequest, name: String) throws {
        let body = try JSONEncoder().encode(request)
        let response = try http.post(
            "/containers/create?name=\(name)",
            body: body,
            timeoutSeconds: 1250
        )
        guard (200..<300).contains(response.status) else {
            throw KegProjectError(
                "create \(name) failed (HTTP \(response.status)): \( Self.errorText(response.body))"
            )
        }
    }

    /// POST /build with a tarred context body. Streams NDJSON
    /// `{"stream": …}` / `{"error": …}` lines back; the whole response is
    /// buffered, so progress lines arrive when the build finishes.
    public func buildImage(
        contextTar: Data,
        tag: String,
        dockerfile: String?,
        args: [String: String],
        onLine: (String) -> Void = { _ in }
    ) throws {
        var path = "/build?t=\(Self.urlEncode(tag))"
        if let dockerfile {
            path += "&dockerfile=\(Self.urlEncode(dockerfile))"
        }
        if !args.isEmpty {
            let encoded = try JSONEncoder().encode(args)
            path += "&buildargs=\(Self.urlEncode(String(data: encoded, encoding: .utf8) ?? "{}"))"
        }
        let response = try http.post(path, body: contextTar, timeoutSeconds: 1800)
        let text = String(data: response.body, encoding: .utf8) ?? ""
        var failure: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = object["error"] as? String {
                failure = error
            } else if let stream = object["stream"] as? String {
                let trimmed = stream.trimmingCharacters(in: .whitespacesAndNewlines)
                // apple's builder reports terminal failures as a stream
                // line ("Error: unknown: \"failed to solve…\""), not the
                // docker-convention "error" field — catch both.
                if trimmed.hasPrefix("Error:"), failure == nil {
                    failure = trimmed
                }
                onLine(trimmed)
            }
        }
        guard response.status == 200, failure == nil else {
            throw KegProjectError("build \(tag) failed: \(failure ?? "HTTP \(response.status)")")
        }
    }

    static func errorText(_ body: Data) -> String {
        if let object = try? JSONDecoder().decode([String: String].self, from: body),
           let message = object["message"] {
            return message
        }
        return String(data: body, encoding: .utf8) ?? "(\(body.count) bytes)"
    }

    static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

// MARK: - Build context tar

public enum KegBuildContext {
    /// Tar a build context with the system bsdtar, honoring `.dockerignore`
    /// (prefix/literal matches + globs as bsdtar understands them) and
    /// always excluding `.git`. Returns the archive bytes.
    public static func archive(contextURL: URL) throws -> Data {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: contextURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw KegProjectError("build context not found: \(contextURL.path)")
        }

        var excludes = [".git"]
        let ignoreURL = contextURL.appendingPathComponent(".dockerignore")
        if let text = try? String(contentsOf: ignoreURL, encoding: .utf8) {
            for rawLine in text.components(separatedBy: .newlines) {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                while line.hasPrefix("/") { line.removeFirst() }
                while line.hasSuffix("/") { line.removeLast() }
                if !line.isEmpty { excludes.append(line) }
            }
        }

        let tarURL = fileManager.temporaryDirectory
            .appendingPathComponent("keg-context-\(UUID().uuidString.prefix(8)).tar")
        defer { try? fileManager.removeItem(at: tarURL) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        var arguments = ["-cf", tarURL.path]
        for pattern in excludes {
            // BSD tar matches exclusions against both the whole path and
            // path components; anchoring the glob to the context root keeps
            // `build/*` from nuking nested lookalikes.
            arguments += ["--exclude", pattern]
        }
        arguments += ["-C", contextURL.path, "."]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw KegProjectError("could not run /usr/bin/tar: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw KegProjectError("failed to tar build context: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try Data(contentsOf: tarURL)
    }
}

// MARK: - Engine

public struct KegServiceStatus: Sendable, Equatable, Encodable {
    public var service: String
    public var container: String
    public var found: Bool
    public var state: String
    public var status: String
    public var image: String
    public var ports: [String]
    public var urls: [String]

    public init(service: String, container: String) {
        self.service = service
        self.container = container
        found = false
        state = "missing"
        status = "not created — run `keg project up`"
        image = ""
        ports = []
        urls = []
    }
}

/// Project lifecycle over Keg's Docker API socket. Synchronous on purpose
/// — same model as the rest of the CLI.
public struct KegProjectEngine {
    public let client: KegAPIClient
    public let fileManager: FileManager

    public init(client: KegAPIClient, fileManager: FileManager = .default) {
        self.client = client
        self.fileManager = fileManager
    }

    // MARK: up

    public struct UpOptions {
        public var rebuild = false
        public var waitTimeout: TimeInterval = 120

        public init() {}
    }

    public struct UpResult: Sendable {
        public struct ServiceOutcome: Sendable {
            public let service: String
            public let container: String
            public let image: String
            public let urls: [String]
        }
        public var outcomes: [ServiceOutcome] = []
    }

    /// Build/pull + recreate + start every service in dependency order.
    /// Recreating on every up is deliberate: a crashed or stale container
    /// otherwise wedges the project forever, and bind/named-volume data
    /// survives the replace. `onProgress` receives human-readable lines.
    @discardableResult
    public func up(
        _ config: KegProjectConfig,
        options: UpOptions = UpOptions(),
        onProgress: (String) -> Void = { _ in }
    ) throws -> UpResult {
        let order = try KegProjectLoader.orderedServiceNames(in: config)
        var result = UpResult()
        let existing = try client.containers(all: true)

        for serviceName in order {
            guard let service = config.services[serviceName] else { continue }
            let containerName = KegProjectLoader.containerName(project: config.name, service: serviceName)
            let progress = onProgress

            // Build when needed (or forced). Pulled images need no local
            // step — create pulls server-side, pinned to the service's
            // platform (default: this Mac's).
            var image: String
            if let build = service.build {
                image = KegProjectLoader.builtImageTag(project: config.name, service: serviceName)
                let contextURL = KegProjectLoader.resolvePath(
                    build.context, relativeTo: URL(filePath: config.directory)
                )
                let needsBuild = try options.rebuild || !imageExists(image)
                if needsBuild {
                    progress("building \(serviceName) → \(image)")
                    let tar = try KegBuildContext.archive(contextURL: contextURL)
                    let megaBytes = Double(tar.count) / (1024 * 1024)
                    progress(String(format: "uploading %.1f MB build context", megaBytes))
                    try client.buildImage(
                        contextTar: tar,
                        tag: image,
                        dockerfile: build.dockerfile,
                        args: build.args
                    ) { line in
                        progress("\(serviceName): \(line)")
                    }
                } else {
                    progress("image \(image) already built — skipping build (use --build to force)")
                }
            } else {
                image = service.image ?? "missing"
            }

            // Recreate: same-name containers (running or crashed) are
            // replaced so the file on disk is the source of truth.
            if existing.contains(where: { $0.displayName == containerName }) {
                progress("recreating \(containerName)")
                try? client.remove(id: containerName, force: true, timeoutSeconds: 300)
            } else {
                progress("creating \(containerName)")
            }

            let createRequest = KegContainerCreateRequest.make(
                for: service, name: serviceName, project: config.name
            )
            progress("preparing \(image) (pulled on demand)")
            do {
                try client.createContainer(request: createRequest, name: containerName)
                try client.start(id: containerName, timeoutSeconds: 300)
            } catch let clientError as UnixSocketHTTPClient.ClientError {
                // A lost response does not mean a lost operation: the server
                // may have created/started the container while the client
                // gave up (seen under load — EAGAIN and slow lists surface
                // as .timeout). Verify against actual state before failing.
                let state = try? client.inspect(id: containerName).state.status.lowercased()
                guard state == "running" else { throw clientError }
                progress("\(serviceName): create/start response lost — container is running, continuing")
            }
            progress("starting \(containerName)")

            try waitUntilRunning(containerName: containerName, service: serviceName, timeout: options.waitTimeout) { line in
                progress("\(serviceName): \(line)")
            }

            let urls = service.ports.filter { $0.proto == "tcp" }.map(\.url)
            for url in urls {
                progress("\(serviceName) → \(url)")
            }
            result.outcomes.append(
                UpResult.ServiceOutcome(service: serviceName, container: containerName, image: image, urls: urls)
            )
        }
        return result
    }

    /// Poll inspect until the container is running. A container that exits
    /// during the window fails the up with its last log lines attached —
    /// the actual diagnosis, not just "exited".
    private func waitUntilRunning(
        containerName: String,
        service: String,
        timeout: TimeInterval,
        onExitLog: (String) -> Void
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastStatus = "unknown"
        while Date() < deadline {
            let inspect = try client.inspect(id: containerName)
            lastStatus = inspect.state.status
            if inspect.state.running { return }
            if !inspect.state.running && lastStatus != "created" && lastStatus != "starting" {
                // Exited/crashed — surface the logs tail.
                let logs = (try? client.logs(id: containerName, tail: 40)) ?? Data()
                let demuxed = DockerLogDemuxer.demux(logs)
                let text = [demuxed.stdout, demuxed.stderr]
                    .compactMap { String(data: $0, encoding: .utf8) }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    onExitLog(text)
                }
                throw KegProjectError(
                    "service \(service): container exited (status \(lastStatus)) right after start — logs above"
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw KegProjectError(
            "service \(service): not running after \(Int(timeout))s (status \(lastStatus)) — check `keg project logs \(service)`"
        )
    }

    // MARK: down

    /// Stop + remove every service container. Bind-mount and named-volume
    /// data always survives down — only explicit volume deletion removes data.
    @discardableResult
    public func down(_ config: KegProjectConfig) throws -> Int {
        let order = (try? KegProjectLoader.orderedServiceNames(in: config)) ?? config.services.keys.sorted()
        var removed = 0
        let existing = try client.containers(all: true)
        // Reverse order: dependents stop before their dependencies.
        for serviceName in order.reversed() {
            let containerName = KegProjectLoader.containerName(project: config.name, service: serviceName)
            guard existing.contains(where: { $0.displayName == containerName }) else { continue }
            try? client.stop(id: containerName, timeoutSeconds: 300)
            try client.remove(id: containerName, force: true, timeoutSeconds: 300)
            removed += 1
        }
        return removed
    }

    // MARK: status

    public func status(_ config: KegProjectConfig) throws -> [KegServiceStatus] {
        let existing = try client.containers(all: true)
        var entries: [KegServiceStatus] = []
        for serviceName in config.services.keys.sorted() {
            let containerName = KegProjectLoader.containerName(project: config.name, service: serviceName)
            var entry = KegServiceStatus(service: serviceName, container: containerName)
            if let match = existing.first(where: { $0.displayName == containerName }) {
                entry.found = true
                entry.state = match.state
                entry.status = match.status
                entry.image = match.image
            }
            if let service = config.services[serviceName] {
                entry.ports = service.ports.map { "\($0.hostPort):\($0.containerPort)/\($0.proto)" }
                entry.urls = service.ports.filter { $0.proto == "tcp" }.map(\.url)
            }
            entries.append(entry)
        }
        return entries
    }

    // MARK: helpers

    private func imageExists(_ reference: String) throws -> Bool {
        let images = try client.images()
        return images.contains { image in
            image.repoTags?.contains(reference) ?? false
        }
    }
}
