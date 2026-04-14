import Foundation

// MARK: - Environment Types

/// AgentEnvironment - cloud container configuration
/// Based on: https://platform.claude.com/docs/en/managed-agents/environments
public struct AgentEnvironment: Codable, Sendable {
    public let id: String
    public let type: String
    public var name: String
    public var description: String?
    public var packages: [Package]
    public var networkAccess: NetworkAccess?
    public var mountedFiles: [MountedFile]?
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, name, description, packages
        case networkAccess = "network_access"
        case mountedFiles = "mounted_files"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Pre-installed package in environment
public struct Package: Codable, Sendable {
    public var name: String
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// Network access rules
public struct NetworkAccess: Codable, Sendable {
    public var allowAll: Bool?
    public var allowList: [String]?
    public var denyList: [String]?

    enum CodingKeys: String, CodingKey {
        case allowAll = "allow_all"
        case allowList = "allow_list"
        case denyList = "deny_list"
    }

    public init(allowAll: Bool? = nil, allowList: [String]? = nil, denyList: [String]? = nil) {
        self.allowAll = allowAll
        self.allowList = allowList
        self.denyList = denyList
    }
}

/// Mounted file configuration
public struct MountedFile: Codable, Sendable {
    public var path: String
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// Parameters for creating an environment
public struct CreateEnvironmentParams: Codable, Sendable {
    public var name: String
    public var description: String?
    public var packages: [Package]?
    public var networkAccess: NetworkAccess?
    public var mountedFiles: [MountedFile]?

    enum CodingKeys: String, CodingKey {
        case name, description, packages
        case networkAccess = "network_access"
        case mountedFiles = "mounted_files"
    }

    public init(
        name: String,
        description: String? = nil,
        packages: [Package]? = nil,
        networkAccess: NetworkAccess? = nil,
        mountedFiles: [MountedFile]? = nil
    ) {
        self.name = name
        self.description = description
        self.packages = packages
        self.networkAccess = networkAccess
        self.mountedFiles = mountedFiles
    }
}

// MARK: - List Responses

public struct AgentListResponse: Codable, Sendable {
    public let data: [Agent]
    public let hasMore: Bool
    public let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case totalCount = "total_count"
    }
}

public struct EnvironmentListResponse: Codable, Sendable {
    public let data: [AgentEnvironment]
    public let hasMore: Bool
    public let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case totalCount = "total_count"
    }
}
