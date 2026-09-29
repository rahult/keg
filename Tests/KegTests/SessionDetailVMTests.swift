import XCTest
@testable import Keg

@MainActor
final class SessionDetailVMTests: XCTestCase {
    var directory: URL!
    var store: SessionStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-session-detail-vm-\(UUID().uuidString)", isDirectory: true)
        store = try SessionStore(sessionsDirectory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSession(id: String = "vm-sess-1") -> Session {
        let now = Date()
        return Session(
            id: id, type: "agent", agentId: "agent-1", agentVersion: 1,
            environmentId: "env-1", status: .running, createdAt: now, updatedAt: now
        )
    }

    func testLoadLocalEventsPopulatesFromSessionLog() async throws {
        let session = makeSession()
        try await store.saveSession(session)
        try await store.appendEvents([
            .userMessage("fix it"),
            SessionEvent(type: .assistantMessage, content: "on it"),
            SessionEvent(type: .toolUse, toolUse: ToolUseEvent(tool: "read", toolInput: [:], toolUseId: "t1")),
        ], toSession: session.id)

        let vm = SessionDetailVM(session: session)
        await vm.loadLocalEvents(store: store)

        XCTAssertEqual(vm.events.map(\.type), [.userMessage, .assistantMessage, .toolUse])
        XCTAssertEqual(vm.events.first?.content, "fix it")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
    }

    func testLoadLocalEventsEmptyForUnknownSession() async throws {
        let vm = SessionDetailVM(session: makeSession(id: "unknown"))

        await vm.loadLocalEvents(store: store)

        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertNil(vm.error)
    }
}
