import Foundation
import KegCLICore

// MARK: - Trace Store
//
// Mirrors agent-session event logs (append-only JSONL on disk) into the
// shared ClickHouse container (`kegdb-clickhouse`, HTTP on loopback) so a
// trace viewer can query them with SQL. Every write is best-effort: a
// ClickHouse outage must never throw into the agent/session path — failures
// are caught at every boundary and logged to ~/.keg/cooper/debug.log.

// MARK: - Row model

/// One row of `trace_events` (also the INSERT payload shape).
struct TraceRow: Equatable {
    var traceId: String
    var eventIndex: UInt32
    var eventType: String
    var name: String
    var toolUseId: String
    var input: String
    var output: String
    var isError: UInt8
    var model: String
    var sessionStatus: String
    var createdAt: Date
}

/// Aggregate view of one trace, for the viewer's list screen.
struct TraceSummary: Equatable, Identifiable {
    var traceId: String
    var name: String
    var sessionStatus: String
    var eventCount: Int
    var startedAt: Date
    var lastEventAt: Date

    var id: String { traceId }
}

/// One decoded event row, ordered by event_index.
struct TraceEventRow: Equatable, Identifiable {
    var eventIndex: UInt32
    var eventType: String
    var name: String
    var toolUseId: String
    var input: String
    var output: String
    var isError: UInt8
    var createdAt: Date

    var id: UInt32 { eventIndex }
}

// MARK: - Pure mapping (unit-tested, no sockets)

/// Maps `SessionEvent` values onto trace row fields. Pure so tests need no
/// ClickHouse and no SessionStore.
struct TraceRowMapper {
    /// Column payload for one session event (row 0's summary fields are
    /// filled in by the store, not the mapper).
    func fields(for event: SessionEvent) -> TraceRow {
        var row = TraceRow(
            traceId: "",
            eventIndex: 0,
            eventType: "",
            name: "",
            toolUseId: "",
            input: "",
            output: "",
            isError: 0,
            model: "",
            sessionStatus: "",
            createdAt: event.timestamp ?? Date()
        )
        switch event.type {
        case .userMessage:
            row.eventType = "user"
            row.input = event.content ?? ""
        case .assistantMessage:
            row.eventType = "assistant"
            row.output = event.content ?? ""
        case .toolUse:
            row.eventType = "tool"
            let tool = event.toolUse
            row.name = tool?.tool ?? ""
            row.toolUseId = tool?.toolUseId ?? ""
            if let input = tool?.toolInput {
                row.input = Self.jsonString(input)
            }
        case .toolResult:
            row.eventType = "tool_result"
            let result = event.toolResult
            row.toolUseId = result?.toolUseId ?? ""
            if let output = result?.toolOutput {
                row.output = Self.jsonString(output)
            }
            row.isError = (result?.isError ?? false) ? 1 : 0
        case .error, .statusUpdate:
            // Not traced: status rides the row-0 summary, errors surface
            // as failed session status.
            row.eventType = ""
        }
        return row
    }

    /// Trace display name: first user content, flattened and truncated.
    static func name(from content: String) -> String {
        let flattened = content
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 80 else { return trimmed }
        return String(trimmed.prefix(80))
    }

    /// Deterministic JSON for AnyCodable payloads (sorted keys so identical
    /// inputs always produce identical SQL).
    static func jsonString(_ value: AnyCodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    static func jsonString(_ value: [String: AnyCodable]) -> String {
        jsonString(AnyCodable(value.mapValues { $0.value }))
    }
}

// MARK: - SQL (pure statement builders)

/// Builds the exact ClickHouse statements. Kept free of any I/O so a
/// scripted transport can assert statement text in tests.
enum TraceSQL {
    static let database = "kegtraces"
    static let table = "trace_events"

    static let createDatabase = "CREATE DATABASE IF NOT EXISTS \(database)"

    static let createTable = """
        CREATE TABLE IF NOT EXISTS \(database).\(table) (
            trace_id String,
            event_index UInt32,
            event_type String,
            name String,
            tool_use_id String,
            input String,
            output String,
            is_error UInt8,
            model String,
            session_status String,
            created_at DateTime64(3)
        ) ENGINE = MergeTree
        ORDER BY (trace_id, event_index)
        """

    /// Single-quote literal escaping. ClickHouse parses backslash escapes
    /// inside string literals by default, so both are doubled.
    static func literal(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    /// ClickHouse DateTime64(3) literal: UTC `yyyy-MM-dd HH:mm:ss.SSS`.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            c.year ?? 1970, c.month ?? 1, c.day ?? 1,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            (c.nanosecond ?? 0) / 1_000_000
        )
    }

