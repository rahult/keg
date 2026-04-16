import Foundation

// MARK: - MCP Types (module-internal)

/// Schema property for MCP tool input schemas
public struct MCPSchemaProperty: Sendable, Codable {
    public let type: String
    public let description: String?

    public init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }
}

// MARK: - MCP Client for Model Context Protocol
// References: MCP protocol (JSON-RPC 2.0 + HTTP/SSE)
// Activepieces: ~400 MCP servers for AI agent tool access

/// MCP client actor — manages connections to MCP servers and tool discovery.
/// MCP protocol: JSON-RPC 2.0 over HTTP, SSE for server→client events.
/// Tools discovered from MCP servers are exposed to the agent tool system.
public actor MCPClient {

    // MARK: - Types

    /// MCP server connection state
    public enum ServerState: Sendable {
        case disconnected
        case connecting
        case ready(MCPServerCapabilities)
        case error(String)
    }

    /// MCP server capabilities negotiated during initialize
    public struct MCPServerCapabilities: Sendable {
        public let tools: MCPToolsCapability?

        public init(tools: MCPToolsCapability? = nil) {
            self.tools = tools
        }
    }

    /// Tools capability (list + call support)
    public struct MCPToolsCapability: Sendable {
        public let listChanged: Bool?

        public init(listChanged: Bool? = nil) {
            self.listChanged = listChanged
        }
    }

    /// A tool exposed by an MCP server
    public struct MCPTool: Identifiable, Sendable {
        public let id: String  // serverName:toolName
        public let name: String
        public let description: String?
        public let inputSchema: MCPInputSchema
        public let serverName: String

        public init(name: String, description: String?, inputSchema: MCPInputSchema, serverName: String) {
            self.id = "\(serverName):\(name)"
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.serverName = serverName
        }

        /// Convert to agent CustomTool for tool system integration
        public func toAgentTool() -> CustomTool {
            let props = inputSchema.properties?.mapValues { prop in
                SchemaProperty(type: prop.type, description: prop.description)
            }
            return CustomTool(
                name: "mcp_\(serverName)_\(name)",
                description: description ?? "MCP tool: \(name) (server: \(serverName))",
                inputSchema: InputSchema(
                    type: "object",
                    properties: props,
                    required: inputSchema.required
                )
            )
        }
    }

    /// Input schema from MCP tool
    public struct MCPInputSchema: Sendable {
        public let type: String
        public let properties: [String: MCPSchemaProperty]?
        public let required: [String]?

        public init(type: String = "object", properties: [String: MCPSchemaProperty]? = nil, required: [String]? = nil) {
            self.type = type
            self.properties = properties
            self.required = required
        }
    }

    /// MCP server configuration
    public struct ServerConfig: Sendable {
        public let name: String
        public let url: URL
        public let auth: [String: String]?

        public init(name: String, url: URL, auth: [String: String]? = nil) {
            self.name = name
            self.url = url
            self.auth = auth
        }
    }

    /// Result of a tools/call invocation
    public struct ToolCallResult: Sendable {
        public let content: [MCPContentBlock]
        public let isError: Bool?

        public init(content: [MCPContentBlock], isError: Bool? = nil) {
            self.content = content
            self.isError = isError
        }

        /// Plain-text output for the agent tool system
        public var textOutput: String {
            content.map { block in
                switch block {
                case .text(let text):
                    return text
                case .image(let image):
                    return "[image: \(image.mimeType ?? "unknown")]"
                case .resource(let resource):
                    return "[\(resource.uri)]: \(resource.content)"
                }
            }.joined(separator: "\n")
        }
    }

    /// MCP content block types
    public enum MCPContentBlock: Sendable {
        case text(String)
        case image(MCPImageContent)
        case resource(MCPResourceContent)

        enum CodingKeys: String, CodingKey {
            case type, text, data, mimeType, uri, content
        }
    }

    public struct MCPImageContent: Sendable {
        public let data: String  // base64
        public let mimeType: String?

        public init(data: String, mimeType: String? = nil) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public struct MCPResourceContent: Sendable {
        public let uri: String
        public let content: String

        public init(uri: String, content: String) {
            self.uri = uri
            self.content = content
        }
    }

    // MARK: - Connection State

    /// Per-server connection actor — holds session state for one MCP server
    private struct ServerConnection: @unchecked Sendable {
        let config: ServerConfig
        var state: ServerState
        var sessionId: String?
        var httpClient: HTTPClient
        var eventStreamTask: Task<Void, Never>?

        init(config: ServerConfig) {
            self.config = config
            self.state = .disconnected
            self.httpClient = HTTPClient(baseURL: config.url, auth: config.auth)
        }
    }

    // MARK: - Private State

    private var connections: [String: ServerConnection] = [:]
    private var discoveredTools: [String: [MCPTool]] = [:]
    private var toolRegistry: MCPServerRegistry?
    private var pollingTask: Task<Void, Never>?
    private var pollingInterval: TimeInterval = 60  // seconds
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    // MARK: - Init

    public init() {
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// Initialize MCP client with an optional registry for tool aggregation
    public init(registry: MCPServerRegistry) {
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.toolRegistry = registry
    }

    /// Set the tool registry for aggregating discovered tools
    public func setToolRegistry(_ registry: MCPServerRegistry) {
        self.toolRegistry = registry
    }

    /// Set polling interval for tool discovery refresh (in seconds)
    public func setPollingInterval(_ interval: TimeInterval) {
        self.pollingInterval = max(10, interval)  // Minimum 10 seconds
    }

    /// Start polling tool discovery from all connected servers
    public func startToolDiscoveryPolling() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollToolDiscovery()
                try? await Task.sleep(nanoseconds: UInt64(self?.pollingInterval ?? 60) * 1_000_000_000)
            }
        }
    }

    /// Stop polling tool discovery
    public func stopToolDiscoveryPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Poll tool discovery from all connected servers
    private func pollToolDiscovery() async {
        for serverName in registeredServers() {
            guard serverState(serverName: serverName).isReady else { continue }

            do {
                let tools = try await listTools(serverName: serverName)
                discoveredTools[serverName] = tools

                // Sync with registry if available
                if let registry = toolRegistry {
                    await registry.removeToolsForServer(name: serverName)
                    await registry.addTools(tools, serverName: serverName, serverType: "http")
                }
            } catch {
                // Silently handle polling errors
            }
        }
    }

    // MARK: - Server Lifecycle

    /// Register and connect to an MCP server
    public func connect(to config: ServerConfig) async throws {
        guard connections[config.name] == nil else {
            throw MCPClientError.serverAlreadyConnected(config.name)
        }

        var conn = ServerConnection(config: config)
        connections[config.name] = conn

        connections[config.name]?.state = .connecting

        // Send initialize
        let initResult: MCPInitializeResult = try await sendRequest(
            serverName: config.name,
            method: "initialize",
            params: MCPInitializeParams(
                protocolVersion: "2024-11-05",
                capabilities: MCPClientCapabilities(),
                clientInfo: MCPClientInfo(name: "keg", version: "1.0.0")
            )
        )

        // Acknowledge the initialized notification
        try await sendNotification(
            serverName: config.name,
            method: "notifications/initialized",
            params: EmptyParams()
        )

        let caps = MCPServerCapabilities(tools: initResult.capabilities.tools.map {
            MCPToolsCapability(listChanged: $0.listChanged)
        })

        connections[config.name]?.state = .ready(caps)

        // Discover tools immediately
        let tools = try await listTools(serverName: config.name)
        discoveredTools[config.name] = tools

        // Sync with registry if available
        if let registry = toolRegistry {
            await registry.registerServer(name: config.name, type: "http")
            await registry.updateServerState(name: config.name, state: .ready(caps))
            await registry.addTools(tools, serverName: config.name, serverType: "http")
        }

        // Start SSE event stream
        startEventStream(serverName: config.name)
    }

    /// Disconnect from an MCP server
    public func disconnect(serverName: String) async {
        guard var conn = connections[serverName] else { return }

        conn.eventStreamTask?.cancel()
        conn.eventStreamTask = nil
        connections[serverName]?.state = .disconnected

        // Send exit notification
        try? await sendNotification(
            serverName: serverName,
            method: "exit",
            params: EmptyParams()
        )

        connections.removeValue(forKey: serverName)
        discoveredTools.removeValue(forKey: serverName)

        // Remove from registry
        if let registry = toolRegistry {
            await registry.unregisterServer(name: serverName)
        }
    }

    /// Disconnect all servers
    public func disconnectAll() async {
        for name in connections.keys {
            await disconnect(serverName: name)
        }
    }

    // MARK: - Tool Discovery

    /// List all tools from an MCP server
    public func listTools(serverName: String) async throws -> [MCPTool] {
        guard let conn = connections[serverName], conn.state.isReady else {
            throw MCPClientError.serverNotReady(serverName)
        }

        let response: MCPToolsListResponse = try await sendRequest(
            serverName: serverName,
            method: "tools/list",
            params: MCPToolsListParams()
        )

        return response.tools.map { tool in
            MCPTool(
                name: tool.name,
                description: tool.description,
                inputSchema: MCPInputSchema(
                    type: "object",
                    properties: tool.inputSchema.properties,
                    required: tool.inputSchema.required
                ),
                serverName: serverName
            )
        }
    }

    /// List all tools from all connected servers
    public func listAllTools() -> [MCPTool] {
        discoveredTools.values.flatMap { $0 }
    }

    /// Find a tool by fully qualified name (serverName:toolName)
    public func findTool(id: String) -> MCPTool? {
        for tools in discoveredTools.values {
            if let tool = tools.first(where: { $0.id == id }) {
                return tool
            }
        }
        return nil
    }

    // MARK: - Tool Execution

    /// Execute an MCP tool
    public func callTool(
        serverName: String,
        toolName: String,
        arguments: [String: AnyCodable]
    ) async throws -> ToolCallResult {
        guard let conn = connections[serverName], conn.state.isReady else {
            throw MCPClientError.serverNotReady(serverName)
        }

        let response: MCPToolCallResponse = try await sendRequest(
            serverName: serverName,
            method: "tools/call",
            params: MCPToolCallParams(name: toolName, arguments: arguments)
        )

        let blocks: [MCPContentBlock] = response.content.compactMap { raw in
            decodeContentBlock(raw)
        }

        return ToolCallResult(content: blocks, isError: response.isError)
    }

    /// Execute an MCP tool by fully qualified tool ID (serverName:toolName)
    public func callToolByID(_ toolID: String, arguments: [String: AnyCodable]) async throws -> ToolCallResult {
        guard let (serverName, toolName) = parseToolID(toolID) else {
            throw MCPClientError.invalidToolID(toolID)
        }
        return try await callTool(serverName: serverName, toolName: toolName, arguments: arguments)
    }

    // MARK: - Server State

    /// Current state of a server
    public func serverState(serverName: String) -> ServerState {
        connections[serverName]?.state ?? .disconnected
    }

    /// All registered server names
    public func registeredServers() -> [String] {
        Array(connections.keys)
    }

    /// Servers that are ready
    public func readyServers() -> [String] {
        connections.filter { _, conn in conn.state.isReady }.keys.map { $0 }
    }

    // MARK: - Private Helpers

    private func sendRequest<T: Decodable, P: Encodable>(
        serverName: String,
        method: String,
        params: P
    ) async throws -> T {
        guard let conn = connections[serverName] else {
            throw MCPClientError.serverNotFound(serverName)
        }

        let request = MCPRequest(method: method, params: params)
        let body = try encoder.encode(request)

        let responseData = try await conn.httpClient.post(
            path: "/mcp",
            body: body
        )

        let response = try decoder.decode(MCPResponse<T>.self, from: responseData)

        if let error = response.error {
            throw MCPClientError.rpcError(code: error.code, message: error.message)
        }

        guard let result = response.result else {
            throw MCPClientError.emptyResponse
        }

        return result
    }

    private func sendNotification<P: Encodable>(
        serverName: String,
        method: String,
        params: P
    ) async throws {
        guard let conn = connections[serverName] else {
            throw MCPClientError.serverNotFound(serverName)
        }

        let notification = MCPNotification(method: method, params: params)
        let body = try encoder.encode(notification)

        _ = try? await conn.httpClient.post(
            path: "/mcp",
            body: body
        )
    }

    private func startEventStream(serverName: String) {
        guard let conn = connections[serverName] else { return }

        let task = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await event in try await conn.httpClient.stream(path: "/mcp/stream") {
                    await self.handleServerEvent(serverName: serverName, event: event)
                }
            } catch {
                // Stream ended or errored — clean up
            }
        }

        connections[serverName]?.eventStreamTask = task
    }

    private func handleServerEvent(serverName: String, event: ServerEvent) async {
        switch event {
        case .toolsListChanged:
            // Re-discover tools when list changes
            if let tools = try? await listTools(serverName: serverName) {
                discoveredTools[serverName] = tools

                // Sync with registry
                if let registry = toolRegistry {
                    await registry.removeToolsForServer(name: serverName)
                    await registry.addTools(tools, serverName: serverName, serverType: "http")
                }
            }
        case .unknown:
            break
        }
    }

    // MARK: - Craft Config Import

    /// Import MCP server configurations from Craft descriptors directory.
    /// Expected format: ~/.claude/descriptors/<server-name>.json
    public func importFromCraftDescriptors(homeDirectory: String = NSHomeDirectory()) async throws {
        let descriptorsPath = "\(homeDirectory)/.claude/descriptors"

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: descriptorsPath) else { return }

        let descriptorURLs = try fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: descriptorsPath),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        for url in descriptorURLs {
            do {
                let data = try Data(contentsOf: url)
                let servers = try JSONDecoder().decode([CraftMCPServer].self, from: data)

                for server in servers {
                    guard let url = URL(string: server.command ?? "") else { continue }

                    let config = ServerConfig(
                        name: server.name ?? url.lastPathComponent,
                        url: url,
                        auth: server.env
                    )

                    // Register in registry if available
                    if let registry = toolRegistry {
                        await registry.registerServer(name: config.name, type: "craft")
                    }
                }
            } catch {
                // Skip malformed descriptors
                continue
            }
        }
    }

    /// Discover and register tools from all connected servers into the registry
    public func discoverAllTools() async {
        for serverName in registeredServers() {
            guard serverState(serverName: serverName).isReady else { continue }

            do {
                let tools = try await listTools(serverName: serverName)

                if let registry = toolRegistry {
                    await registry.addTools(tools, serverName: serverName, serverType: "http")
                }
            } catch {
                // Skip servers with errors
            }
        }
    }

    private func parseToolID(_ id: String) -> (serverName: String, toolName: String)? {
        guard let colonIdx = id.firstIndex(of: ":") else { return nil }
        let serverName = String(id[..<colonIdx])
        let toolName = String(id[id.index(after: colonIdx)...])
        return (serverName, toolName)
    }

    private func decodeContentBlock(_ raw: MCPContentBlockRaw) -> MCPContentBlock? {
        switch raw.type {
        case "text":
            if let text = raw.text {
                return .text(text)
            }
        case "image":
            if let data = raw.data {
                return .image(MCPImageContent(data: data, mimeType: raw.mimeType))
            }
        case "resource":
            if let uri = raw.uri, let content = raw.content {
                return .resource(MCPResourceContent(uri: uri, content: content))
            }
        default:
            break
        }
        return nil
    }
}

