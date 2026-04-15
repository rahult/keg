import XCTest
@testable import Keg

final class AgentAutomationSupportTests: XCTestCase {

    func testBrowserContextParsingSplitsTitleURLAndSelection() {
        let parsed = AgentAutomationService.parseBrowserContext("Example Title\nhttps://example.com\nline one\nline two")

        XCTAssertEqual(parsed.title, "Example Title")
        XCTAssertEqual(parsed.url, "https://example.com")
        XCTAssertEqual(parsed.selectedText, "line one\nline two")
    }

    func testTranscriptTruncationKeepsTail() {
        let transcript = (1...5).map(String.init).joined(separator: "\n")

        let truncated = AgentAutomationService.truncateTranscript(transcript, maxLines: 2)

        XCTAssertEqual(truncated, "4\n5")
    }

    func testDownloadsUseCaseFlagsMissingFinderSelection() {
        let checks = AgentUseCase.byID("downloads-desk-zero")?.capabilityChecks(using: AgentAutomationState(
            context: AgentDesktopContextSnapshot(activeAppName: "Finder"),
            notificationStatus: .authorized
        ))

        let finderCheck = checks?.first(where: { $0.capability == .finderSelection })
        XCTAssertEqual(finderCheck?.status, .attention)
        XCTAssertEqual(finderCheck?.remediation, "Select files in Finder to give this use case live input.")
    }

    func testApprovalInboxTreatsNotificationsAsUnavailableWhenDenied() {
        let checks = AgentUseCase.byID("approval-inbox")?.capabilityChecks(using: AgentAutomationState(
            context: AgentDesktopContextSnapshot(activeAppName: "Keg"),
            notificationStatus: .denied
        ))

        let notificationCheck = checks?.first(where: { $0.capability == .notifications })
        XCTAssertEqual(notificationCheck?.status, .unavailable)
    }

    func testApprovalPreviewUsesUseCaseSpecificSummary() throws {
        let item = AgentApprovalItem.preview(
            for: try XCTUnwrap(AgentUseCase.byID("local-coding-copilot")),
            context: AgentDesktopContextSnapshot(activeAppName: "Xcode")
        )

        XCTAssertEqual(item.useCaseID, "local-coding-copilot")
        XCTAssertEqual(item.source, "Xcode")
        XCTAssertTrue(item.summary.contains("draft patch"))
    }

    @MainActor
    func testAppStateApprovalFiltersOnlyPendingItems() {
        let appState = AppState()
        appState.agentApprovalItems = [
            AgentApprovalItem(useCaseID: "approval-inbox", title: "Pending", summary: "p", source: "Xcode", status: .pending),
            AgentApprovalItem(useCaseID: "approval-inbox", title: "Approved", summary: "a", source: "Xcode", status: .approved)
        ]

        XCTAssertEqual(appState.pendingAgentApprovals.count, 1)
        XCTAssertEqual(appState.pendingAgentApprovals.first?.title, "Pending")
    }
}
