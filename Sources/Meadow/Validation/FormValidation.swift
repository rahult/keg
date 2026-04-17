import Foundation

struct AgentFormValidation {
    let name: String

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nameMessage: String? {
        trimmedName.isEmpty ? "Agent name is required." : nil
    }

    var isValid: Bool {
        nameMessage == nil
    }
}

struct SkillFormValidation {
    let name: String
    let instructions: String

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nameMessage: String? {
        trimmedName.isEmpty ? "Skill name is required." : nil
    }

    var instructionsMessage: String? {
        trimmedInstructions.isEmpty ? "Instructions are required." : nil
    }

    var isValid: Bool {
        nameMessage == nil && instructionsMessage == nil
    }
}

struct APIKeyValidation {
    let apiKey: String

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var message: String? {
        guard !trimmedAPIKey.isEmpty else { return "Claude API key is required." }
        guard trimmedAPIKey.hasPrefix("sk-") else { return "Claude API key should start with 'sk-'." }
        return nil
    }

    var isValid: Bool {
        message == nil
    }
}