// MARK: - ServerState Extensions

extension MCPClient.ServerState {
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - MCP Protocol Types

/// JSON-RPC request
private struct MCPRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: P

    init(method: String, params: P) {
        self.id = UUID().uuidString
        self.method = method
        self.params = params
    }
}

/// JSON-RPC response
private struct MCPResponse<T: Decodable>: Decodable {
    let jsonrpc = "2.0"
    let id: String?
    let result: T?
    let error: MCPError?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }
}

private struct MCPError: Decodable {
    let code: Int
    let message: String
}

/// JSON-RPC notification (no id)
private struct MCPNotification<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: P
}

// MARK: - MCP Request/Response Types

private struct MCPInitializeParams: Encodable {
    let protocolVersion: String
    let capabilities: MCPClientCapabilities
    let clientInfo: MCPClientInfo

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocolVersion"
        case capabilities
        case clientInfo = "clientInfo"
    }
}

private struct MCPClientCapabilities: Encodable {
    let tools: [String: Bool]?

    init(tools: [String: Bool]? = nil) {
        self.tools = tools
    }
}

private struct MCPClientInfo: Encodable {
    let name: String
    let version: String

    enum CodingKeys: String, CodingKey {
        case name
        case version
    }
}

private struct MCPInitializeResult: Decodable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilitiesResponse
    let serverInfo: MCPServerInfo

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocolVersion"
        case capabilities
        case serverInfo = "serverInfo"
    }
}

