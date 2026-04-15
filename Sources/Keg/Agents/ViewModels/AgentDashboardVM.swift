import Foundation

/// ViewModel for Agent Dashboard
@Observable
@MainActor
final class AgentDashboardVM {
    var activeAgents: [AgentSummary] = []
    var recentSessions: [SessionSummary] = []
    var isLoading = false
    var error: String?

    func load() async {
        // TODO: Load from ManagedAgentsClient
    }
}

struct AgentSummary: Identifiable {
    let id: String
    let name: String
    let model: String
    let lastUsed: Date?
    let isActive: Bool
}

struct SessionSummary: Identifiable {
    let id: String
    let agentName: String
    let started: Date
    let ended: Date?
    let messageCount: Int
}
