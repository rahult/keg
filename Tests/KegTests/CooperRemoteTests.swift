import XCTest

@testable import Keg

/// Model-free tests for Cooper's remote (OpenAI-compatible) backend:
/// the `<think>` splitter, tool-call accumulation, history trimming,
/// request-body building, and backend resolution. No network, no
/// FoundationModels calls.
final class CooperRemoteTests: XCTestCase {
    // MARK: - Think stream

    private func feedAll(_ chunks: [String]) -> (visible: String, thinking: String) {
        var stream = CooperThinkStream()
        for chunk in chunks {
            stream.feed(chunk)
        }
        stream.finish()
        return (stream.visible, stream.thinking)
    }

    func testPlainContentStaysVisible() {
        let result = feedAll(["Hello", " there"])
        XCTAssertEqual(result.visible, "Hello there")
        XCTAssertEqual(result.thinking, "")
    }

    func testThinkBlockIsRoutedToThinking() {
        let result = feedAll(["<think>", "reasoning here", "</think>", "The answer."])
        XCTAssertEqual(result.thinking, "reasoning here")
        XCTAssertEqual(result.visible, "The answer.")
    }

    func testTagsSplitAcrossDeltas() {
        // Every tag boundary on its own chunk: the parser must hold back
        // partial tags and never leak tag fragments into the visible text.
        let result = feedAll(["<thi", "nk>deep ", "thought</thi", "nk>", "done"])
        XCTAssertEqual(result.thinking, "deep thought")
        XCTAssertEqual(result.visible, "done")
    }

    func testUnclosedThinkKeepsEverythingAsThinking() {
        let result = feedAll(["<think>", "still reasoning", " forever"])
        XCTAssertEqual(result.visible, "")
        XCTAssertEqual(result.thinking, "still reasoning forever")
    }

    func testMultipleThinkBlocks() {
        let result = feedAll(["<think>a</think>", "mid ", "<think>b</think>", "end"])
        XCTAssertEqual(result.thinking, "ab")
        XCTAssertEqual(result.visible, "mid end")
    }

    func testLessThanThinkWithoutTagCloseStaysVisible() {
        // "<think" without the ">" is ordinary text (e.g. "if x <think of y" —
        // the space rules it out), it must not flip into thinking mode.
        let result = feedAll(["if x <think of y"])
        XCTAssertEqual(result.visible, "if x <think of y")
        XCTAssertEqual(result.thinking, "")
    }

    func testFinishFlushesHeldBackText() {
        var stream = CooperThinkStream()
        stream.feed("answer ending with <")
        let delta = stream.finish()
        XCTAssertEqual(stream.visible, "answer ending with <")
        XCTAssertEqual(delta.visibleDelta, "<")
    }

    // MARK: - Tool call accumulation

    private func toolDelta(index: Int? = nil, id: String? = nil, name: String? = nil, arguments: String? = nil)
        -> CooperWire.Chunk.Choice.ToolCallDelta {
        var function: CooperWire.Chunk.Choice.ToolCallDelta.Function?
        if name != nil || arguments != nil {
            function = CooperWire.Chunk.Choice.ToolCallDelta.Function(name: name, arguments: arguments)
        }
        return CooperWire.Chunk.Choice.ToolCallDelta(index: index, id: id, function: function)
    }

