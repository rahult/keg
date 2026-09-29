import XCTest
@testable import Keg
import KegCLICore

/// Live end-to-end of the assembled local runtime: AgentService creates a
/// session, provisions the recipe's containers on the real runtime, runs a
/// pi turn, and the transcript lands in the session log. Opt-in:
/// KEG_RUN_AGENT_SERVICE_E2E=1 with the runtime up and pi configured.
final class AgentServiceLiveTests: XCTestCase {
    var baseDirectory: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_AGENT_SERVICE_E2E"] == "1" else {
            throw XCTSkip("Set KEG_RUN_AGENT_SERVICE_E2E=1 to run the agent-service live test")
        }
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.keg/docker.sock") else {
            throw XCTSkip("Keg's Docker API socket is not present (runtime down?)")
        }
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-agent-service-live-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let baseDirectory {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }

    func testFullTurnProvisionsRunsAndCompletes() async throws {
        let sessionId = "svc-live-\(UUID().uuidString.prefix(6))"
        let store = try SessionStore(sessionsDirectory: baseDirectory.appendingPathComponent("sessions"))
        let workspace = AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces"))
        let provisioner = AgentEnvironmentProvisioner(workspace: workspace)
        let service = AgentService(store: store, workspace: workspace, provisioner: provisioner) { _ in PiBrain() }

        let recipe = WorldRecipe(
            repo: RepoRef(url: "https://github.com/example/demo.git", branch: "main", commit: "abc123"),
            kegYAML: """
            name: demo
            services:
              web:
                image: alpine:latest
                command: ["sleep", "300"]
            """
        )

        try await service.createSession(id: sessionId, agentId: "agent-1", environmentId: "env-1")

        do {
            try await service.runTurn(sessionId: sessionId, recipe: recipe, prompt: "Reply with exactly: keg-svc-e2e-ok", brain: .pi)
        } catch let error as PiBrain.PiBrainError {
            throw XCTSkip("pi rejected the prompt (provider auth not configured?): \(error.localizedDescription)")
        }

        let session = try await store.loadSession(id: sessionId)
        XCTAssertEqual(session?.status, .completed)

        let events = try await store.loadEvents(forSession: sessionId)
        XCTAssertEqual(events.first?.type, .userMessage)
        XCTAssertTrue(
            events.contains { $0.type == .assistantMessage && ($0.content ?? "").contains("keg-svc-e2e-ok") },
            "expected pi's reply in the log, got: \(events.map(\.type))"
        )

        // Cleanup the provisioned world.
        try await provisioner.teardown(sessionId: sessionId, recipe: recipe)
    }
}