private struct MCPServerCapabilitiesResponse: Decodable {
    let tools: MCPToolsCapabilityResponse?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let tools = try? container.decode(MCPToolsCapabilityResponse.self) {
            self.tools = tools
        } else {
            self.tools = nil
        }
    }
}

private struct MCPToolsCapabilityResponse: Decodable {
    let listChanged: Bool?

    enum CodingKeys: String, CodingKey {
        case listChanged = "listChanged"
    }
}

private struct MCPServerInfo: Decodable {
    let name: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case name
        case version
    }
}

private struct MCPToolsListParams: Encodable {}

private struct MCPToolsListResponse: Decodable {
    let tools: [MCPToolResponse]
}

private struct MCPToolResponse: Decodable {
    let name: String
    let description: String?
    let inputSchema: MCPToolInputSchema

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "inputSchema"
    }
}

private struct MCPToolInputSchema: Decodable {
    let type: String?
    let properties: [String: MCPSchemaProperty]?
    let required: [String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Handle both object form and direct property access
        if let obj = try? container.decode([String: AnyCodable].self) {
            self.type = obj["type"]?.value as? String
            self.properties = nil
            self.required = nil
        } else {
            let nested = try container.decode(MCPToolInputSchemaNested.self)
            self.type = nested.type
            self.properties = nested.properties
            self.required = nested.required
        }
    }
}

