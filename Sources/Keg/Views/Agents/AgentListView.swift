import SwiftUI

struct AgentListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = AgentsVM()
    @State private var selectedAgentID: String?
    @State private var showCreateSheet = false
    @State private var showArchiveConfirmation = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        agentsList
            .navigationTitle("Agents")
            .searchable(text: $searchText, prompt: "Search agents")
            .searchFocused($isSearchFocused)
            .onChange(of: searchText) { vm.searchText = searchText }
            .onChange(of: selectedAgentID) { appState.selectedAgentID = selectedAgentID }
            .toolbar(id: "agents-toolbar") {
                ToolbarItem(id: "create", placement: .primaryAction) {
                    Button { showCreateSheet = true } label: {
                        Label("Create...", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("Create new agent")
                }
                ToolbarItem(id: "duplicate", placement: .primaryAction) {
                    Button {
                        Task { await duplicateSelectedAgent() }
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(selectedAgent == nil)
                    .accessibilityLabel("Duplicate selected agent")
                }
                ToolbarItem(id: "archive", placement: .primaryAction) {
                    Button(role: .destructive) {
                        showArchiveConfirmation = true
                    } label: {
                        Label("Archive", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(selectedAgent == nil)
                    .accessibilityLabel("Archive selected agent")
                }
                ToolbarItem(id: "refresh", placement: .automatic) {
                    Button { Task { await vm.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityLabel("Refresh agents list")
                }
            }
            .toolbarRole(.editor)
            .task { await initializeAndRefresh() }
            .onChange(of: vm.errorMessage) { _, newValue in
                appState.updateAgentServiceReachability(for: newValue)
            }
            .onDeleteCommand {
                if selectedAgent != nil {
                    showArchiveConfirmation = true
                }
            }
            .onExitCommand {
                handleEscape()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
                guard appState.currentArea == .agents,
                      appState.selectedAgentSection == .agents else { return }
                isSearchFocused = true
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateAgentSheet(onCreated: { newAgent in
                    vm.agents.insert(newAgent, at: 0)
                })
            }
            .inspector(isPresented: .init(
                get: { selectedAgentID != nil },
                set: { if !$0 { selectedAgentID = nil } }
            )) {
                if let id = selectedAgentID,
                   let agent = vm.agents.first(where: { $0.id == id }) {
                    AgentDetailView(agent: agent, vm: vm)
                }
            }
            .onDisappear { appState.selectedAgentID = nil }
            .overlay(alignment: .top) {
                if let issue = currentIssue {
                    ErrorBanner(
                        message: issue.message,
                        actionTitle: issue.actionTitle,
                        onAction: { handle(issue: issue) }
                    ) {
                        vm.errorMessage = nil
                        appState.updateAgentServiceReachability(for: nil)
                    }
                }
            }
            .confirmationDialog(
                archiveConfirmationTitle,
                isPresented: $showArchiveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Archive", role: .destructive) {
                    Task { await archiveSelectedAgent() }
                }
            } message: {
                Text(archiveConfirmationMessage)
            }
    }

    @ViewBuilder
    private var agentsList: some View {
        if vm.isLoading && vm.agents.isEmpty {
            ProgressView("Loading agents...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading agents")
        } else if let issue = currentIssue, issue.showsUnavailableState, vm.agents.isEmpty {
            ContentUnavailableView {
                Label("Agents Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(issue.message)
            } actions: {
                Button(issue.actionTitle) {
                    handle(issue: issue)
                }
                .buttonStyle(.borderedProminent)
            }
        } else if filteredAgents.isEmpty {
            ContentUnavailableView(
                vm.agents.isEmpty ? "No Agents" : "No Matching Agents",
                systemImage: "person.2.badge.gearshape",
                description: Text(vm.agents.isEmpty ? "Create an agent to get started" : "Try a different search")
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(vm.agents.isEmpty ? "No agents created yet. Create your first agent to get started." : "No agents match your search. Try a different search term.")
        } else {
            agentsTable
        }
    }

    private var filteredAgents: [Agent] {
        if searchText.isEmpty {
            return vm.agents
        }
        return vm.agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var selectedAgent: Agent? {
        guard let selectedAgentID else { return nil }
        return vm.agents.first(where: { $0.id == selectedAgentID })
    }

    private var archiveConfirmationTitle: String {
        if let selectedAgent {
            return "Archive \(selectedAgent.name)?"
        }
        return "Archive Agent"
    }

    private var archiveConfirmationMessage: String {
        if let selectedAgent {
            return "Archive \(selectedAgent.name). This action cannot be undone."
        }
        return "Archive the selected agent. This action cannot be undone."
    }

    private var agentsTable: some View {
        Table(filteredAgents, selection: $selectedAgentID) {
            TableColumn("Name") { agent in
                Text(agent.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Agent name: \(agent.name)")
            }
            .width(min: 120)

            TableColumn("Model") { agent in
                Text(agent.model.id)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Model: \(agent.model.id)")
            }
            .width(min: 100)

            TableColumn("Type") { agent in
                Text(agent.type)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Type: \(agent.type)")
            }
            .width(min: 80)

            TableColumn("Tools") { agent in
                Text("\(agent.tools.count)")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(agent.tools.count) tools")
            }
            .width(50)

            TableColumn("Skills") { agent in
                Text("\(agent.skills.count)")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(agent.skills.count) skills")
            }
            .width(50)

            TableColumn("Version") { agent in
                Text("v\(agent.version)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Version \(agent.version)")
            }
            .width(60)

            TableColumn("Created") { agent in
                Text(agent.createdAt, format: .dateTime.month().day().year())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Created \(agent.createdAt, format: .dateTime)")
            }
            .width(min: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents list")
        .accessibilityValue("\(filteredAgents.count) agents")
        .accessibilityHint("Use arrow keys to change selection. Press Command Delete to archive the selected agent. Press Escape to clear selection.")
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let agent = vm.agents.first(where: { $0.id == id }) {
                AgentContextMenu(agent: agent, vm: vm) { duplicatedAgent in
                    selectedAgentID = duplicatedAgent.id
                }
            }
        }
    }

    private var currentIssue: AgentIssuePresentation? {
        AgentIssuePresentation(message: vm.errorMessage)
    }

    private func handle(issue: AgentIssuePresentation) {
        switch issue.kind {
        case .auth:
            appState.currentArea = .agents
            appState.selectedAgentSection = .account
        case .offline, .timeout, .generic:
            Task { await initializeAndRefresh() }
        }
    }

    @MainActor
    private func initializeAndRefresh() async {
        do {
            let client = try await ManagedAgentsClient.fromKeychain()
            vm.setClient(client)
            await vm.refresh()
            appState.updateAgentServiceReachability(for: vm.errorMessage)
        } catch {
            let issue = AgentIssuePresentation(error: error)
            vm.errorMessage = issue.message
            appState.updateAgentServiceReachability(for: issue.message)
        }
    }

    @MainActor
    private func duplicateSelectedAgent() async {
        guard let selectedAgent,
              let duplicatedAgent = await vm.duplicate(agent: selectedAgent) else { return }
        selectedAgentID = duplicatedAgent.id
    }

    @MainActor
    private func archiveSelectedAgent() async {
        guard let selectedAgent else { return }
        await vm.archive(id: selectedAgent.id)
        selectedAgentID = nil
    }

    private func handleEscape() {
        if showCreateSheet {
            showCreateSheet = false
            return
        }

        if selectedAgentID != nil {
            selectedAgentID = nil
            return
        }

        if !searchText.isEmpty {
            searchText = ""
            return
        }

        if isSearchFocused {
            isSearchFocused = false
        }
    }
}

struct AgentContextMenu: View {
    let agent: Agent
    let vm: AgentsVM
    let onDuplicate: (Agent) -> Void

    var body: some View {
        Button("Copy ID") {
                        NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.id, forType: .string)
        }
        .accessibilityLabel("Copy agent ID")
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.name, forType: .string)
        }
        .accessibilityLabel("Copy agent name")
        Divider()
        Button("Duplicate") {
            Task {
                if let duplicatedAgent = await vm.duplicate(agent: agent) {
                    await MainActor.run {
                        onDuplicate(duplicatedAgent)
                    }
                }
            }
        }
        .accessibilityLabel("Duplicate agent \(agent.name)")
        Button("Archive", role: .destructive) {
            Task { await vm.archive(id: agent.id) }
        }
        .accessibilityLabel("Archive agent \(agent.name)")
    }
}
