import XCTest
@testable import Keg

/// Pure formatting/filtering logic behind the Traces viewer: duration and
/// waterfall-delta strings, search matching, short IDs, status colors. No
/// sockets — the store itself is covered by TraceStoreTests.
final class TracesFormattingTests: XCTestCase {

    private func summary(
        traceId: String = "abc123",
        name: String = "Fix the login bug",
        status: String = "completed"
    ) -> TraceSummary {
        TraceSummary(
            traceId: traceId,
            name: name,
            sessionStatus: status,
            eventCount: 3,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastEventAt: Date(timeIntervalSince1970: 1_033)
        )
    }

    // MARK: - Duration

    func testDurationSubSecondRendersMilliseconds() {
        let text = TraceFormatting.duration(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 0.42)
        )
        XCTAssertEqual(text, "420ms")
    }

    func testDurationUnderOneMinuteRendersSeconds() {
        let text = TraceFormatting.duration(
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_033)
        )
        XCTAssertEqual(text, "33s")
    }

    func testDurationUnderOneHourRendersMinutesAndSeconds() {
        let text = TraceFormatting.duration(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 125)
        )
        XCTAssertEqual(text, "2m 5s")
    }

    func testDurationOverOneHourRendersHoursAndMinutes() {
        let text = TraceFormatting.duration(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 3_780)
        )
        XCTAssertEqual(text, "1h 3m")
    }

    func testDurationNeverNegative() {
        let text = TraceFormatting.duration(
            from: Date(timeIntervalSince1970: 100),
            to: Date(timeIntervalSince1970: 50)
        )
        XCTAssertEqual(text, "0ms")
    }

    // MARK: - Waterfall delta

    func testDeltaMillisecondsUnderOneSecond() {
        XCTAssertEqual(TraceFormatting.delta(0.12), "120ms")
    }

    func testDeltaSecondsWithOneDecimal() {
        XCTAssertEqual(TraceFormatting.delta(1.234), "1.2s")
    }

    func testDeltaClampsNegativeToZero() {
        XCTAssertEqual(TraceFormatting.delta(-5), "0ms")
    }

    // MARK: - Search matching

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(TraceFormatting.matches("", trace: summary()))
        XCTAssertTrue(TraceFormatting.matches("   ", trace: summary()))
    }

    func testMatchesNameCaseInsensitively() {
        XCTAssertTrue(TraceFormatting.matches("login", trace: summary()))
        XCTAssertTrue(TraceFormatting.matches("LOGIN", trace: summary()))
        XCTAssertTrue(TraceFormatting.matches("fix the", trace: summary()))
    }

    func testMatchesTraceId() {
        XCTAssertTrue(TraceFormatting.matches("abc1", trace: summary()))
        XCTAssertTrue(TraceFormatting.matches("ABC123", trace: summary(traceId: "abc123def456")))
    }

    func testRejectsNonMatchingQuery() {
        XCTAssertFalse(TraceFormatting.matches("deploy", trace: summary()))
        XCTAssertFalse(TraceFormatting.matches("xyz", trace: summary()))
    }

    // MARK: - Short IDs

    func testShortIDTruncatesToTwelveCharacters() {
        XCTAssertEqual(TraceFormatting.shortID("0123456789abcdef"), "0123456789ab")
    }

    func testShortIDKeepsShortIdsWhole() {
        XCTAssertEqual(TraceFormatting.shortID("abc"), "abc")
    }

    // MARK: - Status colors

    func testRunningAndCompletedAreGreen() {
        XCTAssertEqual(TraceFormatting.statusColor("running"), .green)
        XCTAssertEqual(TraceFormatting.statusColor("Completed"), .green)
    }

    func testFailedIsRed() {
        XCTAssertEqual(TraceFormatting.statusColor("failed"), .red)
    }

    func testPendingIsBlueAndUnknownIsGray() {
        XCTAssertEqual(TraceFormatting.statusColor("pending"), .blue)
        XCTAssertEqual(TraceFormatting.statusColor(""), .gray)
        XCTAssertEqual(TraceFormatting.statusColor("whatever"), .gray)
    }
}
