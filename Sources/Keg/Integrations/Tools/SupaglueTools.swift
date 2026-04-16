@preconcurrency import Foundation

/// Tool definitions for the Supaglue integration, registered in the agent runtime.
///
/// Each tool maps to a SupaglueClient operation and carries a JSON schema
/// for the agent's function-calling interface.
///
/// Tools:
///   - `supaglue_list_events`       — list sync events across connections
///   - `supaglue_list_calendar_events` — list calendar events from Google Calendar
///   - `supaglue_create_calendar_event` — create a calendar event
///   - `supaglue_list_email`        — list email messages from Gmail
///   - `supaglue_send_email`        — send an email via Gmail
///   - `supaglue_list_connections`  — list configured OAuth connections
///   - `supaglue_health`            — check Supaglue service health
public enum SupaglueTools {

    // MARK: - Tool Definitions

    /// `supaglue_list_events` — list sync events across all connections.
    public static let listEvents = AgentTool.custom(CustomTool(
        name: "supaglue_list_events",
        description: "List sync events recorded by Supaglue across all configured provider connections. Returns event type, object type, and timestamps. Use this to audit recent data syncs.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "connection_id": SchemaProperty(
                    type: "string",
                    description: "Optional. Filter events by connection ID. If omitted, returns events from all connections."
                ),
                "limit": SchemaProperty(
                    type: "integer",
                    description: "Maximum number of events to return (default 50, max 200)."
                )
            ],
            required: []
        )
    ))

    /// `supaglue_list_calendar_events` — list calendar events from Google Calendar.
    public static let listCalendarEvents = AgentTool.custom(CustomTool(
        name: "supaglue_list_calendar_events",
        description: "List calendar events from a Google Calendar connection. Returns title, time, location, and attendees.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "connection_id": SchemaProperty(
                    type: "string",
                    description: "The Supaglue connection ID for the Google Calendar account."
                ),
                "calendar_id": SchemaProperty(
                    type: "string",
                    description: "Optional. Specific calendar ID to query. Defaults to primary calendar."
                ),
                "start_date": SchemaProperty(
                    type: "string",
                    description: "ISO8601 datetime. Return events starting on or after this date."
                ),
                "end_date": SchemaProperty(
                    type: "string",
                    description: "ISO8601 datetime. Return events ending on or before this date."
                )
            ],
            required: ["connection_id"]
        )
    ))

    /// `supaglue_create_calendar_event` — create a calendar event.
    public static let createCalendarEvent = AgentTool.custom(CustomTool(
        name: "supaglue_create_calendar_event",
        description: "Create a new calendar event on a Google Calendar via Supaglue. Returns the created event details.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "connection_id": SchemaProperty(
                    type: "string",
                    description: "The Supaglue connection ID for the Google Calendar account."
                ),
                "summary": SchemaProperty(
                    type: "string",
                    description: "Event title or summary."
                ),
                "description": SchemaProperty(
                    type: "string",
                    description: "Optional. Event description."
                ),
                "start_time": SchemaProperty(
                    type: "string",
                    description: "ISO8601 datetime for event start."
                ),
                "end_time": SchemaProperty(
                    type: "string",
                    description: "ISO8601 datetime for event end."
                ),
                "location": SchemaProperty(
                    type: "string",
                    description: "Optional. Physical or video meeting location."
                ),
                "attendees": SchemaProperty(
                    type: "array",
                    description: "Optional. List of attendee email addresses."
                ),
                "calendar_id": SchemaProperty(
                    type: "string",
                    description: "Optional. Target calendar ID. Defaults to primary calendar."
                )
            ],
            required: ["connection_id", "summary", "start_time", "end_time"]
        )
    ))

    /// `supaglue_list_email` — list email messages from Gmail.
    public static let listEmail = AgentTool.custom(CustomTool(
        name: "supaglue_list_email",
        description: "List email messages from a Gmail connection. Returns sender, subject, snippet, and date.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "connection_id": SchemaProperty(
                    type: "string",
                    description: "The Supaglue connection ID for the Gmail account."
                ),
                "query": SchemaProperty(
                    type: "string",
                    description: "Optional. Gmail search query (e.g., 'from:alice@example.com is:unread')."
                ),
                "limit": SchemaProperty(
                    type: "integer",
                    description: "Maximum number of messages to return (default 20, max 100)."
                )
            ],
            required: ["connection_id"]
        )
    ))

    /// `supaglue_send_email` — send an email via Gmail.
    public static let sendEmail = AgentTool.custom(CustomTool(
        name: "supaglue_send_email",
        description: "Send an email via a Gmail connection. Returns the sent message details.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "connection_id": SchemaProperty(
                    type: "string",
                    description: "The Supaglue connection ID for the Gmail account."
                ),
                "to": SchemaProperty(
                    type: "array",
                    description: "List of recipient email addresses."
                ),
                "cc": SchemaProperty(
                    type: "array",
                    description: "Optional. CC recipient email addresses."
                ),
                "subject": SchemaProperty(
                    type: "string",
                    description: "Email subject line."
                ),
                "body": SchemaProperty(
                    type: "string",
                    description: "Email body text (plain text)."
                ),
                "from": SchemaProperty(
                    type: "string",
                    description: "Optional. Override the sender address. Defaults to the connected account."
                )
            ],
            required: ["connection_id", "to", "subject", "body"]
        )
    ))

    /// `supaglue_list_connections` — list configured OAuth provider connections.
    public static let listConnections = AgentTool.custom(CustomTool(
        name: "supaglue_list_connections",
        description: "List all configured Supaglue OAuth connections and their status. Use this to discover which providers are connected and their connection IDs.",
        inputSchema: InputSchema(
            type: "object",
            properties: [:],
            required: []
        )
    ))

    /// `supaglue_health` — check Supaglue service health.
    public static let health = AgentTool.custom(CustomTool(
        name: "supaglue_health",
        description: "Check whether the Supaglue service is running and healthy. Returns true if /healthz responds 200.",
        inputSchema: InputSchema(
            type: "object",
            properties: [:],
            required: []
        )
    ))

    // MARK: - All Tools

    /// Convenience: all Supaglue tools as an array, ready to register in the agent runtime.
    public static var allTools: [AgentTool] {
        [
            health,
            listConnections,
            listEvents,
            listCalendarEvents,
            createCalendarEvent,
            listEmail,
            sendEmail,
        ]
    }

    /// Convenience: tool names for quick lookup.
    public static var toolNames: Set<String> {
        Set(allTools.compactMap { tool in
            if case .custom(let c) = tool { return c.name }
            return nil
        })
    }

    // MARK: - Execution

    /// Execute a Supaglue tool by name, forwarding to SupaglueClient.
    /// Returns a JSON-serializable result dictionary.
    static func execute(
        name: String,
        arguments: SupaglueToolArguments,
        client: SupaglueClient
    ) async throws -> SupaglueToolResult {
        switch name {
        case "supaglue_health":
            let ok = try await client.health()
            return SupaglueToolResult(success: ok, data: ["healthy": ok])

        case "supaglue_list_connections":
            let connections = try await client.listConnections()
            return SupaglueToolResult(success: true, data: ["connections": connections.map { $0.asDictionary }])

        case "supaglue_list_events":
            let connectionId = arguments["connection_id"] as? String
            let limit = arguments["limit"] as? Int ?? 50
            let events = try await client.listEvents(connectionId: connectionId, limit: limit)
            return SupaglueToolResult(success: true, data: ["events": events.map { $0.asDictionary }])

        case "supaglue_list_calendar_events":
            let connectionId = arguments["connection_id"] as? String ?? ""
            let calendarId = arguments["calendar_id"] as? String
            let startDate = parseDate(arguments["start_date"] as? String)
            let endDate = parseDate(arguments["end_date"] as? String)
            let events = try await client.listCalendarEvents(
                connectionId: connectionId,
                calendarId: calendarId,
                startDate: startDate,
                endDate: endDate
            )
            return SupaglueToolResult(success: true, data: ["calendar_events": events.map { $0.asDictionary }])

        case "supaglue_create_calendar_event":
            let connectionId = arguments["connection_id"] as? String ?? ""
            guard let summary = arguments["summary"] as? String,
                  let startTimeStr = arguments["start_time"] as? String,
                  let endTimeStr = arguments["end_time"] as? String,
                  let startTime = parseDate(startTimeStr),
                  let endTime = parseDate(endTimeStr) else {
                return SupaglueToolResult(success: false, data: ["error": "missing required fields: summary, start_time, end_time"])
            }
            let params = CreateCalendarEventParams(
                summary: summary,
                description: arguments["description"] as? String,
                startTime: startTime,
                endTime: endTime,
                location: arguments["location"] as? String,
                attendees: arguments["attendees"] as? [String],
                calendarId: arguments["calendar_id"] as? String
            )
            let event = try await client.createCalendarEvent(connectionId: connectionId, params: params)
            return SupaglueToolResult(success: true, data: ["calendar_event": event.asDictionary])

        case "supaglue_list_email":
            let connectionId = arguments["connection_id"] as? String ?? ""
            let query = arguments["query"] as? String
            let limit = arguments["limit"] as? Int ?? 20
            let messages = try await client.listEmailMessages(connectionId: connectionId, query: query, limit: limit)
            return SupaglueToolResult(success: true, data: ["messages": messages.map { $0.asDictionary }])

        case "supaglue_send_email":
            let connectionId = arguments["connection_id"] as? String ?? ""
            guard let to = arguments["to"] as? [String],
                  let subject = arguments["subject"] as? String,
                  let body = arguments["body"] as? String else {
                return SupaglueToolResult(success: false, data: ["error": "missing required fields: to, subject, body"])
            }
            let params = SendEmailParams(
                to: to,
                cc: arguments["cc"] as? [String],
                subject: subject,
                body: body,
                from: arguments["from"] as? String
            )
            let message = try await client.sendEmail(connectionId: connectionId, params: params)
            return SupaglueToolResult(success: true, data: ["message": message.asDictionary])

        default:
            return SupaglueToolResult(success: false, data: ["error": "Unknown tool: \(name)"])
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Tool Result

public struct SupaglueToolResult: @unchecked Sendable, Codable {
    public var success: Bool
    public var data: [String: Any]

    public init(success: Bool, data: [String: Any]) {
        self.success = success
        self.data = data
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(success, forKey: .success)
        try container.encode(data.mapValues { SupaglueAnyCodable($0) }, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case success, data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        let innerData = try container.decode([String: SupaglueAnyCodable].self, forKey: .data)
        data = innerData.mapValues { $0.value }
    }
}

/// Sendable wrapper for tool arguments crossing actor boundaries in Swift 6.
public struct SupaglueToolArguments: @unchecked Sendable {
    public let storage: [String: Any]

    public init(_ storage: [String: Any]) {
        self.storage = storage
    }

    public subscript(key: String) -> Any? {
        storage[key]
    }
}

// MARK: - Codable Helpers

/// Wraps any JSON-compatible value for encoding.
public struct SupaglueAnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([SupaglueAnyCodable].self) {
            self.value = array.map(\.value)
        } else if let dict = try? container.decode([String: SupaglueAnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { SupaglueAnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { SupaglueAnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Dictionary Representations

extension SupaglueConnection {
    public var asDictionary: [String: Any] {
        var dict: [String: Any] = ["id": id, "provider": provider, "provider_category": providerCategory, "customer_id": customerId, "status": status]
        if let createdAt = createdAt { dict["created_at"] = ISO8601DateFormatter().string(from: createdAt) }
        if let updatedAt = updatedAt { dict["updated_at"] = ISO8601DateFormatter().string(from: updatedAt) }
        return dict
    }
}

extension SupaglueEvent {
    public var asDictionary: [String: Any] {
        var dict: [String: Any] = ["id": id, "connection_id": connectionId, "provider": provider, "object_type": objectType, "object_id": objectId, "event_type": eventType]
        if let createdAt = createdAt { dict["created_at"] = ISO8601DateFormatter().string(from: createdAt) }
        return dict
    }
}

extension CalendarEvent {
    public var asDictionary: [String: Any] {
        var dict: [String: Any] = ["id": id]
        if let summary = summary { dict["summary"] = summary }
        if let description = description { dict["description"] = description }
        if let startTime = startTime { dict["start_time"] = ISO8601DateFormatter().string(from: startTime) }
        if let endTime = endTime { dict["end_time"] = ISO8601DateFormatter().string(from: endTime) }
        if let location = location { dict["location"] = location }
        if let attendees = attendees { dict["attendees"] = attendees.map { ["email": $0.email, "status": $0.status ?? ""] } }
        return dict
    }
}

extension EmailMessage {
    public var asDictionary: [String: Any] {
        var dict: [String: Any] = ["id": id]
        if let subject = subject { dict["subject"] = subject }
        if let body = body { dict["body"] = body }
        if let snippet = snippet { dict["snippet"] = snippet }
        if let date = date { dict["date"] = ISO8601DateFormatter().string(from: date) }
        if let from = from { dict["from"] = from.map { ["email": $0.email, "name": $0.name ?? ""] } }
        if let to = to { dict["to"] = to.map { ["email": $0.email, "name": $0.name ?? ""] } }
        if let cc = cc { dict["cc"] = cc.map { ["email": $0.email, "name": $0.name ?? ""] } }
        return dict
    }
}
