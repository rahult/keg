import Foundation

/// Splits a streamed assistant reply into visible text and thinking text,
/// handling the `<think>…</think>` convention that many open models
/// (Qwen3, DeepSeek-R1 distills, Phi-4-reasoner, …) inline into `content`
/// even when the OpenAI-compatible server does not separate a reasoning
/// field.
///
/// The parser is delta-safe: open/close tags can arrive split across
/// chunks (`"<thi"` + `"nk>"`), so a hold-back buffer retains any suffix
/// that is a prefix of one of the tags until the stream disambiguates it.
/// At finish, whatever is held back flushes to the current channel.
struct CooperThinkStream {
    private(set) var visible: String = ""
    private(set) var thinking: String = ""
    private var insideThink = false
    private var holdBack = ""

    static let openTag = "<think>"
    static let closeTag = "</think>"

    mutating func feed(_ delta: String) -> (visibleDelta: String, thinkingDelta: String) {
        let visibleBefore = visible.count
        let thinkingBefore = thinking.count
        holdBack += delta

        while !holdBack.isEmpty {
            if insideThink {
                if let range = holdBack.range(of: Self.closeTag) {
                    thinking += String(holdBack[..<range.lowerBound])
                    holdBack.removeSubrange(..<range.upperBound)
                    insideThink = false
                } else {
                    // Flush everything that cannot be the start of a close
                    // tag; hold only the possible partial.
                    thinking += flushHoldBack(keepingPossibleTag: Self.closeTag)
                    break
                }
            } else {
                if let range = holdBack.range(of: Self.openTag) {
                    visible += String(holdBack[..<range.lowerBound])
                    holdBack.removeSubrange(..<range.upperBound)
                    insideThink = true
                } else {
                    visible += flushHoldBack(keepingPossibleTag: Self.openTag)
                    break
                }
            }
        }
        return (suffix(from: visible, before: visibleBefore), suffix(from: thinking, before: thinkingBefore))
    }

    /// The stream ended: release the hold-back buffer into the channel it
    /// currently belongs to. An unterminated `<think>` keeps everything as
    /// thinking — matching how those models behave.
    mutating func finish() -> (visibleDelta: String, thinkingDelta: String) {
        let visibleBefore = visible.count
        let thinkingBefore = thinking.count
        guard !holdBack.isEmpty else { return ("", "") }
        if insideThink {
            thinking += holdBack
        } else {
            visible += holdBack
        }
        holdBack = ""
        return (suffix(from: visible, before: visibleBefore), suffix(from: thinking, before: thinkingBefore))
    }

    /// Emits all of `holdBack` except a tail that could still grow into
    /// `tag`; the emitted part is returned and the tail stays held back.
    private mutating func flushHoldBack(keepingPossibleTag tag: String) -> String {
        let keep = Self.longestTagPrefixSuffix(holdBack, tag: tag)
        let flushCount = holdBack.count - keep
        guard flushCount > 0 else { return "" }
        let flushed = String(holdBack.prefix(flushCount))
        holdBack.removeFirst(flushCount)
        return flushed
    }

    private func suffix(from text: String, before count: Int) -> String {
        count >= text.count ? "" : String(text.suffix(text.count - count))
    }

    /// Length of the longest suffix of `text` that is a proper prefix of
    /// `tag` (0 when the tail cannot begin a tag). Character-based; the
    /// tags are ASCII and models stream whole characters.
    static func longestTagPrefixSuffix(_ text: String, tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let tail = String(text.suffix(length))
            if tag.hasPrefix(tail) {
                return length
            }
        }
        return 0
    }
}

/// Collects streamed `delta.tool_calls` fragments into complete calls.
/// OpenAI-compatible servers stream each call's name once and its JSON
/// arguments in arbitrary fragments, keyed by `index`.
struct CooperToolCallAccumulator {
    struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: PartialCall] = [:]

    mutating func apply(_ deltas: [CooperWire.Chunk.Choice.ToolCallDelta]) {
        for delta in deltas {
            let index = delta.index ?? partials.count
            var partial = partials[index] ?? PartialCall()
            if let id = delta.id, !id.isEmpty { partial.id = id }
            if let name = delta.function?.name, !name.isEmpty { partial.name += name }
            if let arguments = delta.function?.arguments { partial.arguments += arguments }
            partials[index] = partial
        }
    }

    var hasCalls: Bool { !partials.isEmpty }

    /// Assembled calls in index order. Calls with no name are dropped —
    /// some servers emit a leading empty-index fragment.
    var assembled: [CooperChatMessage.ToolCall] {
        partials
            .sorted { $0.key < $1.key }
            .compactMap { _, partial in
                guard !partial.name.isEmpty else { return nil }
                return CooperChatMessage.ToolCall(
                    id: partial.id.isEmpty ? "call_\(partial.name)" : partial.id,
                    name: partial.name,
                    arguments: partial.arguments
                )
            }
    }
}
