import XCTest
@testable import Keg

@MainActor
final class SessionInboxVMLocalTests: XCTestCase {
    var directory: URL!
    var store: SessionStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-inbox-vm-local-\(UUID().uuidString)", isDirectory: true)
        store = try SessionStore(sessionsDirectory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSession(id: String, status: SessionStatus) -> Session {
        let now = Date()
        return Session(
            id: id, type: "agent", agentId: "agent-1", agentVersion: 1,
            environmentId: "env-1", status: status, createdAt: now, updatedAt: now
        )
    }

    func testLocalSessionsBecomeInboxItems() async throws {
        try await store.saveSession(makeSession(id: "local-1", status: .running))
        try await store.saveSession(makeSession(id: "local-2", status: .completed))
        let vm = SessionInboxVM()

        await vm.loadLocal(store: store)

        XCTAssertEqual(vm.items.count, 2)
        let first = try XCTUnwrap(vm.items.first { $0.sessionID == "local-1" })
        XCTAssertEqual(first.agentName, "Local")
        XCTAssertEqual(first.remoteStatus, .running)
        XCTAssertFalse(vm.isLoading)
    }

    func testLocalLoadWithNoSessionsYieldsEmptyItems() async throws {
        let vm = SessionInboxVM()

        await vm.loadLocal(store: store)

        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertNil(vm.error)
    }

    func testLoadWithNilClientFallsBackToLocalSessions() async throws {
        try await store.saveSession(makeSession(id: "local-3", status: .pending))
        let vm = SessionInboxVM()

        await vm.load(client: nil, store: store)

        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.sessionID, "local-3")
    }
}
