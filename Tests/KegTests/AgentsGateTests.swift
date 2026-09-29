import XCTest
@testable import Keg

@MainActor
final class AgentsGateTests: XCTestCase {
    private let key = "keg.showAgents"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testAgentsSectionIsVisibleByDefault() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(AppState.isAgentsEnabled)
    }

    func testAgentsSectionCanBeExplicitlyHidden() {
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(AppState.isAgentsEnabled)
    }

    func testAgentsSectionStaysVisibleWhenExplicitlyEnabled() {
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(AppState.isAgentsEnabled)
    }
}
