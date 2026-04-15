import Foundation

/// ViewModel for Skill List
@Observable
@MainActor
final class SkillListVM {
    var skills: [AgentSkillItem] = []
    var isLoading = false
    var error: String?
    var searchText = ""

    var filteredSkills: [AgentSkillItem] {
        if searchText.isEmpty { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() async {
        // TODO: Load from local storage
    }
}

struct AgentSkillItem: Identifiable, Codable {
    let id: String
    var name: String
    var description: String
    var instructions: String
    var examples: String?
    var createdAt: Date
    var updatedAt: Date
}
