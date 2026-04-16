import XCTest
@testable import Keg

// MARK: - SessionInboxTests

final class SessionInboxTests: XCTestCase {

    // MARK: - Tool Mention Parsing

    func testParseToolMentionsBareWord() {
        let input = "Use @read_file to read the config, then @write_file to save."
        let tools = SessionManager.parseToolMentions(input)
        XCTAssertEqual(tools, ["read_file", "write_file"])
    }

    func testParseToolMentionsDoubleQuoted() {
        let input = "Call @\"custom tool\" with the data."
        let tools = SessionManager.parseToolMentions(input)
        XCTAssertEqual(tools, ["custom tool"])
    }

    func testParseToolMentionsSingleQuoted() {
        let input = "Use @'another tool' for this task."
        let tools = SessionManager.parseToolMentions(input)
        XCTAssertEqual(tools, ["another tool"])
    }

    func testParseToolMentionsMixed() {
        let input = "@read_file and @\"custom tool\" and @write_file"
        let tools = SessionManager.parseToolMentions(input)
        XCTAssertEqual(tools, ["read_file", "custom tool", "write_file"])
    }

    func testParseToolMentionsDeduplicates() {
        let input = "@read_file appears twice @read_file"
        let tools = SessionManager.parseToolMentions(input)
        XCTAssertEqual(tools, ["read_file"])
    }

    func testParseToolMentionsNoMentions() {
        let input = "Just a plain message with no tool mentions."
        let tools = SessionManager.parseToolMentions(input)
        XCTAssertEqual(tools, [])
    }

    func testParseToolMentionsWordCharacters() {
        let input = "@my-tool_v2 and @anotherTool123"
        let tools = SessionManager.parseToolMentions(input)
        XCTAssertEqual(tools, ["my-tool_v2", "anotherTool123"])
    }

    // MARK: - SessionWorkflowStatus

    func testSessionWorkflowStatusValues() {
        XCTAssertEqual(SessionWorkflowStatus.todo.rawValue, "Todo")
        XCTAssertEqual(SessionWorkflowStatus.inProgress.rawValue, "In Progress")
        XCTAssertEqual(SessionWorkflowStatus.needsReview.rawValue, "Needs Review")
        XCTAssertEqual(SessionWorkflowStatus.done.rawValue, "Done")
    }

    func testSessionWorkflowStatusAllCases() {
        let allCases = SessionWorkflowStatus.allCases
        XCTAssertEqual(allCases.count, 4)
        XCTAssertTrue(allCases.contains(.todo))
        XCTAssertTrue(allCases.contains(.inProgress))
        XCTAssertTrue(allCases.contains(.needsReview))
        XCTAssertTrue(allCases.contains(.done))
    }

    // MARK: - Session isFlagged

    func testSessionIsFlaggedDefault() {
        let session = Session(
            id: "test-session",
            type: "agent",
            agentId: "agent-1",
            agentVersion: 1,
            environmentId: "env-1",
            status: .running,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertFalse(session.isFlagged)
    }

    func testSessionIsFlaggedSet() {
        var session = Session(
            id: "test-session",
            type: "agent",
            agentId: "agent-1",
            agentVersion: 1,
            environmentId: "env-1",
            status: .running,
            createdAt: Date(),
            updatedAt: Date(),
            isFlagged: true
        )
        XCTAssertTrue(session.isFlagged)
        session.isFlagged = false
        XCTAssertFalse(session.isFlagged)
    }

    // MARK: - SkillTemplate

    func testSkillTemplateBuiltInsNotEmpty() {
        XCTAssertFalse(SkillTemplate.builtIns.isEmpty)
    }

    func testSkillTemplateHasRequiredFields() {
        for template in SkillTemplate.builtIns {
            XCTAssertFalse(template.id.isEmpty, "Template \(template.name) has empty id")
            XCTAssertFalse(template.name.isEmpty, "Template has empty name")
            XCTAssertFalse(template.templatePrompt.isEmpty, "Template \(template.name) has empty prompt")
        }
    }

    func testSkillTemplateInstantiate() async {
        let template = SkillTemplate.builtIns.first!
        let prompt = await SkillTemplateRegistry.shared.instantiate(template)
        XCTAssertEqual(prompt, template.templatePrompt)
    }

    func testSkillTemplateInstantiateWithContext() async {
        let template = SkillTemplate(
            id: "test",
            name: "Test",
            description: "A test template",
            templatePrompt: "Review the code in {{file}} for {{language}}",
            category: .development
        )
        let result = await SkillTemplateRegistry.shared.instantiate(template, context: [
            "file": "main.swift",
            "language": "Swift"
        ])
        XCTAssertTrue(result.contains("main.swift"))
        XCTAssertTrue(result.contains("Swift"))
    }

    func testSkillTemplateCategories() {
        XCTAssertEqual(SkillTemplateCategory.allCases.count, 8)
    }

    func testSkillTemplateRegistryTemplatesByCategory() async {
        let devTemplates = await SkillTemplateRegistry.shared.templates(in: .development)
        XCTAssertFalse(devTemplates.isEmpty)
    }
}
