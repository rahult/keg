import XCTest
@testable import Keg

final class SoftwareUpdatePolicyTests: XCTestCase {

    // MARK: - Check frequency

    func testFrequencyRawValuesAreAboveSparklesOneHourMinimum() {
        for frequency in UpdateCheckFrequency.allCases {
            XCTAssertGreaterThanOrEqual(
                frequency.rawValue, 3600,
                "Sparkle silently refuses intervals under an hour, which would leave the app never checking"
            )
        }
    }

    func testClosestMapsAnExactIntervalToItsOwnCase() {
        XCTAssertEqual(UpdateCheckFrequency.closest(to: 86_400), .daily)
        XCTAssertEqual(UpdateCheckFrequency.closest(to: 604_800), .weekly)
    }

    /// Sparkle persists the interval as a bare number of seconds, so a value
    /// set by an older build — or by hand in defaults — need not match any
    /// case we offer. The picker still has to show something.
    func testClosestSnapsAnUnrecognisedIntervalToTheNearestCase() {
        XCTAssertEqual(UpdateCheckFrequency.closest(to: 3600), .daily)
        XCTAssertEqual(UpdateCheckFrequency.closest(to: 500_000), .weekly)
        XCTAssertEqual(UpdateCheckFrequency.closest(to: 0), .daily)
    }

    // MARK: - Version display

    func testPublishedBuildShowsItsBuildNumber() {
        XCTAssertEqual(AppVersion.displayString(short: "0.2.0", build: "417"), "0.2.0 (417)")
    }

    func testLocalBuildOmitsThePlaceholderBuildNumber() {
        XCTAssertEqual(AppVersion.displayString(short: "0.2.0", build: "1"), "0.2.0")
        XCTAssertEqual(AppVersion.displayString(short: "0.0.0-dev", build: "0"), "0.0.0-dev")
    }
}
