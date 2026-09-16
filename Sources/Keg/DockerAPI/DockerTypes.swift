import Foundation

// MARK: - Docker API JSON Types

struct DockerContainer: Codable {
    let id: String
    let names: [String]
    let image: String
    let imageID: String
    let command: String
    let created: Int64
    let state: String
    let status: String
    let ports: [DockerPort]?
    let labels: [String: String]?
    let networkSettings: DockerNetworkSettings?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case imageID = "ImageID"
        case command = "Command"
        case created = "Created"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
        case networkSettings = "NetworkSettings"
    }
}

struct DockerPort: Codable {
    let ip: String?
    let privatePort: Int
    let publicPort: Int?
    let type: String

    enum CodingKeys: String, CodingKey {
        case ip = "IP"
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case type = "Type"
    }
}

struct DockerNetworkSettings: Codable {
    let networks: [String: DockerEndpointSettings]?

    enum CodingKeys: String, CodingKey {
        case networks = "Networks"
    }
}

struct DockerEndpointSettings: Codable {
    let iPAddress: String?

    enum CodingKeys: String, CodingKey {
        case iPAddress = "IPAddress"
    }
}

struct DockerContainerCreateRequest: Codable {
    let image: String?
    let cmd: [String]?
    let env: [String]?
    let hostConfig: DockerHostConfig?
    let name: String?
    let labels: [String: String]?
    let entrypoint: [String]?
    let workingDir: String?
    let exposedPorts: [String: AnyCodable]?
    let tty: Bool?
    let openStdin: Bool?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case cmd = "Cmd"
        case env = "Env"
        case hostConfig = "HostConfig"
        case name = "name"
        case labels = "Labels"
        case entrypoint = "Entrypoint"
        case workingDir = "WorkingDir"
        case exposedPorts = "ExposedPorts"
        case tty = "Tty"
        case openStdin = "OpenStdin"
    }
}

struct DockerHostConfig: Codable {
    let portBindings: [String: [DockerPortBinding]]?
    let binds: [String]?
    let memory: Int64?
    let nanoCPUs: Int64?
    let networkMode: String?
    let restartPolicy: DockerRestartPolicy?
    let privileged: Bool?
    let autoRemove: Bool?

    enum CodingKeys: String, CodingKey {
        case portBindings = "PortBindings"
        case binds = "Binds"
        case memory = "Memory"
        case nanoCPUs = "NanoCpus"
        case networkMode = "NetworkMode"
        case restartPolicy = "RestartPolicy"
        case privileged = "Privileged"
        case autoRemove = "AutoRemove"
    }
}

struct DockerPortBinding: Codable {
    let hostIP: String?
    let hostPort: String?

    enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}

struct DockerRestartPolicy: Codable {
    let name: String?
    let maximumRetryCount: Int?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maximumRetryCount = "MaximumRetryCount"
    }
}

struct DockerContainerCreateResponse: Codable {
    let id: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case warnings = "Warnings"
    }
}

struct DockerContainerInspect: Codable {
    let id: String
    let created: String
    let path: String?
    let args: [String]?
    let state: DockerContainerState
    let image: String
    let name: String
    let config: DockerContainerConfig?
    let networkSettings: DockerInspectNetworkSettings?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case created = "Created"
        case path = "Path"
        case args = "Args"
        case state = "State"
        case image = "Image"
        case name = "Name"
        case config = "Config"
        case networkSettings = "NetworkSettings"
    }
}

struct DockerContainerState: Codable {
    let status: String
    let running: Bool
    let paused: Bool
    let restarting: Bool
    let dead: Bool
    let pid: Int?
    let exitCode: Int?
    let startedAt: String?
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case running = "Running"
        case paused = "Paused"
        case restarting = "Restarting"
        case dead = "Dead"
        case pid = "Pid"
        case exitCode = "ExitCode"
        case startedAt = "StartedAt"
        case finishedAt = "FinishedAt"
    }
}

struct DockerContainerConfig: Codable {
    let image: String?
    let cmd: [String]?
    let env: [String]?
    let labels: [String: String]?
    let tty: Bool?
    let openStdin: Bool?
    let workingDir: String?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case cmd = "Cmd"
        case env = "Env"
        case labels = "Labels"
        case tty = "Tty"
        case openStdin = "OpenStdin"
        case workingDir = "WorkingDir"
    }
}

struct DockerInspectNetworkSettings: Codable {
    let ipAddress: String?
    let gateway: String?
    let ports: [String: [DockerPortBinding]]?
    let networks: [String: DockerEndpointSettings]?

    enum CodingKeys: String, CodingKey {
        case ipAddress = "IPAddress"
        case gateway = "Gateway"
        case ports = "Ports"
        case networks = "Networks"
    }
}

struct DockerImage: Codable {
    let id: String
    let repoTags: [String]
    let repoDigests: [String]?
    let created: Int64
    let size: Int64
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case created = "Created"
        case size = "Size"
        case labels = "Labels"
    }

    /// Returns a copy with a different reported size.

    func withSize(_ size: Int64) -> DockerImage {
        DockerImage(id: id, repoTags: repoTags, repoDigests: repoDigests, created: created, size: size, labels: labels)
    }
}

