import Foundation

// MARK: - Core Types

/// Agent configuration - reusable, versioned persona and capabilities bundle
/// Based on: https://platform.claude.com/docs/en/managed-agents/agent-setup
public struct Agent: Codable, Sendable {
    public let id: String
    public let type: String
    public var name: String
    public var model: AgentModel
    public var system: String?
    public var description: String?
    public var tools: [AgentTool]
    public var skills: [AgentSkill]
    public var mcpServers: [MCPServer]
    public var callableAgents: [CallableAgent]?
    public var metadata: [String: String]?
    public let version: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, type, name, model, system, description, tools, skills
        case mcpServers = "mcp_servers"
        case callableAgents = "callable_agents"
        case metadata, version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

/// Agent model configuration
public struct AgentModel: Codable, Sendable {
    public var id: String
    public var speed: ModelSpeed?

    public init(id: String, speed: ModelSpeed? = nil) {
        self.id = id
        self.speed = speed
    }
}

/// Model speed configuration
public enum ModelSpeed: String, Codable, Sendable {
    case standard
    case fast
}

/// Agent tool configuration
public enum AgentTool: Codable, Sendable {
    case agentToolset(ToolsetConfig)
    case custom(CustomTool)

    enum CodingKeys: String, CodingKey {
        case type, defaultConfig, configs, name, description, inputSchema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "agent_toolset_20260401":
            let defaultConfig = try container.decodeIfPresent(ToolsetDefaultConfig.self, forKey: .defaultConfig)
            let configs = try container.decodeIfPresent([ToolConfig].self, forKey: .configs)
            self = .agentToolset(ToolsetConfig(defaultConfig: defaultConfig, configs: configs ?? []))
        case "custom":
            let name = try container.decode(String.self, forKey: .name)
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let inputSchema = try container.decodeIfPresent(InputSchema.self, forKey: .inputSchema)
            self = .custom(CustomTool(name: name, description: description, inputSchema: inputSchema))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown tool type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .agentToolset(let config):
            try container.encode("agent_toolset_20260401", forKey: .type)
            try container.encodeIfPresent(config.defaultConfig, forKey: .defaultConfig)
            if !config.configs.isEmpty {
                try container.encode(config.configs, forKey: .configs)
            }
        case .custom(let tool):
            try container.encode("custom", forKey: .type)
            try container.encode(tool.name, forKey: .name)
            try container.encodeIfPresent(tool.description, forKey: .description)
            try container.encodeIfPresent(tool.inputSchema, forKey: .inputSchema)
        }
    }
}

/// Toolset configuration with default and per-tool config
public struct ToolsetConfig: Codable, Sendable {
    public var defaultConfig: ToolsetDefaultConfig?
    public var configs: [ToolConfig]

    public init(defaultConfig: ToolsetDefaultConfig? = nil, configs: [ToolConfig] = []) {
        self.defaultConfig = defaultConfig
        self.configs = configs
    }
}

/// Default toolset permissions
public struct ToolsetDefaultConfig: Codable, Sendable {
    public var permissionPolicy: PermissionPolicy?

    public init(permissionPolicy: PermissionPolicy? = nil) {
        self.permissionPolicy = permissionPolicy
    }
}

/// Tool-specific configuration
public struct ToolConfig: Codable, Sendable {
    public var name: String
    public var enabled: Bool?

    public init(name: String, enabled: Bool? = nil) {
        self.name = name
        self.enabled = enabled
    }
}

/// Permission policy for tools
public struct PermissionPolicy: Codable, Sendable {
    public var type: String

    public init(type: String = "always_allow") {
        self.type = type
    }
}

/// Custom tool definition
public struct CustomTool: Codable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: InputSchema?

    public init(name: String, description: String? = nil, inputSchema: InputSchema? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Input schema for custom tools
public struct InputSchema: Codable, Sendable {
    public var type: String
    public var properties: [String: SchemaProperty]?
    public var required: [String]?

    public init(type: String = "object", properties: [String: SchemaProperty]? = nil, required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

/// Schema property definition
public struct SchemaProperty: Codable, Sendable {
    public var type: String
    public var description: String?

    public init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }
}

/// Agent skill configuration
public struct AgentSkill: Codable, Sendable {
    public var identifier: String
    public var config: [String: String]?

    public init(identifier: String, config: [String: String]? = nil) {
        self.identifier = identifier
        self.config = config
    }
}

/// MCP server configuration
public struct MCPServer: Codable, Sendable {
    public var type: String
    public var name: String?
    public var config: MCPServerConfig?

    public init(type: String, name: String? = nil, config: MCPServerConfig? = nil) {
        self.type = type
        self.name = name
        self.config = config
    }
}

/// MCP server connection config
public struct MCPServerConfig: Codable, Sendable {
    public var url: String?
    public var auth: [String: String]?

    public init(url: String? = nil, auth: [String: String]? = nil) {
        self.url = url
        self.auth = auth
    }
}

/// Callable agent reference (multi-agent)
public struct CallableAgent: Codable, Sendable {
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

// MARK: - Create/Update Params

/// Parameters for creating a new agent
public struct CreateAgentParams: Codable, Sendable {
    public var name: String
    public var model: String
    public var system: String?
    public var description: String?
    public var tools: [AgentTool]?
    public var skills: [AgentSkill]?
    public var mcpServers: [MCPServer]?
    public var callableAgents: [CallableAgent]?
    public var metadata: [String: String]?

    public init(
        name: String,
        model: String,
        system: String? = nil,
        description: String? = nil,
        tools: [AgentTool]? = nil,
        skills: [AgentSkill]? = nil,
        mcpServers: [MCPServer]? = nil,
        callableAgents: [CallableAgent]? = nil,
        metadata: [String: String]? = nil
    ) {
        self.name = name
        self.model = model
        self.system = system
        self.description = description
        self.tools = tools
        self.skills = skills
        self.mcpServers = mcpServers
        self.callableAgents = callableAgents
        self.metadata = metadata
    }
}
