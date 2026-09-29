import XCTest

@testable import Keg

/// Live end-to-end test of the pi harness adapter against a real `pi`
/// install. Opt-in like the other live E2Es: set KEG_RUN_PI_E2E=1 with pi on
/// PATH and a working model provider (whatever `pi` is configured with) to
/// run it. Default `swift test` skips it.
final class PiBrainLiveTests: XCTestCase {
    var baseDirectory: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_PI_E2E"] == "1" else {
            throw XCTSkip("Set KEG_RUN_PI_E2E=1 to run the pi live test")
        }
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-pi-live-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        // setUp throws XCTSkip before baseDirectory is assigned — the IUO
        // must not crash the whole suite on skip.
        if let baseDirectory {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }

    func testPiTurnWritesEventsToSessionLog() async throws {
        let store = try SessionStore(sessionsDirectory: baseDirectory.appendingPathComponent("sessions"))
        let workspace = AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces"))
        let now = Date()
        try await store.saveSession(Session(
            id: "pi-live-1", type: "agent", agentId: "agent-1", agentVersion: 1,
            environmentId: "env-1", status: .running, createdAt: now, updatedAt: now
        ))

        let recipe = WorldRecipe(
            repo: RepoRef(url: "https://github.com/example/demo.git", branch: "main", commit: "abc123"),
            kegYAML: "name: demo\nservices:\n  web:\n    image: nginx:alpine\n"
        )
        let runner = AgentRunner(store: store, workspace: workspace)

        do {
            try await runner.run(
                sessionId: "pi-live-1",
                recipe: recipe,
                prompt: "Reply with exactly: keg-pi-e2e-ok",
                brain: PiBrain()
            )
        } catch let error as PiBrain.PiBrainError {
            throw XCTSkip("pi rejected the prompt (provider auth not configured?): \(error.localizedDescription)")
        } catch let error as CocoaError {
            throw XCTSkip("pi could not be launched: \(error.localizedDescription)")
        }

        let events = try await store.loadEvents(forSession: "pi-live-1")
        XCTAssertEqual(events.first?.type, .userMessage)
        XCTAssertTrue(
            events.contains { $0.type == .assistantMessage && ($0.content ?? "").contains("keg-pi-e2e-ok") },
            "expected pi's reply in the log, got: \(events.map(\.type))"
        )
    }
}
