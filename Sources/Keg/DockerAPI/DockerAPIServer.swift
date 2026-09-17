import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import NIOCore
import NIOHTTP1
import Security
import CommonCrypto

/// Reconstructs an image name from an `/images/{name}/**` route. Registry-qualified
/// references contain slashes (docker.io/library/nginx:alpine), which Hummingbird
/// captures in the catchall; the trailing action segment ("json", "history") is
/// not part of the name.
private func imageNameFromPath(_ parameters: Parameters) -> String {
    let first = parameters.get("name", as: String.self) ?? ""
    var rest = parameters.getCatchAll().map(String.init)
    if let last = rest.last, last == "json" || last == "history" {
        rest.removeLast()
    }
    return ([first] + rest).joined(separator: "/")
}

// MARK: - Webhook Manager

/// Actor-safe webhook registry
actor WebhookManager {
    private var webhooks: [String: Webhook] = [:]
    private let session: URLSession

    struct Webhook: Identifiable, Sendable {
        let id: String
        var name: String
        var endpoint: URL
        var enabled: Bool
        var containerFilter: ContainerFilter?
        var events: Set<WebhookEvent>
        var secret: String?

        init(name: String, endpoint: URL, containerFilter: ContainerFilter? = nil, events: [WebhookEvent], secret: String? = nil) {
            self.id = UUID().uuidString
            self.name = name
            self.endpoint = endpoint
            self.enabled = true
            self.containerFilter = containerFilter
            self.events = Set(events)
            self.secret = secret
        }
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - CRUD

    func create(name: String, endpoint: URL, containerFilter: ContainerFilter?, events: [WebhookEvent], secret: String?) -> Webhook {
        let webhook = Webhook(name: name, endpoint: endpoint, containerFilter: containerFilter, events: events, secret: secret)
        webhooks[webhook.id] = webhook
        return webhook
    }

    func list() -> [Webhook] {
        Array(webhooks.values)
    }

    func get(id: String) -> Webhook? {
        webhooks[id]
    }

    func delete(id: String) -> Bool {
        webhooks.removeValue(forKey: id) != nil
    }

    func update(id: String, name: String?, enabled: Bool?) -> Webhook? {
        guard var webhook = webhooks[id] else { return nil }
        if let name = name { webhook.name = name }
        if let enabled = enabled { webhook.enabled = enabled }
        webhooks[id] = webhook
        return webhook
    }

    // MARK: - Event Dispatch

    func dispatch(event: WebhookEvent, container: DockerContainer?, image: DockerImage?) async {
        for webhook in webhooks.values where webhook.enabled && webhook.events.contains(event) {
            // Check container filter if set
            if let filter = webhook.containerFilter, let container = container {
                if let labels = filter.labels {
                    let matches = labels.allSatisfy { key, value in
                        container.labels?[key] == value
                    }
                    if !matches { continue }
                }
                if let name = filter.name, !container.names.contains("/\(name)") && !container.names.contains(name) {
                    continue
                }
                if let imageFilter = filter.image, !container.image.contains(imageFilter) {
                    continue
                }
            }

            await triggerWebhook(webhook, event: event, container: container, image: image)
        }
    }

    private func triggerWebhook(_ webhook: Webhook, event: WebhookEvent, container: DockerContainer?, image: DockerImage?) async {
        var payload = WebhookPayload(
            webhook: WebhookInfo(name: webhook.name, uuid: webhook.id),
            event: event.rawValue,
            timestamp: Date(),
            container: container.map { c in
                ContainerInfo(id: c.id, name: c.names.first ?? c.id, image: c.image, state: c.state, labels: c.labels)
            },
            image: image.map { i in
                ImageInfo(id: i.id, tags: i.repoTags)
            }
        )

        var request = URLRequest(url: webhook.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Keg-Webhook/1.0", forHTTPHeaderField: "User-Agent")

        // Add HMAC signature if secret is configured
        if let secret = webhook.secret {
            do {
                let payloadData = try JSONEncoder().encode(payload)
                let signature = computeHMAC(data: payloadData, key: secret)
                request.setValue("sha256=\(signature)", forHTTPHeaderField: "X-Keg-Signature")
                request.httpBody = payloadData
            } catch {
                return
            }
        } else {
            request.httpBody = try? JSONEncoder().encode(payload)
        }

        _ = try? await session.data(for: request)
    }

    private func computeHMAC(data: Data, key: String) -> String {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withCString { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyPtr,
                    strlen(keyPtr),
                    dataPtr.baseAddress,
                    data.count,
                    &hmac
                )
            }
        }
        return Data(hmac).base64EncodedString()
    }
}

// MARK: - Docker API Server

final class DockerAPIServer: Sendable {
    let bridge: ContainerBridge
    let webhookManager: WebhookManager
    let execRegistry: ExecSessionRegistry
    let eventBus: ContainerEventBus
    /// The socket path that was actually bound after start() succeeds.
    nonisolated(unsafe) private(set) var resolvedSocketPath: String?

