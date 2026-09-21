import Foundation

/// Wire types for the OpenAI chat-completions dialect — request building,
/// streamed-chunk decoding, and error-body decoding. Deliberately tolerant:
/// compatible servers disagree on optional fields, so everything not needed
/// decodes as nil and type mismatches degrade to "ignored" rather than a
/// failed turn.
enum CooperWire {
    // MARK: - Request building

    static func requestBody(
        messages: [CooperChatMessage],
        tools: [CooperToolSpec],
        config: CooperRemoteConfig
    ) throws -> Data {
        var body: [String: CooperJSONValue] = [
            "model": .string(config.model.trimmingCharacters(in: .whitespacesAndNewlines)),
            "messages": .array(messages.map(messageBody)),
            "stream": .bool(true),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map(toolBody))
        }
        if let effort = config.thinking.reasoningEffort {
            body["reasoning_effort"] = .string(effort)
        }
        // User's escape hatch goes in last so it can override anything
        // above (temperature, max_tokens, provider-specific switches).
        let extra = config.extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            guard let data = extra.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let extraValues = object as? [String: Any] else {
                throw CooperRemoteError.configuration("Extra request JSON is not a valid JSON object.")
            }
            for (key, value) in extraValues {
                body[key] = CooperJSONValue(any: value)
            }
        }
        return try JSONEncoder().encode(body)
    }

    static func messageBody(_ message: CooperChatMessage) -> CooperJSONValue {
        switch message.role {
        case .system, .user:
            return .object([
                "role": .string(message.role.rawValue),
                "content": .string(message.content ?? ""),
            ])
        case .assistant:
            var object: [String: CooperJSONValue] = [
                "role": .string("assistant"),
                "content": .string(message.content ?? ""),
            ]
            if let calls = message.toolCalls, !calls.isEmpty {
                object["tool_calls"] = .array(calls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(call.arguments),
                        ]),
                    ])
                })
            }
            return .object(object)
        case .tool:
            return .object([
                "role": .string("tool"),
                "tool_call_id": .string(message.toolCallID ?? ""),
                "content": .string(message.content ?? ""),
            ])
        }
    }

    static func toolBody(_ spec: CooperToolSpec) -> CooperJSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(spec.name),
                "description": .string(spec.description),
                "parameters": spec.parameters,
            ]),
        ])
    }

    // MARK: - Streamed chunks

    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
                /// DeepSeek-R1 style reasoning field.
                var reasoning_content: String?
                /// OpenRouter-style reasoning field.
                var reasoning: String?
                var tool_calls: [ToolCallDelta]?
            }

            struct ToolCallDelta: Decodable {
                struct Function: Decodable {
                    var name: String?
                    var arguments: String?
                }

                var index: Int?
                var id: String?
                var function: Function?
            }

            var delta: Delta?
            /// "stop", "tool_calls", "length", "content_filter", …
            var finish_reason: String?
        }

        var choices: [Choice]?
    }

    // MARK: - Error bodies

    /// Best-effort extraction of a provider error message from an error
    /// response body (`{"error": {"message": "…"}}` or a bare string).
    static func errorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            let text = String(data: body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
        if let dict = object as? [String: Any] {
            if let error = dict["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = dict["error"] as? String { return error }
            if let message = dict["message"] as? String { return message }
            if let detail = dict["detail"] as? String { return detail }
        }
        return nil
    }

    /// Model list responses (`{"data": [{"id": …}]}`).
    static func modelIDs(from body: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let dict = object as? [String: Any],
              let data = dict["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { $0["id"] as? String }.sorted()
    }
}

/// Errors the remote path can raise, in the shapes the controller's
/// recovery logic needs (throttle / overflow / plain copy).
enum CooperRemoteError: LocalizedError, Sendable {
    case configuration(String)
    /// Non-200 from the provider; `status` drives 401/404 copy.
    case http(status: Int, message: String)
    case network(String)
    /// The stream broke mid-reply after content was already shown.
    case interrupted(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .interrupted(let message): return message
        case .http(_, let message): return message
        case .network(let message): return message
        }
    }

    static func isContextOverflow(_ error: Error) -> Bool {
        let needles = ["context length", "context window", "maximum context",
                       "too many tokens", "context_length_exceeded", "reduce the length"]
        let haystack: String
        if let remote = error as? CooperRemoteError, case .http(_, let message) = remote {
            haystack = message.lowercased()
        } else {
            haystack = error.localizedDescription.lowercased()
        }
        return needles.contains { haystack.contains($0) }
    }
}
