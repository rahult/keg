import Foundation

// MARK: - MCP Server Registry

/// Central registry for MCP tools discovered from all connected servers.
/// Aggregates tools across servers, supports search/filtering, and imports
/// tool definitions from external sources (e.g., Craft config files).
public actor MCPServerRegistry {

    // MARK: - Types

    /// Tool registry entry with metadata
    public struct ToolEntry: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let serverName: String
        public let serverType: String
        public let inputSchema: MCPClient.MCPInputSchema
        public let tags: [String]
        public let isEnabled: Bool
        public let discoveredAt: Date

        public init(
            id: String,
            name: String,
            description: String?,
            serverName: String,
            serverType: String,
            inputSchema: MCPClient.MCPInputSchema,
            tags: [String] = [],
            isEnabled: Bool = true,
            discoveredAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.serverName = serverName
            self.serverType = serverType
            self.inputSchema = inputSchema
            self.tags = tags
            self.isEnabled = isEnabled
            self.discoveredAt = discoveredAt
        }

        /// Create from MCPClient.MCPTool
        public init(from mcpTool: MCPClient.MCPTool, serverType: String = "stdio") {
            self.id = mcpTool.id
            self.name = mcpTool.name
            self.description = mcpTool.description
            self.serverName = mcpTool.serverName
            self.serverType = serverType
            self.inputSchema = mcpTool.inputSchema
            self.tags = []
            self.isEnabled = true
            self.discoveredAt = Date()
        }

        /// Human-readable ID format: serverName/toolName
        public var displayID: String {
            "\(serverName)/\(name)"
        }

        /// Extract tags from description (markdown-style #tag parsing)
        public var extractedTags: [String] {
            guard let desc = description else { return [] }
            let pattern = #"#(\w+) "#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(desc.startIndex..., in: desc)
            let matches = regex.matches(in: desc, range: range)
            return matches.compactMap { match in
                guard let tagRange = Range(match.range(at: 1), in: desc) else { return nil }
                return String(desc[tagRange])
            }
        }
    }

    /// Server entry with connection state
    public struct ServerEntry: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let type: String
        public var state: MCPClient.ServerState
        public var toolCount: Int
        public let addedAt: Date
        public var lastDiscovery: Date?

        public init(
            id: String,
            name: String,
            type: String,
            state: MCPClient.ServerState = .disconnected,
            toolCount: Int = 0,
            addedAt: Date = Date(),
            lastDiscovery: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.state = state
            self.toolCount = toolCount
            self.addedAt = addedAt
            self.lastDiscovery = lastDiscovery
        }
    }

    /// Registry statistics
    public struct Stats: Sendable {
        public let totalServers: Int
        public let connectedServers: Int
        public let totalTools: Int
        public let enabledTools: Int
        public let disabledTools: Int

        public init(
            totalServers: Int,
            connectedServers: Int,
            totalTools: Int,
            enabledTools: Int,
            disabledTools: Int
        ) {
            self.totalServers = totalServers
            self.connectedServers = connectedServers
            self.totalTools = totalTools
            self.enabledTools = enabledTools
            self.disabledTools = disabledTools
        }
    }

    // MARK: - Private State

    private var tools: [String: ToolEntry] = [:]  // id -> entry
    private var servers: [String: ServerEntry] = [:]  // serverName -> entry
    private var toolIndex: [String: Set<String>] = [:]  // normalizedName -> toolIDs (for fast lookup)
    private let mcpClient: MCPClient

    // MARK: - Init

    public init(mcpClient: MCPClient) {
        self.mcpClient = mcpClient
    }

    // MARK: - Server Management

    /// Register a server in the registry
    public func registerServer(name: String, type: String) {
        guard servers[name] == nil else { return }
        servers[name] = ServerEntry(id: name, name: name, type: type)
    }

    /// Update server state
    public func updateServerState(name: String, state: MCPClient.ServerState) {
        guard var entry = servers[name] else { return }
        entry.state = state
        servers[name] = entry
    }

    /// Update tool count for a server
    public func updateServerToolCount(name: String, count: Int) {
        guard var entry = servers[name] else { return }
        entry.toolCount = count
        entry.lastDiscovery = Date()
        servers[name] = entry
    }

    /// Remove a server and all its tools
    public func unregisterServer(name: String) {
        // Remove all tools for this server
        let toolIDsToRemove = tools.values.filter { $0.serverName == name }.map { $0.id }
        for id in toolIDsToRemove {
            removeToolFromIndex(id: id)
            tools.removeValue(forKey: id)
        }
        servers.removeValue(forKey: name)
    }

    /// List all registered servers
    public func listServers() -> [ServerEntry] {
        Array(servers.values).sorted { $0.addedAt < $1.addedAt }
    }

    // MARK: - Tool Management

    /// Add a tool to the registry
    public func addTool(_ tool: MCPClient.MCPTool, serverType: String = "stdio") {
        let entry = ToolEntry(from: tool, serverType: serverType)
        addToolEntry(entry)
    }

    /// Add multiple tools from a server
    public func addTools(_ toolList: [MCPClient.MCPTool], serverName: String, serverType: String = "stdio") {
        for tool in toolList {
            let entry = ToolEntry(from: tool, serverType: serverType)
            addToolEntry(entry)
        }
        updateServerToolCount(name: serverName, count: toolList.count)
    }

    /// Add a tool entry directly
    private func addToolEntry(_ entry: ToolEntry) {
        tools[entry.id] = entry
        addToolToIndex(entry)
    }

    /// Enable or disable a tool
    public func setToolEnabled(id: String, enabled: Bool) {
        guard var entry = tools[id] else { return }
        entry = ToolEntry(
            id: entry.id,
            name: entry.name,
            description: entry.description,
            serverName: entry.serverName,
            serverType: entry.serverType,
            inputSchema: entry.inputSchema,
            tags: entry.tags,
            isEnabled: enabled,
            discoveredAt: entry.discoveredAt
        )
        tools[id] = entry
    }

    /// Remove a tool
    public func removeTool(id: String) {
        removeToolFromIndex(id: id)
        tools.removeValue(forKey: id)
    }

    /// Remove all tools for a server
    public func removeToolsForServer(name: String) {
        let toolIDs = tools.values.filter { $0.serverName == name }.map { $0.id }
        for id in toolIDs {
            removeToolFromIndex(id: id)
            tools.removeValue(forKey: id)
        }
        updateServerToolCount(name: name, count: 0)
    }

    /// List all tools
    public func listTools(enabledOnly: Bool = false) -> [ToolEntry] {
        let allTools = Array(tools.values).sorted { $0.name < $1.name }
        if enabledOnly {
            return allTools.filter { $0.isEnabled }
        }
        return allTools
    }

    /// List tools for a specific server
    public func listTools(serverName: String, enabledOnly: Bool = false) -> [ToolEntry] {
        listTools(enabledOnly: enabledOnly).filter { $0.serverName == serverName }
    }

    /// Get a specific tool
    public func getTool(id: String) -> ToolEntry? {
        tools[id]
    }

    // MARK: - Search & Filter

    /// Search tools by name or description
    public func search(query: String) -> [ToolEntry] {
        guard !query.isEmpty else { return listTools() }

        let normalizedQuery = query.lowercased()
        let words = normalizedQuery.components(separatedBy: .whitespaces)

        return listTools().filter { entry in
            // Exact ID match
            if entry.id.lowercased().contains(normalizedQuery) { return true }

            // Name match
            if entry.name.lowercased().contains(normalizedQuery) { return true }

            // Description match
            if entry.description?.lowercased().contains(normalizedQuery) == true { return true }

            // Tag match
            if entry.tags.contains(where: { $0.lowercased().contains(normalizedQuery) }) { return true }

            // Word-by-word match (all words must appear somewhere)
            let searchableText = [entry.name, entry.description ?? ""]
                .joined(separator: " ")
                .lowercased()
            let allWordsMatch = words.allSatisfy { searchableText.contains($0) }
            return allWordsMatch
        }
    }

    /// Filter tools by server
    public func filter(serverName: String) -> [ToolEntry] {
        listTools().filter { $0.serverName == serverName }
    }

    /// Filter tools by tag
    public func filter(tag: String) -> [ToolEntry] {
        listTools().filter { $0.tags.contains(tag) }
    }

    /// Get all unique tags across tools
    public func allTags() -> [String] {
        var tags = Set<String>()
        for entry in tools.values {
            tags.formUnion(entry.tags)
            tags.formUnion(entry.extractedTags)
        }
        return Array(tags).sorted()
    }

    // MARK: - Statistics

    /// Get registry statistics
    public func stats() -> Stats {
        let toolList = Array(tools.values)
        let connectedCount = servers.values.filter { $0.state.isReady }.count
        return Stats(
            totalServers: servers.count,
            connectedServers: connectedCount,
            totalTools: toolList.count,
            enabledTools: toolList.filter { $0.isEnabled }.count,
            disabledTools: toolList.filter { !$0.isEnabled }.count
        )
    }

    // MARK: - Craft Config Import

    /// Import tools from a Craft descriptors directory.
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
                let descriptor = try JSONDecoder().decode(CraftServerDescriptor.self, from: data)
                await importCraftDescriptor(descriptor)
            } catch {
                // Skip malformed descriptors
                continue
            }
        }
    }

    /// Import a single Craft server descriptor
    private func importCraftDescriptor(_ descriptor: CraftServerDescriptor) async {
        registerServer(name: descriptor.name, type: descriptor.type ?? "craft")

        for tool in descriptor.tools {
            // Convert CraftSchemaProperty to MCPSchemaProperty
            var mcpProperties: [String: MCPSchemaProperty]?
            if let craftProps = tool.inputSchema?.properties {
                mcpProperties = craftProps.mapValues {
                    MCPSchemaProperty(type: $0.type, description: $0.description)
                }
            }

            let inputSchema = MCPClient.MCPInputSchema(
                type: "object",
                properties: mcpProperties,
                required: tool.inputSchema?.required
            )

            let toolTags: [String] = tool.tags ?? []
            let entry = ToolEntry(
                id: "\(descriptor.name):\(tool.name)",
                name: tool.name,
                description: tool.description,
                serverName: descriptor.name,
                serverType: descriptor.type ?? "craft",
                inputSchema: inputSchema,
                tags: toolTags,
                isEnabled: true,
                discoveredAt: Date()
            )

            addToolEntry(entry)
        }

        updateServerToolCount(name: descriptor.name, count: descriptor.tools.count)
    }

    // MARK: - Private Helpers

    private func addToolToIndex(_ entry: ToolEntry) {
        let normalizedName = entry.name.lowercased()
        if toolIndex[normalizedName] == nil {
            toolIndex[normalizedName] = []
        }
        toolIndex[normalizedName]?.insert(entry.id)

        // Also index by server name
        let serverKey = "\(entry.serverName):*"
        if toolIndex[serverKey] == nil {
            toolIndex[serverKey] = []
        }
        toolIndex[serverKey]?.insert(entry.id)
    }

    private func removeToolFromIndex(id: String) {
        guard let entry = tools[id] else { return }
        let normalizedName = entry.name.lowercased()
        toolIndex[normalizedName]?.remove(id)

        let serverKey = "\(entry.serverName):*"
        toolIndex[serverKey]?.remove(id)
    }
}

// MARK: - Craft Descriptor Types

/// Server descriptor format from ~/.claude/descriptors/
private struct CraftServerDescriptor: Codable {
    let name: String
    let type: String?
    let description: String?
    let tools: [CraftToolDescriptor]

    enum CodingKeys: String, CodingKey {
        case name, type, description, tools
    }
}

/// Tool descriptor from Craft config
private struct CraftToolDescriptor: Codable {
    let name: String
    let description: String?
    let inputSchema: CraftInputSchema?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, tags
    }
}

/// Input schema from Craft config
private struct CraftInputSchema: Codable {
    let type: String?
    let properties: [String: CraftSchemaProperty]?
    let required: [String]?

    enum CodingKeys: String, CodingKey {
        case type, properties, required
    }
}

/// Schema property from Craft config
private struct CraftSchemaProperty: Codable {
    let type: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case type, description
    }
}
