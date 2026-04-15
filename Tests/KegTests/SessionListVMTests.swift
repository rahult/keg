import XCTest
@testable import Keg

@MainActor
final class SessionListVMTests: XCTestCase {

    func testDateFilterTodayReturnsOnlyTodaySessions() {
        let vm = SessionListVM()
        vm.sessions = [
            makeSession(id: "today", createdAt: Date()),
            makeSession(id: "old", createdAt: Calendar.current.date(byAdding: .day, value: -2, to: Date())!)
        ]
        vm.selectedDateFilter = .today

        XCTAssertEqual(vm.filteredSessions.map(\.id), ["today"])
    }

    func testDateFilterWeekExcludesOlderSessions() {
        let vm = SessionListVM()
        vm.sessions = [
            makeSession(id: "recent", createdAt: Calendar.current.date(byAdding: .day, value: -3, to: Date())!),
            makeSession(id: "stale", createdAt: Calendar.current.date(byAdding: .day, value: -10, to: Date())!)
        ]
        vm.selectedDateFilter = .week

        XCTAssertEqual(vm.filteredSessions.map(\.id), ["recent"])
    }

    func testFlaggedFilterUsesWorkflowState() {
        let vm = SessionListVM()
        vm.sessions = [
            makeSession(id: "flagged", createdAt: Date()),
            makeSession(id: "plain", createdAt: Date())
        ]
        vm.workflowStates = [
            "flagged": SessionWorkflowState(sessionId: "flagged", isFlagged: true),
            "plain": SessionWorkflowState(sessionId: "plain", isFlagged: false)
        ]
        vm.showFlaggedOnly = true

        XCTAssertEqual(vm.filteredSessions.map(\.id), ["flagged"])
    }

    private func makeSession(id: String, createdAt: Date) -> Session {
        Session(
            id: id,
            type: "session",
            agentId: "agent-1",
            agentVersion: 1,
            environmentId: "env-1",
            status: .running,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(60)
        )
    }
}
