import XCTest
@testable import Keg

final class FormValidationTests: XCTestCase {

    func testAgentFormRequiresNonWhitespaceName() {
        let validation = AgentFormValidation(name: "   ")

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.nameMessage, "Agent name is required.")
    }

    func testAgentFormTrimsValidName() {
        let validation = AgentFormValidation(name: "  Build Agent  ")

        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.trimmedName, "Build Agent")
    }

    func testSkillFormRequiresNameAndInstructions() {
        let validation = SkillFormValidation(name: " ", instructions: "\n")

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.nameMessage, "Skill name is required.")
        XCTAssertEqual(validation.instructionsMessage, "Instructions are required.")
    }

    func testAPIKeyValidationRequiresClaudeKeyPrefix() {
        let invalid = APIKeyValidation(apiKey: "abc123")
        let valid = APIKeyValidation(apiKey: "  sk-ant-api-test  ")

        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.message, "Claude API key should start with 'sk-'.")
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.trimmedAPIKey, "sk-ant-api-test")
    }
}
