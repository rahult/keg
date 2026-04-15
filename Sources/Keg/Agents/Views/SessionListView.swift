import SwiftUI

/// Session List - View conversation history
struct SessionListView: View {
    @State private var vm = SessionListVM()
    @State private var selectedSessionID: String?
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
                .accessibilityLabel("Refresh sessions list")
            }
        }
        .task {
            await refresh()
        }
        .inspector(isPresented: .init(
            get: { selectedSessionID != nil },
            set: { if !$0 { selectedSessionID = nil } }
        )) {
            if let id = selectedSessionID,
               let session = vm.sessions.first(where: { $0.id == id }) {
                SessionDetailView(session: session, agent: vm.agents[session.agentId])
            }
        }
        .onChange(of: selectedSessionID) { _, newValue in
            appState.selectedSessionID = newValue
        }
        .overlay(alignment: .top) {
            if let error = vm.error {
                ErrorBanner(message: error) {
                    vm.error = nil
                }
            }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Authentication Required. Connect your Claude API key in Account to view sessions.")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No sessions yet. Start a conversation with an agent to see sessions here.")
    }
    
    private var sessionTable: some View {
        Table(vm.filteredIdentifiableSessions, selection: $selectedSessionID) {
            TableColumn("Agent") { item in
                Text(vm.agents[item.session.agentId]?.name ?? "Unknown")
                    .accessibilityLabel("Agent: \(vm.agents[item.session.agentId]?.name ?? "Unknown")")
            }
            .width(min: 120)

            TableColumn("Started") { item in
                Text(item.session.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Started \(item.session.createdAt, format: .dateTime)")
            }
            .width(min: 100)

            TableColumn("Duration") { item in
                let duration = item.session.updatedAt.timeIntervalSince(item.session.createdAt)
                Text(formatDuration(duration))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Duration: \(formatDuration(duration))")
            }
            .width(80)

            TableColumn("Status") { item in
                StatusBadge(status: item.session.status.rawValue.capitalized)
            }
            .width(80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("\(vm.filteredSessions.count) sessions")
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let session = vm.sessions.first(where: { $0.id == id }) {
                SessionContextMenu(session: session, vm: vm, onDelete: {
                    selectedSessionID = nil
                    Task { await refresh() }
                })
            }
        }
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

        // Filter by search text (matches agent name or session ID)
        if !searchText.isEmpty {
            result = result.filter { session in
                if session.id.localizedCaseInsensitiveContains(searchText) {
                    return true
                }
                if let agentName = agents[session.agentId]?.name,
                   agentName.localizedCaseInsensitiveContains(searchText) {
                    return true
                }
                return false
            }
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

// MARK: - Context Menu

struct SessionContextMenu: View {
    let session: Session
    let vm: SessionListVM
    let onDelete: () -> Void

    @State private var showingDeleteAlert = false
    @State private var isDeleting = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.id, forType: .string)
        } label: {
            Label("Copy Session ID", systemImage: "doc.on.doc")
        }

        Button {
            let markdown = generateMarkdown()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        } label: {
            Label("Copy Summary", systemImage: "doc.text")
        }

        Divider()

        Button(role: .destructive) {
            showingDeleteAlert = true
        } label: {
            Label("Delete Session", systemImage: "trash")
        }
        .alert("Delete Session", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSession() }
            }
            .disabled(isDeleting)
        } message: {
            Text("Are you sure you want to delete this session? This action cannot be undone.")
        }
    }

    private func generateMarkdown() -> String {
        var output = "# Session Summary\n\n"
        output += "**Session ID:** `\(session.id)`\n"
        output += "**Agent:** \(vm.agents[session.agentId]?.name ?? "Unknown")\n"
        output += "**Status:** \(session.status.rawValue.capitalized)\n"
        output += "**Created:** \(session.createdAt.formatted())\n"
        output += "**Duration:** \(formatDuration(session.updatedAt.timeIntervalSince(session.createdAt)))\n"
        return output
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    @MainActor
    private func deleteSession() async {
        isDeleting = true
        defer { isDeleting = false }

        // TODO: Implement delete when ManagedAgentsClient supports it
        // For now, just show the alert - the actual deletion would need API support
        onDelete()
    }
}

#Preview {
    NavigationStack {
        SessionListView()
            .environment(AppState())
    }
}
