import SwiftUI

struct AgentListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = AgentsVM()
    @State private var selectedAgentID: String?
    @State private var showCreateSheet = false
    @State private var searchText = ""

    var body: some View {
        agentsList
            .navigationTitle("Agents")
            .searchable(text: $searchText, prompt: "Search agents")
            .onChange(of: searchText) { vm.searchText = searchText }
            .onChange(of: selectedAgentID) { appState.selectedAgentID = selectedAgentID }
            .toolbar(id: "agents-toolbar") {
                ToolbarItem(id: "create", placement: .primaryAction) {
                    Button { showCreateSheet = true } label: {
                        Label("Create...", systemImage: "plus")
                    }
                }
                ToolbarItem(id: "refresh", placement: .automatic) {
                    Button { Task { await vm.refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .toolbarRole(.editor)
            .task { await initializeAndRefresh() }
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
            .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var agentsList: some View {
        if vm.isLoading && vm.agents.isEmpty {
            ProgressView("Loading agents...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredAgents.isEmpty {
            ContentUnavailableView(
                vm.agents.isEmpty ? "No Agents" : "No Matching Agents",
                systemImage: "person.2.badge.gearshape",
                description: Text(vm.agents.isEmpty ? "Create an agent to get started" : "Try a different search")
            )
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

    private var agentsTable: some View {
        Table(filteredAgents, selection: $selectedAgentID) {
            TableColumn("Name") { agent in
                Text(agent.name).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 120)

            TableColumn("Model") { agent in
                Text(agent.model.id)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100)

            TableColumn("Type") { agent in
                Text(agent.type)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80)

            TableColumn("Tools") { agent in
                Text("\(agent.tools.count)")
                    .foregroundStyle(.secondary)
            }
            .width(50)

            TableColumn("Skills") { agent in
                Text("\(agent.skills.count)")
                    .foregroundStyle(.secondary)
            }
            .width(50)

            TableColumn("Version") { agent in
                Text("v\(agent.version)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(60)

            TableColumn("Created") { agent in
                Text(agent.createdAt, format: .dateTime.month().day().year())
                    .foregroundStyle(.secondary)
            }
            .width(min: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let agent = vm.agents.first(where: { $0.id == id }) {
                AgentContextMenu(agent: agent, vm: vm)
            }
        }
    }

    @MainActor
    private func initializeAndRefresh() async {
        do {
            let client = try await ManagedAgentsClient.fromKeychain()
            vm.setClient(client)
            await vm.refresh()
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }
}

struct AgentContextMenu: View {
    let agent: Agent
    let vm: AgentsVM

    var body: some View {
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.id, forType: .string)
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.name, forType: .string)
        }
        Divider()
        Button("Archive", role: .destructive) {
            Task { await vm.archive(id: agent.id) }
        }
    }
}
