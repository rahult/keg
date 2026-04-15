import SwiftUI

/// Session List - View conversation history
struct SessionListView: View {
    @State private var vm = SessionListVM()
    @State private var selectedSessionID: String?
    @State private var showingDeleteAlert = false
    @Environment(AppState.self) private var appState
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isAgentAuthenticated {
                authenticationRequiredView
            } else {
                filterBar

                if vm.isLoading && vm.sessions.isEmpty {
                    loadingView
                } else if let issue = currentIssue, issue.showsUnavailableState, vm.sessions.isEmpty {
                    unavailableStateView(issue)
                } else if vm.sessions.isEmpty {
                    emptyStateView
                } else {
                    sessionTable
                }
            }
        }
        .navigationTitle("Sessions")
        .searchable(text: $vm.searchText, prompt: "Search sessions")
        .searchFocused($isSearchFocused)
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
        .onChange(of: vm.error) { _, newValue in
            appState.updateAgentServiceReachability(for: newValue)
        }
        .onDeleteCommand {
            if selectedSessionID != nil {
                showingDeleteAlert = true
            }
        }
        .onExitCommand {
            handleEscape()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
            guard appState.currentArea == .agents,
                  appState.selectedAgentSection == .sessions else { return }
            isSearchFocused = true
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
        .alert("Delete Session", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedSession() }
            }
            .disabled(selectedSessionID == nil)
        } message: {
            Text("Are you sure you want to delete this session? This action cannot be undone.")
        }
    }
    
    private func refresh() async {
        if let client = await appState.agentClient {
            await vm.load(client: client)
            appState.updateAgentServiceReachability(for: vm.error)
        }
    }

    private var currentIssue: AgentIssuePresentation? {
        AgentIssuePresentation(message: vm.error)
    }

    private func handle(issue: AgentIssuePresentation) {
        switch issue.kind {
        case .auth:
            appState.currentArea = .agents
            appState.selectedAgentSection = .account
        case .offline, .timeout, .generic:
            Task { await refresh() }
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
            .accessibilityHint("Filter sessions by agent")

            Picker("Workflow", selection: $vm.selectedWorkflowStatusFilter) {
                Text("All States").tag(nil as SessionWorkflowState.WorkflowStatus?)
                ForEach(SessionWorkflowState.WorkflowStatus.allCases) { status in
                    Text(status.rawValue).tag(status as SessionWorkflowState.WorkflowStatus?)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Filter sessions by workflow state")

            Picker("Time", selection: $vm.selectedDateFilter) {
                ForEach(SessionListVM.DateFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Filter sessions by date range")

            Toggle("Flagged", isOn: $vm.showFlaggedOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityHint("Show only flagged sessions")

            Spacer()
            
            if !vm.sessions.isEmpty {
                Text("\(vm.filteredSessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session filters")
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

    private func unavailableStateView(_ issue: AgentIssuePresentation) -> some View {
        ContentUnavailableView {
            Label("Sessions Unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text(issue.message)
        } actions: {
            Button(issue.actionTitle) {
                handle(issue: issue)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var sessionTable: some View {
        Table(vm.filteredIdentifiableSessions, selection: $selectedSessionID) {
            TableColumn("") { item in
                if item.workflowState.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Flagged")
                }
            }
            .width(24)

            TableColumn("Agent") { item in
                Text(vm.agents[item.session.agentId]?.name ?? "Unknown")
                    .accessibilityLabel("Agent: \(vm.agents[item.session.agentId]?.name ?? "Unknown")")
            }
            .width(min: 120)

            TableColumn("Workflow") { item in
                Text(item.workflowState.workflowStatus.rawValue)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Workflow status: \(item.workflowState.workflowStatus.rawValue)")
            }
            .width(min: 110)

            TableColumn("Labels") { item in
                if item.workflowState.labels.isEmpty {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("No labels")
                } else {
                    Text(item.workflowState.labels.joined(separator: ", "))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Labels: \(item.workflowState.labels.joined(separator: ", "))")
                }
            }
            .width(min: 140)

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

            TableColumn("Remote Status") { item in
                StatusBadge(status: item.session.status.rawValue.capitalized)
            }
            .width(110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions list")
        .accessibilityValue("\(vm.filteredSessions.count) sessions")
        .accessibilityHint("Use arrow keys to change selection. Press Command Delete to delete the selected session. Press Escape to clear selection.")
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let session = vm.sessions.first(where: { $0.id == id }) {
                SessionContextMenu(
                    session: session,
                    vm: vm,
                    onDelete: {
                        selectedSessionID = nil
                        Task { await refresh() }
                    },
                    onError: { message in
                        vm.error = message
                        appState.updateAgentServiceReachability(for: message)
                    }
                )
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

    private func handleEscape() {
        if selectedSessionID != nil {
            selectedSessionID = nil
            return
        }

        if !vm.searchText.isEmpty {
            vm.searchText = ""
            return
        }

        if isSearchFocused {
            isSearchFocused = false
        }
    }

    private func deleteSelectedSession() async {
        guard let selectedSessionID,
              let client = await appState.agentClient else { return }

        do {
            try await client.deleteSession(id: selectedSessionID)
            self.selectedSessionID = nil
            await refresh()
        } catch {
            vm.error = AgentIssuePresentation(error: error).message
            appState.updateAgentServiceReachability(for: vm.error)
        }
    }
}

// MARK: - ViewModel

struct IdentifiableSession: Identifiable {
    let id: String
    let session: Session
    let workflowState: SessionWorkflowState

    init(_ session: Session, workflowState: SessionWorkflowState) {
        self.id = session.id
        self.session = session
        self.workflowState = workflowState
    }
}

@Observable
@MainActor
final class SessionListVM {
    enum DateFilter: String, CaseIterable, Identifiable {
        case all = "All Time"
        case today = "Today"
        case week = "This Week"
        case month = "This Month"

        var id: String { rawValue }
    }

    var sessions: [Session] = []
    var agents: [String: Agent] = [:]
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedAgentIdFilter: String?
    var selectedWorkflowStatusFilter: SessionWorkflowState.WorkflowStatus?
    var selectedDateFilter: DateFilter = .all
    var showFlaggedOnly = false
    var workflowStates: [String: SessionWorkflowState] = [:]

    var filteredSessions: [Session] {
        var result = sessions

        if let agentId = selectedAgentIdFilter {
            result = result.filter { $0.agentId == agentId }
        }

        if let workflowStatus = selectedWorkflowStatusFilter {
            result = result.filter { workflowState(for: $0.id).workflowStatus == workflowStatus }
        }

        switch selectedDateFilter {
        case .all:
            break
        case .today:
            result = result.filter { Calendar.current.isDateInToday($0.createdAt) }
        case .week:
            if let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) {
                result = result.filter { $0.createdAt >= weekAgo }
            }
        case .month:
            if let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date()) {
                result = result.filter { $0.createdAt >= monthAgo }
            }
        }

        if showFlaggedOnly {
            result = result.filter { workflowState(for: $0.id).isFlagged }
        }

        // Filter by search text (matches agent name, session ID, workflow status, or labels)
        if !searchText.isEmpty {
            result = result.filter { session in
                if session.id.localizedCaseInsensitiveContains(searchText) {
                    return true
                }
                if let agentName = agents[session.agentId]?.name,
                   agentName.localizedCaseInsensitiveContains(searchText) {
                    return true
                }
                let workflowState = workflowState(for: session.id)
                if workflowState.workflowStatus.rawValue.localizedCaseInsensitiveContains(searchText) {
                    return true
                }
                if workflowState.labels.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) {
                    return true
                }
                return false
            }
        }

        return result.sorted { $0.createdAt > $1.createdAt }
    }
    
    var filteredIdentifiableSessions: [IdentifiableSession] {
        filteredSessions.map { IdentifiableSession($0, workflowState: workflowState(for: $0.id)) }
    }

    func load(client: ManagedAgentsClient?) async {
        guard let client else {
            sessions = []
            return
        }
        
        isLoading = true
        defer { isLoading = false }

        do {
            let storedWorkflowStates = try await AgentStorage.shared.loadSessionWorkflowStates()
            workflowStates = Dictionary(uniqueKeysWithValues: storedWorkflowStates.map { ($0.sessionId, $0) })

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
            self.error = AgentIssuePresentation(error: error).message
        }
    }

    func workflowState(for sessionID: String) -> SessionWorkflowState {
        workflowStates[sessionID] ?? SessionWorkflowState(sessionId: sessionID)
    }

    func toggleFlag(for sessionID: String) async {
        var state = workflowState(for: sessionID)
        state.isFlagged.toggle()
        state.updatedAt = Date()
        workflowStates[sessionID] = state
        await persistWorkflowState(state, activityMessage: state.isFlagged ? "Session flagged" : "Session unflagged")
    }

    func setWorkflowStatus(_ status: SessionWorkflowState.WorkflowStatus, for sessionID: String) async {
        var state = workflowState(for: sessionID)
        state.workflowStatus = status
        state.updatedAt = Date()
        workflowStates[sessionID] = state
        await persistWorkflowState(state, activityMessage: "Workflow status changed to \(status.rawValue)")
    }

    private func persistWorkflowState(_ state: SessionWorkflowState, activityMessage: String) async {
        do {
            try await AgentStorage.shared.saveSessionWorkflowStates(Array(workflowStates.values))
            try await AgentStorage.shared.appendSessionActivityEntry(
                SessionActivityEntry(sessionId: state.sessionId, kind: "workflow", message: activityMessage)
            )
        } catch {
            self.error = AgentIssuePresentation(error: error).message
        }
    }
}

// MARK: - Context Menu

struct SessionContextMenu: View {
    let session: Session
    let vm: SessionListVM
    let onDelete: () -> Void
    let onError: (String) -> Void

    @Environment(AppState.self) private var appState
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

        Button {
            Task { await vm.toggleFlag(for: session.id) }
        } label: {
            Label(vm.workflowState(for: session.id).isFlagged ? "Unflag Session" : "Flag Session", systemImage: "flag")
        }

        Menu("Workflow Status") {
            ForEach(SessionWorkflowState.WorkflowStatus.allCases) { workflowStatus in
                Button(workflowStatus.rawValue) {
                    Task { await vm.setWorkflowStatus(workflowStatus, for: session.id) }
                }
            }
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
        guard let client = await appState.agentClient else { return }

        isDeleting = true
        defer { isDeleting = false }

        do {
            try await client.deleteSession(id: session.id)
            onDelete()
        } catch {
            onError(AgentIssuePresentation(error: error).message)
        }
    }
}

#Preview {
    NavigationStack {
        SessionListView()
            .environment(AppState())
    }
}