    func testStreamedToolCallFragmentsAssemble() {
        var accumulator = CooperToolCallAccumulator()
        accumulator.apply([toolDelta(index: 0, id: "call_1", name: "container_logs")])
        accumulator.apply([toolDelta(index: 0, arguments: "{\"id\": \"web")])
        accumulator.apply([toolDelta(index: 0, arguments: "\", \"tail\": 50}")])
        accumulator.apply([toolDelta(index: 1, id: "call_2", name: "container_inspect"),
                           toolDelta(index: 1, arguments: "{\"id\":\"db\"}")])

        let calls = accumulator.assembled
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].name, "container_logs")
        XCTAssertEqual(calls[0].arguments, "{\"id\": \"web\", \"tail\": 50}")
        XCTAssertEqual(calls[1].name, "container_inspect")
        XCTAssertEqual(calls[1].arguments, "{\"id\":\"db\"}")
    }

    func testNamelessFragmentsAreDropped() {
        var accumulator = CooperToolCallAccumulator()
        accumulator.apply([toolDelta(index: 0, id: "call_x")])
        XCTAssertTrue(accumulator.hasCalls)
        XCTAssertEqual(accumulator.assembled.count, 0)
    }

    // MARK: - History trimming

    private func sampleHistory() -> [CooperChatMessage] {
        [
            .system("system prompt"),
            .user("first question"),
            .assistant("first answer"),
        ]
        + (0..<30).map { index in
            index.isMultiple(of: 2)
                ? CooperChatMessage.user("question \(index)")
                : CooperChatMessage.assistant("answer \(index)")
        }
    }

    func testTrimKeepsSystemAndRecentTail() {
        let history = sampleHistory()
        let trimmed = CooperChatHistory.trimmed(history, keepLast: 6)
        XCTAssertEqual(trimmed.first?.role, .system)
        XCTAssertEqual(trimmed.count, 7)
        XCTAssertEqual(trimmed.last?.content, "answer 29")
    }

    func testTrimDropsDanglingToolResultsAtSeam() {
        var history: [CooperChatMessage] = [.system("s")]
        history.append(.user("q"))
        history.append(.assistant("", toolCalls: [
            CooperChatMessage.ToolCall(id: "call_1", name: "list_containers", arguments: "{}"),
        ]))
        history.append(.toolResult(callID: "call_1", name: "list_containers", text: "result"))
        history.append(.assistant("done"))
        // Force the seam to fall between the assistant call and its result
        // by trimming to just the last two messages.
        let trimmed = CooperChatHistory.trimmed(history, keepLast: 2)
        // The assistant tool-call whose result was cut is rewritten, and no
        // tool result may dangle without its call.
        for (index, message) in trimmed.enumerated() where message.role == .tool {
            let preceding = trimmed[..<index]
            XCTAssertTrue(preceding.contains { $0.toolCalls?.contains { $0.id == message.toolCallID } == true })
        }
    }

    func testCodableRoundTripPreservesToolShapes() throws {
        let history: [CooperChatMessage] = [
            .system("s"),
            .user("q"),
            .assistant("calling", toolCalls: [CooperChatMessage.ToolCall(id: "c1", name: "keg_docs", arguments: "{\"topic\":\"storage\"}")]),
            .toolResult(callID: "c1", name: "keg_docs", text: "docs"),
            .assistant("final"),
        ]
        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode([CooperChatMessage].self, from: data)
        XCTAssertEqual(decoded, history)
    }

    // MARK: - Request body

    private func bodyDictionary(_ messages: [CooperChatMessage], config: CooperRemoteConfig, tools: [CooperToolSpec] = []) throws -> [String: CooperJSONValue] {
        let data = try CooperWire.requestBody(messages: messages, tools: tools, config: config)
        return try JSONDecoder().decode([String: CooperJSONValue].self, from: data)
    }

    func testMessageBodiesMapToOpenAIShapes() throws {
        let messages: [CooperChatMessage] = [
            .system("sys"),
            .user("hi"),
            .assistant("calling", toolCalls: [CooperChatMessage.ToolCall(id: "c1", name: "t", arguments: "{}")]),
            .toolResult(callID: "c1", name: "t", text: "out"),
        ]
        let body = try bodyDictionary(messages, config: CooperRemoteConfig(baseURL: "https://x/v1", model: "m"))
        guard case .array(let encoded)? = body["messages"] else {
            return XCTFail("expected messages array")
        }
        XCTAssertEqual(encoded, [
            CooperJSONValue.object(["role": .string("system"), "content": .string("sys")]),
            CooperJSONValue.object(["role": .string("user"), "content": .string("hi")]),
            CooperJSONValue.object([
                "role": .string("assistant"),
                "content": .string("calling"),
                "tool_calls": .array([.object([
                    "id": .string("c1"),
                    "type": .string("function"),
                    "function": .object(["name": .string("t"), "arguments": .string("{}")]),
                ])]),
            ]),
            CooperJSONValue.object(["role": .string("tool"), "tool_call_id": .string("c1"), "content": .string("out")]),
        ])
    }

    func testReasoningEffortOnlySentForLevels() throws {
        func effortValue(_ thinking: CooperThinkingPreference) throws -> String? {
            var config = CooperRemoteConfig(baseURL: "https://x/v1", model: "m")
            config.thinking = thinking
            let body = try bodyDictionary([.user("q")], config: config)
            if case .string(let effort)? = body["reasoning_effort"] { return effort }
            return nil
        }
        XCTAssertNil(try effortValue(.providerDefault))
        XCTAssertNil(try effortValue(.off))
        XCTAssertEqual(try effortValue(.low), "low")
        XCTAssertEqual(try effortValue(.medium), "medium")
        XCTAssertEqual(try effortValue(.high), "high")
    }

    func testExtraBodyOverridesAndInvalidThrows() throws {
        var config = CooperRemoteConfig(baseURL: "https://x/v1", model: "m")
        config.extraBodyJSON = "{\"temperature\": 0.2, \"stream\": false}"
        let body = try bodyDictionary([.user("q")], config: config)
        XCTAssertEqual(body["temperature"], .double(0.2))
        XCTAssertEqual(body["stream"], .bool(false))

        config.extraBodyJSON = "[1,2,3]"
        XCTAssertThrowsError(try CooperWire.requestBody(messages: [.user("q")], tools: [], config: config))
    }

    func testToolsIncludedAsFunctionDefinitions() throws {
        let spec = CooperToolSpec(
            name: "list_containers",
            description: "lists",
            parameters: .objectSchema(["all": .schema("all?", type: "boolean")], required: ["all"])
        ) { _ in "ok" }
        let body = try bodyDictionary([.user("q")], config: CooperRemoteConfig(baseURL: "https://x/v1", model: "m"), tools: [spec])
        guard case .array(let tools)? = body["tools"], tools.count == 1 else {
            return XCTFail("expected one tool")
        }
        XCTAssertEqual(tools[0], .object([
            "type": .string("function"),
            "function": .object([
                "name": .string("list_containers"),
                "description": .string("lists"),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object(["all": .object(["description": .string("all?"), "type": .string("boolean")])]),
                    "required": .array([.string("all")]),
                ]),
            ]),
        ]))
    }

    // MARK: - Backend resolution

    private let remote = CooperRemoteConfig(baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")

    func testAutoPrefersOnDeviceWhenReady() {
        let resolution = CooperBackendResolver.resolve(systemAvailability: .ready, preference: .auto, remote: remote)
        XCTAssertEqual(resolution.availability, .ready)
        XCTAssertEqual(resolution.brain, .onDevice)
    }

    func testAutoFallsBackToRemoteWhenOnDeviceUnavailable() {
        for state: CooperAvailability in [.appleIntelligenceOff, .deviceNotEligible, .modelNotReady] {
            let resolution = CooperBackendResolver.resolve(systemAvailability: state, preference: .auto, remote: remote)
            XCTAssertEqual(resolution.availability, .ready, "remote must make Cooper ready for \(state)")
            XCTAssertEqual(resolution.brain, .remote)
        }
    }

    func testForcedRemoteWinsEvenWhenOnDeviceReady() {
        let resolution = CooperBackendResolver.resolve(systemAvailability: .ready, preference: .remote, remote: remote)
        XCTAssertEqual(resolution.brain, .remote)
    }

    func testUnconfiguredRemoteDegradesToOnDevice() {
        let resolution = CooperBackendResolver.resolve(
            systemAvailability: .appleIntelligenceOff, preference: .remote, remote: CooperRemoteConfig())
        XCTAssertEqual(resolution.availability, .appleIntelligenceOff)
        XCTAssertEqual(resolution.brain, .onDevice)
    }

    func testForcedOnDeviceNeverUsesRemote() {
        let resolution = CooperBackendResolver.resolve(systemAvailability: .ready, preference: .onDevice, remote: remote)
        XCTAssertEqual(resolution.brain, .onDevice)
    }

    func testConfigValidity() {
        var config = CooperRemoteConfig()
        XCTAssertFalse(config.isConfigured)
        config.baseURL = "https://api.openai.com/v1/"
        config.model = "  "
        XCTAssertFalse(config.isConfigured)
        config.model = "gpt-4o-mini"
        XCTAssertTrue(config.isConfigured)
        XCTAssertEqual(config.effectiveBaseURL?.absoluteString, "https://api.openai.com/v1")
        config.extraBodyJSON = "not json"
        XCTAssertFalse(config.isConfigured)
    }

    func testBaseURLValidation() {
        XCTAssertNil(CooperRemoteConfig.normalizedBaseURL("not a url"))
        XCTAssertNil(CooperRemoteConfig.normalizedBaseURL("ftp://x.com"))
        XCTAssertEqual(CooperRemoteConfig.normalizedBaseURL(" https://api.x.com/v1/ ")?.absoluteString, "https://api.x.com/v1")
        XCTAssertNotNil(CooperRemoteConfig.normalizedBaseURL("http://127.0.0.1:11434/v1"))
    }

    // MARK: - Error bodies & model lists

    func testErrorMessageExtraction() {
        let nested = Data("{\"error\": {\"message\": \"bad key\"}}".utf8)
        XCTAssertEqual(CooperWire.errorMessage(from: nested), "bad key")
        let flat = Data("{\"message\": \"nope\"}".utf8)
        XCTAssertEqual(CooperWire.errorMessage(from: flat), "nope")
        let plain = Data("server exploded".utf8)
        XCTAssertEqual(CooperWire.errorMessage(from: plain), "server exploded")
        XCTAssertNil(CooperWire.errorMessage(from: Data()))
    }

    func testModelIDExtraction() {
        let body = Data("{\"data\": [{\"id\": \"b\"}, {\"id\": \"a\"}, {}]}".utf8)
        XCTAssertEqual(CooperWire.modelIDs(from: body), ["a", "b"])
    }

    func testOverflowDetection() {
        XCTAssertTrue(CooperRemoteError.isContextOverflow(
            CooperRemoteError.http(status: 400, message: "This model's maximum context length is 8192 tokens")
        ))
        XCTAssertTrue(CooperRemoteError.isContextOverflow(
            CooperRemoteError.http(status: 400, message: "please reduce the length of the messages")
        ))
        XCTAssertFalse(CooperRemoteError.isContextOverflow(
            CooperRemoteError.http(status: 400, message: "invalid tool definition")
        ))
    }

    func testEndpointDeduplicatesPath() {
        let base = URL(string: "https://api.openai.com/v1")!
        XCTAssertEqual(CooperOpenAIBackend.endpoint(base, path: "chat/completions").absoluteString,
                       "https://api.openai.com/v1/chat/completions")
        let withSuffix = URL(string: "https://proxy.example.com/v1/chat/completions")!
        XCTAssertEqual(CooperOpenAIBackend.endpoint(withSuffix, path: "chat/completions").absoluteString,
                       "https://proxy.example.com/v1/chat/completions")
    }
}
