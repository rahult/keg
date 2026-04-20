# Implementation Roadmap: Meadow + Agents

## Overview

Timeline: ~4-6 weeks for full implementation  
Effort: ~40-60 hours total  
Pattern: Incremental delivery, test at each phase

---

## Phase 1: Navigation Foundation ⚙️

**Goal:** Area-based navigation without breaking existing Meadow functionality  
**Time:** ~4-6 hours  
**Deliverable:** Working sidebar with Meadow/Agents toggle

### Tasks

#### 1.1 AppState Redesign
```swift
// File: Sources/Meadow/App/AppState.swift

// New enums
enum AppArea: String, CaseIterable, Identifiable {
    case meadow = "Meadow"
    case agents = "Agents"
    
    var id: String { rawValue }
}

enum MeadowSection: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case compose = "Compose"
    case kubernetes = "Kubernetes"
    case images = "Images"
    case builds = "Builds"
    case networks = "Networks"
    case volumes = "Volumes"
    case registries = "Registries"
    
    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .containers: return "cube.box"
        case .compose: return "doc.text"
        case .kubernetes: return "helm"
        case .images: return "photo.stack"
        case .builds: return "hammer"
        case .networks: return "network"
        case .volumes: return "externaldrive"
        case .registries: return "globe"
        }
    }
}

enum AgentSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case agents = "Agents"
    case sessions = "Sessions"
    case sources = "Sources"
    case skills = "Skills"
    
    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .agents: return "person.2.badge.gearshape"
        case .sessions: return "clock"
        case .sources: return "square.stack.3d.up"
        case .skills: return "book"
        }
    }
}
```

**Changes to AppState:**
- Replace `selectedSection: NavigationSection` with:
  - `currentArea: AppArea`
  - `selectedMeadowSection: MeadowSection`
  - `selectedAgentSection: AgentSection`
- Keep `selectedContainerID`, `selectedAgentID`, `selectedSessionID`
- Add computed properties for current section/title

#### 1.2 SidebarView Refactor
```swift
// File: Sources/Meadow/App/Components/SidebarView.swift

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        List(selection: binding) {
            // Area header
            Section {
                AreaPicker()
            }
            
            // Area-specific sections
            switch appState.currentArea {
            case .meadow:
                MeadowSidebarContent()
            case .agents:
                AgentSidebarContent()
            }
        }
    }
    
    private var binding: Binding<String> {
        Binding(
            get: { appState.currentArea == .meadow 
                     ? appState.selectedMeadowSection.rawValue 
                     : appState.selectedAgentSection.rawValue },
            set: { newValue in
                if let meadow = MeadowSection(rawValue: newValue) {
                    appState.currentArea = .meadow
                    appState.selectedMeadowSection = meadow
                } else if let agent = AgentSection(rawValue: newValue) {
                    appState.currentArea = .agents
                    appState.selectedAgentSection = agent
                }
            }
        )
    }
}

struct AreaPicker: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Picker("Area", selection: $appState.currentArea) {
            ForEach(AppArea.allCases) { area in
                Label(area.rawValue, systemImage: area.iconName)
                    .tag(area)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 8)
    }
}

struct MeadowSidebarContent: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Section("Workloads") {
            ForEach([MeadowSection.containers, .compose, .kubernetes]) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section.rawValue)
            }
        }
        
        Section("Content") {
            ForEach([MeadowSection.images, .builds]) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section.rawValue)
            }
        }
        
        Section("System") {
            ForEach([MeadowSection.networks, .volumes, .registries]) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section.rawValue)
            }
        }
    }
}

struct AgentSidebarContent: View {
    var body: some View {
        Section("Overview") {
            ForEach([AgentSection.dashboard, .sessions]) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section.rawValue)
            }
        }
        
        Section("Manage") {
            ForEach([AgentSection.agents, .skills, .sources]) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .tag(section.rawValue)
            }
        }
    }
}
```

#### 1.3 DetailView Routing Update
```swift
// File: Sources/Meadow/App/MeadowApp.swift (DetailView section)

struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.currentArea {
        case .meadow:
            MeadowDetailView()
        case .agents:
            AgentDetailView()
        }
    }
}

struct MeadowDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedMeadowSection {
        case .containers: ContainerListView()
        case .compose: ComposeView()
        case .kubernetes: KubernetesView()
        case .images: ImageListView()
        case .builds: BuildView()
        case .networks: NetworkListView()
        case .volumes: VolumeListView()
        case .registries: RegistryListView()
        }
    }
}

struct AgentDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedAgentSection {
        case .dashboard: AgentDashboardView()
        case .agents: AgentListView()
        case .sessions: SessionListView()
        case .sources: SourceListView()
        case .skills: SkillListView()
        }
    }
}
```

