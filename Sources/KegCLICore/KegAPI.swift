import Foundation

// MARK: - Socket resolution

/// Where the `keg` CLI finds Keg's Docker API socket. Mirrors the app's
/// own binding order: DOCKER_HOST wins, then the system path the app tries
/// first, then the user-level fallback.
public enum KegSocketResolver {
    public static let userSocketPath = NSHomeDirectory() + "/.keg/docker.sock"
    public static let systemSocketPath = "/var/run/docker.sock"

    /// Resolves the socket path from DOCKER_HOST (unix:// scheme) or the
    /// on-disk candidates. DOCKER_HOST is an explicit override and is
    /// trusted as-is — a dead path surfaces as a connect error later,
    /// which is more honest than silently ignoring it.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let host = environment["DOCKER_HOST"],
           host.hasPrefix("unix://"),
           let path = host.dropFirst("unix://".count).split(separator: "?").first {
            return String(path)
        }
        for candidate in [systemSocketPath, userSocketPath] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// All socket paths worth reporting in `doctor`, in priority order.
    public static var candidates: [String] {
        [systemSocketPath, userSocketPath]
    }
}

// MARK: - API models (Docker JSON shapes, subset the CLI renders)

public struct CLIContainer: Decodable, Sendable {
    public let id: String
    public let names: [String]
    public let image: String
    public let state: String
    public let status: String
    public let created: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case created = "Created"
    }

    public var displayName: String {
        (names.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public struct CLIImage: Decodable, Sendable {
    public let id: String
    public let repoTags: [String]?
    public let created: Int64
    public let size: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case created = "Created"
        case size = "Size"
    }

    public var displayName: String {
        repoTags?.first ?? id
    }
}

public struct CLISystemVersion: Decodable, Sendable {
    public let version: String
    public let apiVersion: String
    public let os: String
    public let arch: String

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
        case os = "Os"
        case arch = "Arch"
    }
}

public struct CLIContainerInspect: Decodable, Sendable {
    public let id: String
    public struct ContainerState: Decodable, Sendable {
        public let status: String
        public let running: Bool
        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case running = "Running"
        }
    }
    public let state: ContainerState

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case state = "State"
    }
}

// MARK: - Typed API surface

/// Docker API calls the `keg` CLI uses, decoded into CLI models.
public struct KegAPIClient: Sendable {
    public let http: UnixSocketHTTPClient

    public init(socketPath: String) {
        self.http = UnixSocketHTTPClient(socketPath: socketPath)
    }

    public func ping() throws -> Bool {
        let response = try http.get("/_ping")
        return response.status == 200
    }

    public func systemVersion() throws -> CLISystemVersion {
        try decode(http.get("/version"))
    }

    public func containers(all: Bool) throws -> [CLIContainer] {
        try decode(http.get("/containers/json\(all ? "?all=1" : "")"))
    }

    public func images() throws -> [CLIImage] {
        try decode(http.get("/images/json"))
    }

    /// Raw stdcopy-framed log bytes for a container.
    public func logs(id: String, tail: Int?) throws -> Data {
        var path = "/containers/\(id)/logs?stdout=1&stderr=1"
        if let tail {
            path += "&tail=\(tail)"
        }
        let response = try http.get(path)
        guard response.status == 200 else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(
                "logs failed (HTTP \(response.status)): \(String(data: response.body, encoding: .utf8) ?? "")"
            )
        }
        return response.body
    }

    public func inspect(id: String) throws -> CLIContainerInspect {
        try decode(http.get("/containers/\(id)/json"))
    }

    public func start(id: String) throws {
        let response = try http.post("/containers/\(id)/start")
        guard (200..<300).contains(response.status) || response.status == 304 else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(
                "start failed (HTTP \(response.status)): \(String(data: response.body, encoding: .utf8) ?? "")"
            )
        }
    }

    public func stop(id: String) throws {
        let response = try http.post("/containers/\(id)/stop")
        guard (200..<300).contains(response.status) || response.status == 304 else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(
                "stop failed (HTTP \(response.status)): \(String(data: response.body, encoding: .utf8) ?? "")"
            )
        }
    }

    public func restart(id: String) throws {
        let response = try http.post("/containers/\(id)/restart")
        guard (200..<300).contains(response.status) else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(
                "restart failed (HTTP \(response.status)): \(String(data: response.body, encoding: .utf8) ?? "")"
            )
        }
    }

    public func remove(id: String, force: Bool) throws {
        let response = try http.delete("/containers/\(id)\(force ? "?force=1" : "")")
        guard (200..<300).contains(response.status) else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(
                "remove failed (HTTP \(response.status)): \(String(data: response.body, encoding: .utf8) ?? "")"
            )
        }
    }

    private func decode<T: Decodable>(_ response: UnixSocketHTTPClient.Response) throws -> T {
        guard response.status == 200 else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(
                "request failed (HTTP \(response.status))"
            )
        }
        return try JSONDecoder().decode(T.self, from: response.body)
    }
}

// MARK: - stdcopy demuxing

/// Splits a Docker stdcopy stream (8-byte header + payload frames) into
/// plain stdout/stderr bytes. The framed format is what Keg's (and Docker's)
/// non-TTY log endpoints return.
public enum DockerLogDemuxer {
    public struct Output: Sendable {
        public var stdout = Data()
        public var stderr = Data()
    }

    public static func demux(_ data: Data) -> Output {
        var output = Output()
        var index = data.startIndex
        while data.distance(from: index, to: data.endIndex) >= 8 {
            let streamByte = data[index]
            let lengthBytes = data[data.index(index, offsetBy: 4)..<data.index(index, offsetBy: 8)]
            let length = lengthBytes.reduce(0) { ($0 << 8) | UInt32($1) }
            let payloadStart = data.index(index, offsetBy: 8)
            guard data.distance(from: payloadStart, to: data.endIndex) >= Int(length) else { break }
            let payloadEnd = data.index(payloadStart, offsetBy: Int(length))
            let payload = data[payloadStart..<payloadEnd]
            if streamByte == 2 {
                output.stderr.append(contentsOf: payload)
            } else {
                output.stdout.append(contentsOf: payload)
            }
            index = payloadEnd
        }
        return output
    }
}
