import Foundation

/// Actor wrapping HTTP calls to the Supaglue API running at localhost:3000.
///
/// Supaglue exposes a REST API for managing connections and syncing data.
/// This client provides typed Swift wrappers for the operations most relevant
/// to the agent runtime: listing events, creating calendar events, and
/// sending email.
///
/// API base: http://127.0.0.1:3000
/// Auth:     Bearer token from ~/.keg/supaglue/api_key (written by Supaglue on first run)
public actor SupaglueClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var apiKey: String?

    init(baseURL: URL = URL(string: "http://127.0.0.1:3000")!, session: URLSession? = nil) {
        self.baseURL = baseURL

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        // Load stored API key if available
        self.apiKey = Self.loadAPIKey()
    }

    /// Refresh the stored API key from disk.
    func refreshAPIKey() {
        apiKey = Self.loadAPIKey()
    }

    // MARK: - Health

    /// GET /healthz — returns true if Supaglue is healthy.
    func health() async throws -> Bool {
        let req = try buildRequest(path: "/healthz", method: "GET")
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    // MARK: - Connections

    /// GET /api/v1/connections — list all configured provider connections.
    func listConnections() async throws -> [SupaglueConnection] {
        let req = try buildRequest(path: "/api/v1/connections", method: "GET")
        return try await perform(req)
    }

    /// POST /api/v1/connections — create a new OAuth connection.
    func createConnection(provider: String, params: CreateConnectionParams) async throws -> SupaglueConnection {
        let body = try encoder.encode(params)
        let req = try buildRequest(path: "/api/v1/connections?provider=\(provider)", method: "POST", body: body)
        return try await perform(req)
    }

    /// DELETE /api/v1/connections/:id — remove a connection.
    func deleteConnection(id: String) async throws {
        let req = try buildRequest(path: "/api/v1/connections/\(id)", method: "DELETE")
        _ = try await session.data(for: req)
    }

    // MARK: - Events

    /// GET /api/v1/events — list sync events across all connections.
    func listEvents(connectionId: String? = nil, limit: Int = 50) async throws -> [SupaglueEvent] {
        var path = "/api/v1/events?limit=\(limit)"
        if let connectionId = connectionId {
            path += "&connection_id=\(connectionId)"
        }
        let req = try buildRequest(path: path, method: "GET")
        return try await perform(req)
    }

    /// GET /api/v1/events/:id — get a single event.
    func getEvent(id: String) async throws -> SupaglueEvent {
        let req = try buildRequest(path: "/api/v1/events/\(id)", method: "GET")
        return try await perform(req)
    }

    // MARK: - Calendar (Google Calendar)

    /// GET /api/v1/calendar/events — list calendar events.
    func listCalendarEvents(
        connectionId: String,
        calendarId: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [CalendarEvent] {
        var components = URLComponents(string: "/api/v1/calendar/events")!
        var query = [URLQueryItem(name: "connection_id", value: connectionId)]
        if let calendarId = calendarId {
            query.append(URLQueryItem(name: "calendar_id", value: calendarId))
        }
        if let startDate = startDate {
            let formatter = ISO8601DateFormatter()
            query.append(URLQueryItem(name: "start_date", value: formatter.string(from: startDate)))
        }
        if let endDate = endDate {
            let formatter = ISO8601DateFormatter()
            query.append(URLQueryItem(name: "end_date", value: formatter.string(from: endDate)))
        }
        components.queryItems = query

        guard let path = components.string else {
            throw SupaglueClientError.invalidURL("/api/v1/calendar/events")
        }
        let req = try buildRequest(path: path, method: "GET")
        return try await perform(req)
    }

    /// POST /api/v1/calendar/events — create a calendar event.
    func createCalendarEvent(connectionId: String, params: CreateCalendarEventParams) async throws -> CalendarEvent {
        let body = try encoder.encode(params)
        let req = try buildRequest(path: "/api/v1/calendar/events?connection_id=\(connectionId)", method: "POST", body: body)
        return try await perform(req)
    }

    /// DELETE /api/v1/calendar/events/:id — delete a calendar event.
    func deleteCalendarEvent(connectionId: String, eventId: String) async throws {
        let req = try buildRequest(
            path: "/api/v1/calendar/events/\(eventId)?connection_id=\(connectionId)",
            method: "DELETE"
        )
        _ = try await session.data(for: req)
    }

    // MARK: - Email (Gmail)

    /// GET /api/v1/email/messages — list email messages.
    func listEmailMessages(connectionId: String, query: String? = nil, limit: Int = 20) async throws -> [EmailMessage] {
        var components = URLComponents(string: "/api/v1/email/messages")!
        var queryItems = [
            URLQueryItem(name: "connection_id", value: connectionId),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let q = query {
            queryItems.append(URLQueryItem(name: "q", value: q))
        }
        components.queryItems = queryItems

        guard let path = components.string else {
            throw SupaglueClientError.invalidURL("/api/v1/email/messages")
        }
        let req = try buildRequest(path: path, method: "GET")
        return try await perform(req)
    }

    /// POST /api/v1/email/messages/send — send an email.
    func sendEmail(connectionId: String, params: SendEmailParams) async throws -> EmailMessage {
        let body = try encoder.encode(params)
        let req = try buildRequest(
            path: "/api/v1/email/messages/send?connection_id=\(connectionId)",
            method: "POST",
            body: body
        )
        return try await perform(req)
    }

    // MARK: - Request Helpers

    private func buildRequest(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SupaglueClientError.invalidURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key = apiKey {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        req.httpBody = body
        return req
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupaglueClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SupaglueClientError.httpError(statusCode: http.statusCode, message: msg)
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func loadAPIKey() -> String? {
        let path = NSHomeDirectory() + "/.keg/supaglue/api_key"
        return try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Error

enum SupaglueClientError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .invalidURL(let path):  return "Invalid URL: \(path)"
        case .invalidResponse:      return "Invalid response from Supaglue"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .notReady:              return "Supaglue container is not running"
        }
    }
}

// MARK: - Response Types

/// A Supaglue-managed OAuth connection to a third-party provider.
public struct SupaglueConnection: Codable, Sendable, Identifiable {
    public let id: String
    public let provider: String
    public let providerCategory: String
    public let customerId: String
    public let status: String
    public let createdAt: Date?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, provider, status
        case providerCategory = "provider_category"
        case customerId = "customer_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CreateConnectionParams: Codable, Sendable {
    public var customerId: String
    public var code: String?
    public var redirectUri: String?

    public init(customerId: String, code: String? = nil, redirectUri: String? = nil) {
        self.customerId = customerId
        self.code = code
        self.redirectUri = redirectUri
    }
}

/// A sync event recorded by Supaglue.
public struct SupaglueEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let connectionId: String
    public let provider: String
    public let objectType: String
    public let objectId: String
    public let eventType: String
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, provider
        case connectionId = "connection_id"
        case objectType = "object_type"
        case objectId = "object_id"
        case eventType = "event_type"
        case createdAt = "created_at"
    }
}

// MARK: - Calendar Types

public struct CalendarEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let summary: String?
    public let description: String?
    public let startTime: Date?
    public let endTime: Date?
    public let location: String?
    public let attendees: [CalendarAttendee]?

    enum CodingKeys: String, CodingKey {
        case id, summary, description, location, attendees
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

public struct CalendarAttendee: Codable, Sendable {
    public let email: String
    public let status: String?
}

public struct CreateCalendarEventParams: Codable, Sendable {
    public var summary: String
    public var description: String?
    public var startTime: Date
    public var endTime: Date
    public var location: String?
    public var attendees: [String]?
    public var calendarId: String?

    enum CodingKeys: String, CodingKey {
        case summary, description, location, attendees
        case startTime = "start_time"
        case endTime = "end_time"
        case calendarId = "calendar_id"
    }

    public init(
        summary: String,
        description: String? = nil,
        startTime: Date,
        endTime: Date,
        location: String? = nil,
        attendees: [String]? = nil,
        calendarId: String? = nil
    ) {
        self.summary = summary
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
        self.attendees = attendees
        self.calendarId = calendarId
    }
}

// MARK: - Email Types

public struct EmailMessage: Codable, Sendable, Identifiable {
    public let id: String
    public let from: [EmailAddress]?
    public let to: [EmailAddress]?
    public let cc: [EmailAddress]?
    public let subject: String?
    public let body: String?
    public let date: Date?
    public let snippet: String?

    enum CodingKeys: String, CodingKey {
        case id, from, to, cc, subject, body, date, snippet
    }
}

public struct EmailAddress: Codable, Sendable {
    public let email: String
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case email, name
    }
}

public struct SendEmailParams: Codable, Sendable {
    public var to: [String]
    public var cc: [String]?
    public var subject: String
    public var body: String
    public var from: String?

    enum CodingKeys: String, CodingKey {
        case to, cc, subject, body, from
    }

    public init(to: [String], cc: [String]? = nil, subject: String, body: String, from: String? = nil) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.from = from
    }
}
