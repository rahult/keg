@testable import Keg
import XCTest

/// Tests for SupaglueClient and SupaglueContainer.
///
/// MockURLProtocol intercepts HTTP requests so tests run without a real
/// Supaglue container.
///
/// Run unit tests with:
///   swift test --filter SupaglueClientTests
///
/// Run integration tests against live localhost:3000 with:
///   KEG_RUN_SUPAGLUE=1 swift test --filter SupaglueClientIntegrationTests
final class SupaglueClientTests: XCTestCase {

    /// Per-test session + mock handler. Each test creates its own so
    /// MockURLProtocol.handler (static) always matches what the test expects.
    private var session: URLSession!
    private var mockHandler: MockURLProtocol.Handler!

    private func configure(handler: @escaping MockURLProtocol.Handler) -> URLSession {
        mockHandler = handler
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(session: URLSession) -> SupaglueClient {
        SupaglueClient(session: session)
    }

    // MARK: - Health

    func testHealthReturnsTrue_whenServerResponds200() async throws {
        session = configure { _, _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1:3000/healthz")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let ok = try await client.health()
        XCTAssertTrue(ok)
    }

    func testHealthReturnsFalse_whenServerResponds503() async throws {
        session = configure { _, _ in
            (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1:3000/healthz")!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let ok = try await client.health()
        XCTAssertFalse(ok)
    }

    func testHealthThrows_whenNetworkError() async throws {
        session = configure { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = makeClient(session: session)
        do {
            _ = try await client.health()
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    // MARK: - Connections

    func testListConnections_returnsConnections() async throws {
        let json = """
        [
          {
            "id": "conn_1",
            "provider": "gmail",
            "provider_category": "email",
            "customer_id": "alice@example.com",
            "status": "available",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z"
          },
          {
            "id": "conn_2",
            "provider": "hubspot",
            "provider_category": "crm",
            "customer_id": "acme-corp",
            "status": "available",
            "created_at": "2026-01-02T00:00:00Z",
            "updated_at": "2026-01-02T00:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        session = configure { req, _ in
            XCTAssertEqual(req.url?.path, "/api/v1/connections")
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let connections = try await client.listConnections()
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(connections[0].provider, "gmail")
        XCTAssertEqual(connections[0].status, "available")
        XCTAssertEqual(connections[1].provider, "hubspot")
    }

    func testListConnections_returnsEmpty_whenNoConnections() async throws {
        session = configure { req, _ in
            XCTAssertEqual(req.url?.path, "/api/v1/connections")
            return ("[]".data(using: .utf8)!, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let connections = try await client.listConnections()
        XCTAssertEqual(connections.count, 0)
    }

    // MARK: - Events

    func testListEvents_returnsEvents() async throws {
        let json = """
        [
          {
            "id": "evt_1",
            "connection_id": "conn_1",
            "provider": "gmail",
            "object_type": "email_message",
            "object_id": "msg_123",
            "event_type": "create",
            "created_at": "2026-01-01T00:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        session = configure { req, _ in
            XCTAssertTrue(req.url?.path.hasPrefix("/api/v1/events") ?? false)
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let events = try await client.listEvents(connectionId: "conn_1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "evt_1")
        XCTAssertEqual(events[0].provider, "gmail")
        XCTAssertEqual(events[0].objectType, "email_message")
    }

    // MARK: - Calendar

    func testCreateCalendarEvent_returnsEvent() async throws {
        let json = """
        {
          "id": "evt_cal_1",
          "summary": "Team Standup",
          "description": "Daily standup meeting",
          "start_time": "2026-01-15T09:00:00Z",
          "end_time": "2026-01-15T09:30:00Z",
          "location": "Google Meet",
          "attendees": [{ "email": "alice@example.com", "status": "accepted" }]
        }
        """.data(using: .utf8)!

        session = configure { req, _ in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url?.path.hasPrefix("/api/v1/calendar/events") ?? false)
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-01-15T09:00:00Z")!
        let end   = formatter.date(from: "2026-01-15T09:30:00Z")!

        let params = CreateCalendarEventParams(
            summary: "Team Standup",
            description: "Daily standup meeting",
            startTime: start,
            endTime: end,
            location: "Google Meet",
            attendees: ["alice@example.com"]
        )
        let event = try await client.createCalendarEvent(connectionId: "conn_1", params: params)
        XCTAssertEqual(event.id, "evt_cal_1")
        XCTAssertEqual(event.summary, "Team Standup")
        XCTAssertEqual(event.location, "Google Meet")
        XCTAssertEqual(event.attendees?.first?.email, "alice@example.com")
    }

    func testListCalendarEvents_filtersByConnectionId() async throws {
        let json = """
        [
          {
            "id": "cal_evt_1",
            "summary": "Project Review",
            "start_time": "2026-02-01T14:00:00Z",
            "end_time": "2026-02-01T15:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        session = configure { req, _ in
            XCTAssertTrue(req.url?.query?.contains("connection_id=conn_abc") ?? false)
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let events = try await client.listCalendarEvents(connectionId: "conn_abc")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "cal_evt_1")
        XCTAssertEqual(events[0].summary, "Project Review")
    }

    // MARK: - Email

    func testSendEmail_returnsMessage() async throws {
        let json = """
        {
          "id": "sent_1",
          "from": [{ "email": "alice@example.com", "name": "Alice" }],
          "to": [{ "email": "bob@example.com", "name": null }],
          "subject": "Hello",
          "body": "Test email body",
          "date": "2026-01-01T12:00:00Z",
          "snippet": "Test email body"
        }
        """.data(using: .utf8)!

        session = configure { req, _ in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url?.path.contains("/api/v1/email/messages/send") ?? false)
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let params = SendEmailParams(
            to: ["bob@example.com"],
            subject: "Hello",
            body: "Test email body"
        )
        let message = try await client.sendEmail(connectionId: "conn_gmail", params: params)
        XCTAssertEqual(message.id, "sent_1")
        XCTAssertEqual(message.subject, "Hello")
        XCTAssertEqual(message.to?.first?.email, "bob@example.com")
    }

    func testListEmailMessages_filtersByQuery() async throws {
        let json = """
        [
          {
            "id": "msg_1",
            "from": [{ "email": "charlie@example.com", "name": "Charlie" }],
            "to": [{ "email": "alice@example.com", "name": null }],
            "subject": "Re: Project Update",
            "snippet": "Thanks for the update...",
            "date": "2026-01-03T10:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        session = configure { req, _ in
            XCTAssertTrue(req.url?.query?.contains("q=from:charlie") ?? false)
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        let messages = try await client.listEmailMessages(connectionId: "conn_gmail", query: "from:charlie")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].from?.first?.email, "charlie@example.com")
    }

    // MARK: - Error Handling

    func testListConnections_throwsOnHTTPError() async throws {
        session = configure { req, _ in
            ("{\"error\": \"Internal Server Error\"}".data(using: .utf8)!,
             HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let client = makeClient(session: session)
        do {
            _ = try await client.listConnections()
            XCTFail("Expected HTTP error")
        } catch let error as SupaglueClientError {
            if case .httpError(let code, let msg) = error {
                XCTAssertEqual(code, 500)
                XCTAssertTrue(msg.contains("Internal Server Error"))
            } else {
                XCTFail("Expected SupaglueClientError.httpError")
            }
        }
    }
}

// MARK: - Tool Execution Tests

final class SupaglueToolsTests: XCTestCase {

    func testAllTools_haveUniqueNames() {
        let names = SupaglueTools.allTools.map { tool -> String in
            if case .custom(let c) = tool { return c.name }
            return ""
        }
        XCTAssertEqual(Set(names).count, names.count, "Tool names must be unique")
    }

    func testToolNames_containsExpectedTools() {
        let expected = [
            "supaglue_health",
            "supaglue_list_connections",
            "supaglue_list_events",
            "supaglue_list_calendar_events",
            "supaglue_create_calendar_event",
            "supaglue_list_email",
            "supaglue_send_email",
        ]
        for name in expected {
            XCTAssertTrue(
                SupaglueTools.toolNames.contains(name),
                "Missing tool: \(name)"
            )
        }
    }

    func testCalendarEventParams_codableRoundTrip() throws {
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-01-15T09:00:00Z")!
        let end   = formatter.date(from: "2026-01-15T09:30:00Z")!

        let params = CreateCalendarEventParams(
            summary: "Team Sync",
            description: "Weekly sync",
            startTime: start,
            endTime: end,
            location: "Room 1",
            attendees: ["alice@example.com", "bob@example.com"],
            calendarId: "primary"
        )

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(CreateCalendarEventParams.self, from: data)
        XCTAssertEqual(decoded.summary, "Team Sync")
        XCTAssertEqual(decoded.attendees?.count, 2)
        XCTAssertEqual(decoded.attendees?.last, "bob@example.com")
        XCTAssertEqual(decoded.calendarId, "primary")
    }

    func testSendEmailParams_codableRoundTrip() throws {
        let params = SendEmailParams(
            to: ["bob@example.com"],
            cc: ["cc@example.com"],
            subject: "Test Subject",
            body: "Test body",
            from: "alice@example.com"
        )
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(SendEmailParams.self, from: data)
        XCTAssertEqual(decoded.to.count, 1)
        XCTAssertEqual(decoded.to.first, "bob@example.com")
        XCTAssertEqual(decoded.cc?.first, "cc@example.com")
        XCTAssertEqual(decoded.subject, "Test Subject")
        XCTAssertEqual(decoded.body, "Test body")
        XCTAssertEqual(decoded.from, "alice@example.com")
    }

    func testCalendarEvent_asDictionary() {
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-01-15T09:00:00Z")!
        let end   = formatter.date(from: "2026-01-15T09:30:00Z")!

        let event = CalendarEvent(
            id: "evt_123",
            summary: "Meeting",
            description: "Important meeting",
            startTime: start,
            endTime: end,
            location: "HQ",
            attendees: [CalendarAttendee(email: "alice@example.com", status: "accepted")]
        )

        let dict = event.asDictionary
        XCTAssertEqual(dict["id"] as? String, "evt_123")
        XCTAssertEqual(dict["summary"] as? String, "Meeting")
        XCTAssertEqual(dict["location"] as? String, "HQ")
        XCTAssertNotNil(dict["start_time"] as? String)
        XCTAssertEqual(((dict["attendees"] as? [[String: Any]])?.first)?["email"] as? String, "alice@example.com")
    }

    func testSupaglueConnection_asDictionary() {
        let formatter = ISO8601DateFormatter()
        let created = formatter.date(from: "2026-01-01T00:00:00Z")!

        let conn = SupaglueConnection(
            id: "conn_abc",
            provider: "gmail",
            providerCategory: "email",
            customerId: "alice",
            status: "available",
            createdAt: created,
            updatedAt: nil
        )

        let dict = conn.asDictionary
        XCTAssertEqual(dict["id"] as? String, "conn_abc")
        XCTAssertEqual(dict["provider"] as? String, "gmail")
        XCTAssertEqual(dict["status"] as? String, "available")
        XCTAssertNotNil(dict["created_at"] as? String)
    }

    func testSupaglueToolResult_success() throws {
        let result = SupaglueToolResult(success: true, data: ["count": 42, "items": ["a", "b"]])
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SupaglueToolResult.self, from: data)
        XCTAssertTrue(decoded.success)
    }

    func testSupaglueToolResult_failure() throws {
        let result = SupaglueToolResult(success: false, data: ["error": "Not found"])
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SupaglueToolResult.self, from: data)
        XCTAssertFalse(decoded.success)
    }
}

// MARK: - MockURLProtocol

@preconcurrency import Foundation

/// A URLProtocol that intercepts requests and returns controlled responses for testing.
class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: Handler?

    typealias Handler = (URLRequest, TimeInterval) throws -> (Data, URLResponse)

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        guard let handler = Self.handler else {
            fatalError("MockURLProtocol.handler is nil — call configure() in your test first")
        }
        do {
            let (data, response) = try handler(request, 0)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    nonisolated override func stopLoading() {}
}
