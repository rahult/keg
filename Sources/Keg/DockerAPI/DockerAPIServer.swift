import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore
import NIOHTTP1

// MARK: - Docker API Server

final class DockerAPIServer: Sendable {
    let bridge: ContainerBridge

    init() {
        self.bridge = ContainerBridge()
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
