import Foundation

/// Managed Agents API client
/// Base URL: https://api.anthropic.com/v1
/// Requires: anthropic-beta: managed-agents-2026-04-01 header
public actor ManagedAgentsClient {
    public let apiKey: String
    public let baseURL: URL

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Beta header value required for all Managed Agents requests
    public static let betaHeader = "managed-agents-2026-04-01"

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Request Building

    private func buildRequest(
        path: String,
        method: String,
        body: Data? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ManagedAgentsError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = body

        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManagedAgentsError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ManagedAgentsError.httpError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Agent Operations

    /// Create a new agent
    /// POST /v1/agents
    public func createAgent(_ params: CreateAgentParams) async throws -> Agent {
        let body = try encoder.encode(params)
        let request = try buildRequest(path: "/v1/agents", method: "POST", body: body)
        return try await perform(request)
    }

    /// List all agents
    /// GET /v1/agents
    public func listAgents() async throws -> AgentListResponse {
        let request = try buildRequest(path: "/v1/agents", method: "GET")
        return try await perform(request)
    }

    /// Get an agent by ID
    /// GET /v1/agents/:id
    public func getAgent(id: String) async throws -> Agent {
        let request = try buildRequest(path: "/v1/agents/\(id)", method: "GET")
        return try await perform(request)
    }

    /// Update an agent
    /// PATCH /v1/agents/:id
    public func updateAgent(id: String, params: CreateAgentParams) async throws -> Agent {
        let body = try encoder.encode(params)
        let request = try buildRequest(path: "/v1/agents/\(id)", method: "PATCH", body: body)
        return try await perform(request)
    }

    /// Archive an agent (soft delete)
    /// DELETE /v1/agents/:id
    public func archiveAgent(id: String) async throws {
        let request = try buildRequest(path: "/v1/agents/\(id)", method: "DELETE")
        _ = try await session.data(for: request)
    }

    // MARK: - Environment Operations

    /// Create a new environment
    /// POST /v1/environments
    public func createEnvironment(_ params: CreateEnvironmentParams) async throws -> AgentEnvironment {
        let body = try encoder.encode(params)
        let request = try buildRequest(path: "/v1/environments", method: "POST", body: body)
        return try await perform(request)
    }

    /// List all environments
    /// GET /v1/environments
    public func listEnvironments() async throws -> EnvironmentListResponse {
        let request = try buildRequest(path: "/v1/environments", method: "GET")
        return try await perform(request)
    }

    /// Get an environment by ID
    /// GET /v1/environments/:id
    public func getEnvironment(id: String) async throws -> AgentEnvironment {
        let request = try buildRequest(path: "/v1/environments/\(id)", method: "GET")
        return try await perform(request)
    }

    /// Update an environment
    /// PATCH /v1/environments/:id
    public func updateEnvironment(id: String, params: CreateEnvironmentParams) async throws -> AgentEnvironment {
        let body = try encoder.encode(params)
        let request = try buildRequest(path: "/v1/environments/\(id)", method: "PATCH", body: body)
        return try await perform(request)
    }

    /// Delete an environment
    /// DELETE /v1/environments/:id
    public func deleteEnvironment(id: String) async throws {
        let request = try buildRequest(path: "/v1/environments/\(id)", method: "DELETE")
        _ = try await session.data(for: request)
    }

    // MARK: - Session Operations

    /// Create a new session
    /// POST /v1/sessions
    public func createSession(_ params: CreateSessionParams) async throws -> Session {
        let body = try encoder.encode(params)
        let request = try buildRequest(path: "/v1/sessions", method: "POST", body: body)
        return try await perform(request)
    }

    /// List sessions
    /// GET /v1/sessions
    public func listSessions(agentId: String? = nil) async throws -> SessionListResponse {
        var path = "/v1/sessions"
        if let agentId = agentId {
            path += "?agent_id=\(agentId)"
        }
        let request = try buildRequest(path: path, method: "GET")
        return try await perform(request)
    }

    /// Get a session by ID
    /// GET /v1/sessions/:id
    public func getSession(id: String) async throws -> Session {
        let request = try buildRequest(path: "/v1/sessions/\(id)", method: "GET")
        return try await perform(request)
    }

    /// Delete/cancel a session
    /// DELETE /v1/sessions/:id
    public func deleteSession(id: String) async throws {
        let request = try buildRequest(path: "/v1/sessions/\(id)", method: "DELETE")
        _ = try await session.data(for: request)
    }

    // MARK: - Event Operations

    /// Send an event to a session
    /// POST /v1/sessions/:id/events
    public func sendEvent(sessionId: String, event: SessionEvent) async throws -> [SessionEvent] {
        let body = try encoder.encode(event)
        let request = try buildRequest(path: "/v1/sessions/\(sessionId)/events", method: "POST", body: body)
        return try await perform(request)
    }

    /// Get event history for a session
    /// GET /v1/sessions/:id/events
    public func getEvents(sessionId: String) async throws -> [SessionEvent] {
        let request = try buildRequest(path: "/v1/sessions/\(sessionId)/events", method: "GET")
        return try await perform(request)
    }
}

// MARK: - Error Types

public enum ManagedAgentsError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "Invalid URL path: \(path)"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .missingAPIKey:
            return "API key is required"
        }
    }
}
