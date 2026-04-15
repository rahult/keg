import XCTest
@testable import Keg

final class AgentIssuePresentationTests: XCTestCase {

    func testClassifiesAuthErrors() {
        let issue = AgentIssuePresentation(error: ManagedAgentsError.missingAPIKey)

        XCTAssertEqual(issue.kind, .auth)
        XCTAssertEqual(issue.actionTitle, "Open Account")
        XCTAssertFalse(issue.showsUnavailableState)
    }

    func testClassifiesUnauthorizedHTTPAsAuth() {
        let issue = AgentIssuePresentation(error: ManagedAgentsError.httpError(statusCode: 401, message: "Unauthorized"))

        XCTAssertEqual(issue.kind, .auth)
        XCTAssertEqual(issue.actionTitle, "Open Account")
    }

    func testClassifiesTimeoutErrors() {
        let issue = AgentIssuePresentation(error: URLError(.timedOut))

        XCTAssertEqual(issue.kind, .timeout)
        XCTAssertEqual(issue.actionTitle, "Retry")
        XCTAssertTrue(issue.showsUnavailableState)
    }

    func testClassifiesOfflineErrors() {
        let issue = AgentIssuePresentation(error: URLError(.cannotConnectToHost))

        XCTAssertEqual(issue.kind, .offline)
        XCTAssertEqual(issue.actionTitle, "Retry")
        XCTAssertTrue(issue.showsUnavailableState)
    }

    @MainActor
    func testAppStateReachabilityTracksUnavailableIssues() {
        let appState = AppState()

        appState.updateAgentServiceReachability(for: "HTTP 408: Request timeout")
        XCTAssertEqual(appState.agentServiceReachability, .unreachable)
        XCTAssertTrue(appState.isAgentServiceUnavailable)

        appState.updateAgentServiceReachability(for: "Authentication failed")
        XCTAssertEqual(appState.agentServiceReachability, .reachable)
        XCTAssertFalse(appState.isAgentServiceUnavailable)
    }
}
