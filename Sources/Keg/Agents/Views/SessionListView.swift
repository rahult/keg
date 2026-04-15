import SwiftUI

/// Session List - View conversation history
struct SessionListView: View {
    @State private var vm = SessionListVM()
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isAgentAuthenticated {
                authenticationRequiredView
            } else {
                filterBar
                
                if vm.isLoading && vm.sessions.isEmpty {
                    loadingView
                } else if vm.sessions.isEmpty {
                    emptyStateView
                } else {
                    sessionTable
                }
            }
        }
        .navigationTitle("Sessions")
        .searchable(text: $vm.searchText, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            await refresh()
        }
        .alert("Error", isPresented: .init(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }
    
    private func refresh() async {
        if let client = await appState.agentClient {
            await vm.load(client: client)
        }
    }
    
    private var authenticationRequiredView: some View {
        ContentUnavailableView {
            Label("Authentication Required", systemImage: "person.badge.key")
        } description: {
            Text("Connect your Claude API key in Account to view sessions")
        } actions: {
            Button("Open Account") {
                appState.currentArea = .agents
                appState.selectedAgentSection = .account
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var filterBar: some View {
        HStack {
            Picker("Agent", selection: $vm.selectedAgentIdFilter) {
                Text("All Agents").tag(nil as String?)
                ForEach(Array(vm.agents.values), id: \.id) { agent in
                    Text(agent.name).tag(agent.id as String?)
                }
            }
            .pickerStyle(.menu)
            
            Spacer()
            
            if !vm.sessions.isEmpty {
                Text("\(vm.filteredSessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading sessions...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "clock")
        } description: {
            Text("Start a conversation with an agent to see sessions here")
        }
    }
    
    private var sessionTable: some View {
        Table(vm.filteredIdentifiableSessions) {
            TableColumn("Agent") { item in
                Text(vm.agents[item.session.agentId]?.name ?? "Unknown")
            }
            .width(min: 120)
            
            TableColumn("Started") { item in
                Text(item.session.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100)
            
            TableColumn("Duration") { item in
                let duration = (item.session.updatedAt ?? Date()).timeIntervalSince(item.session.createdAt)
                Text(formatDuration(duration))
                    .foregroundStyle(.secondary)
            }
            .width(80)
            
            TableColumn("Status") { item in
                StatusBadge(status: item.session.status.rawValue.capitalized)
            }
            .width(80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - ViewModel

struct IdentifiableSession: Identifiable {
    let id: String
    let session: Session
    
    init(_ session: Session) {
        self.id = session.id
        self.session = session
    }
}

@Observable
@MainActor
final class SessionListVM {
    var sessions: [Session] = []
    var agents: [String: Agent] = [:]
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedAgentIdFilter: String?

    var filteredSessions: [Session] {
        var result = sessions
        
        if let agentId = selectedAgentIdFilter {
            result = result.filter { $0.agentId == agentId }
        }
        
        return result.sorted { $0.createdAt > $1.createdAt }
    }
    
    var filteredIdentifiableSessions: [IdentifiableSession] {
        filteredSessions.map { IdentifiableSession($0) }
    }

    func load(client: ManagedAgentsClient?) async {
        guard let client else {
            sessions = []
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

#Preview {
    NavigationStack {
        SessionListView()
            .environment(AppState())
    }
}
