import SwiftUI

/// Agent Dashboard - Overview of agents and recent activity
struct AgentDashboardView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Agents Dashboard", systemImage: "square.grid.2x2")
        } description: {
            Text("Manage your AI agents and conversations")
        } actions: {
            Button("Get Started") {
                // Navigate to agents
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    AgentDashboardView()
}
