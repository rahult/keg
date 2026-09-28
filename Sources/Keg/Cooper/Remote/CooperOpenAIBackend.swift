import Foundation

/// One progress event from a remote turn, streamed to the controller on
/// the main actor.
struct CooperStreamUpdate: Sendable {
    var visibleDelta: String?
    var thinkingDelta: String?
    /// Tool execution bookkeeping for the ⚙/✓ chips.
    var toolStarted: String?
    var toolFinished: String?
}

/// Terminal event of a turn: the new full conversation history (system
/// message, prior turns, this turn's user message, and everything the
/// model produced), ready to persist.
enum CooperTurnEvent: Sendable {
    case update(CooperStreamUpdate)
    case done([CooperChatMessage])
}

/// The OpenAI-compatible backend: an agentic loop over any
/// `/chat/completions` endpoint (OpenAI, OpenRouter, Groq, DeepSeek,
/// Ollama, LM Studio, vLLM, …). Streams SSE, executes function calls
/// against `CooperToolSpec`s, and folds reasoning output — both separate
/// fields (`reasoning_content`/`reasoning`) and inline `<think>` tags —
/// out of the visible reply.
///
/// Calling-pattern differences are absorbed here rather than per provider:
/// request-side thinking uses the de-facto `reasoning_effort` (levels only,
/// never sent for off/default), provider-specific switches ride the extra
/// body JSON, and response-side reasoning is parsed defensively no matter
/// which dialect the server picked.
enum CooperOpenAIBackend {
    /// Upper bound on model round-trips per user turn; the repeat-call
    /// guard in the gateway catches loops within a round.
    static let maxToolRounds = 8

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Reasoning models can be silent for minutes before the first
        // token, and a long tool call delays the follow-up request; the
        // controller's watchdog plus user Stop are the real deadlines.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Runs one full turn: stream a completion, run requested tools, feed
    /// results back, repeat until the model answers in plain text.
    /// Events arrive on whatever task consumes the stream; `done` carries
    /// the history to persist and is always the last event before finish.
    static func turn(
        config: CooperRemoteConfig,
        apiKey: String,
        history: [CooperChatMessage],
        userPrompt: String,
        tools: [CooperToolSpec]
    ) -> AsyncThrowingStream<CooperTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let newHistory = try await runLoop(
                        config: config,
                        apiKey: apiKey,
                        history: history,
                        userPrompt: userPrompt,
                        tools: tools
                    ) { update in
                        continuation.yield(.update(update))
                    }
                    continuation.yield(.done(newHistory))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalized(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// The loop body, factored out for readability. `yield` may be called
    /// from this detached context.
    private static func runLoop(
        config: CooperRemoteConfig,
        apiKey: String,
        history: [CooperChatMessage],
        userPrompt: String,
        tools: [CooperToolSpec],
        yield: @escaping @Sendable (CooperStreamUpdate) -> Void
    ) async throws -> [CooperChatMessage] {
        var history = history
        history.append(.user(userPrompt))
        let thinkStream = CooperStreamBox()

        for round in 0..<maxToolRounds {
            let request = try makeRequest(
                endpoint: endpoint(config.effectiveBaseURL ?? URL(string: "https://invalid.invalid")!, path: "chat/completions"),
                apiKey: apiKey,
                body: try CooperWire.requestBody(messages: history, tools: tools, config: config)
            )
            let (assembledCalls, finishReason) = try await streamOnce(
                request: request, thinkStream: thinkStream, yield: yield
            )

            if assembledCalls.isEmpty {
                var reply = CooperChatMessage.assistant(thinkStream.visible)
                if finishReason == "length" {
                    reply.content = (reply.content ?? "") + "\n\n(reply hit the provider's length limit)"
                }
                history.append(reply)
                return history
            }

            // The model wants tools: record its call message, execute each
            // request sequentially (approvals must serialize), append the
            // results, and go around again.
            history.append(.assistant(thinkStream.visible, toolCalls: assembledCalls))
            if round == maxToolRounds - 1 {
                history.append(.assistant(
                    "Stopped after \(maxToolRounds) tool rounds; reporting what is known so far."
                ))
                return history
            }
            for call in assembledCalls {
                yield(CooperStreamUpdate(toolStarted: call.name))
                let result = await execute(call: call, tools: tools)
                yield(CooperStreamUpdate(toolFinished: call.name))
                history.append(.toolResult(callID: call.id, name: call.name, text: result))
            }
        }
        return history
    }

    /// Executes one tool call. Errors — including gate refusals and
    /// denials — become the tool result text, mirroring how thrown errors
    /// inside FoundationModels `Tool.call` surface to that model.
    private static func execute(call: CooperChatMessage.ToolCall, tools: [CooperToolSpec]) async -> String {
        guard let spec = tools.first(where: { $0.name == call.name }) else {
            return "Unknown tool \"\(call.name)\". Available tools: \(tools.map(\.name).joined(separator: ", "))."
        }
        do {
            return try await spec.invoke(call.arguments)
        } catch is CancellationError {
            return "Tool execution was stopped by the user."
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }

    /// Streams one completion request, yielding visible/thinking deltas and
    /// collecting streamed tool-call fragments. Returns the assembled tool
    /// calls (empty when none) and the finish reason.
    private static func streamOnce(
        request: URLRequest,
        thinkStream: CooperStreamBox,
        yield: @escaping @Sendable (CooperStreamUpdate) -> Void
    ) async throws -> ([CooperChatMessage.ToolCall], String?) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CooperRemoteError.network("The server did not answer over HTTP.")
        }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let message = CooperWire.errorMessage(from: body)
                ?? "The model server returned HTTP \(http.statusCode)."
            throw CooperRemoteError.http(status: http.statusCode, message: message)
        }

