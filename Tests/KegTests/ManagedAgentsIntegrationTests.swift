import XCTest
@testable import Keg

/// Integration tests for ManagedAgentsClient using real Anthropic API
/// Requires: ANTHROPIC_API_KEY environment variable (stored in Keychain)
///
/// Run with:
///   ANTHROPIC_API_KEY=sk-ant-api... xctest --filter ManagedAgentsIntegrationTests
final class ManagedAgentsIntegrationTests: XCTestCase {

    private var client: ManagedAgentsClient!
    private var createdAgentIds: [String] = []
    private var createdEnvironmentIds: [String] = []

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_MANAGED_AGENTS"] == "1" else {
            throw XCTSkip("Set KEG_RUN_MANAGED_AGENTS=1 to run Managed Agents integration tests")
        }

        try await super.setUp()

        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw XCTSkip("ANTHROPIC_API_KEY not set - skipping integration tests")
        }

        // Store API key and create client
        client = try await ManagedAgentsClient.withStoredCredentials(apiKey: apiKey)
    }

    override func tearDown() async throws {
        // Clean up created resources
        for agentId in createdAgentIds {
            do {
                try await client.archiveAgent(id: agentId)
                print("🧹 Archived agent: \(agentId)")
            } catch {
                print("⚠️ Failed to archive agent \(agentId): \(error)")
            }
        }

        for environmentId in createdEnvironmentIds {
            do {
                try await client.deleteEnvironment(id: environmentId)
                print("🧹 Deleted environment: \(environmentId)")
            } catch {
                print("⚠️ Failed to delete environment \(environmentId): \(error)")
            }
        }

        createdAgentIds.removeAll()
        createdEnvironmentIds.removeAll()

        try await super.tearDown()
    }

    // MARK: - Agent CRUD Tests

    func testAgentCreateAndGet() async throws {
        let testName = "keg-integration-test-\(UUID().uuidString.prefix(8))"
        let params = CreateAgentParams(
            name: testName,
            model: "claude-sonnet-4-7-20250514",
            system: "You are a test assistant."
        )

        // Create
        let agent = try await client.createAgent(params)

        XCTAssertFalse(agent.id.isEmpty, "Agent should have an ID")
        XCTAssertEqual(agent.name, testName)
        XCTAssertEqual(agent.model.id, "claude-sonnet-4-7-20250514")
        XCTAssertEqual(agent.system, "You are a test assistant.")
        XCTAssertEqual(agent.version, 1)
        XCTAssertNil(agent.archivedAt)

        createdAgentIds.append(agent.id)
        print("✅ Created agent: \(agent.id) (\(agent.name))")

        // Get by ID
        let retrieved = try await client.getAgent(id: agent.id)
        XCTAssertEqual(retrieved.id, agent.id)
        XCTAssertEqual(retrieved.name, agent.name)
        XCTAssertEqual(retrieved.version, agent.version)
        print("✅ Retrieved agent: \(retrieved.id)")
    }

    func testAgentList() async throws {
        let response = try await client.listAgents()

        XCTAssertNotNil(response.data, "List response should have data array")
        XCTAssertFalse(response.data.isEmpty, "Should have at least one agent (or be empty if none exist)")
        print("✅ Listed agents: \(response.data.count) total, hasMore=\(response.hasMore ?? false)")

        for agent in response.data.prefix(5) {
            print("   - \(agent.name) (id: \(agent.id), version: \(agent.version))")
        }
    }

    func testAgentUpdate() async throws {
        // Create agent first
        let testName = "keg-update-test-\(UUID().uuidString.prefix(8))"
        let createParams = CreateAgentParams(
            name: testName,
            model: "claude-sonnet-4-7-20250514",
            system: "Original system prompt"
        )

        let agent = try await client.createAgent(createParams)
        createdAgentIds.append(agent.id)
        print("✅ Created agent for update: \(agent.id)")

        // Update
        let updatedSystem = "Updated system prompt - \(Date().timeIntervalSince1970)"
        let updateParams = CreateAgentParams(
            name: testName,
            model: "claude-opus-4-7-20250514",
            system: updatedSystem,
            description: "Updated description"
        )

        let updated = try await client.updateAgent(id: agent.id, params: updateParams)

        XCTAssertEqual(updated.id, agent.id)
        XCTAssertEqual(updated.system, updatedSystem)
        XCTAssertEqual(updated.model.id, "claude-opus-4-7-20250514")
        XCTAssertEqual(updated.description, "Updated description")
        XCTAssertGreaterThan(updated.version, agent.version, "Version should increment on update")
        print("✅ Updated agent: version \(agent.version) -> \(updated.version)")
    }

    func testAgentArchive() async throws {
        // Create agent
        let testName = "keg-archive-test-\(UUID().uuidString.prefix(8))"
        let params = CreateAgentParams(
            name: testName,
            model: "claude-sonnet-4-7-20250514"
        )

        let agent = try await client.createAgent(params)
        // Don't add to cleanup list since we're archiving it

        // Archive
        try await client.archiveAgent(id: agent.id)
        print("✅ Archived agent: \(agent.id)")

        // Verify archived by getting it
        let archived = try await client.getAgent(id: agent.id)
        XCTAssertNotNil(archived.archivedAt, "Archived agent should have archivedAt timestamp")
        print("✅ Verified archive timestamp: \(archived.archivedAt!)")
    }

    func testAgentWithMetadata() async throws {
        let testName = "keg-metadata-test-\(UUID().uuidString.prefix(8))"
        let params = CreateAgentParams(
            name: testName,
            model: "claude-sonnet-4-7-20250514",
            metadata: [
                "test": "true",
                "framework": "keg",
                "build": "integration"
            ]
        )

        let agent = try await client.createAgent(params)
        createdAgentIds.append(agent.id)

        XCTAssertEqual(agent.metadata?["test"], "true")
        XCTAssertEqual(agent.metadata?["framework"], "keg")
        XCTAssertEqual(agent.metadata?["build"], "integration")
        print("✅ Agent with metadata created: \(agent.metadata!)")
    }

    func testAgentWithTools() async throws {
        let testName = "keg-tools-test-\(UUID().uuidString.prefix(8))"
        let params = CreateAgentParams(
            name: testName,
            model: "claude-sonnet-4-7-20250514",
            tools: [
                .agentToolset(ToolsetConfig(
                    defaultConfig: ToolsetDefaultConfig(permissionPolicy: PermissionPolicy(type: "always_allow")),
                    configs: [
                        ToolConfig(name: "web_search", enabled: false),
                        ToolConfig(name: "bash", enabled: true)
                    ]
                ))
            ]
        )

        let agent = try await client.createAgent(params)
        createdAgentIds.append(agent.id)

        XCTAssertFalse(agent.tools.isEmpty)
        print("✅ Agent with tools created: \(agent.tools.count) tool(s)")
    }

    // MARK: - Environment CRUD Tests

    func testEnvironmentCreateAndGet() async throws {
        let testName = "keg-env-test-\(UUID().uuidString.prefix(8))"
        let params = CreateEnvironmentParams(
            name: testName,
            description: "Integration test environment",
            packages: [Package(name: "python3")]
        )

        // Create
        let env = try await client.createEnvironment(params)

        XCTAssertFalse(env.id.isEmpty)
        XCTAssertEqual(env.name, testName)
        XCTAssertEqual(env.version, 1)

        createdEnvironmentIds.append(env.id)
        print("✅ Created environment: \(env.id) (\(env.name))")

        // Get
        let retrieved = try await client.getEnvironment(id: env.id)
        XCTAssertEqual(retrieved.id, env.id)
        XCTAssertEqual(retrieved.name, env.name)
        print("✅ Retrieved environment: \(retrieved.id)")
    }

    func testEnvironmentList() async throws {
        let response = try await client.listEnvironments()

        XCTAssertNotNil(response.data)
        print("✅ Listed environments: \(response.data.count) total")

        for env in response.data.prefix(5) {
            print("   - \(env.name) (id: \(env.id))")
        }
    }

    func testEnvironmentUpdate() async throws {
        // Create
        let testName = "keg-env-update-test-\(UUID().uuidString.prefix(8))"
        let createParams = CreateEnvironmentParams(
            name: testName,
            packages: [Package(name: "python3")]
        )

        let env = try await client.createEnvironment(createParams)
        createdEnvironmentIds.append(env.id)

        // Update
        let updated = try await client.updateEnvironment(
            id: env.id,
            params: CreateEnvironmentParams(
                name: testName,
                description: "Updated description",
                packages: [Package(name: "python3"), Package(name: "git")]
            )
        )

        XCTAssertEqual(updated.id, env.id)
        XCTAssertEqual(updated.description, "Updated description")
        XCTAssertEqual(updated.packages.count, 2)
        print("✅ Updated environment: \(updated.packages.map(\.name))")
    }

    func testEnvironmentDelete() async throws {
        // Create
        let testName = "keg-env-delete-test-\(UUID().uuidString.prefix(8))"
        let params = CreateEnvironmentParams(name: testName)

        let env = try await client.createEnvironment(params)
        // Don't add to cleanup list - we're deleting it

        // Delete
        try await client.deleteEnvironment(id: env.id)
        print("✅ Deleted environment: \(env.id)")

        // Verify deletion by trying to get it (should fail)
        do {
            _ = try await client.getEnvironment(id: env.id)
            XCTFail("Expected environment to be deleted")
        } catch {
            print("✅ Verified deletion (get failed as expected)")
        }
    }

    // MARK: - Session Tests

    func testSessionCreateAndList() async throws {
        // First create an agent
        let testAgentName = "keg-session-test-\(UUID().uuidString.prefix(8))"
        let agentParams = CreateAgentParams(
            name: testAgentName,
            model: "claude-sonnet-4-7-20250514"
        )
        let agent = try await client.createAgent(agentParams)
        createdAgentIds.append(agent.id)
        print("✅ Created agent for session test: \(agent.id)")

        // Create session
        // Sessions require an environment - create one first
        let envParams = CreateEnvironmentParams(
            name: "test-env-\(UUID().uuidString.prefix(8))",
            packages: [Package(name: "python3", version: "3.11")]
        )
        let env = try await client.createEnvironment(envParams)
        createdEnvironmentIds.append(env.id)

        let sessionParams = CreateSessionParams(
            agentId: agent.id,
            agentVersion: agent.version,
            environmentId: env.id
        )
        let session = try await client.createSession(sessionParams)

        XCTAssertFalse(session.id.isEmpty)
        XCTAssertEqual(session.agentId, agent.id)
        XCTAssertEqual(session.agentVersion, agent.version)
        XCTAssertEqual(session.type, "session")
        print("✅ Created session: \(session.id)")

        // List sessions for this agent
        let response = try await client.listSessions(agentId: agent.id)
        XCTAssertTrue(response.data.contains { $0.id == session.id })
        print("✅ Listed sessions: found \(response.data.count) for agent")

        // Cleanup session
        try await client.deleteSession(id: session.id)
        print("✅ Deleted session: \(session.id)")
    }

    func testSessionGetAndDelete() async throws {
        // Create agent
        let testAgentName = "keg-session-get-test-\(UUID().uuidString.prefix(8))"
        let agent = try await client.createAgent(CreateAgentParams(
            name: testAgentName,
            model: "claude-sonnet-4-7-20250514"
        ))
        createdAgentIds.append(agent.id)

        // Create session
        // Sessions require an environment - create one first
        let envParams = CreateEnvironmentParams(
            name: "test-env-\(UUID().uuidString.prefix(8))",
            packages: [Package(name: "python3", version: "3.11")]
        )
        let env = try await client.createEnvironment(envParams)
        createdEnvironmentIds.append(env.id)

        let session = try await client.createSession(CreateSessionParams(
            agentId: agent.id,
            agentVersion: agent.version,
            environmentId: env.id
        ))
        print("✅ Created session: \(session.id)")

        // Get session
        let retrieved = try await client.getSession(id: session.id)
        XCTAssertEqual(retrieved.id, session.id)
        XCTAssertEqual(retrieved.agentId, agent.id)
        print("✅ Retrieved session: \(retrieved.id), status=\(retrieved.status.rawValue)")

        // Delete session
        try await client.deleteSession(id: session.id)
        print("✅ Deleted session: \(session.id)")
    }

    // MARK: - Error Handling Tests

    func testGetNonExistentAgent() async throws {
        do {
            _ = try await client.getAgent(id: "non_existent_agent_id_12345")
            XCTFail("Expected 404 error for non-existent agent")
        } catch let error as ManagedAgentsError {
            if case .httpError(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 404, "Should return 404 for non-existent agent")
                print("✅ Got expected 404 for non-existent agent")
            } else {
                XCTFail("Expected HTTP error")
            }
        }
    }

    func testGetNonExistentEnvironment() async throws {
        do {
            _ = try await client.getEnvironment(id: "non_existent_env_id_12345")
            XCTFail("Expected 404 error for non-existent environment")
        } catch let error as ManagedAgentsError {
            if case .httpError(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 404, "Should return 404 for non-existent environment")
                print("✅ Got expected 404 for non-existent environment")
            } else {
                XCTFail("Expected HTTP error")
            }
        }
    }

    func testUnauthorizedAccess() async throws {
        // Create client with invalid API key stored
        let invalidClient = try await ManagedAgentsClient.withStoredCredentials(
            apiKey: "invalid_key_123"
        )

        do {
            _ = try await invalidClient.listAgents()
            XCTFail("Expected 401 error with invalid API key")
        } catch let error as ManagedAgentsError {
            if case .httpError(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 401, "Should return 401 for invalid API key")
                print("✅ Got expected 401 for unauthorized access")
            } else {
                XCTFail("Expected HTTP error")
            }
        }
    }
}
