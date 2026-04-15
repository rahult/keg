import SwiftUI

/// Source List - Manage agent data sources (MCP, REST, files)
struct SourceListView: View {
    @State private var vm = SourceListVM()
    @Environment(AppState.self) private var appState
    @State private var showEditor = false
    @State private var editingSource: AgentSource?

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isAgentAuthenticated {
                authenticationRequiredView
            } else {
                sourceTable
            }
        }
        .navigationTitle("Sources")
        .searchable(text: $vm.searchText, prompt: "Search sources")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("MCP Server") {
                        editingSource = nil
                        showEditor = true
                    }
                    .accessibilityLabel("Add MCP server source")
                    Button("REST API") {
                        editingSource = nil
                        showEditor = true
                    }
                    .accessibilityLabel("Add REST API source")
                    Button("File System") {
                        editingSource = nil
                        showEditor = true
                    }
                    .accessibilityLabel("Add file system source")
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh source list")
            }
        }
        .task {
            await vm.load()
        }
        .sheet(isPresented: $showEditor) {
            SourceEditorView(source: editingSource) { newSource in
                if let editing = editingSource {
                    vm.updateSource(newSource)
                } else {
                    vm.addSource(newSource)
                }
            }
        }
    }
    
    private func refresh() async {
        await vm.load()
    }
    
    private var authenticationRequiredView: some View {
        ContentUnavailableView {
            Label("Authentication Required", systemImage: "person.badge.key")
        } description: {
            Text("Connect your Claude API key in Account to manage sources")
        } actions: {
            Button("Open Account") {
                appState.currentArea = .agents
                appState.selectedAgentSection = .account
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityLabel("Authentication required to manage sources")
    }

    private var sourceTable: some View {
        Group {
            if vm.sources.isEmpty && !vm.isLoading {
                emptyStateView
            } else {
                Table(vm.filteredSources) {
                    TableColumn("Name") { source in
                        Text(source.name)
                    }
                    .width(min: 150)
                    
                    TableColumn("Type") { source in
                        Text(source.type.rawValue.capitalized)
                    }
                    .width(100)
                    
                    TableColumn("Status") { source in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor(source.status))
                                .frame(width: 6, height: 6)
                            Text(source.status.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Sources", systemImage: "square.stack.3d.up")
        } description: {
            Text("Connect MCP servers, REST APIs, and file sources for your agents")
        } actions: {
            Button("Add Source") {
                showEditor = true
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityLabel("No sources available")
    }

    private func statusColor(_ status: AgentSource.ConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .disconnected: return .gray
        case .error: return .red
        case .unknown: return .yellow
        }
    }
}

// MARK: - Source Editor

struct SourceEditorView: View {
    let source: AgentSource?
    let onSave: (AgentSource) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var sourceType: SourceType = .mcp
    @State private var isEnabled = true
    
    // MCP fields
    @State private var serverURL = ""
    @State private var authToken = ""
    
    // REST fields
    @State private var endpoint = ""
    @State private var method = "GET"
    
    // Files fields
    @State private var pathPatterns = ""
    @State private var watchEnabled = false
    
    enum SourceType: String, CaseIterable {
        case mcp = "MCP Server"
        case rest = "REST API"
        case files = "File System"
    }
    
    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $name)
                Picker("Type", selection: $sourceType) {
                    ForEach(SourceType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                Toggle("Enabled", isOn: $isEnabled)
            }
            
            configSection
            
            Section {
                Button("Test Connection") {
                    // TODO: Implement test
                }
                .disabled(!isConfigValid)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConfigValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
    
    @ViewBuilder
    private var configSection: some View {
        switch sourceType {
        case .mcp:
            Section("MCP Server") {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Auth Token", text: $authToken)
            }
        case .rest:
            Section("REST API") {
                TextField("Endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                Picker("Method", selection: $method) {
                    Text("GET").tag("GET")
                    Text("POST").tag("POST")
                }
            }
        case .files:
            Section("File System") {
                TextField("Path Patterns (comma-separated)", text: $pathPatterns)
                    .textFieldStyle(.roundedBorder)
                Toggle("Watch for changes", isOn: $watchEnabled)
            }
        }
    }
    
    private var isConfigValid: Bool {
        switch sourceType {
        case .mcp: return !serverURL.isEmpty
        case .rest: return !endpoint.isEmpty
        case .files: return !pathPatterns.isEmpty
        }
    }
    
    private func save() {
        let newSource = AgentSource(
            id: source?.id ?? UUID().uuidString,
            name: name,
            type: sourceType.toSourceType(),
            isEnabled: isEnabled,
            status: .unknown
        )
        onSave(newSource)
        dismiss()
    }
}

extension SourceEditorView.SourceType {
    func toSourceType() -> AgentSource.SourceType {
        switch self {
        case .mcp: return .mcp
        case .rest: return .rest
        case .files: return .files
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class SourceListVM {
    var sources: [AgentSource] = []
    var isLoading = false
    var error: String?
    var searchText = ""

    var filteredSources: [AgentSource] {
        if searchText.isEmpty { return sources }
        return sources.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func load() async {
        // TODO: Load from local storage
        isLoading = false
    }
    
    func addSource(_ source: AgentSource) {
        sources.append(source)
        // TODO: Save to storage
    }
    
    func updateSource(_ source: AgentSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        }
        // TODO: Save to storage
    }
    
    func deleteSource(id: String) {
        sources.removeAll { $0.id == id }
        // TODO: Remove from storage
    }
}

#Preview {
    NavigationStack {
        SourceListView()
            .environment(AppState())
    }
}