    init() {
        self.bridge = ContainerBridge()
        self.webhookManager = WebhookManager()
        self.execRegistry = ExecSessionRegistry()
        self.eventBus = ContainerEventBus(bridge: self.bridge, webhooks: self.webhookManager)
        self.resolvedSocketPath = nil
    }

    /// Try binding to `/var/run/docker.sock` first; fall back to `~/.keg/docker.sock`.
    func start() async throws {
        // Ensure ~/.keg directory exists
        let kegDir = URL(filePath: NSHomeDirectory()).appendingPathComponent(".keg")
        try FileManager.default.createDirectory(at: kegDir, withIntermediateDirectories: true)

        // Try preferred path first, then fallback
        let preferredPath = "/var/run/docker.sock"
        let fallbackPath = Self.defaultSocketPath()

        let socketPath: String
        if canBindSocket(at: preferredPath) {
            socketPath = preferredPath
        } else {
            socketPath = fallbackPath
        }

        // Remove old socket
        try? FileManager.default.removeItem(atPath: socketPath)

        let bridge = self.bridge
        let execRegistry = self.execRegistry
        let eventBus = self.eventBus
        let whManager = self.webhookManager

        let router = Router(options: .autoGenerateHeadEndpoints)

        // Diagnostic trail for Docker compatibility work: method, path, status,
        // and any thrown error description appended to ~/.keg/docker-api.log.
        // Must be added before routes so it wraps them.
        struct AccessLogMiddleware: RouterMiddleware {
            typealias Context = BasicRequestContext

            func handle(
                _ request: Request,
                context: Context,
                next: (Request, Context) async throws -> Response
            ) async throws -> Response {
                do {
                    let response = try await next(request, context)
                    Self.appendLog("\(request.method.rawValue) \(request.uri.path) -> \(response.status.code)")
                    return response
                } catch {
                    let detail = (error as? CustomStringConvertible).map { "\($0)" } ?? error.localizedDescription
                    Self.appendLog("\(request.method.rawValue) \(request.uri.path) !! \(detail)")
                    throw error
                }
            }

            static func appendLog(_ line: String) {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let entry = "[\(timestamp)] \(line)\n"
                let logURL = URL(filePath: NSHomeDirectory()).appendingPathComponent(".keg/docker-api.log")
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(Data(entry.utf8))
                    try? handle.close()
                } else {
                    try? entry.write(to: logURL, atomically: true, encoding: .utf8)
                }
            }
        }
        router.middlewares.add(AccessLogMiddleware())