### Verification
- [x] Sidebar shows Meadow/Agents picker
- [x] Switching areas changes sidebar content
- [x] Switching areas changes detail view
- [x] Existing Meadow navigation still works
- [x] Keyboard shortcuts (Cmd+1 for Meadow, Cmd+2 for Agents?)

---

## Phase 2: Agents Module Shell 📦

**Goal:** Create placeholder views and ViewModels for all Agents screens  
**Time:** ~6-8 hours  
**Deliverable:** Empty but navigable Agents area

### Tasks

#### 2.1 Directory Structure
```
Sources/Meadow/Agents/
├── Views/
│   ├── AgentDashboardView.swift      # Placeholder
│   ├── AgentListView.swift           # Placeholder
│   ├── AgentEditorView.swift        # Placeholder
│   ├── SessionListView.swift        # Placeholder
│   ├── SessionDetailView.swift      # Placeholder
│   ├── SourceListView.swift         # Placeholder
│   ├── SourceEditorView.swift       # Placeholder
│   ├── SkillListView.swift          # Placeholder
│   └── SkillEditorView.swift        # Placeholder
└── ViewModels/
    ├── AgentDashboardVM.swift        # Placeholder
    ├── AgentListVM.swift             # Placeholder
    ├── SessionListVM.swift           # Placeholder
    ├── SourceListVM.swift            # Placeholder
    └── SkillListVM.swift             # Placeholder
```

#### 2.2 ViewModels (Stubs)

```swift
// Sources/Meadow/Agents/ViewModels/AgentDashboardVM.swift
import Foundation

@Observable
@MainActor
final class AgentDashboardVM {
    var activeAgents: [AgentSummary] = []
    var recentSessions: [SessionSummary] = []
    var isLoading = false
    var error: String?

    func load() async {
        // TODO: Implement
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
```

```swift
// Sources/Meadow/Agents/ViewModels/AgentListVM.swift
import Foundation

@Observable
@MainActor
final class AgentListVM {
    var agents: [Agent] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedAgentID: String?
    
    private let client = ManagedAgentsClient.shared

    var filteredAgents: [Agent] {
        if searchText.isEmpty {
            return agents
        }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            agents = try await client.listAgents()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createAgent(_ params: CreateAgentParams) async throws -> Agent {
        let agent = try await client.createAgent(params)
        agents.append(agent)
        return agent
    }

    func updateAgent(id: String, params: CreateAgentParams) async throws -> Agent {
        let agent = try await client.updateAgent(id: id, params: params)
        if let index = agents.firstIndex(where: { $0.id == id }) {
            agents[index] = agent
        }
        return agent
    }

    func deleteAgent(id: String) async throws {
        try await client.archiveAgent(id: id)
        agents.removeAll { $0.id == id }
    }
}
```

#### 2.3 Views (Stubs)

```swift
// Sources/Meadow/Agents/Views/AgentDashboardView.swift
import SwiftUI

struct AgentDashboardView: View {
    @State private var vm = AgentDashboardVM()
    
    var body: some View {
        ContentUnavailableView(
            "Agents Dashboard",
            systemImage: "square.grid.2x2",
            description: Text("Dashboard coming soon")
        )
    }
}
```

#### 2.4 Navigation Commands
Add to MeadowApp commands:
```swift
CommandMenu("Agent") {
    Button("New Agent") {
        NotificationCenter.default.post(name: .meadowNewAgent, object: nil)
    }
    .keyboardShortcut("N", modifiers: [.command, .option])
}
```

### Verification
- [x] All 5 Agents screens accessible via sidebar
- [x] All screens available (placeholder shell phase has been surpassed by implemented content)
- [x] Navigation between screens works
- [x] No crashes or errors

---

## Phase 3: Authentication & Configuration 🔐

**Goal:** API key management and connection status  
**Time:** ~3-4 hours  
**Deliverable:** Working auth with Settings UI

### Tasks

