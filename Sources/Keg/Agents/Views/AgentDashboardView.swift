import SwiftUI

/// Agent Dashboard - Overview of agents and recent activity
struct AgentDashboardView: View {
    @State private var vm = AgentDashboardVM()
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                liveContextSection

                if !appState.isAgentAuthenticated {
                    authenticationRequiredView
                } else if vm.isLoading && vm.activeAgents.isEmpty {
                    loadingView
                } else if let issue = currentIssue,
                          issue.showsUnavailableState,
                          vm.activeAgents.isEmpty,
                          vm.recentSessions.isEmpty {
                    unavailableStateView(issue)
                } else if vm.activeAgents.isEmpty && vm.recentSessions.isEmpty {
                    emptyStateView
                } else {
                    contentView
                }

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.selectedAgentSection = .useCases
                } label: {
                    Label("Use Cases", systemImage: "wand.and.stars")
                }
                .accessibilityLabel("Browse macOS agent use cases")
                .accessibilityHint("Open the template library for agent starting points")

                Button {
                    appState.selectedAgentSection = .agents
                } label: {
                    Label("Manage Agents", systemImage: "gearshape")
                }
                .accessibilityLabel("Navigate to manage agents")
                .accessibilityHint("Open the full agents list")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh dashboard")
                .accessibilityHint("Reload agents, recent sessions, and live desktop context")
            }
        }
        .task {
            await refresh()
        }
        .onChange(of: vm.error) { _, newValue in
            appState.updateAgentServiceReachability(for: newValue)
        }
        .overlay(alignment: .top) {
            if let issue = currentIssue {
                ErrorBanner(
                    message: issue.message,
                    actionTitle: issue.actionTitle,
                    onAction: { handle(issue: issue) }
                ) {
                    vm.error = nil
                    appState.updateAgentServiceReachability(for: nil)
                }
            }
        }
    }
    
    private func refresh() async {
        async let automationRefresh: Void = appState.refreshAgentAutomation()

        if let client = await appState.agentClient {
            await vm.load(client: client)
            appState.updateAgentServiceReachability(for: vm.error)
        }

        _ = await automationRefresh
    }

    private var currentIssue: AgentIssuePresentation? {
        AgentIssuePresentation(message: vm.error)
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents Dashboard")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Overview of your AI agents and recent activity")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agents Dashboard. Overview of your AI agents and recent activity.")
    }
    
    private var liveContextSection: some View {
        AgentLiveContextPanel(
            automation: appState.agentAutomationState,
            pendingApprovalCount: appState.pendingAgentApprovals.count,
            isRefreshing: appState.isRefreshingAgentAutomation,
            onRefresh: {
                Task { await appState.refreshAgentAutomation() }
            },
            onRequestNotifications: appState.agentAutomationState.notificationStatus == .notDetermined || appState.agentAutomationState.notificationStatus == .unknown ? {
                Task { await appState.requestAgentNotificationAccess() }
            } : nil
        )
    }

    private var authenticationRequiredView: some View {
        ContentUnavailableView {
            Label("Authentication Required", systemImage: "person.badge.key")
        } description: {
            Text("Connect your Claude API key in Settings to use Agents")
        } actions: {
            Button("Open Settings") {
                appState.openSettings()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Open app settings")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Authentication Required. Connect your Claude API key in Settings to use Agents.")
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading agents...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Agents Yet", systemImage: "person.2.badge.gearshape")
        } description: {
            Text("Start from a Mac-native use case or create your first agent from scratch")
        } actions: {
            Button("Browse Use Cases") {
                appState.selectedAgentSection = .useCases
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Open the template library")

            Button("Create Agent") {
                appState.selectedAgentSection = .agents
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Open the agents list to create a new agent")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No Agents Yet. Create your first agent to get started.")
    }

    private func unavailableStateView(_ issue: AgentIssuePresentation) -> some View {
        ContentUnavailableView {
            Label("Agents Unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text(issue.message)
        } actions: {
            Button(issue.actionTitle) {
                handle(issue: issue)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Resolve the current agents availability issue")
        }
    }

    private func handle(issue: AgentIssuePresentation) {
        switch issue.kind {
        case .auth:
            appState.openSettings()
        case .offline, .timeout, .generic:
            Task { await refresh() }
        }
    }
    
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !vm.activeAgents.isEmpty {
                activeAgentsSection
            }
            
            if !vm.recentSessions.isEmpty {
                recentSessionsSection
            }
        }
    }
    
    private var activeAgentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Active Agents")
                    .font(.headline)
                Spacer()
                Button("View All") {
                    appState.selectedAgentSection = .agents
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("View all agents")
            }
            
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)
            ], spacing: 12) {
                ForEach(vm.activeAgents) { agent in
                    AgentCard(agent: agent)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(vm.activeAgents.count) active agents")
    }
    
    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Sessions")
                    .font(.headline)
                Spacer()
                Button("View All") {
                    appState.selectedAgentSection = .sessions
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("View all sessions")
            }
            
            Table(vm.recentSessions) {
                TableColumn("Agent") { session in
                    Text(session.agentName)
                        .accessibilityLabel("Agent: \(session.agentName)")
                }
                TableColumn("Started") { session in
                    Text(session.started, style: .relative)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Started \(session.started, style: .relative) ago")
                }
                TableColumn("Messages") { session in
                    Text("\(session.messageCount)")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(session.messageCount) messages")
                }
                TableColumn("Status") { session in
                    StatusBadge(status: session.ended == nil ? "Active" : "Completed")
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .accessibilityLabel("Recent sessions table")
            .accessibilityHint("Use arrow keys to review recent sessions")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(vm.recentSessions.count) recent sessions")
    }
}

// MARK: - Supporting Views

struct AgentCard: View {
    let agent: AgentSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Circle()
                    .fill(agent.isActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(agent.isActive ? "Active" : "Inactive")
            }
            
            Text(agent.name)
                .font(.headline)
                .lineLimit(1)
            
            Text(agent.model)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if let lastUsed = agent.lastUsed {
                Text("Last used \(lastUsed, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(buildAccessibilityLabel())
        .accessibilityHint("Agent summary card")
    }
    
    private func buildAccessibilityLabel() -> String {
        var parts: [String] = []
        parts.append(agent.name)
        parts.append("Model: \(agent.model)")
        parts.append(agent.isActive ? "Status: Active" : "Status: Inactive")
        if let lastUsed = agent.lastUsed {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(for: lastUsed, relativeTo: Date())
            parts.append("Last used \(relative) ago")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class AgentDashboardVM {
    var activeAgents: [AgentSummary] = []
    var recentSessions: [SessionSummary] = []
    var isLoading = false
    var error: String?

    func load(client: ManagedAgentsClient?) async {
        guard let client else {
            activeAgents = []
            recentSessions = []
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let response = try await client.listAgents()
            activeAgents = response.data.prefix(6).map { agent in
                AgentSummary(
                    id: agent.id,
                    name: agent.name,
                    model: agent.model.id,
                    lastUsed: agent.updatedAt,
                    isActive: agent.archivedAt == nil
                )
            }
            
            var sessions: [SessionSummary] = []
            for agent in response.data.prefix(3) {
                let agentSessions = try await client.listSessions(agentId: agent.id)
                sessions.append(contentsOf: agentSessions.data.prefix(5).map { session in
                    SessionSummary(
                        id: session.id,
                        agentName: agent.name,
                        started: session.createdAt,
                        ended: session.status == .completed ? session.updatedAt : nil,
                        messageCount: 0
                    )
                })
            }
            recentSessions = sessions.sorted { $0.started > $1.started }
            
        } catch {
            self.error = AgentIssuePresentation(error: error).message
        }
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

#Preview {
    NavigationStack {
        AgentDashboardView()
            .environment(AppState())
    }
}