    static func insert(_ row: TraceRow) -> String {
        """
        INSERT INTO \(database).\(table) \
        (trace_id, event_index, event_type, name, tool_use_id, input, output, is_error, model, session_status, created_at) \
        VALUES (\(literal(row.traceId)), \(row.eventIndex), \(literal(row.eventType)), \(literal(row.name)), \
        \(literal(row.toolUseId)), \(literal(row.input)), \(literal(row.output)), \(row.isError), \
        \(literal(row.model)), \(literal(row.sessionStatus)), \(literal(timestamp(row.createdAt)))
        )
        """
    }

    /// Row-0 summary updates (status transitions, first-name arrival) are
    /// delete+insert: MergeTree has no upsert, and lightweight deletes are
    /// made synchronous so the replacement insert can't race the mutation.
    static func deleteRow(traceId: String, eventIndex: UInt32) -> String {
        """
        ALTER TABLE \(database).\(table) DELETE \
        WHERE trace_id = \(literal(traceId)) AND event_index = \(eventIndex) SETTINGS mutations_sync = 1
        """
    }

    static func maxEventIndex(traceId: String) -> String {
        "SELECT max(event_index) FROM \(database).\(table) WHERE trace_id = \(literal(traceId))"
    }

    static func rowCount(traceId: String) -> String {
        "SELECT count() FROM \(database).\(table) WHERE trace_id = \(literal(traceId))"
    }

    /// `output_format_json_quote_64bit_integers = 0`: without it ClickHouse
    /// JSONEachRow emits UInt64 counts as *strings* ("event_count":"1"),
    /// which Codable won't decode into Int and would silently drop rows.
    static let listTraces = """
        SELECT trace_id, \
        max(if(event_type = 'trace', name, '')) AS name, \
        max(if(event_type = 'trace', session_status, '')) AS session_status, \
        countIf(event_type != 'trace') AS event_count, \
        min(created_at) AS started_at, \
        max(created_at) AS last_event_at \
        FROM \(database).\(table) GROUP BY trace_id ORDER BY started_at DESC \
        SETTINGS output_format_json_quote_64bit_integers = 0 FORMAT JSONEachRow
        """

    static func traceEvents(traceId: String) -> String {
        """
        SELECT event_index, event_type, name, tool_use_id, input, output, is_error, created_at \
        FROM \(database).\(table) WHERE trace_id = \(literal(traceId)) \
        ORDER BY event_index FORMAT JSONEachRow
        """
    }
}

// MARK: - Transport (injectable seam)

enum TraceStoreError: Error, LocalizedError {
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "ClickHouse HTTP \(code): \(String(body.prefix(200)))"
        }
    }
}

/// One SQL statement → raw response body. Seamed so tests can script
/// responses and assert exact statement text without a socket.
protocol TraceTransport: Sendable {
    func execute(query: String, host: String, port: Int) async throws -> String
}

