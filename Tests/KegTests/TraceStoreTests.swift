import XCTest
@testable import Keg
import KegCLICore

/// Trace-store tests: the pure SessionEvent→row mapper, SQL literal
/// escaping, statement shapes against a scripted transport, JSONEachRow
/// decoding, and the failure-containment guarantee (dead ClickHouse never
/// throws into the session path). No real sockets — the transport is the seam.
final class TraceStoreTests: XCTestCase {

    // MARK: - Scripted transport

    final class ScriptedTransport: TraceTransport, @unchecked Sendable {
        struct Call: Equatable {
            let query: String
            let host: String
            let port: Int
        }

        private(set) var calls: [Call] = []
        var handler: (String) throws -> String

        init(handler: @escaping (String) throws -> String = { _ in "" }) {
            self.handler = handler
        }

        func execute(query: String, host: String, port: Int) async throws -> String {
            calls.append(Call(query: query, host: host, port: port))
            return try handler(query)
        }
    }

    struct Boom: Error {}

    /// Handler that fails every call — a total ClickHouse outage.
    private func deadHandler(query: String) throws -> String { throw Boom() }

    private func makeStore(
        transport: ScriptedTransport,
        port: Int = KegDatabaseEngine.clickhouse.defaultPort
    ) -> TraceStore {
        TraceStore(host: "127.0.0.1", port: port, transport: transport)
    }

    private struct EmptyBrain: AgentBrain {
        func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // MARK: - Mapper: all four event types

    func testMapperUserMessage() {
        let row = TraceRowMapper().fields(for: .userMessage("hello keg"))
        XCTAssertEqual(row.eventType, "user")
        XCTAssertEqual(row.input, "hello keg")
        XCTAssertEqual(row.output, "")
        XCTAssertEqual(row.isError, 0)
    }

    func testMapperAssistantMessage() {
        let row = TraceRowMapper().fields(for: SessionEvent(type: .assistantMessage, content: "working on it"))
        XCTAssertEqual(row.eventType, "assistant")
        XCTAssertEqual(row.output, "working on it")
        XCTAssertEqual(row.input, "")
    }

    func testMapperToolUseEncodesInputAsSortedJSON() {
        let event = SessionEvent(
            type: .toolUse,
            toolUse: ToolUseEvent(
                tool: "run_container",
                toolInput: ["image": AnyCodable("nginx"), "name": AnyCodable("web")],
                toolUseId: "tu-1"
            )
        )
        let row = TraceRowMapper().fields(for: event)
        XCTAssertEqual(row.eventType, "tool")
        XCTAssertEqual(row.name, "run_container")
        XCTAssertEqual(row.toolUseId, "tu-1")
        // Sorted keys: image before name, deterministically.
        XCTAssertEqual(row.input, #"{"image":"nginx","name":"web"}"#)
    }

    func testMapperToolResultWithError() {
        let event = SessionEvent(
            type: .toolResult,
            toolResult: ToolResultEvent(toolUseId: "tu-1", toolOutput: AnyCodable("boom"), isError: true)
        )
        let row = TraceRowMapper().fields(for: event)
        XCTAssertEqual(row.eventType, "tool_result")
        XCTAssertEqual(row.toolUseId, "tu-1")
        XCTAssertEqual(row.output, "\"boom\"")
        XCTAssertEqual(row.isError, 1)
    }

    func testMapperToolResultSuccessIsNotError() {
        let event = SessionEvent(
            type: .toolResult,
            toolResult: ToolResultEvent(toolUseId: "tu-2", toolOutput: AnyCodable("ok"), isError: nil)
        )
        XCTAssertEqual(TraceRowMapper().fields(for: event).isError, 0)
    }

    func testMapperSkipsUntracedEventTypes() {
        let error = TraceRowMapper().fields(for: SessionEvent(type: .error, content: "x"))
        let status = TraceRowMapper().fields(for: SessionEvent(type: .statusUpdate, status: .running))
        XCTAssertEqual(error.eventType, "")
        XCTAssertEqual(status.eventType, "")
    }

    func testMapperUsesEventTimestampWhenPresent() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let event = SessionEvent(type: .userMessage, content: "hi", timestamp: stamp)
        XCTAssertEqual(TraceRowMapper().fields(for: event).createdAt, stamp)
    }

    // MARK: - Name truncation

    func testNameTruncation() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(TraceRowMapper.name(from: long).count, 80)
        XCTAssertEqual(TraceRowMapper.name(from: "short"), "short")
        XCTAssertEqual(TraceRowMapper.name(from: "line one\nline two"), "line one line two")
        XCTAssertEqual(TraceRowMapper.name(from: "  padded  "), "padded")
    }

    // MARK: - SQL escaping

    func testLiteralEscapesSingleQuotes() {
        XCTAssertEqual(TraceSQL.literal("o'brien"), "'o''brien'")
    }