        // Docker CLI sends requests with a /v1.XX version prefix. Hummingbird
        // matches routes by path before middlewares run, so rewriting the URI
        // in a middleware can't re-route. Instead, register every route twice:
        // once at the bare path, once under `/v1.{apiVersion}` so the same
        // handler serves both shapes.
        let registerRoutes: (String) -> Void = { prefix in
            // MARK: System
            router.get("\(prefix)/_ping") { _, _ in
                // The docker CLI negotiates its API version and OS handling
                // from these headers on /_ping (HEAD first, then GET).
                var response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "OK")))
                response.headers[.contentType] = "text/plain; charset=utf-8"
                response.headers[HTTPField.Name("Api-Version")!] = "1.45"
                response.headers[HTTPField.Name("OSType")!] = "linux"
                response.headers[HTTPField.Name("Builder-Version")!] = "1"
                response.headers[HTTPField.Name("Docker-Experimental")!] = "false"
                return response
            }

            router.get("\(prefix)/version") { _, _ in
                let version = DockerVersion(
                    version: "0.1.0",
                    apiVersion: "1.45",
                    minAPIVersion: "1.24",
                    gitCommit: "keg",
                    goVersion: "swift",
                    os: "darwin",
                    arch: "arm64",
                    kernelVersion: "Darwin",
                    buildTime: ""
                )
                return try JSONResponse(version)
            }

            router.get("\(prefix)/info") { _, _ in
                let info = try await bridge.systemInfo()
                return try JSONResponse(info)
            }

            // MARK: Containers
            router.get("\(prefix)/containers/json") { request, _ in
                let all = request.uri.queryParameters.get("all") != nil
                var containers = try await bridge.listContainers(all: all)
                if let filterSpec = request.uri.queryParameters.get("filters") {
                    containers = DockerAPIServer.applyContainerFilters(containers, spec: filterSpec)
                }
                return try JSONResponse(containers)
            }

            router.post("\(prefix)/containers/create") { request, _ in
                let name = request.uri.queryParameters.get("name")
                let body = try await request.body.collect(upTo: 1024 * 1024)
                let createReq = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(buffer: body))
                let response = try await bridge.createContainer(from: createReq, name: name)
                return try JSONResponse(response, status: .created)
            }

            router.post("\(prefix)/containers/{id}/start") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                try await bridge.startContainerWithExitTracking(id: id)
                return Response(status: .noContent)
            }

            router.post("\(prefix)/containers/{id}/stop") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                try? await bridge.stopContainer(id: id)
                return Response(status: .noContent)
            }

            router.post("\(prefix)/containers/{id}/kill") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                try? await bridge.killContainer(id: id)
                return Response(status: .noContent)
            }

            router.post("\(prefix)/containers/{id}/restart") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                try? await bridge.stopContainer(id: id)
                try? await bridge.startContainer(id: id)
                return Response(status: .noContent)
            }

            router.delete("\(prefix)/containers/{id}") { request, context in
                let id = context.parameters.get("id", as: String.self)!
                let force = request.uri.queryParameters.get("force") != nil
                try await bridge.removeContainer(id: id, force: force)
                return Response(status: .noContent)
            }

            router.get("\(prefix)/containers/{id}/json") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                let inspect = try await bridge.inspectContainer(id: id)
                return try JSONResponse(inspect)
            }

            router.get("\(prefix)/containers/{id}/logs") { request, context in
                let id = context.parameters.get("id", as: String.self)!
                let tail = request.uri.queryParameters.get("tail").flatMap(Int.init)
                let follow = request.uri.queryParameters.get("follow") == "1" || request.uri.queryParameters.get("follow") == "true"
                let logs = try await bridge.containerLogs(id: id, tail: tail, follow: follow)
                // Docker clients demux non-TTY streams with stdcopy framing;
                // raw text makes them fail with "unrecognized stream".
                var buffer = ByteBuffer()
                let payload = Array(logs.utf8)
                buffer.writeInteger(UInt8(1)) // stdout stream type
                buffer.writeInteger(UInt8(0)); buffer.writeInteger(UInt8(0)); buffer.writeInteger(UInt8(0))
                buffer.writeInteger(UInt32(payload.count))
                buffer.writeBytes(payload)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/vnd.docker.raw-stream"
                return response
            }

            router.post("\(prefix)/containers/{id}/wait") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                // 404 up front for unknown containers, like the daemon.
                _ = try await bridge.inspectContainer(id: id)

                // Docker ≥1.30 contract: /wait writes its response HEADERS
                // immediately and the JSON body only when the container
                // exits. The CLI's ContainerWait blocks until the headers
                // arrive before it will issue /start, so a response that
                // withholds headers until exit deadlocks `docker run`.
                let body = ResponseBody(contentLength: nil) { writer in
                    let statusCode = try await bridge.waitContainerWithExitCode(id: id)
                    try await writer.write(ByteBuffer(string: "{\"StatusCode\":\(Int(statusCode))}"))
                    try await writer.finish(nil)
                }
                var response = Response(status: .ok, body: body)
                response.headers[.contentType] = "application/json"
                return response
            }

            // MARK: Exec
            router.post("\(prefix)/containers/{id}/exec") { request, context in
                let id = context.parameters.get("id", as: String.self)!
                let body = try await request.body.collect(upTo: 1024 * 1024)
                let execReq = try JSONDecoder().decode(DockerExecCreateRequest.self, from: Data(buffer: body))
                guard let cmd = execReq.cmd, let first = cmd.first, !first.isEmpty else {
                    throw DockerAPIError.badRequest("No command specified")
                }
                let execID = await execRegistry.create(containerID: id, request: execReq)
                return try JSONResponse(DockerExecCreateResponse(id: execID), status: .created)
            }

            // Exec attach for clients that don't hijack the connection
            // (docker-py, docker-java, curl): plain 200 with a streamed,
            // stdcopy-multiplexed body. The docker CLI goes through the
            // hijack channel instead and never reaches this route.
            router.post("\(prefix)/exec/{id}/start") { request, context in
                let execID = context.parameters.get("id", as: String.self)!
                guard let session = await execRegistry.get(id: execID) else {
                    throw DockerAPIError.badRequest("No such exec instance: \(execID)")
                }

                let pump = try await bridge.startExec(
                    containerID: session.containerID,
                    execID: execID,
                    request: session.request
                )
                await execRegistry.markStarted(id: execID)

                let tty = pump.tty
                let body = ResponseBody(contentLength: nil) { writer in
                    for try await chunk in pump.makeOutputStream() {
                        if tty {
                            try await writer.write(ByteBuffer(bytes: chunk.data))
                        } else {
                            try await writer.write(ByteBuffer(data: Self.stdcopyFrame(chunk)))
                        }
                    }
                    _ = await pump.completion()
                    try await writer.finish(nil)
                }
                Task {
                    let code = await pump.completion()
                    await execRegistry.markFinished(id: execID, exitCode: Int(clamping: code))
                }
                var response = Response(status: .ok, body: body)
                response.headers[.contentType] = "application/vnd.docker.raw-stream"
                return response
            }

            router.post("\(prefix)/exec/{id}/resize") { request, context in
                let execID = context.parameters.get("id", as: String.self)!
                let width = request.uri.queryParameters.get("w").flatMap(UInt16.init) ?? 80
                let height = request.uri.queryParameters.get("h").flatMap(UInt16.init) ?? 24
                try await bridge.resizeExec(execID: execID, width: width, height: height)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{}")))
            }

            router.get("\(prefix)/exec/{id}/json") { _, context in
                let execID = context.parameters.get("id", as: String.self)!
                guard let inspect = await execRegistry.inspect(id: execID) else {
                    throw DockerAPIError.badRequest("No such exec instance: \(execID)")
                }
                return try JSONResponse(inspect)
            }

            // MARK: Images
            router.get("\(prefix)/images/json") { _, _ in
                let images = try await bridge.listImages()
                return try JSONResponse(images)
            }

            router.post("\(prefix)/images/create") { request, _ in
                let fromImage = request.uri.queryParameters.get("fromImage") ?? ""
                let tag = request.uri.queryParameters.get("tag")
                let input = request.uri.queryParameters.get("input") ?? ""
                // docker pull --platform sends linux/amd64 etc.; anything
                // else falls back to the host platform.
                let rawPlatform = request.uri.queryParameters.get("platform").map { String($0) }
                let platform = (rawPlatform?.isEmpty == false) ? rawPlatform : nil
                var imageRef = fromImage.isEmpty ? input : fromImage
                if let tag, !tag.isEmpty {
                    // Docker sends the reference and tag separately.
                    imageRef = imageRef.split(separator: ":", maxSplits: 1).map(String.init).first ?? imageRef
                    imageRef += ":\(tag)"
                }
                guard !imageRef.isEmpty else {
                    throw DockerAPIError.badRequest("No image specified")
                }

                // Stream pull progress as Docker-format JSON lines so
                // `docker pull` renders live layer progress.
                let output: StreamingProcess.Output
                do {
                    output = try bridge.pullImageStream(from: imageRef, platform: platform)
                } catch {
                    throw DockerAPIError.imagePullFailed("\(error)")
                }
                let encoder = JSONEncoder()
                let body = ResponseBody(contentLength: nil) { writer in
                    do {
                        for try await line in output.lines {
                            guard let message = PullProgressMapper.message(forLine: line) else { continue }
                            let data = try encoder.encode(message)
                            var buffer = ByteBuffer(data: data)
                            buffer.writeString("\n")
                            try await writer.write(buffer)
                        }
                        let code = await output.waitForExit()
                        if code != 0 {
                            let failure = DockerImageProgressMessage(
                                status: "error", id: nil, progressDetail: nil, progress: nil,
                                error: "pull failed with exit code \(code)", errorDetail: DockerErrorDetail(message: "pull failed with exit code \(code)")
                            )
                            let data = try encoder.encode(failure)
                            var buffer = ByteBuffer(data: data)
                            buffer.writeString("\n")
                            try await writer.write(buffer)
                        }
                    } catch {
                        // Client went away; make sure the CLI process stops.
                    }
                    try await writer.finish(nil)
                }
                return Response(status: .ok, body: body)
            }

            router.get("\(prefix)/images/{name}/**") { _, context in
                // Docker client may hit /images/{name}/json or /images/{name}/history.
                // Names can contain slashes (docker.io/library/nginx:alpine) — the
                // extra segments land in the catchall, before the trailing action.
                let name = imageNameFromPath(context.parameters)
                let image = try await bridge.inspectImage(name: name)
                return try JSONResponse(image)
            }

            router.delete("\(prefix)/images/{name}/**") { _, context in
                let name = imageNameFromPath(context.parameters)
                try await bridge.removeImage(name: name)
                return Response(status: .noContent)
            }

            // MARK: Networks
            router.get("\(prefix)/networks") { _, _ in
                let networks = try await bridge.listNetworks()
                return try JSONResponse(networks)
            }
            router.post("\(prefix)/networks/create") { request, _ in
                let body = try await request.body.collect(upTo: 1024 * 1024)
                let name = (try? JSONDecoder().decode(DockerNetworkCreateRequest.self, from: Data(buffer: body)))?.name
                    ?? "keg-net-\(UUID().uuidString.prefix(8).lowercased())"
                let network = try await bridge.createNetwork(name: name, labels: nil)
                return try JSONResponse(DockerNetworkCreateResponse(id: network.id, warning: ""))
            }
            router.get("\(prefix)/networks/{id}") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                if let network = await bridge.network(id: id) {
                    return try JSONResponse(network)
                }
                let networks = try await bridge.listNetworks()
                if let network = networks.first(where: { $0.id == id || $0.name == id }) {
                    return try JSONResponse(network)
                }
                return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "{\"message\":\"network not found\"}")))
            }
            router.delete("\(prefix)/networks/{id}") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                try await bridge.removeNetwork(id: id)
                return Response(status: .noContent)
            }
            router.post("\(prefix)/networks/{id}/connect") { _, _ in
                // All containers share the built-in NAT network; connect is
                // bookkeeping-only for compose compatibility.
                Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{}")))
            }
            router.post("\(prefix)/networks/{id}/disconnect") { _, _ in
                Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{}")))
            }

            // MARK: Volumes
            router.get("\(prefix)/volumes") { _, _ in
                let volumeList = try await bridge.listVolumes()
                return try JSONResponse(volumeList)
            }

            router.post("\(prefix)/volumes/create") { request, _ in
                let body = try await request.body.collect(upTo: 1024 * 1024)
                let createReq = try? JSONDecoder().decode(DockerVolumeCreateRequest.self, from: Data(buffer: body))
                let requested = createReq?.name ?? ""
                let name = requested.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "keg-vol-\(UUID().uuidString.prefix(8).lowercased())"
                    : requested
                let volume = try await bridge.createVolume(name: name)
                return try JSONResponse(volume, status: .created)
            }

            router.delete("\(prefix)/volumes/{name}") { _, context in
                let name = context.parameters.get("name", as: String.self)!
                try await bridge.removeVolume(name: name)
                return Response(status: .noContent)
            }

            // MARK: Stats
            router.get("\(prefix)/containers/{id}/stats") { request, context in
                let id = context.parameters.get("id", as: String.self)!
                // Clients send stream=0, stream=false, or one-shot=1.
                let streamParam = request.uri.queryParameters.get("stream")
                let stream = streamParam != "0" && streamParam != "false"
                let oneShot = request.uri.queryParameters.get("one-shot") == "1"
                let encoder = JSONEncoder()

                if !stream || oneShot {
                    let stats = try await bridge.containerStats(id: id)
                    return try JSONResponse(stats)
                }

                let body = ResponseBody(contentLength: nil) { writer in
                    while true {
                        let stats = try await bridge.containerStats(id: id)
                        let data = try encoder.encode(stats)
                        var buffer = ByteBuffer(data: data)
                        buffer.writeString("\n")
                        try await writer.write(buffer)
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                return Response(status: .ok, body: body)
            }

            // MARK: Build
            router.post("\(prefix)/build") { request, _ in
                // The docker CLI streams the build context as a tarball in
                // the request body; `container build` needs it on disk.
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("keg-build-\(UUID().uuidString.prefix(8))")
                let tarPath = tempDir.appendingPathComponent("context.tar").path
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                // FileHandle(forWritingTo:) needs the file to exist first.
                FileManager.default.createFile(atPath: tarPath, contents: nil)
                let tarHandle = try FileHandle(forWritingTo: URL(filePath: tarPath))
                do {
                    for try await chunk in request.body {
                        try tarHandle.write(contentsOf: Data(buffer: chunk))
                    }
                } catch {
                    try? tarHandle.close()
                    try? FileManager.default.removeItem(at: tempDir)
                    throw error
                }
                try tarHandle.close()

                // Extract with the system tar (bsdtar handles docker's
                // context format, including long names).
                let extract = Process()
                extract.executableURL = URL(filePath: "/usr/bin/tar")
                extract.arguments = ["-xf", tarPath, "-C", tempDir.path]
                extract.standardOutput = FileHandle.nullDevice
                extract.standardError = FileHandle.nullDevice
                try extract.run()
                extract.waitUntilExit()
                guard extract.terminationStatus == 0 else {
                    throw DockerAPIError.badRequest("failed to extract build context")
                }

                // dockerfile comes in relative to the context root; Apple's
                // CLI resolves -f against the process CWD, so make it
                // absolute within the extracted context.
                let dockerfilePath = request.uri.queryParameters.get("dockerfile").map {
                    tempDir.appendingPathComponent(String($0)).path
                }
                let tags = request.uri.queryParameters[values: "t"] + request.uri.queryParameters[values: "tag"]
                var buildArgs: [String] = []
                if let encoded = request.uri.queryParameters.get("buildargs"),
                   let data = encoded.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    buildArgs = decoded.map { "\($0.key)=\($0.value)" }.sorted()
                }
                let noCache = request.uri.queryParameters.get("nocache") == "1"

                let output = try bridge.buildImageStream(
                    contextDir: tempDir.path,
                    dockerfile: dockerfilePath,
                    tag: tags.first.map(String.init),
                    buildArgs: buildArgs,
                    noCache: noCache
                )

                // Docker clients parse NDJSON objects with "stream" fields.
                // The build process is spawned now and streams into the
                // line buffer; the context dir lives until the response
                // body finishes (the route's defer would delete it too
                // early — the body runs after the handler returns).
                let encoder = JSONEncoder()
                let body = ResponseBody(contentLength: nil) { writer in
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    for try await line in output.lines {
                        let message = ["stream": line + "\n"]
                        if let data = try? JSONSerialization.data(withJSONObject: message) {
                            var buffer = ByteBuffer(data: data)
                            buffer.writeString("\n")
                            try await writer.write(buffer)
                        }
                    }
                    _ = await output.waitForExit()
                    try await writer.finish(nil)
                }
                return Response(status: .ok, body: body)
            }

            // MARK: Image push
            router.post("\(prefix)/images/{name}/push") { request, context in
                var name = imageNameFromPath(context.parameters)
                // imageNameFromPath keeps trailing segments; drop the
                // trailing "push" action.
                if name.hasSuffix("/push") {
                    name = String(name.dropLast("/push".count))
                }
                guard !name.isEmpty else {
                    throw DockerAPIError.badRequest("No image specified")
                }

                let output: StreamingProcess.Output
                do {
                    output = try bridge.pushImageStream(name: name)
                } catch {
                    throw DockerAPIError.imagePullFailed("\(error)")
                }
                let encoder = JSONEncoder()
                let body = ResponseBody(contentLength: nil) { writer in
                    for try await line in output.lines {
                        guard let message = PullProgressMapper.message(forLine: line) else { continue }
                        let data = try encoder.encode(message)
                        var buffer = ByteBuffer(data: data)
                        buffer.writeString("\n")
                        try await writer.write(buffer)
                    }
                    _ = await output.waitForExit()
                    try await writer.finish(nil)
                }
                return Response(status: .ok, body: body)
            }

            // MARK: System
            router.get("\(prefix)/system/df") { _, _ in
                let df = try await bridge.systemDiskUsage()
                return try JSONResponse(df)
            }

            router.post("\(prefix)/containers/prune") { _, _ in
                let deleted = try await bridge.pruneContainers()
                let ids = deleted.map(\.id)
                let response: [String: Any] = ["ContainersDeleted": ids, "SpaceReclaimed": 0]
                let data = try JSONSerialization.data(withJSONObject: response)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
            }

            // MARK: Events
            router.get("\(prefix)/events") { _, _ in
                let stream = await eventBus.subscribe()
                let encoder = JSONEncoder()
                let body = ResponseBody(contentLength: nil) { writer in
                    for await event in stream {
                        guard let data = try? encoder.encode(event) else { continue }
                        var buffer = ByteBuffer(data: data)
                        buffer.writeString("\n")
                        try await writer.write(buffer)
                    }
                    try await writer.finish(nil)
                }
                return Response(status: .ok, body: body)
            }

            // MARK: Webhooks
            router.post("\(prefix)/webhooks") { request, _ in
                let body = try await request.body.collect(upTo: 1024 * 1024)
                let createReq = try JSONDecoder().decode(CreateWebhookRequest.self, from: Data(buffer: body))
                guard let endpoint = URL(string: createReq.endpoint) else {
                    throw DockerAPIError.badRequest("Invalid webhook endpoint URL")
                }
                let secret = createReq.secret ?? generateWebhookSecret()
                let filter = createReq.containerFilter.flatMap { filterReq -> ContainerFilter? in
                    ContainerFilter(labels: filterReq.labels, name: filterReq.name, image: filterReq.image)
                }
                let webhook = await whManager.create(
                    name: createReq.name,
                    endpoint: endpoint,
                    containerFilter: filter,
                    events: createReq.events.compactMap { WebhookEvent(rawValue: $0) },
                    secret: secret
                )
                let response: [String: Any] = [
                    "ID": webhook.id,
                    "Name": webhook.name,
                    "Endpoint": webhook.endpoint.absoluteString,
                    "Secret": secret
                ]
                let responseData = try! JSONSerialization.data(withJSONObject: response)
                return Response(status: .created, body: .init(byteBuffer: ByteBuffer(data: responseData)))
            }

            router.get("\(prefix)/webhooks") { _, _ in
                let webhooks = await whManager.list()
                let response = WebhookListResponse(webhooks: webhooks.map {
                    WebhookInfo(name: $0.name, uuid: $0.id)
                })
                return try JSONResponse(response)
            }

            router.delete("\(prefix)/webhooks/{id}") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                let deleted = await whManager.delete(id: id)
                if !deleted { throw DockerAPIError.webhookNotFound(id) }
                return Response(status: .noContent)
            }

            router.get("\(prefix)/webhooks/{id}") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                guard let webhook = await whManager.get(id: id) else {
                    throw DockerAPIError.webhookNotFound(id)
                }
                return try JSONResponse(WebhookInfo(name: webhook.name, uuid: webhook.id))
            }

            router.patch("\(prefix)/webhooks/{id}") { request, context in
                let id = context.parameters.get("id", as: String.self)!
                let body = try await request.body.collect(upTo: 1024 * 1024)
                let updateReq = try JSONDecoder().decode(UpdateWebhookRequest.self, from: Data(buffer: body))
                guard let webhook = await whManager.update(id: id, name: updateReq.name, enabled: updateReq.enabled) else {
                    throw DockerAPIError.webhookNotFound(id)
                }
                return try JSONResponse(WebhookInfo(name: webhook.name, uuid: webhook.id))
            }
        }

        registerRoutes("")
        registerRoutes("/v1.{apiVersion}")

        // Catch-alls for unmatched routes (must be registered last). POST
        // needs its own: returning an honest 501 here beats a framework
        // default 404 for endpoints Docker clients know exist.
        router.get("/**") { _, _ in
            Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "{}")))
        }
        router.post("/**") { request, _ in
            let message = ["message": "not implemented by Keg: \(request.uri.path)"]
            let data = try JSONSerialization.data(withJSONObject: message)
            return Response(status: .notImplemented, body: .init(byteBuffer: ByteBuffer(data: data)))
        }

        // The docker CLI hijacks the connection for exec attach and
        // container attach (docker run): it refuses a plain 200 and insists
        // on `101 Switching Protocols` + `Upgrade: tcp`, after which the
        // socket carries raw (stdcopy-multiplexed) bytes. Hummingbird has
        // no upgrade support, so we run our own HTTP child channel that
        // defers to NIO's classic upgrade handler.
        let hijackHandler: @Sendable (String, HijackedConnection) -> Bool = { path, connection in
            guard let target = Self.hijackTarget(forPath: path) else {
                return false
            }

            // Session lookup and process setup are async; they run once the
            // splice handler is live, and stdin arriving in the meantime is
            // buffered by the connection. Unknown targets simply close.
            connection.onEstablished = {
                Task.detached {
                    switch target {
                    case .execStart(let execID):
                        guard let session = await execRegistry.get(id: execID) else {
                            connection.close()
                            return
                        }
                        do {
                            let pump = try await bridge.startExec(
                                containerID: session.containerID,
                                execID: execID,
                                request: session.request
                            )
                            await execRegistry.markStarted(id: execID)

                            connection.setReadHandler(
                                { data in pump.writeStdin(data) },
                                eof: { pump.closeStdin() }
                            )

                            for try await chunk in pump.makeOutputStream() {
                                if pump.tty {
                                    connection.write(chunk.data)
                                } else {
                                    connection.write(Self.stdcopyFrame(chunk))
                                }
                            }

                            let code = await pump.completion()
                            await execRegistry.markFinished(id: execID, exitCode: Int(clamping: code))
                            connection.close()
                        } catch {
                            connection.close()
                        }

                    case .containerAttach(let id, let wantsStdin):
                        // Attaching to an already-running container isn't
                        // possible: the init process's stdio was fixed at
                        // bootstrap. (Apple's own CLI has the same limit.)
                        guard let inspect = try? await bridge.inspectContainer(id: id),
                              !inspect.state.running else {
                            connection.close()
                            return
                        }
                        let pump = ExecPump(
                            execID: "attach-\(id)",
                            tty: inspect.config?.tty ?? false,
                            interactive: wantsStdin
                        )
                        connection.setReadHandler(
                            { data in pump.writeStdin(data) },
                            eof: { pump.closeStdin() }
                        )
                        // The /start route picks this up and bootstraps the
                        // container with the attached pipes as stdio.
                        await bridge.registerAttachIntent(id: id, pump: pump)

                        for try await chunk in pump.makeOutputStream() {
                            if pump.tty {
                                connection.write(chunk.data)
                            } else {
                                connection.write(Self.stdcopyFrame(chunk))
                            }
                        }
                        _ = await pump.completion()
                        connection.close()
                    }
                }
            }
            return true
        }

        let server = HTTPServerBuilder { responder in
            DockerHijackHTTPChannel(responder: responder, hijackHandler: hijackHandler)
        }

        let app = Application(
            router: router,
            server: server,
            configuration: .init(address: .unixDomainSocket(path: socketPath))
        )

        // Store the resolved path so callers know which socket was bound
        resolvedSocketPath = socketPath

        try await app.runService()
    }

    /// The connection-hijack targets Keg supports.
    enum HijackTarget: Equatable {
        case execStart(String)
        case containerAttach(String, stdin: Bool)
    }

    /// Parses a hijack-eligible path into its target:
    /// `/v1.51/exec/{id}/start` or `/v1.51/containers/{id}/attach?stream=1…`.
    static func hijackTarget(forPath path: String) -> HijackTarget? {
        var pathOnly = path
        var query = ""
        if let q = path.firstIndex(of: "?") {
            pathOnly = String(path[path.startIndex..<q])
            query = String(path[path.index(after: q)...])
        }
        var components = pathOnly.split(separator: "/").map(String.init)
        if let first = components.first, first.hasPrefix("v1."), first.contains(".") {
            components.removeFirst()
        }
        guard components.count == 3 else { return nil }
        if components[0] == "exec", components[2] == "start" {
            return .execStart(components[1])
        }
        if components[0] == "containers", components[2] == "attach" {
            let stdin = query.split(separator: "&").contains { $0.hasPrefix("stdin=1") }
            return .containerAttach(components[1], stdin: stdin)
        }
        return nil
    }

    /// Extracts the exec id from a hijack-eligible path like
    /// `/v1.51/exec/abc123/start` (returns nil for anything else).
    static func execIDFromPath(_ path: String) -> String? {
        if case .execStart(let id) = hijackTarget(forPath: path) {
            return id
        }
        return nil
    }

    /// Encodes one tagged exec chunk as a Docker stdcopy frame (Data form
    /// for the raw hijacked connection).
    static func stdcopyFrame(_ chunk: ExecPump.TaggedChunk) -> Data {
        var data = Data([chunk.stream.rawValue, 0, 0, 0])
        var length = UInt32(chunk.data.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(chunk.data)
        return data
    }

    /// Server-side `filters` support for `GET /containers/json`, as used by
    /// docker compose. Supports `label` (key or key=value), `status`, and
    /// `name` matchers. Handles both filter encodings: the legacy array form
    /// (`{"label":["a=b"]}`) and the ≥ API 1.43 map form
    /// (`{"label":{"a=b":true}}`) that modern compose actually sends.
    static func applyContainerFilters(_ containers: [DockerContainer], spec: String) -> [DockerContainer] {
        guard let data = spec.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return containers }

        func values(_ key: String) -> [String] {
            guard let entry = raw[key] else { return [] }
            if let array = entry as? [String] { return array }
            if let map = entry as? [String: Any] {
                return map.compactMap { $0.value as? Bool == true ? $0.key : nil }
            }
            return []
        }

        var result = containers

        let labels = values("label")
        if !labels.isEmpty {
            result = result.filter { container in
                let containerLabels = container.labels ?? [:]
                return labels.allSatisfy { matcher in
                    if let eq = matcher.firstIndex(of: "=") {
                        let key = String(matcher[..<eq])
                        let value = String(matcher[matcher.index(after: eq)...])
                        return containerLabels[key] == value
                    }
                    return containerLabels[matcher] != nil
                }
            }
        }

        let statuses = values("status")
        if !statuses.isEmpty {
            result = result.filter { statuses.contains($0.state) }
        }

        let names = values("name")
        if !names.isEmpty {
            result = result.filter { container in
                names.contains { matcher in
                    container.names.contains { $0.contains(matcher) }
                }
            }
        }

        return result
    }

    /// Check whether we can create/bind a Unix socket at the given path.
    private func canBindSocket(at path: String) -> Bool {        // Check if we can write to the directory containing the socket
        let dir = (path as NSString).deletingLastPathComponent
        return FileManager.default.isWritableFile(atPath: dir)
    }

    static func defaultSocketPath() -> String {
        NSHomeDirectory() + "/.keg/docker.sock"
    }

    static func socketPath() -> String {
        defaultSocketPath()
    }

    /// Liveness probe: true if a server at `path` answers `GET /_ping` with an
    /// HTTP 200 whose body is "OK". Used before unlinking a socket file so we
    /// never remove a live socket owned by another (or our own previous) Keg
    /// process — `AppState` is instantiated by unit tests too, and an eager
    /// unconditional unlink breaks a running app's Docker API.
    static func socketRespondsToPing(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < sunPathSize else { return false }
        path.withCString { cPath in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                // sun_path sits at a fixed offset inside sockaddr_un; reach it
                // as a CChar buffer so `strncpy` writes the NUL-terminated path.
                let base = UnsafeMutableRawPointer(addrPtr).assumingMemoryBound(to: CChar.self)
                let pathPtr = base.advanced(by: MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!)
                strncpy(pathPtr, cPath, sunPathSize - 1)
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { return false }

        // Bound but dead sockets accept connect() then EOF — require a real
        // HTTP response with a short read timeout so we never mistake one
        // for a live server.
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let request = "GET /_ping HTTP/1.0\r\nHost: localhost\r\n\r\n"
        let sent = request.withCString { cRequest in
            send(fd, cRequest, strlen(cRequest), 0)
        }
        guard sent == strlen(request) else { return false }

        var buffer = [UInt8](repeating: 0, count: 512)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { return false }
        let response = String(decoding: buffer[0..<received], as: UTF8.self)
        return response.hasPrefix("HTTP/1.1 200") || response.hasPrefix("HTTP/1.0 200")
    }
}

// MARK: - Response helper

private func JSONResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(status: status, body: .init(byteBuffer: ByteBuffer(data: data)))
}

// MARK: - Webhook Request/Response Types

struct CreateWebhookRequest: Codable {
    let name: String
    let endpoint: String
    let containerFilter: WebhookContainerFilter?
    let events: [String]
    let secret: String?

    enum CodingKeys: String, CodingKey {
        case name
        case endpoint = "Endpoint"
        case containerFilter = "ContainerFilter"
        case events = "Events"
        case secret = "Secret"
    }
}

struct UpdateWebhookRequest: Codable {
    let name: String?
    let enabled: Bool?
}

struct WebhookContainerFilter: Codable {
    let labels: [String: String]?
    let name: String?
    let image: String?
}

// MARK: - Helpers

private func generateWebhookSecret() -> String {
    var buffer = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
    return Data(buffer).base64EncodedString().prefix(32).description
}
