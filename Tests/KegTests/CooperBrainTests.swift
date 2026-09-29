import XCTest
@testable import Keg

final class CooperBrainTests: XCTestCase {

    private final class FakeTurn: @unchecked Sendable {
        var captured: [(history: [CooperChatMessage], prompt: String)] = []
        var stream: AsyncThrowingStream<CooperTurnEvent, Error> = AsyncThrowingStream { $0.finish() }
    }

    private let config = CooperRemoteConfig(baseURL: "http://127.0.0.1:1/v1", model: "test-model")

    private func makeBrain(_ fake: FakeTurn, history: [CooperChatMessage] = []) -> CooperBrain {
        let turn: CooperBrain.TurnFn = { _, _, history, prompt, _ in
            fake.captured.append((history, prompt))
            return fake.stream
        }
        let tool = CooperToolSpec(name: "noop", description: "t", parameters: .object([:])) { _ in "ok" }
        return CooperBrain(
            config: config,
            apiKey: "",
            tools: [tool],
            initialHistory: history,
            turn: turn
        )
    }

    func testAssistantTextMapsToAssistantEvent() async throws {
        let fake = FakeTurn()
        fake.stream = AsyncThrowingStream { continuation in
            continuation.yield(.done([
                .user("hi"),
                .assistant("hello there"),
            ]))
            continuation.finish()
        }
        let brain = makeBrain(fake)

        let events = try await collect(brain.run(prompt: "hi", workspace: URL(filePath: "/tmp")))

        XCTAssertEqual(events.map(\.type), [.assistantMessage])
        XCTAssertEqual(events.first?.content, "hello there")
    }

    func testToolCallAndResultMapToToolUseThenToolResult() async throws {
        let fake = FakeTurn()
        fake.stream = AsyncThrowingStream { continuation in
            continuation.yield(.done([
                .user("list them"),
                .assistant("", toolCalls: [.init(id: "call-1", name: "list_containers", arguments: #"{"all":true}"#)]),
                .toolResult(callID: "call-1", name: "list_containers", text: "nginx"),
            ]))
            continuation.finish()
        }
        let brain = makeBrain(fake)

        let events = try await collect(brain.run(prompt: "list them", workspace: URL(filePath: "/tmp")))

        XCTAssertEqual(events.map(\.type), [.toolUse, .toolResult])
        XCTAssertEqual(events[0].toolUse?.tool, "list_containers")
        XCTAssertEqual(events[0].toolUse?.toolUseId, "call-1")
        XCTAssertEqual(events[0].toolUse?.toolInput["all"]?.value as? Bool, true)
        XCTAssertEqual(events[1].toolResult?.toolUseId, "call-1")
        XCTAssertEqual(events[1].toolResult?.toolOutput.value as? String, "nginx")
    }

    func testTextAndToolCallInOneMessageEmitTextFirst() async throws {
        let fake = FakeTurn()
        fake.stream = AsyncThrowingStream { continuation in
            continuation.yield(.done([
                .user("go"),
                .assistant("let me check", toolCalls: [.init(id: "c", name: "noop", arguments: "")]),
                .toolResult(callID: "c", name: "noop", text: "done"),
                .assistant("all done"),
            ]))
            continuation.finish()
        }
        let brain = makeBrain(fake)

        let events = try await collect(brain.run(prompt: "go", workspace: URL(filePath: "/tmp")))

        XCTAssertEqual(events.map(\.type), [.assistantMessage, .toolUse, .toolResult, .assistantMessage])
        XCTAssertEqual(events.first?.content, "let me check")
        XCTAssertEqual(events.last?.content, "all done")
    }

    func testUserMessagesAreNotReEmitted() async throws {
        let fake = FakeTurn()
        fake.stream = AsyncThrowingStream { continuation in
            continuation.yield(.done([.user("again")]))
            continuation.finish()
        }
        let brain = makeBrain(fake)

        let events = try await collect(brain.run(prompt: "again", workspace: URL(filePath: "/tmp")))

        XCTAssertTrue(events.isEmpty)
    }

    func testHistoryGrowsAcrossRuns() async throws {
        let fake = FakeTurn()
        fake.stream = AsyncThrowingStream { continuation in
            continuation.yield(.done([
                .user("first"),
                .assistant("answer one"),
            ]))
            continuation.finish()
        }
        let brain = makeBrain(fake)
        _ = try await collect(brain.run(prompt: "first", workspace: URL(filePath: "/tmp")))

        fake.stream = AsyncThrowingStream { continuation in
            continuation.yield(.done([
                .user("first"),
                .assistant("answer one"),
                .user("second"),
                .assistant("answer two"),
            ]))
            continuation.finish()
        }
        _ = try await collect(brain.run(prompt: "second", workspace: URL(filePath: "/tmp")))

        XCTAssertEqual(fake.captured.count, 2)
        XCTAssertEqual(fake.captured[1].prompt, "second")
        // The backend's contract is the full conversation including each
        // turn's user message (runLoop appends it internally).
        XCTAssertEqual(fake.captured[1].history.map(\.content), ["first", "answer one"])
    }

    func testTurnErrorPropagates() async throws {
        struct TurnFailure: Error {}

        let fake = FakeTurn()
        fake.stream = AsyncThrowingStream { continuation in
            continuation.finish(throwing: TurnFailure())
        }
        let brain = makeBrain(fake)

        do {
            _ = try await collect(brain.run(prompt: "x", workspace: URL(filePath: "/tmp")))
            XCTFail("expected error")
        } catch is TurnFailure {
            // expected
        }
    }

    /// Drain an event stream, returning collected events.
    private func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}