/// Plain URLSession POST; the statement travels in the body, which is the
/// ClickHouse HTTP interface's natural shape (no query-string size limits).
struct URLSessionTraceTransport: TraceTransport {
    func execute(query: String, host: String, port: Int) async throws -> String {
        // ClickHouse's ValuesBlockInputFormat rejects a trailing newline
        // after the final `)` (SYNTAX_ERROR pointing at the last column —
        // verified live): the statement must reach the server trimmed.
        let statement = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(statement.utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TraceStoreError.httpError(code, String(decoding: data, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Store

/// ClickHouse-backed mirror of the session logs. An actor: the ingest
/// loop, backfill, and queries can all run concurrently while the
/// per-trace event-index counters stay race-free for the single writer.
actor TraceStore {
    private let host: String
    private let port: Int
    private let transport: any TraceTransport
    private let mapper = TraceRowMapper()

    /// event_index allocation: events are 1-based (row 0 is the synthetic
    /// summary), seeded lazily from `max(event_index)` on first sight of a
    /// trace so a restart continues where the last run left off.
    private var nextEventIndex: [String: UInt32] = [:]
    /// First user content seen per trace this run — becomes the row-0 name.
    private var firstUserContent: [String: String] = [:]

    private var ingestTask: Task<Void, Never>?

    init(
        host: String = "127.0.0.1",
        port: Int = KegDatabaseEngine.clickhouse.defaultPort,
        transport: any TraceTransport = URLSessionTraceTransport()
    ) {
        self.host = host
        self.port = port
        self.transport = transport
    }

    deinit {
        ingestTask?.cancel()
    }

    // MARK: - Transport helpers

    private func query(_ sql: String) async throws -> String {
        try await transport.execute(query: sql, host: host, port: port)
    }

    /// Best-effort schema creation; throws so callers can log, never to
    /// propagate into the session path.
    private func ensureSchema() async throws {
        _ = try await query(TraceSQL.createDatabase)
        _ = try await query(TraceSQL.createTable)
    }

    // MARK: - Ingest

    /// Subscribe to the agent service's live projection and mirror every
    /// write into ClickHouse. The stream runs until cancelled; every
    /// failure inside the loop is caught and logged — a dead ClickHouse
    /// degrades traces, never sessions.
    func startIngest(service: AgentService) {
        ingestTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureSchema()
            } catch {
                Self.log("trace schema init failed (traces disabled): \(error.localizedDescription)")
            }
            let stream = await service.updates()
            for await update in stream {
                do {
                    switch update {
                    case .event(let sessionId, let event):
                        try await self.ingestEvent(sessionId: sessionId, event: event)
                    case .sessionSaved(let session):
                        try await self.upsertTraceSummary(session: session)
                    }
                } catch {
                    Self.log("trace ingest failed for session: \(error.localizedDescription)")
                }
            }
        }
        ingestTask = task
    }

    /// Backfill traces for sessions that already exist on disk. Skips any
    /// trace ClickHouse already has rows for. Called once at wire-up;
    /// failures are caught per session so one bad dir can't stop the rest.
    func backfill(store: SessionStore) async {
        do {
            try await ensureSchema()
        } catch {
            Self.log("trace backfill: schema init failed: \(error.localizedDescription)")
            return
        }
        guard let sessions = try? await store.loadAllSessions() else {
            Self.log("trace backfill: could not list sessions")
            return
        }
        for session in sessions {
            do {
                guard try await traceRowCount(traceId: session.id) == 0 else { continue }
                let events = try await store.loadEvents(forSession: session.id)
                try await insertTrace(traceId: session.id, session: session, events: events)
                Self.log("trace backfill: imported \(events.count) events for \(session.id)")
            } catch {
                Self.log("trace backfill failed for \(session.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Writes

    private func ingestEvent(sessionId: String, event: SessionEvent) async throws {
        let fields = mapper.fields(for: event)
        guard !fields.eventType.isEmpty else { return } // error/statusUpdate not traced

        if fields.eventType == "user", firstUserContent[sessionId] == nil {
            let content = event.content ?? ""
            firstUserContent[sessionId] = content
            let status = (try? await loadSessionStatus(sessionId: sessionId)) ?? ""
            try await upsertSummaryRow(traceId: sessionId, sessionStatus: status, firstUserContent: content)
        }

        var index = nextEventIndex[sessionId]
        if index == nil {
            index = try await maxEventIndex(traceId: sessionId) + 1
        }
        var row = fields
        row.traceId = sessionId
        row.eventIndex = index!
        nextEventIndex[sessionId] = index! + 1
        _ = try await query(TraceSQL.insert(row))
    }

    private func upsertTraceSummary(session: Session) async throws {
        let content = firstUserContent[session.id]
        try await upsertSummaryRow(traceId: session.id, sessionStatus: session.status.rawValue, firstUserContent: content)
    }

    /// Row 0: event_type 'trace', the aggregate/summary row the viewer
    /// lists by. Delete+insert keeps it single under plain MergeTree.
    private func upsertSummaryRow(traceId: String, sessionStatus: String, firstUserContent: String?) async throws {
        _ = try await query(TraceSQL.deleteRow(traceId: traceId, eventIndex: 0))
        let row = TraceRow(
            traceId: traceId,
            eventIndex: 0,
            eventType: "trace",
            name: firstUserContent.map(TraceRowMapper.name(from:)) ?? "",
            toolUseId: "",
            input: "",
            output: "",
            isError: 0,
            model: "",
            sessionStatus: sessionStatus,
            createdAt: Date()
        )
        _ = try await query(TraceSQL.insert(row))
    }

    /// Backfill insert: row 0 + all events with stable 1-based indices.
    private func insertTrace(traceId: String, session: Session, events: [SessionEvent]) async throws {
        let firstUser = events.first { $0.type == .userMessage }?.content
        var row = TraceRow(
            traceId: traceId,
            eventIndex: 0,
            eventType: "trace",
            name: firstUser.map(TraceRowMapper.name(from:)) ?? "",
            toolUseId: "",
            input: "",
            output: "",
            isError: 0,
            model: "",
            sessionStatus: session.status.rawValue,
            createdAt: session.createdAt
        )
        _ = try await query(TraceSQL.insert(row))

        var index: UInt32 = 1
        for event in events {
            let fields = mapper.fields(for: event)
            guard !fields.eventType.isEmpty else { continue }
            row = fields
            row.traceId = traceId
            row.eventIndex = index
            row.sessionStatus = session.status.rawValue
            _ = try await query(TraceSQL.insert(row))
            index += 1
        }
        nextEventIndex[traceId] = index
        if let firstUser { firstUserContent[traceId] = firstUser }
    }

    // MARK: - Reads (viewer API)

    /// All traces, newest first, for the viewer's list screen.
    func listTraces() async throws -> [TraceSummary] {
        let body = try await query(TraceSQL.listTraces)
        return decodeJSONEachRow(body, as: TraceSummaryRow.self)
            .map { decoded in
                TraceSummary(
                    traceId: decoded.trace_id,
                    name: decoded.name,
                    sessionStatus: decoded.session_status,
                    eventCount: decoded.event_count,
                    startedAt: decoded.startedAt,
                    lastEventAt: decoded.lastEventAt
                )
            }
    }

    /// One trace's events, ordered by event_index (row 0 first).
    func traceEvents(traceId: String) async throws -> [TraceEventRow] {
        let body = try await query(TraceSQL.traceEvents(traceId: traceId))
        return decodeJSONEachRow(body, as: TraceEventRowDecoded.self)
            .map { decoded in
                TraceEventRow(
                    eventIndex: decoded.event_index,
                    eventType: decoded.event_type,
                    name: decoded.name,
                    toolUseId: decoded.tool_use_id,
                    input: decoded.input,
                    output: decoded.output,
                    isError: decoded.is_error,
                    createdAt: decoded.createdAt
                )
            }
    }

    private func traceRowCount(traceId: String) async throws -> Int {
        let body = try await query(TraceSQL.rowCount(traceId: traceId))
        return Int(body.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// `SELECT max()` over an empty set returns the type default (0) — both
    /// that and an unparseable body mean "no events yet", which seeds 1.
    private func maxEventIndex(traceId: String) async throws -> UInt32 {
        let body = try await query(TraceSQL.maxEventIndex(traceId: traceId))
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt32(trimmed) ?? 0
    }

    /// session.json status for the summary row's first-name upsert. Read
    /// through a fresh on-disk store (AgentService doesn't expose session
    /// listing); the file is the same source either way.
    private func loadSessionStatus(sessionId: String) async throws -> String {
        let sessionStore = try SessionStore()
        return try await sessionStore.loadSession(id: sessionId)?.status.rawValue ?? ""
    }

    // MARK: - JSONEachRow decoding

    /// ClickHouse `FORMAT JSONEachRow`: one JSON object per line.
    private func decodeJSONEachRow<T: Decodable>(_ body: String, as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        var rows: [T] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let row = try? decoder.decode(T.self, from: data) {
                rows.append(row)
            }
        }
        return rows
    }

    // MARK: - Logging

    /// Same sink as Cooper's stage tracing: ~/.keg/cooper/debug.log.
    nonisolated static func log(_ message: String) {
        CooperController.debugLog("trace: \(message)")
    }
}

// MARK: - Decoding DTOs

/// ClickHouse serializes DateTime64(3) in JSONEachRow as a
/// `"yyyy-MM-dd HH:mm:ss.SSS"` string — parsed manually rather than fought
/// through Codable date strategies.
private enum TraceDateParsing {
    static let utc = TimeZone(identifier: "UTC")!

    static func date(from string: String) -> Date {
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = utc
            if let date = formatter.date(from: string) { return date }
        }
        return Date(timeIntervalSince1970: 0)
    }
}

private struct TraceSummaryRow: Decodable {
    let trace_id: String
    let name: String
    let session_status: String
    let event_count: Int
    let started_at: String
    let last_event_at: String

    var startedAt: Date { TraceDateParsing.date(from: started_at) }
    var lastEventAt: Date { TraceDateParsing.date(from: last_event_at) }
}

private struct TraceEventRowDecoded: Decodable {
    let event_index: UInt32
    let event_type: String
    let name: String
    let tool_use_id: String
    let input: String
    let output: String
    let is_error: UInt8
    let created_at: String

    var createdAt: Date { TraceDateParsing.date(from: created_at) }
}
