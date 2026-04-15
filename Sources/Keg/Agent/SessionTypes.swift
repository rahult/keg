import Foundation

// MARK: - Session Types

/// Session - running agent instance within an environment
/// Based on: https://platform.claude.com/docs/en/managed-agents/sessions
public struct Session: Codable, Sendable {
    public let id: String
    public let type: String
    public let agentId: String
    public let agentVersion: Int
    public let environmentId: String
    public var status: SessionStatus
    public let createdAt: Date
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, status
        case agentId = "agent_id"
        case agentVersion = "agent_version"
        case environmentId = "environment_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Session status
public enum SessionStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

/// Parameters for creating a session
public struct CreateSessionParams: Codable, Sendable {
    public var agentId: String
    public var agentVersion: Int?
    public var environmentId: String
    public var description: String?

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentVersion = "agent_version"
        case environmentId = "environment_id"
        case description
    }

    public init(
        agentId: String,
        agentVersion: Int? = nil,
        environmentId: String,
        description: String? = nil
    ) {
        self.agentId = agentId
        self.agentVersion = agentVersion
        self.environmentId = environmentId
        self.description = description
    }
}

public struct SessionListResponse: Codable, Sendable {
    public let data: [Session]
    public let hasMore: Bool?
    public let nextPage: String?
    public let firstID: String?
    public let lastID: String?
    public let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
        case firstID = "first_id"
        case lastID = "last_id"
        case totalCount = "total_count"
    }
}

// MARK: - Event Types

/// Event types exchanged between app and agent
public enum SessionEventType: String, Codable, Sendable {
    case userMessage = "user"
    case assistantMessage = "assistant"
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case error
    case statusUpdate = "status_update"
}

/// Session event
public struct SessionEvent: Codable, Sendable {
    public var type: SessionEventType
    public var content: String?
    public var toolUse: ToolUseEvent?
    public var toolResult: ToolResultEvent?
    public var status: SessionStatus?
    public var id: String?
    public let timestamp: Date?

    enum CodingKeys: String, CodingKey {
        case type, content, toolUse, toolResult, status, id, timestamp
    }

    public init(
        type: SessionEventType,
        content: String? = nil,
        toolUse: ToolUseEvent? = nil,
        toolResult: ToolResultEvent? = nil,
        status: SessionStatus? = nil,
        id: String? = nil,
        timestamp: Date? = nil
    ) {
        self.type = type
        self.content = content
        self.toolUse = toolUse
        self.toolResult = toolResult
        self.status = status
        self.id = id
        self.timestamp = timestamp
    }

    /// Create a user message event
    public static func userMessage(_ content: String) -> SessionEvent {
        SessionEvent(type: .userMessage, content: content)
    }
}

/// Tool use event (agent calling a tool)
public struct ToolUseEvent: Codable, Sendable {
    public var tool: String
    public var toolInput: [String: AnyCodable]
    public var toolUseId: String?

    enum CodingKeys: String, CodingKey {
        case tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
    }

    public init(tool: String, toolInput: [String: AnyCodable], toolUseId: String? = nil) {
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
    }
}

/// Tool result event (response from tool execution)
public struct ToolResultEvent: Codable, Sendable {
    public var toolUseId: String
    public var toolOutput: AnyCodable
    public var isError: Bool?

    enum CodingKeys: String, CodingKey {
        case toolUseId = "tool_use_id"
        case toolOutput = "tool_output"
        case isError = "is_error"
    }

    public init(toolUseId: String, toolOutput: AnyCodable, isError: Bool? = nil) {
        self.toolUseId = toolUseId
        self.toolOutput = toolOutput
        self.isError = isError
    }
}

