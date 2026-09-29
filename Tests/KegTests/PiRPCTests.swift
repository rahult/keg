import XCTest
@testable import Keg

final class PiRPCTests: XCTestCase {

    // MARK: - Framing (strict LF-only JSONL per pi docs)

    func testSplitRecordsSeparatesOnLFOnly() {
        let chunk = Data(#"{"type":"agent_start"}"#.utf8) + Data([0x0A]) + Data(#"{"type":"turn_start"}"#.utf8) + Data([0x0A])
        let (records, remainder) = PiRPC.splitRecords(chunk)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testSplitRecordsKeepsPartialLineAsRemainder() {
        let chunk = Data(#"{"type":"agent_start"}"#.utf8) + Data([0x0A]) + Data(#"{"type":"turn_"#.utf8)
        let (records, remainder) = PiRPC.splitRecords(chunk)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(String(data: remainder, encoding: .utf8), #"{"type":"turn_"#)
    }

    func testSplitRecordsDoesNotSplitOnUnicodeLineSeparatorInsideJSON() {
        // U+2028 is valid inside a JSON string and is NOT a record boundary.
        let sep = String(Character(Unicode.Scalar(0x2028)!))
        let json = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"line1\#(sep)line2"}]}}"#
        let chunk = Data(json.utf8) + Data([0x0A])
        let (records, remainder) = PiRPC.splitRecords(chunk)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testSplitRecordsAcceptsCRLF() {
        let chunk = Data(#"{"type":"agent_start"}"#.utf8) + Data([0x0D, 0x0A])
        let (records, _) = PiRPC.splitRecords(chunk)
        XCTAssertEqual(records.count, 1)
    }

    // MARK: - Record → SessionEvent mapping

    private func record(_ json: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
    }

    func testMapsAssistantMessageEndToAssistantEvent() {
        let event = PiRPC.mapEvent(record(#"""
        {"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hello world"}]}}
        """#))
        XCTAssertEqual(event?.type, .assistantMessage)
        XCTAssertEqual(event?.content, "Hello world")
    }

    func testMapsMultiblockAssistantContentByConcatenatingText() {
        let event = PiRPC.mapEvent(record(#"""
        {"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"part one "},{"type":"text","text":"part two"}]}}
        """#))
        XCTAssertEqual(event?.content, "part one part two")
    }

    func testIgnoresUserMessageEnd() {
        let event = PiRPC.mapEvent(record(#"""
        {"type":"message_end","message":{"role":"user","content":"the prompt"}}
        """#))
        XCTAssertNil(event)
    }

    func testIgnoresLifecycleAndQueueEvents() {
        for type in ["agent_start", "agent_end", "agent_settled", "turn_start", "turn_end",
                     "queue_update", "compaction_start", "compaction_end",
                     "auto_retry_start", "auto_retry_end", "message_start"] {
            XCTAssertNil(PiRPC.mapEvent(record(#"{"type":"\#(type)"}"#)), "\(type) should not map")
        }
    }

    func testMapsToolExecutionStartToToolUse() {
        let event = PiRPC.mapEvent(record(#"""
        {"type":"tool_execution_start","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"}}
        """#))
        XCTAssertEqual(event?.type, .toolUse)
        XCTAssertEqual(event?.toolUse?.tool, "bash")
        XCTAssertEqual(event?.toolUse?.toolUseId, "call_abc123")
        XCTAssertEqual(event?.toolUse?.toolInput["command"]?.value as? String, "ls -la")
    }

    func testMapsToolExecutionEndToToolResult() {
        let event = PiRPC.mapEvent(record(#"""
        {"type":"tool_execution_end","toolCallId":"call_abc123","toolName":"bash","result":{"content":[{"type":"text","text":"total 48"}],"details":{}},"isError":false}
        """#))
        XCTAssertEqual(event?.type, .toolResult)
        XCTAssertEqual(event?.toolResult?.toolUseId, "call_abc123")
        XCTAssertEqual(event?.toolResult?.toolOutput.value as? String, "total 48")
        XCTAssertEqual(event?.toolResult?.isError, false)
    }

    func testMapsToolExecutionEndWithErrorFlag() {
        let event = PiRPC.mapEvent(record(#"""
        {"type":"tool_execution_end","toolCallId":"call_x","toolName":"bash","result":{"content":[{"type":"text","text":"boom"}]},"isError":true}
        """#))
        XCTAssertEqual(event?.toolResult?.isError, true)
    }

    func testIgnoresMessageUpdateDeltas() {
        let event = PiRPC.mapEvent(record(#"""
        {"type":"message_update","usage":{"totalTokens":101},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello "}}
        """#))
        XCTAssertNil(event)
    }

    // MARK: - Command construction

    func testPromptCommandIsStrictJSONL() throws {
        let data = PiRPC.promptCommand(id: "req-1", message: "fix it")
        let line = String(data: data, encoding: .utf8)!
        XCTAssertTrue(line.hasSuffix("\n"))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(parsed["id"] as? String, "req-1")
        XCTAssertEqual(parsed["type"] as? String, "prompt")
        XCTAssertEqual(parsed["message"] as? String, "fix it")
    }
}
