import Foundation

@Observable
@MainActor
final class AgentsVM {
    var agents: [Agent] = []
    var isLoading = false
    var errorMessage: String?
    var searchText = ""

    private var client: ManagedAgentsClient?

    var filteredAgents: [Agent] {
        guard !searchText.isEmpty else { return agents }
        return agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    func setClient(_ client: ManagedAgentsClient?) {
        self.client = client
    }

    func refresh() async {
        guard let client else {
            errorMessage = "Not authenticated"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.listAgents()
            agents = response.data
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archive(id: String) async {
        guard let client else { return }
        do {
            try await client.archiveAgent(id: id)
            agents.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAgent(_ params: CreateAgentParams) async -> Agent? {
        guard let client else { return nil }
        do {
            let agent = try await client.createAgent(params)
            agents.insert(agent, at: 0)
            return agent
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
