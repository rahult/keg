import XCTest
@testable import Keg

final class MCPToolDiscoveryTests: XCTestCase {

    // MARK: - MCPServerRegistry Tests

    func testRegistryInitialization() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        let stats = await registry.stats()
        XCTAssertEqual(stats.totalServers, 0)
        XCTAssertEqual(stats.totalTools, 0)
    }

    func testRegisterServer() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        await registry.registerServer(name: "test-server", type: "stdio")

        let servers = await registry.listServers()
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "test-server")
        XCTAssertEqual(servers[0].type, "stdio")
    }

    func testUnregisterServer() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        await registry.registerServer(name: "test-server", type: "stdio")
        await registry.unregisterServer(name: "test-server")

        let servers = await registry.listServers()
        XCTAssertTrue(servers.isEmpty)
    }

    func testAddTool() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        let tool = MCPClient.MCPTool(
            name: "test_tool",
            description: "A test tool",
            inputSchema: MCPClient.MCPInputSchema(
                type: "object",
                properties: ["arg1": MCPSchemaProperty(type: "string", description: "First argument")],
                required: ["arg1"]
            ),
            serverName: "test-server"
        )

        await registry.addTool(tool)

        let tools = await registry.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "test_tool")
        XCTAssertEqual(tools[0].serverName, "test-server")
        XCTAssertEqual(tools[0].id, "test-server:test_tool")
    }

    func testAddMultipleToolsFromServer() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        let tools = [
            MCPClient.MCPTool(name: "tool1", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server"),
            MCPClient.MCPTool(name: "tool2", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server"),
            MCPClient.MCPTool(name: "tool3", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server"),
        ]

        await registry.addTools(tools, serverName: "server", serverType: "http")

        let serverTools = await registry.listTools(serverName: "server")
        XCTAssertEqual(serverTools.count, 3)

        let stats = await registry.stats()
        XCTAssertEqual(stats.totalTools, 3)
    }

    func testEnableDisableTool() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        let tool = MCPClient.MCPTool(
            name: "test_tool",
            description: nil,
            inputSchema: MCPClient.MCPInputSchema(),
            serverName: "test-server"
        )

        await registry.addTool(tool)

        // Disable tool
        await registry.setToolEnabled(id: "test-server:test_tool", enabled: false)

        let enabledOnly = await registry.listTools(enabledOnly: true)
        XCTAssertTrue(enabledOnly.isEmpty)

        let allTools = await registry.listTools(enabledOnly: false)
        XCTAssertEqual(allTools.count, 1)
        XCTAssertFalse(allTools[0].isEnabled)

        // Re-enable tool
        await registry.setToolEnabled(id: "test-server:test_tool", enabled: true)

        let reEnabledTools = await registry.listTools(enabledOnly: true)
        XCTAssertEqual(reEnabledTools.count, 1)
    }

    func testSearchByName() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        await registry.addTool(
            MCPClient.MCPTool(name: "file_read", description: "Read files from disk", inputSchema: MCPClient.MCPInputSchema(), serverName: "fs")
        )
        await registry.addTool(
            MCPClient.MCPTool(name: "file_write", description: "Write files to disk", inputSchema: MCPClient.MCPInputSchema(), serverName: "fs")
        )
        await registry.addTool(
            MCPClient.MCPTool(name: "web_search", description: "Search the web", inputSchema: MCPClient.MCPInputSchema(), serverName: "web")
        )

        let results = await registry.search(query: "file")
        XCTAssertEqual(results.count, 2)

        let searchResults = await registry.search(query: "web")
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults[0].name, "web_search")
    }

    func testSearchByDescription() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        await registry.addTool(
            MCPClient.MCPTool(name: "tool1", description: "Send emails to users", inputSchema: MCPClient.MCPInputSchema(), serverName: "email")
        )
        await registry.addTool(
            MCPClient.MCPTool(name: "tool2", description: "Calendar event management", inputSchema: MCPClient.MCPInputSchema(), serverName: "calendar")
        )

        let results = await registry.search(query: "email")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "tool1")
    }

    func testFilterByServer() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        await registry.addTool(
            MCPClient.MCPTool(name: "tool1", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server-a")
        )
        await registry.addTool(
            MCPClient.MCPTool(name: "tool2", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server-b")
        )
        await registry.addTool(
            MCPClient.MCPTool(name: "tool3", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server-a")
        )

        let serverATools = await registry.filter(serverName: "server-a")
        XCTAssertEqual(serverATools.count, 2)
    }

    func testGetToolByID() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        let tool = MCPClient.MCPTool(
            name: "specific_tool",
            description: "A specific tool",
            inputSchema: MCPClient.MCPInputSchema(),
            serverName: "my-server"
        )

        await registry.addTool(tool)

        let retrieved = await registry.getTool(id: "my-server:specific_tool")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "specific_tool")
    }

    func testToolEntryDisplayID() async {
        let entry = MCPServerRegistry.ToolEntry(
            id: "server:tool",
            name: "tool",
            description: nil,
            serverName: "server",
            serverType: "http",
            inputSchema: MCPClient.MCPInputSchema()
        )

        XCTAssertEqual(entry.displayID, "server/tool")
    }

    func testRegistryStats() async {
        let mcpClient = MCPClient()
        let registry = MCPServerRegistry(mcpClient: mcpClient)

        await registry.registerServer(name: "server1", type: "stdio")
        await registry.registerServer(name: "server2", type: "http")

        await registry.addTool(
            MCPClient.MCPTool(name: "tool1", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server1")
        )
        await registry.addTool(
            MCPClient.MCPTool(name: "tool2", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server1")
        )
        await registry.addTool(
            MCPClient.MCPTool(name: "tool3", description: nil, inputSchema: MCPClient.MCPInputSchema(), serverName: "server2")
        )

        // Disable one tool
        await registry.setToolEnabled(id: "server1:tool1", enabled: false)

        let stats = await registry.stats()
        XCTAssertEqual(stats.totalServers, 2)
        XCTAssertEqual(stats.totalTools, 3)
        XCTAssertEqual(stats.enabledTools, 2)
        XCTAssertEqual(stats.disabledTools, 1)
    }

    // MARK: - MCPTool Tests

    func testMCPToolConversion() {
        let inputSchema = MCPClient.MCPInputSchema(
            type: "object",
            properties: [
                "filename": MCPSchemaProperty(type: "string", description: "Name of the file"),
                "content": MCPSchemaProperty(type: "string", description: "File contents")
            ],
            required: ["filename"]
        )

        let tool = MCPClient.MCPTool(
            name: "write_file",
            description: "Write content to a file",
            inputSchema: inputSchema,
            serverName: "filesystem"
        )

        let agentTool = tool.toAgentTool()

        XCTAssertEqual(agentTool.name, "mcp_filesystem_write_file")
        XCTAssertEqual(agentTool.description, "Write content to a file")
        XCTAssertNotNil(agentTool.inputSchema)
        XCTAssertEqual(agentTool.inputSchema?.properties?.count, 2)
        XCTAssertEqual(agentTool.inputSchema?.required?.first, "filename")
    }

    func testMCPToolID() {
        let tool = MCPClient.MCPTool(
            name: "my_tool",
            description: nil,
            inputSchema: MCPClient.MCPInputSchema(),
            serverName: "my_server"
        )

        XCTAssertEqual(tool.id, "my_server:my_tool")
    }

    // MARK: - MCPClient Tests

    func testMCPClientInitialization() async {
        let client = MCPClient()
        let servers = await client.registeredServers()
        XCTAssertTrue(servers.isEmpty)
    }

    func testMCPClientWithRegistry() async {
        let client = MCPClient()
        let registry = MCPServerRegistry(mcpClient: client)
        await client.setToolRegistry(registry)

        // Registry should be set
        let tools = await registry.listTools()
        XCTAssertTrue(tools.isEmpty)
    }

    func testPollingIntervalMinimum() async {
        let client = MCPClient()

        // Setting interval below minimum should clamp to 10 seconds
        await client.setPollingInterval(5)

        // The interval is stored as a private property, we verify via behavior
        // by checking the task doesn't crash with small intervals
        await client.startToolDiscoveryPolling()
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        await client.stopToolDiscoveryPolling()
    }

    // MARK: - Input Schema Tests

    func testInputSchemaCreation() {
        let schema = MCPClient.MCPInputSchema(
            type: "object",
            properties: [
                "path": MCPSchemaProperty(type: "string", description: "File path"),
                "recursive": MCPSchemaProperty(type: "boolean", description: "Search recursively")
            ],
            required: ["path"]
        )

        XCTAssertEqual(schema.type, "object")
        XCTAssertEqual(schema.properties?.count, 2)
        XCTAssertEqual(schema.required?.first, "path")
    }

    func testEmptyInputSchema() {
        let schema = MCPClient.MCPInputSchema()

        XCTAssertEqual(schema.type, "object")
        XCTAssertNil(schema.properties)
        XCTAssertNil(schema.required)
    }

    // MARK: - ToolEntry Tests

    func testToolEntryFromMCPTool() async {
        let mcpTool = MCPClient.MCPTool(
            name: "list_files",
            description: "List files in a directory",
            inputSchema: MCPClient.MCPInputSchema(),
            serverName: "fs"
        )

        let entry = MCPServerRegistry.ToolEntry(from: mcpTool, serverType: "stdio")

        XCTAssertEqual(entry.name, "list_files")
        XCTAssertEqual(entry.description, "List files in a directory")
        XCTAssertEqual(entry.serverName, "fs")
        XCTAssertEqual(entry.serverType, "stdio")
        XCTAssertEqual(entry.isEnabled, true)
    }

    func testToolEntryExtractedTags() async {
        let entry = MCPServerRegistry.ToolEntry(
            id: "test:tagged",
            name: "tagged_tool",
            description: "This tool #filesystem #read does something",
            serverName: "test",
            serverType: "http",
            inputSchema: MCPClient.MCPInputSchema()
        )

        let tags = entry.extractedTags
        XCTAssertTrue(tags.contains("filesystem"))
        XCTAssertTrue(tags.contains("read"))
    }

    // MARK: - ServerState Tests

    func testServerStateIsReady() async {
        let client = MCPClient()

        // Disconnected should not be ready
        let disconnected = await client.serverState(serverName: "unknown")
        XCTAssertFalse(disconnected.isReady)

        // The internal state tracking is tested via the registry
        let registry = MCPServerRegistry(mcpClient: client)
        await registry.registerServer(name: "test", type: "http")
        await registry.updateServerState(name: "test", state: .connecting)

        let servers = await registry.listServers()
        XCTAssertEqual(servers.count, 1)
    }
}

// MARK: - AnyCodable Helper for Tests

extension MCPToolDiscoveryTests {
    func createAnyCodableDict(_ dict: [String: Any]) -> [String: AnyCodable] {
        dict.mapValues { AnyCodable($0) }
    }
}
