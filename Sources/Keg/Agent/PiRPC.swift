import Foundation

/// pi (https://github.com/earendil-works/pi) RPC-mode protocol helpers.
///
/// pi runs as a long-lived subprocess speaking strict JSONL: commands on
/// stdin, responses and session events on stdout, diagnostics on stderr.
/// Records are LF-terminated; Unicode line/paragraph separators are valid
/// inside JSON strings and must never be treated as boundaries.
enum PiRPC {

    // MARK: - Framing

    /// Split a raw byte chunk into complete LF-terminated records plus the
    /// trailing partial record (which the next chunk continues).
    static func splitRecords(_ data: Data) -> (records: [Data], remainder: Data) {
        var records: [Data] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                var record = data.subdata(in: start..<index)
                // Tolerate CRLF: strip a trailing CR.
                if let last = record.last, last == 0x0D {
                    record.removeLast()
                }
                if !record.isEmpty {
                    records.append(record)
                }
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        return (records, data.subdata(in: start..<data.endIndex))
    }

    // MARK: - Commands

    /// One `prompt` command, strictly framed with a terminating LF.
    static func promptCommand(id: String, message: String) -> Data {
        let object: [String: Any] = ["id": id, "type": "prompt", "message": message]
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    // MARK: - Record → SessionEvent

    /// Translate one pi session-event record into the Keg session log's
    /// event model. Returns nil for records the log doesn't keep (lifecycle
    /// noise, deltas, user messages — the runner already logged the prompt).
    static func mapEvent(_ record: [String: Any]) -> SessionEvent? {
        switch record["type"] as? String {
        case "message_end":
            guard let message = record["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { return nil }
            let text = extractText(from: message["content"])
            return SessionEvent(type: .assistantMessage, content: text)

        case "tool_execution_start":
            guard let toolCallId = record["toolCallId"] as? String,
                  let toolName = record["toolName"] as? String else { return nil }
            let args = (record["args"] as? [String: Any]) ?? [:]
            return SessionEvent(
                type: .toolUse,
                toolUse: ToolUseEvent(
                    tool: toolName,
                    toolInput: args.mapValues(AnyCodable.init),
                    toolUseId: toolCallId
                )
            )

        case "tool_execution_end":
            guard let toolCallId = record["toolCallId"] as? String else { return nil }
            let result = record["result"] as? [String: Any]
            let text = extractText(from: result?["content"])
            return SessionEvent(
                type: .toolResult,
                toolResult: ToolResultEvent(
                    toolUseId: toolCallId,
                    toolOutput: AnyCodable(text),
                    isError: record["isError"] as? Bool
                )
            )

        default:
            return nil
        }
    }

    /// Concatenate the text of `text` content blocks; falls back to the
    /// value itself when content is a plain string.
    private static func extractText(from content: Any?) -> String {
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
        }
        if let string = content as? String {
            return string
        }
        return ""
    }
}
