import Foundation
import Hummingbird
import HummingbirdCore
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
    /// The socket path that was actually bound after start() succeeds.
    nonisolated(unsafe) private(set) var resolvedSocketPath: String?

    init() {
        self.bridge = ContainerBridge()
        self.webhookManager = WebhookManager()
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
        let whManager = self.webhookManager
        let whBridge = self.bridge

        let router = Router()

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
                Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "OK")))
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
                try await bridge.startContainer(id: id)
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
                let statusCode = try await bridge.waitContainer(id: id)
                return try JSONResponse(["StatusCode": statusCode])
            }

            // MARK: Exec (stub)
            router.post("\(prefix)/containers/{id}/exec") { _, context in
                _ = context.parameters.get("id", as: String.self)!
                let execId = "exec-\(UUID().uuidString.prefix(12))"
                let response: [String: String] = ["Id": execId]
                return try JSONResponse(response, status: .created)
            }

            // MARK: Images
            router.get("\(prefix)/images/json") { _, _ in
                let images = try await bridge.listImages()
                return try JSONResponse(images)
            }

            router.post("\(prefix)/images/create") { request, _ in
                let fromImage = request.uri.queryParameters.get("fromImage") ?? ""
                let input = request.uri.queryParameters.get("input") ?? ""
                let imageRef = fromImage.isEmpty ? input : fromImage
                guard !imageRef.isEmpty else {
                    throw DockerAPIError.badRequest("No image specified")
                }
                try await bridge.pullImage(from: imageRef)
                return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "")))
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
            router.get("\(prefix)/networks/{id}") { _, context in
                let id = context.parameters.get("id", as: String.self)!
                let networks = try await bridge.listNetworks()
                if let network = networks.first(where: { $0.id == id || $0.name == id }) {
                    return try JSONResponse(network)
                }
                return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "{\"message\":\"network not found\"}")))
            }

            // MARK: Volumes
            router.get("\(prefix)/volumes") { _, _ in
                let volumeList = try await bridge.listVolumes()
                return try JSONResponse(volumeList)
            }

            // MARK: Events (stub)
            router.get("\(prefix)/events") { _, _ in
                Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "")))
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

        // Hook webhook dispatch into container events
        await hookContainerEvents(manager: whManager, bridge: whBridge)

        // Catch-all for unmatched routes (must be registered last)
        router.get("/**") { _, _ in
            Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "{}")))
        }

        let app = Application(
            router: router,
            configuration: .init(address: .unixDomainSocket(path: socketPath))
        )

        // Store the resolved path so callers know which socket was bound
        resolvedSocketPath = socketPath

        try await app.runService()
    }

    /// Server-side `filters` support for `GET /containers/json`, as used by
    /// docker compose (`filters={"label":["com.docker.compose.project=x"]}`).
    /// Supports `label` (key or key=value), `status`, and `name` matchers.
    static func applyContainerFilters(_ containers: [DockerContainer], spec: String) -> [DockerContainer] {
        guard let data = spec.data(using: .utf8),
              let filters = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return containers }

        var result = containers

        if let labels = filters["label"], !labels.isEmpty {
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

        if let statuses = filters["status"], !statuses.isEmpty {
            result = result.filter { statuses.contains($0.state) }
        }

        if let names = filters["name"], !names.isEmpty {
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

private func hookContainerEvents(manager: WebhookManager, bridge: ContainerBridge) async {
    // Container events are hooked via the bridge methods
    // This function can be extended to poll for events if needed
}