    func testLiteralEscapesBackslashes() {
        // ClickHouse parses backslash escapes in string literals by default.
        XCTAssertEqual(TraceSQL.literal(#"C:\temp"#), #"'C:\\temp'"#)
    }

    func testLiteralEscapesBothTogether() {
        XCTAssertEqual(TraceSQL.literal(#"it's C:\x"#), #"'it''s C:\\x'"#)
    }

    func testTimestampFormatUTC() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TraceSQL.timestamp(date), "1970-01-01 00:00:00.000")
    }

    // MARK: - Statement shapes (scripted transport)

    func testEnsureSchemaStatements() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        let sessionStore = try SessionStore(sessionsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-trace-tests-\(UUID().uuidString)"))
        await store.backfill(store: sessionStore)
        XCTAssertTrue(transport.calls.contains { $0.query == TraceSQL.createDatabase })
        XCTAssertTrue(transport.calls.contains { $0.query == TraceSQL.createTable })
    }

    func testBackfillSkipsExistingTracesAndImportsMissingOnes() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-trace-backfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionStore = try SessionStore(sessionsDirectory: base.appendingPathComponent("sessions"))

        let transport = ScriptedTransport { query in
            if query.hasPrefix("SELECT count()") && query.contains("'existing-sess'") { return "3\n" }
            if query.hasPrefix("SELECT count()") { return "0\n" }
            return ""
        }

        let now = Date()
        for (id, status) in [("existing-sess", SessionStatus.completed), ("fresh-sess", SessionStatus.running)] {
            try await sessionStore.saveSession(Session(
                id: id, type: "agent", agentId: "a", agentVersion: 1,
                environmentId: "env", status: status, createdAt: now, updatedAt: now
            ))
        }
        try await sessionStore.appendEvent(.userMessage("build me a thing"), toSession: "fresh-sess")
        try await sessionStore.appendEvent(SessionEvent(
            type: .toolUse,
            toolUse: ToolUseEvent(tool: "grep", toolInput: ["pattern": AnyCodable("todo")], toolUseId: "t1")
        ), toSession: "fresh-sess")

        let store = makeStore(transport: transport)
        await store.backfill(store: sessionStore)

        let inserts = transport.calls.filter { $0.query.hasPrefix("INSERT INTO") }
        // Only the fresh trace is inserted: 1 summary row + 2 events.
        XCTAssertEqual(inserts.count, 3)
        XCTAssertTrue(inserts.allSatisfy { $0.query.contains("'fresh-sess'") })
        XCTAssertFalse(inserts.contains { $0.query.contains("'existing-sess'") })
        // Summary row first, with the first user content as its name.
        XCTAssertTrue(inserts[0].query.contains("'trace'"))
        XCTAssertTrue(inserts[0].query.contains("'build me a thing'"))
        XCTAssertTrue(inserts[0].query.contains("'running'"))
        // Events are 1-based and preserve order.
        XCTAssertTrue(inserts[1].query.contains(" 1, 'user'"))
        XCTAssertTrue(inserts[2].query.contains(" 2, 'tool'"))
        // Tool input is JSON-encoded inside the statement.
        XCTAssertTrue(inserts[2].query.contains(#"{"pattern":"todo"}"#))
    }

    func testIngestLiveEventsAllocateIndicesMonotonically() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-trace-ingest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionStore = try SessionStore(sessionsDirectory: base.appendingPathComponent("sessions"))
        let service = AgentService(store: sessionStore, makeBrain: { _ in EmptyBrain() })

        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.startIngest(service: service)

        let now = Date()
        try await service.createSession(id: "live-sess", agentId: "a", environmentId: "env")
        try await sessionStore.saveSession(Session(
            id: "live-sess", type: "agent", agentId: "a", agentVersion: 1,
            environmentId: "env", status: .running, createdAt: now, updatedAt: now
        ))
        try await sessionStore.appendEvent(.userMessage("do the thing"), toSession: "live-sess")
        try await sessionStore.appendEvent(SessionEvent(type: .assistantMessage, content: "on it"), toSession: "live-sess")

        // Wait for the ingest loop to drain every update.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let events = transport.calls.filter { $0.query.hasPrefix("INSERT INTO") && $0.query.contains(", 'user'") }.count
            let assistants = transport.calls.filter { $0.query.hasPrefix("INSERT INTO") && $0.query.contains(", 'assistant'") }.count
            if events >= 1, assistants >= 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Events are 1-based, in order; the second event reuses the counter
        // instead of re-querying max(event_index).
        XCTAssertTrue(transport.calls.contains { $0.query.contains(" 1, 'user'") })
        XCTAssertTrue(transport.calls.contains { $0.query.contains(" 2, 'assistant'") })
        XCTAssertEqual(transport.calls.filter { $0.query.contains("max(event_index)") }.count, 1)
        XCTAssertTrue(transport.calls.contains { $0.query == TraceSQL.createTable })
        // Row 0 is upserted (delete+insert) on session saves and first user
        // message — all carrying the trace type.
        let rowZeroInserts = transport.calls.filter {
            $0.query.hasPrefix("INSERT INTO") && $0.query.contains(", 'trace'")
        }
        XCTAssertFalse(rowZeroInserts.isEmpty)
        XCTAssertEqual(
            transport.calls.filter { $0.query.hasPrefix("ALTER TABLE") }.count,
            rowZeroInserts.count,
            "every row-0 upsert is a paired delete+insert"
        )
    }

    func testQueryStatementsAndDecoding() async throws {
        let transport = ScriptedTransport { query in
            if query.hasPrefix("SELECT trace_id") {
                return """
                    {"trace_id":"s1","name":"first task","session_status":"completed","event_count":2,"started_at":"2026-09-30 10:00:00.000","last_event_at":"2026-09-30 10:05:00.500"}
                    {"trace_id":"s2","name":"","session_status":"running","event_count":0,"started_at":"2026-10-01 09:00:00.000","last_event_at":"2026-10-01 09:00:00.000"}

                    """
            }
            return """
                {"event_index":0,"event_type":"trace","name":"first task","tool_use_id":"","input":"","output":"","is_error":0,"created_at":"2026-09-30 10:00:00.000"}
                {"event_index":1,"event_type":"user","name":"","tool_use_id":"","input":"hi","output":"","is_error":0,"created_at":"2026-09-30 10:01:00.000"}

                """
        }
        let store = makeStore(transport: transport)

        let summaries = try await store.listTraces()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].traceId, "s1")
        XCTAssertEqual(summaries[0].name, "first task")
        XCTAssertEqual(summaries[0].sessionStatus, "completed")
        XCTAssertEqual(summaries[0].eventCount, 2)
        // 2026-09-30 10:05:00.500 UTC
        XCTAssertEqual(summaries[0].lastEventAt.timeIntervalSince1970, 1_790_762_700.5, accuracy: 0.001)
        XCTAssertEqual(summaries[1].sessionStatus, "running")

        let events = try await store.traceEvents(traceId: "s1")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].eventType, "trace")
        XCTAssertEqual(events[1].eventType, "user")
        XCTAssertEqual(events[1].input, "hi")

        XCTAssertEqual(transport.calls[0].query, TraceSQL.listTraces)
        XCTAssertEqual(transport.calls[1].query, TraceSQL.traceEvents(traceId: "s1"))
        XCTAssertTrue(transport.calls[0].query.contains("FORMAT JSONEachRow"))
        XCTAssertTrue(transport.calls[1].query.contains("FORMAT JSONEachRow"))
        // The trace id is literal-quoted (injection-safe).
        XCTAssertTrue(transport.calls[1].query.contains("trace_id = 's1'"))
    }

    // MARK: - Failure containment

    func testIngestNeverThrowsWithDeadClickHouse() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-trace-dead-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionStore = try SessionStore(sessionsDirectory: base.appendingPathComponent("sessions"))
        let service = AgentService(store: sessionStore, makeBrain: { _ in EmptyBrain() })

        let transport = ScriptedTransport(handler: deadHandler)
        let store = TraceStore(host: "127.0.0.1", port: 1, transport: transport)
        await store.startIngest(service: service)

        _ = try await service.createSession(id: "dead-sess", agentId: "a", environmentId: "env")
        try await sessionStore.appendEvent(.userMessage("still works?"), toSession: "dead-sess")
        try await sessionStore.appendEvent(SessionEvent(type: .assistantMessage, content: "yes"), toSession: "dead-sess")

        // Give the ingest loop time to hit the dead transport for every update.
        try await Task.sleep(nanoseconds: 500_000_000)

        // The appends completed without throwing — the store absorbed every
        // failure — and the log itself is intact.
        let events = try await service.loadEvents(forSession: "dead-sess")
        XCTAssertEqual(events.count, 2)
        XCTAssertGreaterThan(transport.calls.count, 0)
    }

    func testBackfillNeverThrowsWithDeadClickHouse() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-trace-dead-backfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessionStore = try SessionStore(sessionsDirectory: base.appendingPathComponent("sessions"))
        let now = Date()
        try await sessionStore.saveSession(Session(
            id: "b1", type: "agent", agentId: "a", agentVersion: 1,
            environmentId: "env", status: .completed, createdAt: now, updatedAt: now
        ))

        let transport = ScriptedTransport(handler: deadHandler)
        let store = TraceStore(host: "127.0.0.1", port: 1, transport: transport)
        await store.backfill(store: sessionStore) // must not throw
        XCTAssertGreaterThan(transport.calls.count, 0)
    }

    func testDefaultPortComesFromClickHouseEngine() async {
        let transport = ScriptedTransport()
        let store = TraceStore(transport: transport)
        _ = try? await store.listTraces()
        XCTAssertTrue(transport.calls.allSatisfy { $0.port == KegDatabaseEngine.clickhouse.defaultPort })
        XCTAssertTrue(transport.calls.allSatisfy { $0.host == "127.0.0.1" })
    }
}
