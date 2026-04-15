import XCTest
@testable import Keg

final class AgentUseCaseTests: XCTestCase {

    func testUseCaseCatalogContainsFiveStableEntries() {
        XCTAssertEqual(AgentUseCase.all.count, 5)
        XCTAssertEqual(Set(AgentUseCase.all.map(\.id)).count, 5)
    }

    func testEveryUseCaseHasMacSpecificDraftContent() {
        for useCase in AgentUseCase.all {
            XCTAssertFalse(useCase.title.isEmpty)
            XCTAssertFalse(useCase.summary.isEmpty)
            XCTAssertFalse(useCase.macAdvantage.isEmpty)
            XCTAssertFalse(useCase.surfaces.isEmpty)
            XCTAssertFalse(useCase.capabilities.isEmpty)
            XCTAssertFalse(useCase.samplePrompts.isEmpty)
            XCTAssertFalse(useCase.draft.name.isEmpty)
            XCTAssertFalse(useCase.draft.description.isEmpty)
            XCTAssertFalse(useCase.draft.systemPrompt.isEmpty)
            XCTAssertEqual(useCase.draft.metadata?["keg.use_case_id"], useCase.id)
        }
    }

    func testLookupByIdentifierReturnsExpectedUseCase() {
        let useCase = AgentUseCase.byID("approval-inbox")

        XCTAssertEqual(useCase?.title, "Approval Inbox")
        XCTAssertEqual(useCase?.draft.metadata?["keg.use_case_surface"], "menu-bar")
    }

    func testBlankDraftStaysEmpty() {
        XCTAssertEqual(AgentUseCase.blankDraft.name, "")
        XCTAssertEqual(AgentUseCase.blankDraft.description, "")
        XCTAssertEqual(AgentUseCase.blankDraft.systemPrompt, "")
        XCTAssertNil(AgentUseCase.blankDraft.metadata)
    }
}
