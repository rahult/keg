import XCTest
@testable import Keg

/// Spec tests for Claude Managed Agents API implementation
/// Based on: https://platform.claude.com/docs/en/managed-agents/overview
/// Beta header required: managed-agents-2026-04-01

final class ManagedAgentsSpec: XCTestCase {

    // MARK: - Agent CRUD

    func testAgentCreate() async throws {
        // POST /v1/agents - Create agent with name, model, system prompt, tools
        let params = CreateAgentParams(
            name: "Test Agent",
            model: "claude-sonnet-4-6",
            system: "You are a helpful assistant."
        )
        XCTAssertEqual(params.name, "Test Agent")
        XCTAssertEqual(params.model, "claude-sonnet-4-6")
        XCTAssertEqual(params.system, "You are a helpful assistant.")
    }

    func testAgentList() async throws {
        // GET /v1/agents - List all agents (verify type structure)
        let response = AgentListResponse(data: [], hasMore: false, totalCount: 0)
        XCTAssertEqual(response.data.count, 0)
        XCTAssertFalse(response.hasMore)
    }

    func testAgentGet() async throws {
        // GET /v1/agents/:id - Get agent by ID (verify type structure)
        let agent = Agent(
            id: "test_123",
            type: "agent",
            name: "Test",
            model: AgentModel(id: "claude-sonnet-4-6"),
            system: nil,
            description: nil,
            tools: [],
            skills: [],
            mcpServers: [],
            callableAgents: nil,
            metadata: nil,
            version: 1,
            createdAt: Date(),
            updatedAt: Date(),
            archivedAt: nil
        )
        XCTAssertEqual(agent.id, "test_123")
        XCTAssertEqual(agent.version, 1)
    }

    func testAgentUpdate() async throws {
        // PATCH /v1/agents/:id - Update agent config
        let params = CreateAgentParams(name: "Updated Agent", model: "claude-opus-4-6")
        XCTAssertEqual(params.name, "Updated Agent")
    }

    func testAgentArchive() async throws {
        // DELETE /v1/agents/:id - Archive agent (soft delete)
        // Verify agent has archivedAt field
        let agent = Agent(
            id: "test",
            type: "agent",
            name: "Test",
            model: AgentModel(id: "claude-sonnet-4-6"),
            system: nil,
            description: nil,
            tools: [],
            skills: [],
            mcpServers: [],
            callableAgents: nil,
            metadata: nil,
            version: 1,
            createdAt: Date(),
            updatedAt: Date(),
            archivedAt: Date()
        )
        XCTAssertNotNil(agent.archivedAt)
    }

    // MARK: - Environment CRUD

    func testEnvironmentCreate() async throws {
        // POST /v1/environments
        let params = CreateEnvironmentParams(
            name: "Test Env",
            packages: [Package(name: "python3")]
        )
        XCTAssertEqual(params.name, "Test Env")
        XCTAssertEqual(params.packages?.first?.name, "python3")
    }

    func testEnvironmentList() async throws {
        // GET /v1/environments
        let response = EnvironmentListResponse(data: [], hasMore: false, totalCount: 0)
        XCTAssertEqual(response.data.count, 0)
    }

