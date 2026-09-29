import XCTest
@testable import Keg

final class SessionBundleTests: XCTestCase {
    var store: SessionStore!
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-session-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        store = try SessionStore(sessionsDirectory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRecipe() -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: "https://github.com/example/demo.git", branch: "main", commit: "abc123"),
            kegYAML: "name: demo\nservices:\n  web:\n    image: nginx:alpine\n",
            env: ["NODE_ENV": "test"],
            databases: []
        )
    }

    private func makeSession(id: String) async throws {
        let now = Date()
        try await store.saveSession(Session(
            id: id, type: "agent", agentId: "agent-1", agentVersion: 1,
            environmentId: "env-1", status: .running, createdAt: now, updatedAt: now
        ))
    }

    // MARK: - Export / import round-trip

    func testExportImportRoundTrip() async throws {
        let sessionId = "sess-1"
        try await makeSession(id: sessionId)

        let events = [
            SessionEvent.userMessage("fix the bug"),
            SessionEvent(type: .assistantMessage, content: "on it"),
            SessionEvent(type: .toolUse, toolUse: ToolUseEvent(tool: "read", toolInput: ["path": AnyCodable("main.swift")], toolUseId: "tu-1")),
        ]
        try await store.appendEvents(events, toSession: sessionId)

        let recipe = makeRecipe()
        let bundleURL = directory.appendingPathComponent("out.kegsession")
        try await SessionBundle.export(sessionId: sessionId, recipe: recipe, store: store, to: bundleURL)

        let bundle = try await SessionBundle.import(from: bundleURL)
        XCTAssertEqual(bundle.recipe, recipe)
        XCTAssertEqual(bundle.events.map(\.type), events.map(\.type))
        XCTAssertEqual(bundle.events.first?.content, "fix the bug")
        XCTAssertEqual(bundle.events.last?.toolUse?.tool, "read")
    }

    func testImportReplaysEventsInAppendOrder() async throws {
        let sessionId = "sess-2"
        try await makeSession(id: sessionId)
        let events = (0..<25).map { SessionEvent.userMessage("msg-\($0)") }
        try await store.appendEvents(events, toSession: sessionId)

        let bundleURL = directory.appendingPathComponent("out.kegsession")
        try await SessionBundle.export(sessionId: sessionId, recipe: makeRecipe(), store: store, to: bundleURL)
        let bundle = try await SessionBundle.import(from: bundleURL)

        XCTAssertEqual(bundle.events.map(\.content), (0..<25).map { "msg-\($0)" })
    }

    func testExportThrowsForUnknownSession() async throws {
        let bundleURL = directory.appendingPathComponent("out.kegsession")
        do {
            try await SessionBundle.export(sessionId: "nope", recipe: makeRecipe(), store: store, to: bundleURL)
            XCTFail("expected .sessionNotFound")
        } catch let error as SessionBundle.BundleError {
            guard case .sessionNotFound(let id) = error else {
                return XCTFail("expected .sessionNotFound, got \(error)")
            }
            XCTAssertEqual(id, "nope")
        }
    }

    func testBundleFileIsSelfContainedJSON() async throws {
        let sessionId = "sess-3"
        try await makeSession(id: sessionId)
        try await store.appendEvent(.userMessage("hello"), toSession: sessionId)

        let bundleURL = directory.appendingPathComponent("out.kegsession")
        try await SessionBundle.export(sessionId: sessionId, recipe: makeRecipe(), store: store, to: bundleURL)

        let data = try Data(contentsOf: bundleURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["recipe"])
        XCTAssertNotNil(json?["events"])
    }
}
