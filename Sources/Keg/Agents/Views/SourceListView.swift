import SwiftUI

/// Source List - Manage agent data sources (MCP, REST, files)
struct SourceListView: View {
    @State private var vm = SourceListVM()
    @Environment(AppState.self) private var appState
    @State private var showEditor = false
    @State private var editingSource: AgentSource?
    @State private var selectedSourceID: String?
    @State private var newSourceType: SourceEditorView.SourceType = .mcp
    @FocusState private var isSearchFocused: Bool

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
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("MCP Server") {
                        presentNewSourceEditor(.mcp)
                    }
                    .accessibilityLabel("Add MCP server source")

                    Button("REST API") {
                        presentNewSourceEditor(.rest)
                    }
                    .accessibilityLabel("Add REST API source")

                    Button("File System") {
                        presentNewSourceEditor(.files)
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
        .onChange(of: vm.error) { _, newValue in
            appState.updateAgentServiceReachability(for: newValue)
        }
        .onDeleteCommand {
            if let selectedSourceID {
                vm.deleteSource(id: selectedSourceID)
                self.selectedSourceID = nil
            }
        }
        .onExitCommand {
            if showEditor {
                showEditor = false
            } else if selectedSourceID != nil {
                selectedSourceID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
            guard appState.currentArea == .agents,
                  appState.selectedAgentSection == .sources else { return }
            isSearchFocused = true
        }
        .sheet(isPresented: $showEditor) {
            SourceEditorView(source: editingSource, initialType: newSourceType) { newSource in
                if editingSource != nil {
                    vm.updateSource(newSource)
                } else {
                    vm.addSource(newSource)
                }
            }
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
        await vm.load()
        appState.updateAgentServiceReachability(for: vm.error)
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

    private func presentNewSourceEditor(_ type: SourceEditorView.SourceType) {
        editingSource = nil
        newSourceType = type
        showEditor = true
    }

    private func presentEditSourceEditor(_ source: AgentSource) {
        editingSource = source
        newSourceType = SourceEditorView.SourceType.from(source.type)
        showEditor = true
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
            if vm.isLoading && vm.sources.isEmpty {
                ProgressView("Loading sources...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.sources.isEmpty {
                emptyStateView
            } else {
                Table(vm.filteredSources, selection: $selectedSourceID) {
                    TableColumn("Name") { source in
                        Text(source.name)
                            .accessibilityLabel("Source name: \(source.name)")
                    }
                    .width(min: 150)

                    TableColumn("Type") { source in
                        Text(source.type.displayName)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Source type: \(source.type.displayName)")
                    }
                    .width(100)

                    TableColumn("Enabled") { source in
                        Toggle(
                            source.isEnabled ? "Enabled" : "Disabled",
                            isOn: Binding(
                                get: { source.isEnabled },
                                set: { vm.setSourceEnabled(id: source.id, isEnabled: $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(source.isEnabled ? "Enabled" : "Disabled")
                        .accessibilityHint("Toggle whether agents can use this source")
                    }
                    .width(70)

                    TableColumn("Status") { source in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor(source.status))
                                .frame(width: 6, height: 6)
                            Text(source.status.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Connection status: \(source.status.rawValue.capitalized)")
                    }
                    .width(100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sources list")
                .accessibilityValue("\(vm.filteredSources.count) sources")
                .accessibilityHint("Use arrow keys to change selection. Use the Enabled toggle in each row to turn sources on or off. Press Delete to remove the selected source. Press Escape to clear selection.")
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let source = vm.sources.first(where: { $0.id == id }) {
                        Button("Edit") {
                            presentEditSourceEditor(source)
                        }
                        Button("Test Connection") {
                            Task { await vm.testSource(id: id) }
                        }
                        Button(source.isEnabled ? "Disable" : "Enable") {
                            vm.setSourceEnabled(id: id, isEnabled: !source.isEnabled)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            if selectedSourceID == id {
                                selectedSourceID = nil
                            }
                            vm.deleteSource(id: id)
                        }
                    }
                }
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
                presentNewSourceEditor(.mcp)
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

    @State private var name: String
    @State private var sourceType: SourceType
    @State private var isEnabled: Bool

    // Shared auth field
    @State private var authToken: String

    // MCP fields
    @State private var serverURL: String

    // REST fields
    @State private var endpoint: String
    @State private var method: String

    // Files fields
    @State private var pathPatterns: String
    @State private var watchEnabled: Bool

    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testMessage: String?
    @State private var testStatus: AgentSource.ConnectionStatus?

    enum SourceType: String, CaseIterable {
        case mcp = "MCP Server"
        case rest = "REST API"
        case files = "File System"
    }

    init(
        source: AgentSource?,
        initialType: SourceType = .mcp,
        onSave: @escaping (AgentSource) -> Void
    ) {
        self.source = source
        self.onSave = onSave

        let resolvedType = source.map { SourceType.from($0.type) } ?? initialType
        _name = State(initialValue: source?.name ?? "")
        _sourceType = State(initialValue: resolvedType)
        _isEnabled = State(initialValue: source?.isEnabled ?? true)
        _authToken = State(initialValue: source?.config["authToken"] ?? "")
        _serverURL = State(initialValue: source?.config["url"] ?? "")
        _endpoint = State(initialValue: source?.config["endpoint"] ?? "")
        _method = State(initialValue: source?.config["method"] ?? "GET")
        _pathPatterns = State(initialValue: source?.config["patterns"] ?? "")
        _watchEnabled = State(initialValue: Bool(source?.config["watchEnabled"] ?? "") ?? false)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .accessibilityHint("Enter a source name")
                Picker("Type", selection: $sourceType) {
                    ForEach(SourceType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                Toggle("Enabled", isOn: $isEnabled)
                    .accessibilityHint("Disabled sources are saved but not used by agents")
            } header: {
                Text("General")
            } footer: {
                if let nameValidationMessage {
                    Text(nameValidationMessage)
                        .foregroundStyle(.red)
                }
            }

            configSection

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTesting {
                        Label("Testing…", systemImage: "hourglass")
                    } else {
                        Label("Test Connection", systemImage: "checkmark.circle")
                    }
                }
                .disabled(!isConfigValid || isTesting || isSaving || !isEnabled)

                if let testMessage, let testStatus {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: testStatus))
                            .frame(width: 8, height: 8)
                        Text(testMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        Label("Saving…", systemImage: "hourglass")
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isFormValid || isSaving || isTesting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: sourceType) { _, _ in
            testMessage = nil
            testStatus = nil
        }
        .onChange(of: isEnabled) { _, _ in
            testMessage = nil
            testStatus = nil
        }
    }

    @ViewBuilder
    private var configSection: some View {
        switch sourceType {
        case .mcp:
            Section {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("Enter the MCP server URL")
                SecureField("Auth Token", text: $authToken)
                    .accessibilityHint("Optional authentication token for the MCP server")
            } header: {
                Text("MCP Server")
            } footer: {
                validationFooter(for: .mcp)
            }
        case .rest:
            Section {
                TextField("Endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("Enter the REST API endpoint URL")
                Picker("Method", selection: $method) {
                    Text("GET").tag("GET")
                    Text("POST").tag("POST")
                }
                SecureField("Auth Token", text: $authToken)
                    .accessibilityHint("Optional authentication token for the REST API")
            } header: {
                Text("REST API")
            } footer: {
                validationFooter(for: .rest)
            }
        case .files:
            Section {
                TextField("Path Patterns (comma-separated)", text: $pathPatterns)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("Enter one or more file or folder paths separated by commas")
                Toggle("Watch for changes", isOn: $watchEnabled)
                    .accessibilityHint("Enable file watching for this source")
            } header: {
                Text("File System")
            } footer: {
                validationFooter(for: .files)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameValidationMessage: String? {
        trimmedName.isEmpty ? "Source name is required." : nil
    }

    private var configValidationMessage: String? {
        switch sourceType {
        case .mcp:
            let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty else { return "Server URL is required." }
            return isValidURL(trimmedURL, schemes: ["http", "https", "ws", "wss"]) ? nil : "Enter a valid MCP server URL using http, https, ws, or wss."
        case .rest:
            let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedEndpoint.isEmpty else { return "Endpoint is required." }
            return isValidURL(trimmedEndpoint, schemes: ["http", "https"]) ? nil : "Enter a valid REST endpoint using http or https."
        case .files:
            let patterns = parsedPathPatterns
            guard !patterns.isEmpty else { return "At least one path pattern is required." }
            return pathPatterns.contains(",,") ? "Remove empty path patterns before saving." : nil
        }
    }

    private var isConfigValid: Bool {
        configValidationMessage == nil
    }

    private var isFormValid: Bool {
        nameValidationMessage == nil && isConfigValid
    }

    private var parsedPathPatterns: [String] {
        pathPatterns
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func buildConfig() -> [String: String] {
        switch sourceType {
        case .mcp:
            return [
                "url": serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                "authToken": authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        case .rest:
            return [
                "endpoint": endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                "method": method,
                "authToken": authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        case .files:
            return [
                "patterns": parsedPathPatterns.joined(separator: ", "),
                "watchEnabled": String(watchEnabled)
            ]
        }
    }

    private func buildSource(status: AgentSource.ConnectionStatus) -> AgentSource {
        AgentSource(
            id: source?.id ?? UUID().uuidString,
            name: trimmedName,
            type: sourceType.toSourceType(),
            isEnabled: isEnabled,
            status: isEnabled ? status : .disconnected,
            config: buildConfig()
        )
    }

    private func save() async {
        guard isFormValid else { return }

        if !isEnabled {
            onSave(buildSource(status: .disconnected))
            dismiss()
            return
        }

        isSaving = true
        defer { isSaving = false }

        let result = await SourceConnectionTester.shared.testSource(buildSource(status: .unknown))
        let resolvedStatus: AgentSource.ConnectionStatus

        switch result {
        case .success:
            resolvedStatus = .connected
            testStatus = .connected
            testMessage = "Connection succeeded"
        case .timeout:
            resolvedStatus = .error
            testStatus = .error
            testMessage = "Connection timed out"
        case .failure(let message):
            resolvedStatus = .error
            testStatus = .error
            testMessage = message
        }

        onSave(buildSource(status: resolvedStatus))
        dismiss()
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        let result = await SourceConnectionTester.shared.testSource(buildSource(status: .unknown))
        switch result {
        case .success:
            testStatus = .connected
            testMessage = "Connection succeeded"
        case .timeout:
            testStatus = .error
            testMessage = "Connection timed out"
        case .failure(let message):
            testStatus = .error
            testMessage = message
        }
    }

    @ViewBuilder
    private func validationFooter(for type: SourceType) -> some View {
        if sourceType == type, let configValidationMessage {
            Text(configValidationMessage)
                .foregroundStyle(.red)
        }
    }

    private func isValidURL(_ value: String, schemes: Set<String>) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              schemes.contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private func color(for status: AgentSource.ConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .disconnected: return .gray
        case .error: return .red
        case .unknown: return .yellow
        }
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

    static func from(_ sourceType: AgentSource.SourceType) -> SourceEditorView.SourceType {
        switch sourceType {
        case .mcp: return .mcp
        case .rest: return .rest
        case .files: return .files
        }
    }
}

private extension AgentSource.SourceType {
    var displayName: String {
        switch self {
        case .mcp: return "MCP"
        case .rest: return "REST"
        case .files: return "Files"
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
        isLoading = true
        defer { isLoading = false }

        do {
            sources = try await AgentStorage.shared.loadSources().map(normalized)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addSource(_ source: AgentSource) {
        sources.append(normalized(source))
        Task { await persistSources() }
    }

    func updateSource(_ source: AgentSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = normalized(source)
            Task { await persistSources() }
        }
    }

    func setSourceEnabled(id: String, isEnabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].isEnabled = isEnabled
        sources[index].status = isEnabled ? .unknown : .disconnected
        Task { await persistSources() }
    }

    func deleteSource(id: String) {
        sources.removeAll { $0.id == id }
        Task { await persistSources() }
    }

    func testSource(id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        guard sources[index].isEnabled else {
            error = "Enable the source before testing its connection"
            sources[index].status = .disconnected
            await persistSources()
            return
        }

        let result = await SourceConnectionTester.shared.testSource(sources[index])
        switch result {
        case .success:
            sources[index].status = .connected
            error = nil
        case .timeout:
            sources[index].status = .error
            error = "Connection timed out for \(sources[index].name)"
        case .failure(let message):
            sources[index].status = .error
            error = message
        }

        await persistSources()
    }

    private func normalized(_ source: AgentSource) -> AgentSource {
        AgentSource(
            id: source.id,
            name: source.name,
            type: source.type,
            isEnabled: source.isEnabled,
            status: source.isEnabled ? source.status : .disconnected,
            config: source.config
        )
    }

    private func persistSources() async {
        do {
            try await AgentStorage.shared.saveSources(sources)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        SourceListView()
            .environment(AppState())
    }
}