private struct MCPToolInputSchemaNested: Decodable {
    let type: String?
    let properties: [String: MCPSchemaProperty]?
    let required: [String]?
}

private struct MCPToolCallParams: Encodable {
    let name: String
    let arguments: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(arguments, forKey: .arguments)
    }
}

private struct MCPToolCallResponse: Decodable {
    let content: [MCPContentBlockRaw]
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case content
        case isError = "isError"
    }
}

private struct MCPContentBlockRaw: Decodable {
    let type: String
    let text: String?
    let data: String?
    let mimeType: String?
    let uri: String?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, uri, content
    }
}

private struct EmptyParams: Encodable {}

// MARK: - HTTP Client for MCP Transport

/// HTTP client for MCP JSON-RPC transport (HTTP POST + SSE stream)
private actor HTTPClient {
    let baseURL: URL
    let auth: [String: String]?
    private let session: URLSession

    init(baseURL: URL, auth: [String: String]?) {
        self.baseURL = baseURL
        self.auth = auth

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func post(path: String, body: Data) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw MCPClientError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = body

        if let auth = auth {
            for (key, value) in auth {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.transportError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw MCPClientError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    func stream(path: String) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let url = URL(string: path, relativeTo: baseURL) else {
                continuation.finish(throwing: MCPClientError.invalidURL(path))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            request.setValue("no-cache", forHTTPHeaderField: "cache-control")

            if let auth = auth {
                for (key, value) in auth {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            let task = session.dataTask(with: request) { data, _, error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }

                guard let data = data else {
                    continuation.finish()
                    return
                }

                // Parse SSE events
                if let event = self.parseSSEvent(from: data) {
                    continuation.yield(event)
                }

                continuation.finish()
            }

            task.resume()

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func parseSSEvent(from data: Data) -> ServerEvent? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // SSE format: "event: <type>\ndata: <payload>\n\n"
        let lines = text.components(separatedBy: "\n")
        var eventType: String?
        var eventData: String?

        for line in lines {
            if line.hasPrefix("event:") {
                eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                eventData = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let type = eventType else { return .unknown }

        switch type {
        case "tools/list_changed":
            return .toolsListChanged
        default:
            return .unknown
        }
    }
}

// MARK: - Server Events

private enum ServerEvent: Sendable {
    case toolsListChanged
    case unknown
}

// MARK: - Craft Config Types

/// MCP server definition from Craft descriptors
private struct CraftMCPServer: Codable {
    let name: String?
    let command: String?
    let args: [String]?
    let env: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name
        case command
        case args
        case env
    }
}

// Note: AnyCodable is defined in DockerTypes.swift (shared across modules)

// MARK: - MCP Bridge: Integrate MCP tools with ToolExecutor

/// Bridge that adapts MCP tools to the agent tool system.
/// Allows MCP tools to be executed via ToolExecutor interface.
public actor MCPBridge {
    private let mcpClient: MCPClient
    private let toolExecutor: ToolExecutor

    public init(mcpClient: MCPClient, toolExecutor: ToolExecutor) {
        self.mcpClient = mcpClient
        self.toolExecutor = toolExecutor
    }

    /// Execute an MCP tool by fully qualified ID via ToolExecutor interface.
    /// Tool name format: "mcp_<serverName>_<toolName>"
    /// Arguments passed directly to the MCP server.
    public func executeMCPTool(toolID: String, arguments: [String: Any]) async throws -> ToolExecutor.ToolOutput {
        // Verify tool exists
        guard let tool = await mcpClient.findTool(id: toolID) else {
            throw MCPClientError.toolNotFound(toolID)
        }

        let result = try await mcpClient.callToolByID(tool.id, arguments: arguments.mapValues { AnyCodable($0) })

        return ToolExecutor.ToolOutput(
            content: result.textOutput,
            isError: result.isError ?? false
        )
    }

    /// List all available MCP tools as CustomTool for agent registration
    public func availableMCPTools() async -> [CustomTool] {
        await mcpClient.listAllTools().map { $0.toAgentTool() }
    }

    /// Wrap MCP tools in AgentTool.custom for use in Agent.tools
    public func agentTools() async -> [AgentTool] {
        await availableMCPTools().map { .custom($0) }
    }
}

// MARK: - Errors

public enum MCPClientError: Error, LocalizedError, Sendable {
    case serverAlreadyConnected(String)
    case serverNotFound(String)
    case serverNotReady(String)
    case invalidToolID(String)
    case toolNotFound(String)
    case rpcError(code: Int, message: String)
    case emptyResponse
    case invalidURL(String)
    case transportError(String)
    case httpError(statusCode: Int)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .serverAlreadyConnected(let name):
            return "MCP server already connected: \(name)"
        case .serverNotFound(let name):
            return "MCP server not found: \(name)"
        case .serverNotReady(let name):
            return "MCP server not ready: \(name)"
        case .invalidToolID(let id):
            return "Invalid MCP tool ID: \(id)"
        case .toolNotFound(let id):
            return "MCP tool not found: \(id)"
        case .rpcError(let code, let message):
            return "MCP RPC error \(code): \(message)"
        case .emptyResponse:
            return "Empty response from MCP server"
        case .invalidURL(let path):
            return "Invalid URL path: \(path)"
        case .transportError(let msg):
            return "Transport error: \(msg)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        }
    }
}