#### 3.1 AgentAuth Enhancement
```swift
// Sources/Meadow/Agent/AgentAuth.swift (existing - enhance)

extension AgentAuth {
    static func testConnection() async throws -> Bool {
        let client = ManagedAgentsClient.shared
        let agents = try await client.listAgents()
        return true
    }
    
    static func getAccountInfo() async throws -> AccountInfo {
        // GET /v1/account
    }
}

struct AccountInfo: Codable {
    let userId: String
    let email: String?
    let plan: String?
}
```

#### 3.2 Settings Updates
Add to SettingsView:
```swift
// Agents section in settings
Section("Claude Agents API") {
    if AgentAuth.hasAPIKey() {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Connected")
            Spacer()
            Button("Disconnect") {
                AgentAuth.clearAPIKey()
            }
            .buttonStyle(.borderless)
        }
        
        if let info = accountInfo {
            Text(info.email ?? info.userId)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    } else {
        Text("Not connected")
            .foregroundStyle(.secondary)
        
        SecureField("API Key", text: $apiKeyInput)
            .textFieldStyle(.roundedBorder)
        
        Button("Connect") {
            await connect()
        }
        .buttonStyle(.borderedProminent)
        .disabled(apiKeyInput.isEmpty)
    }
}
```

### Verification
- [x] API key stored in Keychain
- [x] Connection tested on save
- [x] Error shown on invalid key
- [x] Disconnect clears key

---

## Phase 4: Dashboard Implementation 📊

**Goal:** Working dashboard with agent cards and activity  
**Time:** ~6-8 hours  
**Deliverable:** Functional dashboard with live data

### Tasks

#### 4.1 AgentDashboardVM Implementation
```swift
@Observable
@MainActor
final class AgentDashboardVM {
    var activeAgents: [AgentSummary] = []
    var recentSessions: [SessionSummary] = []
    var isLoading = false
    var error: String?
    
    private let client = ManagedAgentsClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let agents = try await client.listAgents()
            activeAgents = agents.prefix(6).map { agent in
                AgentSummary(
                    id: agent.id,
                    name: agent.name,
                    model: agent.model.id,
                    lastUsed: agent.updatedAt,
                    isActive: agent.archivedAt == nil
                )
            }
            
            // Load recent sessions for all agents
            var sessions: [SessionSummary] = []
            for agent in agents.prefix(3) {
                let agentSessions = try await client.listSessions(agentId: agent.id)
                sessions.append(contentsOf: agentSessions.prefix(5).map { session in
                    SessionSummary(
                        id: session.id,
                        agentName: agent.name,
                        started: session.createdAt,
                        ended: session.endedAt,
                        messageCount: session.messageCount
                    )
                })
            }
            recentSessions = sessions.sorted { $0.started > $1.started }
            
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

#### 4.2 AgentDashboardView Implementation
```swift
struct AgentDashboardView: View {
    @State private var vm = AgentDashboardVM()
    @Environment(AppState.self) private var appState
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                
                if !vm.activeAgents.isEmpty {
                    agentCardsSection
                }
                
                if !vm.recentSessions.isEmpty {
                    recentSessionsSection
                }
                
