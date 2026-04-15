import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore
import NIOHTTP1
import Security
import CommonCrypto

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

    init() {
        self.bridge = ContainerBridge()
        self.webhookManager = WebhookManager()
    }

    func start() async throws {
        let socketPath = Self.socketPath()

        // Ensure ~/.keg directory exists
        let kegDir = URL(filePath: NSHomeDirectory()).appendingPathComponent(".keg")
        try FileManager.default.createDirectory(at: kegDir, withIntermediateDirectories: true)

        // Remove old socket
        try? FileManager.default.removeItem(atPath: socketPath)

        let bridge = self.bridge

        let router = Router()
        router.middlewares.add(DockerVersionStripMiddleware())

        // MARK: - System Routes
        router.get("/_ping") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "OK")))
        }

        router.get("/version") { _, _ in
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
            return try! JSONResponse(version)
        }

        router.get("/info") { request, _ in
            let info = try await bridge.systemInfo()
            return try! JSONResponse(info)
        }

        // MARK: - Container Routes
        router.get("/containers/json") { request, _ in
            let all = request.uri.queryParameters.get("all") != nil
            let containers = try await bridge.listContainers(all: all)
            return try! JSONResponse(containers)
        }

        router.post("/containers/create") { request, _ in
            let name = request.uri.queryParameters.get("name")
            let body = try await request.body.collect(upTo: 1024 * 1024)
            let createReq = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(buffer: body))
            let response = try await bridge.createContainer(from: createReq, name: name)
            return try! JSONResponse(response, status: .created)
        }

        router.post("/containers/{id}/start") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            try await bridge.startContainer(id: id)
            return Response(status: .noContent)
        }

        router.post("/containers/{id}/stop") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            try? await bridge.stopContainer(id: id)
            return Response(status: .noContent)
        }

        router.post("/containers/{id}/kill") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            try? await bridge.killContainer(id: id)
            return Response(status: .noContent)
        }

        router.post("/containers/{id}/restart") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            try? await bridge.stopContainer(id: id)
            try? await bridge.startContainer(id: id)
            return Response(status: .noContent)
        }

        router.delete("/containers/{id}") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            let force = request.uri.queryParameters.get("force") != nil
            try await bridge.removeContainer(id: id, force: force)
            return Response(status: .noContent)
        }

        router.get("/containers/{id}/json") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            let inspect = try await bridge.inspectContainer(id: id)
            return try! JSONResponse(inspect)
        }

        router.get("/containers/{id}/logs") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            let tail = request.uri.queryParameters.get("tail").flatMap(Int.init)
            let follow = request.uri.queryParameters.get("follow") == "1" || request.uri.queryParameters.get("follow") == "true"
            let logs = try await bridge.containerLogs(id: id, tail: tail, follow: follow)
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: logs)))
        }

        // MARK: - Exec Routes (stub)
        router.post("/containers/{id}/exec") { request, context in
            let _ = context.parameters.get("id", as: String.self)!
            let execId = "exec-\(UUID().uuidString.prefix(12))"
            let response: [String: String] = ["Id": execId]
            return try! JSONResponse(response, status: .created)
        }

        // MARK: - Image Routes
        router.get("/images/json") { _, _ in
            let images = try await bridge.listImages()
            return try! JSONResponse(images)
        }

        router.post("/images/create") { request, _ in
            let fromImage = request.uri.queryParameters.get("fromImage") ?? ""
            let input = request.uri.queryParameters.get("input") ?? ""
            let imageRef = fromImage.isEmpty ? input : fromImage

            guard !imageRef.isEmpty else {
                throw DockerAPIError.badRequest("No image specified")
            }

            try await bridge.pullImage(from: imageRef)
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "")))
        }

        router.get("/images/{name}/**") { request, context in
            // Docker client may hit /images/{name}/json or /images/{name}/history
            let name = context.parameters.get("name", as: String.self)!
            let image = try await bridge.inspectImage(name: name)
            return try! JSONResponse(image)
        }

        router.delete("/images/{name}/**") { request, context in
            let name = context.parameters.get("name", as: String.self)!
            try await bridge.removeImage(name: name)
            return Response(status: .noContent)
        }

        // MARK: - Network Routes (stubs)
        router.get("/networks") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "[]")))
        }
        router.get("/networks/**") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "[]")))
        }

        // MARK: - Volume Routes (stubs)
        router.get("/volumes") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "[]")))
        }

        // MARK: - Events (stub)
        router.get("/events") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "")))
        }

        // MARK: - Webhook Routes
        let whManager = self.webhookManager
        let whBridge = self.bridge

        router.post("/webhooks") { request, _ in
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

            // Return webhook info (without secret)
            let response: [String: Any] = [
                "ID": webhook.id,
                "Name": webhook.name,
                "Endpoint": webhook.endpoint.absoluteString,
                "Secret": secret // Only shown on creation
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            return Response(status: .created, body: .init(byteBuffer: ByteBuffer(data: responseData)))
        }

        router.get("/webhooks") { _, _ in
            let webhooks = await whManager.list()
            let response = WebhookListResponse(webhooks: webhooks.map {
                WebhookInfo(name: $0.name, uuid: $0.id)
            })
            return try! JSONResponse(response)
        }

        router.delete("/webhooks/{id}") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            let deleted = await whManager.delete(id: id)
            if !deleted {
                throw DockerAPIError.webhookNotFound(id)
            }
            return Response(status: .noContent)
        }

        router.get("/webhooks/{id}") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            guard let webhook = await whManager.get(id: id) else {
                throw DockerAPIError.webhookNotFound(id)
            }
            let info = WebhookInfo(name: webhook.name, uuid: webhook.id)
            return try! JSONResponse(info)
        }

        router.patch("/webhooks/{id}") { request, context in
            let id = context.parameters.get("id", as: String.self)!
            let body = try await request.body.collect(upTo: 1024 * 1024)
            let updateReq = try JSONDecoder().decode(UpdateWebhookRequest.self, from: Data(buffer: body))

            guard let webhook = await whManager.update(id: id, name: updateReq.name, enabled: updateReq.enabled) else {
                throw DockerAPIError.webhookNotFound(id)
            }
            let info = WebhookInfo(name: webhook.name, uuid: webhook.id)
            return try! JSONResponse(info)
        }

        // Hook webhook dispatch into container events
        await hookContainerEvents(manager: whManager, bridge: whBridge)

        // Catch-all for unmatched routes
        router.get("/**") { request, _ in
            return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "{}")))
        }

        let app = Application(
            router: router,
            configuration: .init(address: .unixDomainSocket(path: socketPath))
        )

        try await app.runService()
    }

    static func socketPath() -> String {
        NSHomeDirectory() + "/.keg/docker.sock"
    }
}

// MARK: - Response helper

private func JSONResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(status: status, body: .init(byteBuffer: ByteBuffer(data: data)))
}

// MARK: - Docker Version Strip Middleware

/// Strips /v1.XX prefix from request URI before routing.
/// Docker CLI sends `/v1.54/containers/json` but routes are at `/containers/json`.
struct DockerVersionStripMiddleware<Context: RequestContext>: RouterMiddleware {
    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        // Match /v1.XX/... → /...
        guard path.hasPrefix("/v1.") else {
            return try await next(request, context)
        }
        // Find the slash after the version number
        let afterPrefix = path.index(path.startIndex, offsetBy: 4) // after "/v1."
        guard let slashIdx = path[afterPrefix...].firstIndex(of: "/") else {
            return try await next(request, context)
        }
        let newPath = String(path[slashIdx...]) // includes leading /
        let query = request.uri.query.map { "?\($0)" } ?? ""
        let newRequest = Request(head: .init(method: request.head.method, url: URL(string: (newPath + query).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? newPath)!, headerFields: request.head.headerFields), body: request.body)
        return try await next(newRequest, context)
    }
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
