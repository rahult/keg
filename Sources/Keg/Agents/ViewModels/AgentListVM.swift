import Foundation

/// ViewModel for Agent List
@Observable
@MainActor
final class AgentListVM {
    var agents: [Agent] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedAgentID: String?
    var showEditor = false
    var editingAgent: Agent?

    private var client: ManagedAgentsClient?

    var filteredAgents: [Agent] {
        if searchText.isEmpty {
            return agents
        }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func setClient(_ client: ManagedAgentsClient?) {
        self.client = client
    }

    func load() async {
        guard let client else {
            error = "Not authenticated"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.listAgents()
            agents = response.data
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createAgent(_ params: CreateAgentParams) async throws -> Agent {
        guard let client else { throw ManagedAgentsError.missingAPIKey }
        let agent = try await client.createAgent(params)
        agents.insert(agent, at: 0)
        return agent
    }

    func updateAgent(id: String, params: CreateAgentParams) async throws -> Agent {
        guard let client else { throw ManagedAgentsError.missingAPIKey }
        let agent = try await client.updateAgent(id: id, params: params)
        if let index = agents.firstIndex(where: { $0.id == id }) {
            agents[index] = agent
        }
        return agent
    }

    func archiveAgent(id: String) async throws {
        guard let client else { throw ManagedAgentsError.missingAPIKey }
        try await client.archiveAgent(id: id)
        agents.removeAll { $0.id == id }
    }
}