                Spacer()
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.selectedAgentSection = .agents
                } label: {
                    Label("Manage Agents", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { await vm.load() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task { await vm.load() }
        .overlay(alignment: .bottom) {
            if let error = vm.error {
                ErrorBanner(message: error) { vm.error = nil }
            }
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents Dashboard")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Overview of your AI agents and recent activity")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var agentCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Agents")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.adaptive(minWidth: 200, maxWidth: 300), spacing: 12)
            ], spacing: 12) {
                ForEach(vm.activeAgents) { agent in
                    AgentCard(agent: agent)
                }
            }
        }
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
            }
            
            Table(vm.recentSessions) {
                TableColumn("Agent") { session in
                    Text(session.agentName)
                }
                TableColumn("Started") { session in
                    Text(session.started, style: .relative)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Messages") { session in
                    Text("\(session.messageCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

struct AgentCard: View {
    let agent: AgentSummary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.accent)
                Spacer()
                Circle()
                    .fill(agent.isActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
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
        .contextMenu {
            Button("Open Agent") { }
            Button("Start Session") { }
            Divider()
            Button("Edit") { }
        }
    }
}
```

### Verification
- [x] Dashboard loads agents from API
- [x] Dashboard loads recent sessions
- [x] Cards show correct info
- [x] Refresh works
- [x] Empty state when no agents
- [x] Error banner on failure

---

## Phase 5: Agent CRUD 🎛️

**Goal:** Full agent management (create, edit, delete, duplicate)  
**Time:** ~8-10 hours  
**Deliverable:** Complete agent management UI

### Tasks

#### 5.1 AgentListVM Implementation
```swift
@Observable
@MainActor
final class AgentListVM {
    var agents: [Agent] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedAgentID: String?
    var showEditor = false
    var editingAgent: Agent?
    
    private let client = ManagedAgentsClient.shared

    var filteredAgents: [Agent] {
        if searchText.isEmpty { return agents }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            agents = try await client.listAgents()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createAgent(_ params: CreateAgentParams) async throws -> Agent {
        let agent = try await client.createAgent(params)
        agents.append(agent)
        return agent
    }

    func updateAgent(id: String, params: CreateAgentParams) async throws -> Agent {
        let agent = try await client.updateAgent(id: id, params: params)
        if let index = agents.firstIndex(where: { $0.id == id }) {
            agents[index] = agent
        }
        return agent
    }

    func duplicateAgent(_ agent: Agent) async throws -> Agent {
        var params = CreateAgentParams(
            name: "\(agent.name) (Copy)",
            model: agent.model.id,
            system: agent.system,
            description: agent.description,
            tools: agent.tools,
            skills: agent.skills,
            mcpServers: agent.mcpServers
        )
        return try await createAgent(params)
    }

    func archiveAgent(id: String) async throws {
        try await client.archiveAgent(id: id)
        agents.removeAll { $0.id == id }
    }
}
```

#### 5.2 AgentListView Implementation
```swift
struct AgentListView: View {
    @State private var vm = AgentListVM()
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 0) {
            if vm.agents.isEmpty && !vm.isLoading {
                emptyState
            } else {
                tableView
            }
        }
        .searchable(text: $vm.searchText, prompt: "Search agents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.editingAgent = nil
                    vm.showEditor = true
                } label: {
                    Label("New Agent", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                Button { await vm.load() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task { await vm.load() }
        .sheet(isPresented: $vm.showEditor) {
            AgentEditorView(
                agent: vm.editingAgent,
                onSave: { params in
                    if let id = vm.editingAgent?.id {
                        try await vm.updateAgent(id: id, params: params)
                    } else {
                        try await vm.createAgent(params)
                    }
                }
            )
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Agents", systemImage: "person.2.badge.gearshape")
        } description: {
            Text("Create your first agent to get started")
        } actions: {
            Button("Create Agent") {
                vm.editingAgent = nil
                vm.showEditor = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var tableView: some View {
        Table(vm.filteredAgents, selection: $vm.selectedAgentID) {
            TableColumn("Name") { agent in
                Text(agent.name)
            }
            .width(min: 150)
            
            TableColumn("Model") { agent in
                Text(agent.model.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100)
            
            TableColumn("Tools") { agent in
                Text("\(agent.tools.count)")
                    .foregroundStyle(.secondary)
            }
            .width(60)
            
            TableColumn("Skills") { agent in
                Text("\(agent.skills.count)")
                    .foregroundStyle(.secondary)
            }
            .width(60)
            
            TableColumn("Created") { agent in
                Text(agent.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let agent = vm.agents.first(where: { $0.id == id }) {
                AgentContextMenu(agent: agent, vm: vm)
            }
        }
        .onDoubleClick { 
            if let id = vm.selectedAgentID,
               let agent = vm.agents.first(where: { $0.id == id }) {
                vm.editingAgent = agent
                vm.showEditor = true
            }
        }
    }
}

struct AgentContextMenu: View {
    let agent: Agent
    let vm: AgentListVM
    
    var body: some View {
        Button("Edit") {
            vm.editingAgent = agent
            vm.showEditor = true
        }
        Button("Duplicate") {
            Task { try? await vm.duplicateAgent(agent) }
        }
        Divider()
        Button("Start Session") {
            // Start session in dashboard
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { try? await vm.archiveAgent(id: agent.id) }
        }
    }
}
```

#### 5.3 AgentEditorView Implementation
```swift
struct AgentEditorView: View {
    let agent: Agent?
    let onSave: (CreateAgentParams) async throws -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var model = "claude-sonnet-4-5"
    @State private var systemPrompt = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var error: String?
    
    private let availableModels = [
        "claude-opus-4-5",
        "claude-sonnet-4-5",
        "claude-haiku-4-5"
    ]
    
    var body: some View {
        @Bindable var dismiss = dismiss
        
        Form {
            Section("Basic") {
                TextField("Name", text: $name)
                    .disabled(agent != nil) // Can't rename
                
                Picker("Model", selection: $model) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                
                TextField("Description", text: $description)
            }
            
            Section("Instructions") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 200)
                    .font(.system(.body, design: .monospaced))
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
                Button("Save") { await save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || isSaving)
            }
        }
        .onAppear {
            if let agent = agent {
                name = agent.name
                model = agent.model.id
                systemPrompt = agent.system ?? ""
                description = agent.description ?? ""
            }
        }
        .alert("Error", isPresented: .init(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
    
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        
        let params = CreateAgentParams(
            name: agent?.name ?? name, // Name can't change on edit
            model: model,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            description: description.isEmpty ? nil : description
        )
        
        do {
            try await onSave(params)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

### Verification
- [x] List all agents from API
- [x] Create new agent via sheet
- [x] Edit existing agent via detail/editor flow
- [x] Duplicate agent
- [x] Archive/delete agent
- [x] Search filters agents
- [x] Context menu works
- [x] Keyboard shortcuts work

---

## Phase 6: Sessions 📝

**Goal:** View and manage conversation sessions  
**Time:** ~6-8 hours  
**Deliverable:** Session list and detail views

### Tasks

#### 6.1 SessionListVM
```swift
@Observable
@MainActor
final class SessionListVM {
    var sessions: [Session] = []
    var agents: [String: Agent] = [:] // agentId -> Agent
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedAgentIdFilter: String?
    var dateFilter: DateFilter = .all
    
    private let client = ManagedAgentsClient.shared

    enum DateFilter: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
    }

    var filteredSessions: [Session] {
        var result = sessions
        
        if let agentId = selectedAgentIdFilter {
            result = result.filter { $0.agentId == agentId }
        }
        
        let now = Date()
        switch dateFilter {
        case .all: break
        case .today:
            result = result.filter { Calendar.current.isDateInToday($0.createdAt) }
        case .week:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
            result = result.filter { $0.createdAt >= weekAgo }
        case .month:
            let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: now)!
            result = result.filter { $0.createdAt >= monthAgo }
        }
        
        if !searchText.isEmpty {
            if let agentId = selectedAgentIdFilter,
               let agent = agents[agentId] {
                result = result.filter { $0.agentId == agentId }
            }
            result = result.filter { session in
                if let agent = agents[session.agentId] {
                    return agent.name.localizedCaseInsensitiveContains(searchText)
                }
                return false
            }
        }
        
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Load all agents first
            let allAgents = try await client.listAgents()
            for agent in allAgents {
                agents[agent.id] = agent
            }
            
            // Load sessions for each agent
            var allSessions: [Session] = []
            for agent in allAgents {
                let agentSessions = try await client.listSessions(agentId: agent.id)
                allSessions.append(contentsOf: agentSessions)
            }
            sessions = allSessions
            
        } catch {
            self.error = error.localizedDescription
        }
    }

    func exportSession(_ session: Session) -> String {
        // Generate markdown transcript
        var md = "# Session: \(agents[session.agentId]?.name ?? "Unknown Agent")\n\n"
        md += "**Started:** \(session.createdAt.formatted())\n"
        if let ended = session.endedAt {
            md += "**Ended:** \(ended.formatted())\n"
        }
        md += "\n---\n\n"
        
        for event in session.events {
            switch event {
            case .userMessage(let msg):
                md += "## User\n\n\(msg.content)\n\n"
            case .assistantMessage(let msg):
                md += "## Assistant\n\n\(msg.content)\n\n"
            case .toolUse(let tool):
                md += "### Tool: \(tool.name)\n\n```\n\(tool.input)\n```\n\n"
            }
        }
        
        return md
    }
}
```

#### 6.2 SessionListView
```swift
struct SessionListView: View {
    @State private var vm = SessionListVM()
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 0) {
            filterBar
            
            if vm.sessions.isEmpty && !vm.isLoading {
                emptyState
            } else {
                sessionTable
            }
        }
        .searchable(text: $vm.searchText, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { await vm.load() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task { await vm.load() }
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
            
            Picker("Time", selection: $vm.dateFilter) {
                ForEach(DateFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "clock")
        } description: {
            Text("Start a conversation with an agent to see sessions here")
        }
    }
    
    private var sessionTable: some View {
        Table(vm.filteredSessions, selection: $appState.selectedSessionID) {
            TableColumn("Agent") { session in
                Text(vm.agents[session.agentId]?.name ?? "Unknown")
            }
            .width(min: 120)
            
            TableColumn("Started") { session in
                Text(session.createdAt, style: .date)
            }
            .width(min: 100)
            
            TableColumn("Duration") { session in
                let duration = (session.endedAt ?? Date()).timeIntervalSince(session.createdAt)
                Text(formatDuration(duration))
                    .foregroundStyle(.secondary)
            }
            .width(80)
            
            TableColumn("Messages") { session in
                Text("\(session.messageCount)")
                    .foregroundStyle(.secondary)
            }
            .width(80)
            
            TableColumn("Status") { session in
                StatusBadge(status: session.endedAt == nil ? "Active" : "Completed")
            }
            .width(80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let session = vm.sessions.first(where: { $0.id == id }) {
                Button("View Transcript") {
                    appState.selectedSessionID = id
                }
                Button("Export as Markdown") {
                    let md = vm.exportSession(session)
                    copyToClipboard(md)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    // Delete session
                }
            }
        }
        .navigationDestination(item: $appState.selectedSessionID) { sessionId in
            if let session = vm.sessions.first(where: { $0.id == sessionId }) {
                SessionDetailView(session: session, agent: vm.agents[session.agentId])
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
```

#### 6.3 SessionDetailView
```swift
struct SessionDetailView: View {
    let session: Session
    let agent: Agent?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                sessionHeader
                    .padding(.horizontal)
                
                Divider()
                
                ForEach(Array(session.events.enumerated()), id: \.offset) { index, event in
                    EventRow(event: event)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let md = exportMarkdown()
                    copyToClipboard(md)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
            }
        }
    }
    
    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(agent?.name ?? "Unknown Agent")
                .font(.title2)
                .fontWeight(.semibold)
            
            HStack {
                Label(session.createdAt.formatted(), systemImage: "calendar")
                Spacer()
                Label(formatDuration(sessionDuration), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var sessionDuration: TimeInterval {
        (session.endedAt ?? Date()).timeIntervalSince(session.createdAt)
    }
    
    private func exportMarkdown() -> String {
        var md = "# Session with \(agent?.name ?? "Unknown Agent")\n\n"
        md += "**Date:** \(session.createdAt.formatted())\n"
        md += "**Duration:** \(formatDuration(sessionDuration))\n\n"
        md += "---\n\n"
        
        for event in session.events {
            switch event {
            case .userMessage(let msg):
                md += "## User\n\n\(msg.content)\n\n"
            case .assistantMessage(let msg):
                md += "## Assistant\n\n\(msg.content)\n\n"
            case .toolUse(let tool):
                md += "### Tool: \(tool.name)\n\n```\n\(tool.input)\n```\n\n"
            }
        }
        
        return md
    }
}

struct EventRow: View {
    let event: SessionEvent
    
    var body: some View {
        switch event {
        case .userMessage(let msg):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("You")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(msg.content)
                        .textSelection(.enabled)
                }
            }
            
        case .assistantMessage(let msg):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cpu.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(msg.content)
                        .textSelection(.enabled)
                }
            }
            
        case .toolUse(let tool):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "command.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Tool: \(tool.name)")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        if tool.status == .completed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                    Text(tool.input)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
```

### Verification
- [x] Session list loads from API
- [x] Filter by agent works
- [x] Filter by date works
- [x] Search sessions works
- [x] Click session opens detail view
- [x] Transcript displays correctly
- [x] Copy transcript works
- [x] Context menu works

---

## Phase 7: Sources 🔌

**Goal:** Manage agent data sources (MCP, REST, files)  
**Time:** ~8-10 hours  
**Deliverable:** Source management UI

### Tasks

#### 7.1 SourceListVM
```swift
@Observable
@MainActor
final class SourceListVM {
    var sources: [AgentSource] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    
    enum SourceType: String, CaseIterable {
        case mcp = "MCP Server"
        case rest = "REST API"
        case files = "File System"
    }

    var filteredSources: [AgentSource] {
        if searchText.isEmpty { return sources }
        return sources.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func load() async {
        // Load from local storage + API
    }
    
    func addSource(_ source: AgentSource) async throws {
        // Save to storage
    }
    
    func testConnection(_ source: AgentSource) async throws -> Bool {
        // Test connection based on type
    }
    
    func deleteSource(id: String) async throws {
        // Remove from storage
    }
}

struct AgentSource: Identifiable, Codable {
    let id: String
    var name: String
    var type: SourceType
    var isEnabled: Bool
    var config: SourceConfig
    var lastSync: Date?
    var status: ConnectionStatus
    
    enum SourceType: String, Codable {
        case mcp
        case rest
        case files
    }
    
    enum ConnectionStatus: String, Codable {
        case connected
        case disconnected
        case error
        case unknown
    }
}

struct SourceConfig: Codable {
    // MCP
    var serverURL: String?
    var authToken: String?
    
    // REST
    var endpoint: String?
    var method: String?
    var headers: [String: String]?
    
    // Files
    var pathPatterns: [String]?
    var watchEnabled: Bool?
}
```

#### 7.2 SourceListView
```swift
struct SourceListView: View {
    @State private var vm = SourceListVM()
    @State private var showEditor = false
    @State private var editingSource: AgentSource?
    
    var body: some View {
        VStack(spacing: 0) {
            if vm.sources.isEmpty && !vm.isLoading {
                emptyState
            } else {
                sourceTable
            }
        }
        .searchable(text: $vm.searchText, prompt: "Search sources")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(SourceListVM.SourceType.allCases, id: \.self) { type in
                        Button(type.rawValue) {
                            editingSource = nil
                            showEditor = true
                        }
                    }
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { await vm.load() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await vm.load() }
        .sheet(isPresented: $showEditor) {
            SourceEditorView(source: editingSource)
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sources", systemImage: "square.stack.3d.up")
        } description: {
            Text("Add MCP servers, REST APIs, or file sources for your agents")
        }
    }
    
    private var sourceTable: some View {
        Table(vm.filteredSources) {
            TableColumn("Name") { source in
                Text(source.name)
            }
            .width(min: 150)
            
            TableColumn("Type") { source in
                Text(source.type.rawValue)
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
            
            TableColumn("Last Sync") { source in
                if let lastSync = source.lastSync {
                    Text(lastSync, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("-")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
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
```

#### 7.3 SourceEditorView
```swift
struct SourceEditorView: View {
    let source: AgentSource?
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var sourceType: SourceListVM.SourceType = .mcp
    @State private var isEnabled = true
    @State private var isTesting = false
    @State private var testResult: TestResult?
    
    enum TestResult {
        case success
        case failure(String)
    }
    
    // MCP fields
    @State private var serverURL = ""
    @State private var authToken = ""
    
    // REST fields
    @State private var endpoint = ""
    @State private var method = "GET"
    @State private var headers = ""
    
    // Files fields
    @State private var pathPatterns = ""
    @State private var watchEnabled = false
    
    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $name)
                Picker("Type", selection: $sourceType) {
                    ForEach(SourceListVM.SourceType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                Toggle("Enabled", isOn: $isEnabled)
            }
            
            configSection
            
            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(name.isEmpty || !isConfigValid)
                
                if let result = testResult {
                    switch result {
                    case .success:
                        Label("Connection successful", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
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
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConfigValid)
            }
        }
        .onAppear {
            if let source = source {
                name = source.name
                sourceType = SourceListVM.SourceType(rawValue: source.type.rawValue.capitalized) ?? .mcp
                isEnabled = source.isEnabled
                populateConfig(source.config)
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
                TextField("Headers (JSON)", text: $headers)
                    .textFieldStyle(.roundedBorder)
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
    
    private func populateConfig(_ config: SourceConfig) {
        serverURL = config.serverURL ?? ""
        authToken = config.authToken ?? ""
        endpoint = config.endpoint ?? ""
        method = config.method ?? "GET"
        headers = config.headers?.map { "\($0.key): \($0.value)" }.joined(separator: "\n") ?? ""
        pathPatterns = config.pathPatterns?.joined(separator: ", ") ?? ""
        watchEnabled = config.watchEnabled ?? false
    }
    
    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        
        // Implement actual test
        try? await Task.sleep(for: .seconds(1))
        testResult = .success
    }
    
    private func save() {
        dismiss()
    }
}
```

### Verification
- [x] Source list displays all sources
- [x] Add MCP source works
- [x] Add REST source works
- [x] Add Files source works
- [x] Test connection works
- [x] Enable/disable sources
- [x] Delete sources
- [x] Search/filter works

---

## Phase 8: Skills 📚

**Goal:** Manage reusable agent skills  
**Time:** ~6-8 hours  
**Deliverable:** Skill management and editor

### Tasks

#### 8.1 SkillListVM
```swift
@Observable
@MainActor
final class SkillListVM {
    var skills: [AgentSkill] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    
    var filteredSkills: [AgentSkill] {
        if searchText.isEmpty { return skills }
        return skills.filter { 
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() async {
        // Load from local storage
    }
    
    func importSkill(from url: URL) async throws {
        // Parse YAML + markdown
    }
    
    func exportSkill(_ skill: AgentSkill) -> URL? {
        // Write to temp file
    }
}
```

#### 8.2 SkillEditorView
```swift
struct SkillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var examples = ""
    @State private var isSaving = false
    
    var body: some View {
        TabView {
            Form {
                Section("Basic") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description)
                }
                
                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)
                }
            }
            .padding()
            .tabItem {
                Label("YAML", systemImage: "doc.text")
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Examples & Guide")
                    .font(.headline)
                TextEditor(text: $examples)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 400)
            }
            .padding()
            .tabItem {
                Label("Markdown", systemImage: "doc.richtext")
            }
        }
        .frame(width: 600, height: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || instructions.isEmpty)
            }
        }
    }
    
    private func save() {
        dismiss()
    }
}
```

### Verification
- [x] Skill list displays all skills
- [x] Create skill via editor
- [x] Edit existing skill
- [x] YAML + Markdown tabs
- [x] Import skill from file
- [x] Export skill to file
- [x] Delete skills
- [x] Search/filter works

---

## Phase 9: Polish & Integration ✨

**Goal:** Error handling, empty states, keyboard shortcuts, accessibility  
**Time:** ~4-6 hours  
**Deliverable:** Production-ready Agents area

### Tasks

#### 9.1 Error Handling
- [x] Network errors with retry
- [x] Auth errors with re-auth flow
- [x] Validation errors in forms
- [x] Timeout handling
- [x] Offline state handling

#### 9.2 Empty States
- [x] Dashboard empty: "No agents yet"
- [x] Agents empty: Create first agent CTA
- [x] Sessions empty: "Start a conversation"
- [x] Sources empty: Add first source CTA
- [x] Skills empty: Import or create skill CTA

#### 9.3 Keyboard Shortcuts
- [x] Cmd+N: New agent
- [x] Cmd+Delete: Delete selected
- [x] Cmd+F: Focus search
- [x] Escape: Clear selection/close
- [x] Cmd+1/2: Switch areas

#### 9.4 Accessibility
- [ ] VoiceOver labels on all controls
- [ ] Dynamic Type support
- [ ] Sufficient color contrast
- [ ] Focus indicators
- [ ] Keyboard navigation

---

## Timeline Summary

| Phase | Name | Time | Cumulative |
|-------|------|------|------------|
| 1 | Navigation Foundation | 4-6h | 4-6h |
| 2 | Agents Module Shell | 6-8h | 10-14h |
| 3 | Authentication | 3-4h | 13-18h |
| 4 | Dashboard | 6-8h | 19-26h |
| 5 | Agent CRUD | 8-10h | 27-36h |
| 6 | Sessions | 6-8h | 33-44h |
| 7 | Sources | 8-10h | 41-54h |
| 8 | Skills | 6-8h | 47-62h |
| 9 | Polish | 4-6h | 51-68h |

**Total: ~51-68 hours (4-6 weeks at 10-15h/week)**

---

## Test Coverage Goals

### Unit Tests
- ViewModels: 80%+ coverage
- Types Codable: 100% coverage
- Client request/response: 90% coverage

### Integration Tests
- API calls (requires key)
- Keychain operations
- SSE streaming

### UI Tests
- Navigation flows
- Create/edit/delete flows
- Error states

### Manual Testing
- Full user journeys
- Edge cases
- Performance on large datasets
