import Foundation

/// ViewModel for Session List
@Observable
@MainActor
final class SessionListVM {
    var sessions: [Session] = []
    var agents: [String: Agent] = [:]
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedAgentIdFilter: String?

    private var client: ManagedAgentsClient?

    var filteredSessions: [Session] {
        var result = sessions
        if let agentId = selectedAgentIdFilter {
            result = result.filter { $0.agentId == agentId }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
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
            for agent in response.data {
                agents[agent.id] = agent
            }

            var allSessions: [Session] = []
            for agent in response.data {
                let agentSessions = try await client.listSessions(agentId: agent.id)
                allSessions.append(contentsOf: agentSessions.data)
            }
            sessions = allSessions
        } catch {
            self.error = error.localizedDescription
        }
    }
}