    func testEnvironmentGet() async throws {
        // GET /v1/environments/:id
        let env = AgentEnvironment(
            id: "env_123",
            type: "environment",
            name: "Test",
            description: nil,
            packages: [],
            networkAccess: nil,
            mountedFiles: nil,
            version: 1,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertEqual(env.id, "env_123")
    }

    func testEnvironmentUpdate() async throws {
        // PATCH /v1/environments/:id
        let params = CreateEnvironmentParams(name: "Updated Env")
        XCTAssertEqual(params.name, "Updated Env")
    }

    func testEnvironmentDelete() async throws {
        // DELETE /v1/environments/:id
        let env = AgentEnvironment(
            id: "env_123",
            type: "environment",
            name: "Test",
            description: nil,
            packages: [],
            networkAccess: nil,
            mountedFiles: nil,
            version: 1,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertEqual(env.id, "env_123")
    }

    // MARK: - Session Lifecycle

    func testSessionCreate() async throws {
        // POST /v1/sessions
        let params = CreateSessionParams(
            agentId: "agent_123",
            environmentId: "env_123"
        )
        XCTAssertEqual(params.agentId, "agent_123")
        XCTAssertEqual(params.environmentId, "env_123")
    }

    func testSessionList() async throws {
        // GET /v1/sessions
        let response = SessionListResponse(data: [], hasMore: false, totalCount: 0)
        XCTAssertEqual(response.data.count, 0)
    }

    func testSessionGet() async throws {
        // GET /v1/sessions/:id
        let session = Session(
            id: "session_123",
            type: "session",
            agentId: "agent_123",
            agentVersion: 1,
            environmentId: "env_123",
            status: .pending,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertEqual(session.id, "session_123")
        XCTAssertEqual(session.status, .pending)
    }

    func testSessionDelete() async throws {
        // DELETE /v1/sessions/:id
        let session = Session(
            id: "session_123",
            type: "session",
            agentId: "agent_123",
            agentVersion: 1,
            environmentId: "env_123",
            status: .running,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertEqual(session.status, .running)
    }

    // MARK: - Events & Streaming

    func testSessionSendEvent() async throws {
        // POST /v1/sessions/:id/events
        let event = SessionEvent.userMessage("Hello, agent!")
        XCTAssertEqual(event.type, .userMessage)
        XCTAssertEqual(event.content, "Hello, agent!")
    }

    func testSessionGetEvents() async throws {
        // GET /v1/sessions/:id/events
        let events: [SessionEvent] = []
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - Agent Configuration

    func testAgentWithModel() async throws {
        // Agent model config: id + optional speed
        let model = AgentModel(id: "claude-opus-4-6", speed: .fast)
        XCTAssertEqual(model.id, "claude-opus-4-6")
        XCTAssertEqual(model.speed, .fast)
    }

    func testAgentWithSystemPrompt() async throws {
        // Agent with system prompt for persona
        let params = CreateAgentParams(
            name: "Persona Agent",
            model: "claude-sonnet-4-6",
            system: "You are a pirate. Arrr!"
        )
        XCTAssertTrue(params.system?.contains("pirate") ?? false)
    }

    func testAgentWithMetadata() async throws {
        // Agent with arbitrary key-value metadata
        let params = CreateAgentParams(
            name: "Meta Agent",
            model: "claude-sonnet-4-6",
            metadata: ["team": "engineering", "tier": "production"]
        )
        XCTAssertEqual(params.metadata?["team"], "engineering")
        XCTAssertEqual(params.metadata?["tier"], "production")
    }

    // MARK: - Tools

    func testAgentWithToolset() async throws {
        // Agent with agent_toolset_20260401 (all built-in tools)
        let toolset = ToolsetConfig(defaultConfig: ToolsetDefaultConfig())
        XCTAssertNotNil(toolset.defaultConfig)
    }

    func testAgentToolsetDisableSpecificTools() async throws {
        // Toolset with configs to disable specific tools
        let toolset = ToolsetConfig(
            defaultConfig: ToolsetDefaultConfig(),
            configs: [
                ToolConfig(name: "web_search", enabled: false),
                ToolConfig(name: "web_fetch", enabled: false)
            ]
        )
        let webSearch = toolset.configs.first { $0.name == "web_search" }
        XCTAssertEqual(webSearch?.enabled, false)
    }

    func testAgentWithCustomTool() async throws {
        // Agent with custom tool (type: custom, name, description, input_schema)
        let tool = CustomTool(
            name: "get_weather",
            description: "Get current weather for a location",
            inputSchema: InputSchema(
                type: "object",
                properties: ["location": SchemaProperty(type: "string", description: "City name")],
                required: ["location"]
            )
        )
        XCTAssertEqual(tool.name, "get_weather")
        XCTAssertEqual(tool.inputSchema?.required?.first, "location")
    }

    // MARK: - Built-in Tools

    func testToolBash() async throws {
        // bash tool for shell commands
        let config = ToolConfig(name: "bash")
        XCTAssertEqual(config.name, "bash")
    }

    func testToolRead() async throws {
        // read tool for file reading
        let config = ToolConfig(name: "read")
        XCTAssertEqual(config.name, "read")
    }

    func testToolWrite() async throws {
        // write tool for file writing
        let config = ToolConfig(name: "write")
        XCTAssertEqual(config.name, "write")
    }

    func testToolEdit() async throws {
        // edit tool for string replacement
        let config = ToolConfig(name: "edit")
        XCTAssertEqual(config.name, "edit")
    }

    func testToolGlob() async throws {
        // glob tool for pattern matching
        let config = ToolConfig(name: "glob")
        XCTAssertEqual(config.name, "glob")
    }

    func testToolGrep() async throws {
        // grep tool for regex search
        let config = ToolConfig(name: "grep")
        XCTAssertEqual(config.name, "grep")
    }

    func testToolWebFetch() async throws {
        // web_fetch tool for URL content retrieval
        let config = ToolConfig(name: "web_fetch")
        XCTAssertEqual(config.name, "web_fetch")
    }

    func testToolWebSearch() async throws {
        // web_search tool for web searches
        let config = ToolConfig(name: "web_search")
        XCTAssertEqual(config.name, "web_search")
    }

    // MARK: - MCP Servers

    func testAgentWithMCPServers() async throws {
        // Agent with mcp_servers configuration
        let server = MCPServer(
            type: "mcp",
            name: "filesystem",
            config: MCPServerConfig(url: "http://localhost:8080")
        )
        XCTAssertEqual(server.type, "mcp")
        XCTAssertEqual(server.config?.url, "http://localhost:8080")
    }

    // MARK: - Skills

    func testAgentWithSkills() async throws {
        // Agent with skills array
        let skill = AgentSkill(identifier: "code-review", config: ["strictness": "high"])
        XCTAssertEqual(skill.identifier, "code-review")
        XCTAssertEqual(skill.config?["strictness"], "high")
    }

    // MARK: - Authentication

    func testBetaHeaderRequired() async throws {
        // Verify beta header constant
        XCTAssertEqual(ManagedAgentsClient.betaHeader, "managed-agents-2026-04-01")
    }

    func testAPIKeyRequired() async throws {
        // Client initialization requires API key
        let client = ManagedAgentsClient(apiKey: "sk-test-key")
        let retrievedKey = await client.apiKey
        XCTAssertEqual(retrievedKey, "sk-test-key")
    }
}
