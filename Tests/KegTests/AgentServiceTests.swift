import XCTest
@testable import Keg

final class AgentServiceTests: XCTestCase {
    var baseDirectory: URL!
    var store: SessionStore!

    override func setUp() async throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-agent-service-tests-\(UUID().uuidString)", isDirectory: true)
        store = try SessionStore(sessionsDirectory: baseDirectory.appendingPathComponent("sessions"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private struct FakeBrain: AgentBrain {
        let events: [SessionEvent]
        func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private final class Recorder: @unchecked Sendable {
        var provisioned: [String] = []
        var brainKinds: [AgentService.BrainKind] = []
    }

    private func makeService(_ recorder: Recorder) -> AgentService {
        let provisioner = AgentEnvironmentProvisioner(
            workspace: AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces")),
            up: { _, _ in recorder.provisioned.append("up"); return ["kegagent-x-web-1"] },
            down: { _, _ in }
        )
        return AgentService(
            store: store,
            workspace: AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces")),
            provisioner: provisioner,
            makeBrain: { kind in
                recorder.brainKinds.append(kind)
                return FakeBrain(events: [SessionEvent(type: .assistantMessage, content: "done")])
            }
        )
    }

    private func makeRecipe() -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: "/tmp/keg-test-repo", branch: "main", commit: "abc123"),
            kegYAML: "name: demo\nservices:\n  web:\n    image: nginx:alpine\n"
        )
    }

    // MARK: -

    func testCreateSessionPersistsPendingSession() async throws {
        let service = makeService(Recorder())

        let session = try await service.createSession(id: "s-1", agentId: "agent-1", environmentId: "env-1")

        XCTAssertEqual(session.status, .pending)
        let persisted = try await store.loadSession(id: "s-1")
        XCTAssertEqual(persisted?.status, .pending)
    }

    func testRunTurnProvisionsRunsAndCompletes() async throws {
        let recorder = Recorder()
        let service = makeService(recorder)
        try await service.createSession(id: "s-2", agentId: "a", environmentId: "e")

        try await service.runTurn(sessionId: "s-2", recipe: makeRecipe(), prompt: "go", brain: .pi)

        XCTAssertEqual(recorder.provisioned, ["up"])
        XCTAssertEqual(recorder.brainKinds, [.pi])
        let events = try await store.loadEvents(forSession: "s-2")
        XCTAssertEqual(events.map(\.type), [.userMessage, .assistantMessage])
        let finalStatus = try await store.loadSession(id: "s-2")?.status
        XCTAssertEqual(finalStatus, .completed)
    }

    func testRunTurnFailureMarksSessionFailed() async throws {
        struct TurnFailure: Error {}
        final class FailingBrain: AgentBrain, @unchecked Sendable {
            func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: TurnFailure()) }
            }
        }
        let recorder = Recorder()
        let service = AgentService(
            store: store,
            workspace: AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces")),
            provisioner: AgentEnvironmentProvisioner(
                workspace: AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces")),
                up: { _, _ in [] },
                down: { _, _ in }
            ),
            makeBrain: { _ in FailingBrain() }
        )
        try await service.createSession(id: "s-3", agentId: "a", environmentId: "e")

        do {
            try await service.runTurn(sessionId: "s-3", recipe: makeRecipe(), prompt: "go", brain: .cooper)
            XCTFail("expected error")
        } catch is TurnFailure {
            // expected
        }

        let failedStatus = try await store.loadSession(id: "s-3")?.status
        XCTAssertEqual(failedStatus, .failed)
    }

    func testRunTurnThrowsForUnknownSession() async throws {
        let service = makeService(Recorder())
        do {
            try await service.runTurn(sessionId: "nope", recipe: makeRecipe(), prompt: "go", brain: .pi)
            XCTFail("expected error")
        } catch AgentService.ServiceError.sessionNotFound(let id) {
            XCTAssertEqual(id, "nope")
        }
    }
}
