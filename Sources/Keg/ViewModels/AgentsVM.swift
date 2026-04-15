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
            errorMessage = AgentIssuePresentation(error: error).message
        }
    }

    func archive(id: String) async {
        guard let client else { return }
        do {
            try await client.archiveAgent(id: id)
            agents.removeAll { $0.id == id }
        } catch {
            errorMessage = AgentIssuePresentation(error: error).message
        }
    }

    func createAgent(_ params: CreateAgentParams) async -> Agent? {
        guard let client else { return nil }
        do {
            let agent = try await client.createAgent(params)
            agents.insert(agent, at: 0)
            return agent
        } catch {
            errorMessage = AgentIssuePresentation(error: error).message
            return nil
        }
    }

    func duplicate(agent: Agent) async -> Agent? {
        let params = CreateAgentParams(
            name: "\(agent.name) (Copy)",
            model: agent.model.id,
            system: agent.system,
            description: agent.description,
            tools: agent.tools.isEmpty ? nil : agent.tools,
            skills: agent.skills.isEmpty ? nil : agent.skills,
            mcpServers: agent.mcpServers.isEmpty ? nil : agent.mcpServers,
            callableAgents: agent.callableAgents,
            metadata: agent.metadata
        )
        return await createAgent(params)
    }
}