        var accumulator = CooperToolCallAccumulator()
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(CooperWire.Chunk.self, from: data),
                  let choice = chunk.choices?.first else { continue }

            if let delta = choice.delta {
                if let reasoning = delta.reasoning_content ?? delta.reasoning, !reasoning.isEmpty {
                    let thinkingDelta = thinkStream.feedThinking(reasoning)
                    yield(CooperStreamUpdate(thinkingDelta: thinkingDelta))
                }
                if let content = delta.content, !content.isEmpty {
                    let (visibleDelta, _) = thinkStream.feedContent(content)
                    if !visibleDelta.isEmpty {
                        yield(CooperStreamUpdate(visibleDelta: visibleDelta))
                    }
                }
                if let toolDeltas = delta.tool_calls, !toolDeltas.isEmpty {
                    accumulator.apply(toolDeltas)
                }
            }
            if let reason = choice.finish_reason {
                finishReason = reason
            }
        }

        // Flush any hold-back (a `<think>` that never closed, trailing
        // partial text) so nothing is lost at end of message.
        let (visibleDelta, thinkingDelta) = thinkStream.finish()
        if !thinkingDelta.isEmpty {
            yield(CooperStreamUpdate(thinkingDelta: thinkingDelta))
        }
        if !visibleDelta.isEmpty {
            yield(CooperStreamUpdate(visibleDelta: visibleDelta))
        }
        return (accumulator.assembled, finishReason)
    }

    // MARK: - Plumbing

    /// Mutable thinking splitter for the loop above. A class so the same
    /// instance survives across rounds; access is confined to the single
    /// detached task, so no locking is needed.
    private final class CooperStreamBox: @unchecked Sendable {
        private var contentSplitter = CooperThinkStream()

        /// Reasoning fields never carry tags; they feed the thinking text
        /// directly.
        func feedThinking(_ text: String) -> String { text }

        func feedContent(_ text: String) -> (visibleDelta: String, thinkingDelta: String) {
            contentSplitter.feed(text)
        }

        func finish() -> (visibleDelta: String, thinkingDelta: String) {
            contentSplitter.finish()
        }

        var visible: String { contentSplitter.visible }
    }

    static func endpoint(_ base: URL, path: String) -> URL {
        if base.path.hasSuffix(path) { return base }
        return base.appendingPathComponent(path)
    }

    private static func makeRequest(endpoint: URL, apiKey: String, body: Data) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// GET `/models` — used by Settings' model list. Works on every major
    /// OpenAI-compatible server.
    static func listModels(config: CooperRemoteConfig, apiKey: String) async throws -> [String] {
        guard let base = config.effectiveBaseURL else {
            throw CooperRemoteError.configuration("The server URL is not valid.")
        }
        var request = URLRequest(url: endpoint(base, path: "models"))
        request.timeoutInterval = 20
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CooperRemoteError.network("The server did not answer over HTTP.")
        }
        guard http.statusCode == 200 else {
            let message = CooperWire.errorMessage(from: data)
                ?? "The model server returned HTTP \(http.statusCode)."
            throw CooperRemoteError.http(status: http.statusCode, message: message)
        }
        return CooperWire.modelIDs(from: data)
    }

    /// URLSession surfaces cancellation as `URLError(.cancelled)`; the
    /// controller's pipeline expects `CancellationError` for its
    /// stopped-by-user path.
    static func normalized(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        if (error as? CocoaError)?.code == .userCancelled {
            return CancellationError()
        }
        return error
    }
}
