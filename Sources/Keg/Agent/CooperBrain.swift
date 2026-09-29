import Foundation

/// Cooper's remote backend as an agent brain: any OpenAI-compatible server
/// driving the full tool set through `CooperGateway`, so the permission
/// gate / approvals / repeat-call guard apply exactly as they do in the
/// panel. The on-device FoundationModels path is UI-coupled and stays in
/// the inspector panel; this is the headless default for agent sessions.
///
/// Conversation history is kept here (not in the panel's persisted
/// transcripts) so agent sessions are self-contained; the runner serializes
/// turns, which is why plain mutable state is safe.
final class CooperBrain: AgentBrain, @unchecked Sendable {
    /// The seam every turn goes through; production wires
    /// `CooperOpenAIBackend.turn`, tests inject a canned stream.
    typealias TurnFn = @Sendable (
        _ config: CooperRemoteConfig,
        _ apiKey: String,
        _ history: [CooperChatMessage],
        _ userPrompt: String,
        _ tools: [CooperToolSpec]
    ) -> AsyncThrowingStream<CooperTurnEvent, Error>

    let config: CooperRemoteConfig
    let apiKey: String
    let tools: [CooperToolSpec]
    private let turn: TurnFn
    private var history: [CooperChatMessage]

    init(
        config: CooperRemoteConfig,
        apiKey: String,
        tools: [CooperToolSpec],
        initialHistory: [CooperChatMessage] = [],
        turn: @escaping TurnFn = { CooperOpenAIBackend.turn(config: $0, apiKey: $1, history: $2, userPrompt: $3, tools: $4) }
    ) {
        self.config = config
        self.apiKey = apiKey
        self.tools = tools
        self.history = initialHistory
        self.turn = turn
    }

    func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var prior = history
                    var updated = history
                    for try await event in turn(config, apiKey, prior, prompt, tools) {
                        if case .done(let newHistory) = event {
                            updated = newHistory
                        }
                    }
                    let events = Self.sessionEvents(newMessages: Array(updated.dropFirst(prior.count)))
                    prior = updated
                    history = updated
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CooperOpenAIBackend.normalized(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Map the messages one turn appended to the log's event model. User
    /// messages are skipped — the runner already logged the prompt.
    static func sessionEvents(newMessages: [CooperChatMessage]) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for message in newMessages {
            switch message.role {
            case .assistant:
                if let text = message.content, !text.isEmpty {
                    events.append(SessionEvent(type: .assistantMessage, content: text))
                }
                for call in message.toolCalls ?? [] {
                    events.append(SessionEvent(
                        type: .toolUse,
                        toolUse: ToolUseEvent(
                            tool: call.name,
                            toolInput: parseArguments(call.arguments),
                            toolUseId: call.id
                        )
                    ))
                }
            case .tool:
                events.append(SessionEvent(
                    type: .toolResult,
                    toolResult: ToolResultEvent(
                        toolUseId: message.toolCallID ?? "",
                        toolOutput: AnyCodable(message.content ?? ""),
                        isError: nil
                    )
                ))
            case .user, .system:
                break
            }
        }
        return events
    }

    /// Tool arguments arrive as raw JSON text exactly as the model emitted
    /// it; tolerate the empty string some models emit for no-arg tools.
    private static func parseArguments(_ raw: String) -> [String: AnyCodable] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let dict = object as? [String: Any] else {
            return trimmed.isEmpty ? [:] : ["_raw": AnyCodable(trimmed)]
        }
        return dict.mapValues(AnyCodable.init)
    }
}
