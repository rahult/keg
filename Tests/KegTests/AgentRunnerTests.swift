import XCTest
@testable import Keg

final class AgentRunnerTests: XCTestCase {
    var store: SessionStore!
    var workspace: AgentWorkspace!
    var baseDirectory: URL!

    override func setUp() async throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-agent-runner-tests-\(UUID().uuidString)", isDirectory: true)
        store = try SessionStore(sessionsDirectory: baseDirectory.appendingPathComponent("sessions"))
        workspace = AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private struct FakeBrain: AgentBrain {
        let events: [SessionEvent]
        let error: Error?

        init(events: [SessionEvent], error: Error? = nil) {
            self.events = events
            self.error = error
        }

        func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private struct FakeBrainError: Error {}

    private func makeRecipe() -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: "/tmp/keg-test-repo", branch: "main", commit: "abc123"),
            kegYAML: "name: demo\nservices:\n  web:\n    image: nginx:alpine\n"
        )
    }

    private func makeSession(id: String) async throws {
        let now = Date()
        try await store.saveSession(Session(
            id: id, type: "agent", agentId: "agent-1", agentVersion: 1,
            environmentId: "env-1", status: .running, createdAt: now, updatedAt: now
        ))
    }

    // MARK: -

    func testRunAppendsPromptThenBrainEventsInOrder() async throws {
        try await makeSession(id: "sess-1")
        let brain = FakeBrain(events: [
            SessionEvent(type: .assistantMessage, content: "working"),
            SessionEvent(type: .toolUse, toolUse: ToolUseEvent(tool: "read", toolInput: [:], toolUseId: "tu-1")),
            SessionEvent(type: .toolResult, toolResult: ToolResultEvent(toolUseId: "tu-1", toolOutput: AnyCodable("done"))),
        ])
        let runner = AgentRunner(store: store, workspace: workspace)

        try await runner.run(sessionId: "sess-1", recipe: makeRecipe(), prompt: "fix the bug", brain: brain)

        let events = try await store.loadEvents(forSession: "sess-1")
        XCTAssertEqual(events.map(\.type), [
            .userMessage, .assistantMessage, .toolUse, .toolResult,
        ])
        XCTAssertEqual(events.first?.content, "fix the bug")
        XCTAssertEqual(events[1].content, "working")
    }

    func testRunMaterializesWorkspaceFromRecipe() async throws {
        try await makeSession(id: "sess-2")
        let runner = AgentRunner(store: store, workspace: workspace)
        let recipe = makeRecipe()

        try await runner.run(sessionId: "sess-2", recipe: recipe, prompt: "hi", brain: FakeBrain(events: []))

        let path = await workspace.workspacePath(sessionId: "sess-2")
        let written = try String(contentsOf: path.appendingPathComponent("keg.yaml"), encoding: .utf8)
        XCTAssertEqual(written, recipe.kegYAML)
    }

    func testRunThrowsWhenSessionDoesNotExist() async throws {
        let runner = AgentRunner(store: store, workspace: workspace)
        do {
            try await runner.run(sessionId: "nope", recipe: makeRecipe(), prompt: "hi", brain: FakeBrain(events: []))
            XCTFail("expected error")
        } catch AgentRunner.RunnerError.sessionNotFound(let id) {
            XCTAssertEqual(id, "nope")
        }
    }

    func testRunPropagatesBrainFailureAfterAppendingEvents() async throws {
        try await makeSession(id: "sess-3")
        let brain = FakeBrain(
            events: [SessionEvent(type: .assistantMessage, content: "partial")],
            error: FakeBrainError()
        )
        let runner = AgentRunner(store: store, workspace: workspace)

        do {
            try await runner.run(sessionId: "sess-3", recipe: makeRecipe(), prompt: "go", brain: brain)
            XCTFail("expected error")
        } catch is FakeBrainError {
            // expected
        }

        let events = try await store.loadEvents(forSession: "sess-3")
        XCTAssertEqual(events.map(\.content), ["go", "partial"])
    }

    func testRunRejectsInvalidRecipeBeforeInvokingBrain() async throws {
        try await makeSession(id: "sess-4")
        var bad = makeRecipe()
        bad.kegYAML = "::: broken :::"
        let runner = AgentRunner(store: store, workspace: workspace)

        do {
            try await runner.run(sessionId: "sess-4", recipe: bad, prompt: "go", brain: FakeBrain(events: []))
            XCTFail("expected error")
        } catch WorldRecipeError.invalidKegYAML {
            // expected
        }

        let events = try await store.loadEvents(forSession: "sess-4")
        XCTAssertTrue(events.isEmpty)
    }
}