/// Shape of `GET /images/{name}/json`. Unlike the list entry, Docker clients
/// (docker compose especially) unmarshal `Created` strictly as an RFC 3339
/// *string* — a numeric epoch here fails with "cannot unmarshal number into
/// Go struct field ImageInspectResult.Created of type string".
struct DockerImageInspect: Codable {
    let id: String
    let repoTags: [String]?
    let repoDigests: [String]?
    let created: String
    let size: Int64
    let architecture: String?
    let os: String?
    let config: DockerContainerConfig?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case created = "Created"
        case size = "Size"
        case architecture = "Architecture"
        case os = "Os"
        case config = "Config"
    }
}

struct DockerVersion: Codable {
    let version: String
    let apiVersion: String
    let minAPIVersion: String
    let gitCommit: String
    let goVersion: String
    let os: String
    let arch: String
    let kernelVersion: String
    let buildTime: String

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
        case minAPIVersion = "MinAPIVersion"
        case gitCommit = "GitCommit"
        case goVersion = "GoVersion"
        case os = "Os"
        case arch = "Arch"
        case kernelVersion = "KernelVersion"
        case buildTime = "BuildTime"
    }
}

struct DockerInfo: Codable {
    let id: String
    let containers: Int
    let containersRunning: Int
    let containersStopped: Int
    let images: Int
    let operatingSystem: String
    let architecture: String
    let kernelVersion: String
    let serverVersion: String
    let dockerRootDir: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case containers = "Containers"
        case containersRunning = "ContainersRunning"
        case containersStopped = "ContainersStopped"
        case images = "Images"
        case operatingSystem = "OperatingSystem"
        case architecture = "Architecture"
        case kernelVersion = "KernelVersion"
        case serverVersion = "ServerVersion"
        case dockerRootDir = "DockerRootDir"
    }
}

// MARK: - Network Types

struct DockerNetwork: Codable {
    let name: String
    let id: String
    let created: String
    let scope: String
    let driver: String
    let enableIPv6: Bool
    let ipam: DockerIPAM?
    let `internal`: Bool
    let attachable: Bool
    let ingress: Bool
    let options: [String: String]?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
        case created = "Created"
        case scope = "Scope"
        case driver = "Driver"
        case enableIPv6 = "EnableIPv6"
        case ipam = "IPAM"
        case `internal` = "Internal"
        case attachable = "Attachable"
        case ingress = "Ingress"
        case options = "Options"
        case labels = "Labels"
    }
}

struct DockerIPAM: Codable {
    let driver: String
    let config: [DockerIPAMConfig]?

    enum CodingKeys: String, CodingKey {
        case driver = "Driver"
        case config = "Config"
    }
}

struct DockerIPAMConfig: Codable {
    let subnet: String?
    let gateway: String?

    enum CodingKeys: String, CodingKey {
        case subnet = "Subnet"
        case gateway = "Gateway"
    }
}

// MARK: - Volume Types

struct DockerVolumeListResponse: Codable {
    let volumes: [DockerVolume]?
    let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case volumes = "Volumes"
        case warnings = "Warnings"
    }
}

struct DockerVolume: Codable {
    let name: String
    let driver: String
    let mountpoint: String
    let createdAt: String?
    let scope: String
    let labels: [String: String]?
    let options: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
        case createdAt = "CreatedAt"
        case scope = "Scope"
        case labels = "Labels"
        case options = "Options"
    }
}

// MARK: - Webhook Types

/// Docker webhook configuration
struct DockerWebhook: Codable {
    let name: String
    let endpoint: String
    let enabled: Bool
    let containerFilter: ContainerFilter?
    let events: [WebhookEvent]

    enum CodingKeys: String, CodingKey {
        case name
        case endpoint = "endpoint"
        case enabled
        case containerFilter = "container_filter"
        case events
    }
}

/// Filter criteria for webhook triggers
struct ContainerFilter: Codable {
    let labels: [String: String]?
    let name: String?
    let image: String?
}

/// Webhook event types
enum WebhookEvent: String, Codable {
    case containerStart = "container.start"
    case containerStop = "container.stop"
    case containerDestroy = "container.destroy"
    case containerHealth = "container.health"
    case imagePull = "image.pull"
}

/// Webhook payload sent to the endpoint
struct WebhookPayload: Codable {
    let webhook: WebhookInfo
    let event: String
    let timestamp: Date
    let container: ContainerInfo?
    let image: ImageInfo?

    enum CodingKeys: String, CodingKey {
        case webhook = "Webhook"
        case event
        case timestamp = "Time"
        case container = "Container"
        case image = "Image"
    }
}

/// Webhook identification info
struct WebhookInfo: Codable {
    let name: String
    let uuid: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case uuid = "UUID"
    }
}

/// Container info in webhook payload
struct ContainerInfo: Codable {
    let id: String
    let name: String
    let image: String
    let state: String
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Name"
        case image = "Image"
        case state = "State"
        case labels = "Labels"
    }
}

/// Image info in webhook payload
struct ImageInfo: Codable {
    let id: String
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case tags = "Tags"
    }
}

/// Webhook list response
struct WebhookListResponse: Codable {
    let webhooks: [WebhookInfo]

    enum CodingKeys: String, CodingKey {
        case webhooks = "Webhooks"
    }
}

// MARK: - Helper for dynamic JSON

public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyCodable.init))
        default: try container.encodeNil()
        }
    }
}
