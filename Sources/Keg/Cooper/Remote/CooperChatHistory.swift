import Foundation

/// One message in the remote model's conversation, shaped after the OpenAI
/// chat-completions dialect. Persisted to `~/.keg/cooper/remote-transcript.json`
/// so the next launch rehydrates the same way the on-device transcript does.
struct CooperChatMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    struct ToolCall: Codable, Equatable, Sendable {
        var id: String
        var name: String
        /// Raw JSON text exactly as the model emitted it — resent verbatim
        /// on subsequent requests.
        var arguments: String
    }

    var role: Role
    /// Text content. Nil for assistant messages that carry only tool calls.
    var content: String?
    /// Present when `role == .assistant` and the model asked for tools.
    var toolCalls: [ToolCall]?
    /// Present when `role == .tool`.
    var toolCallID: String?
    /// Tool name, present when `role == .tool`.
    var toolName: String?

    init(role: Role, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
    }

    static func system(_ text: String) -> CooperChatMessage { CooperChatMessage(role: .system, content: text) }
    static func user(_ text: String) -> CooperChatMessage { CooperChatMessage(role: .user, content: text) }
    static func assistant(_ text: String, toolCalls: [ToolCall]? = nil) -> CooperChatMessage {
        CooperChatMessage(role: .assistant, content: text.isEmpty && toolCalls != nil ? nil : text, toolCalls: toolCalls)
    }
    static func toolResult(callID: String, name: String, text: String) -> CooperChatMessage {
        CooperChatMessage(role: .tool, content: text, toolCallID: callID, toolName: name)
    }
}

/// Persistence + trimming for the remote history. Kept separate from
/// `CooperController` so it is unit-testable without any model or actor.
enum CooperChatHistory {
    static var fileURL: URL {
        URL.homeDirectory.appendingPathComponent(".keg/cooper/remote-transcript.json")
    }

    static func load() -> [CooperChatMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let messages = try? JSONDecoder().decode([CooperChatMessage].self, from: data) else { return [] }
        return messages
    }

    static func persist(_ messages: [CooperChatMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func removePersistence() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Keeps the system message plus the most recent exchanges. A tool
    /// result may never appear without the assistant tool-call that caused
    /// it, so leading `.tool` messages at the seam are dropped; an
    /// assistant tool-call whose results were trimmed is rewritten to a
    /// plain assistant note (some providers hard-reject the orphan shape).
    static func trimmed(_ messages: [CooperChatMessage], keepLast: Int = 24) -> [CooperChatMessage] {
        guard let firstSystem = messages.first(where: { $0.role == .system }) else { return messages }
        let rest = messages.filter { $0.role != .system }
        guard rest.count > keepLast else { return messages }

        var tail = Array(rest.suffix(keepLast))
        while let first = tail.first, first.role == .tool {
            tail.removeFirst()
        }
        var result = [firstSystem] + tail
        // Find assistant messages with tool calls whose results no longer
        // follow them (result was trimmed or calls dropped mid-sequence).
        var patched: [CooperChatMessage] = []
        for (index, message) in result.enumerated() {
            if let calls = message.toolCalls, !calls.isEmpty {
                let followingIDs = Set(result[(index + 1)...].prefix(calls.count).compactMap(\.toolCallID))
                let answered = calls.allSatisfy { followingIDs.contains($0.id) }
                if answered {
                    patched.append(message)
                } else {
                    var note = message
                    note.toolCalls = nil
                    if note.content == nil || note.content?.isEmpty == true {
                        note.content = "(earlier tool activity)"
                    }
                    patched.append(note)
                }
            } else {
                patched.append(message)
            }
        }
        result = patched
        return result
    }
}
