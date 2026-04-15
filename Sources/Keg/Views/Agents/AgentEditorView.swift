import SwiftUI

// MARK: - Agent Editor View

struct AgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let existingAgent: Agent?
    let isNewAgent: Bool
    let onSave: (CreateAgentParams) async throws -> Agent
    let onCancel: () -> Void

    @State private var name = ""
    @State private var modelID = "claude-sonnet-4-7"
    @State private var selectedSpeed: ModelSpeed = .standard
    @State private var description = ""
    @State private var systemPrompt = ""
    @State private var tools: [AgentTool] = []
    @State private var skills: [AgentSkill] = []
    @State private var mcpServers: [MCPServer] = []

    @State private var showToolPicker = false
    @State private var showSkillPicker = false
    @State private var showMCPConfigSheet = false

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var contextMenuSelection: Set<String> = []

    private let availableModels = [
        "claude-sonnet-4-7",
        "claude-opus-4-7",
        "claude-3-5-haiku",
        "claude-3-5-sonnet",
        "claude-3-5-opus"
    ]

    init(
        agent: Agent? = nil,
        isNewAgent: Bool = false,
        onSave: @escaping (CreateAgentParams) async throws -> Agent,
        onCancel: @escaping () -> Void = {}
    ) {
        self.existingAgent = agent
        self.isNewAgent = isNewAgent
        self.onSave = onSave
        self.onCancel = onCancel

        let existing = agent
        _name = State(initialValue: existing?.name ?? "")
        _modelID = State(initialValue: existing?.model.id ?? "claude-sonnet-4-7")
        _selectedSpeed = State(initialValue: existing?.model.speed ?? .standard)
        _description = State(initialValue: existing?.description ?? "")
        _systemPrompt = State(initialValue: existing?.system ?? "")
        _tools = State(initialValue: existing?.tools ?? [])
        _skills = State(initialValue: existing?.skills ?? [])
        _mcpServers = State(initialValue: existing?.mcpServers ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            editorContent
            Divider()
            actionBar
        }
        .frame(minWidth: 600, minHeight: 500)
        .navigationTitle(isNewAgent ? "Create Agent" : "Edit Agent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .disabled(isSaving)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(isNewAgent ? "Create" : "Save") {
                    Task { await saveAgent() }
                }
                .disabled(name.isEmpty || isSaving)
            }
        }
        .sheet(isPresented: $showToolPicker) {
            ToolPickerSheet(
                selectedTools: $tools,
                onDismiss: { showToolPicker = false }
            )
        }
        .sheet(isPresented: $showSkillPicker) {
            SkillPickerSheet(
                selectedSkills: $skills,
                onDismiss: { showSkillPicker = false }
            )
        }
        .sheet(isPresented: $showMCPConfigSheet) {
            MCPServerConfigSheet(
                servers: $mcpServers,
                onDismiss: { showMCPConfigSheet = false }
            )
        }
        .overlay {
            if isSaving {
                ZStack {
                    Color.black.opacity(0.3)
                    ProgressView("Saving agent...")
                        .padding()
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .ignoresSafeArea()
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                basicInfoSection
                Divider()
                modelSection
                Divider()
                systemPromptSection
                Divider()
                toolsSection
                Divider()
                skillsSection
                Divider()
                mcpServersSection
            }
            .padding(20)
        }
    }

    private var actionBar: some View {
        HStack {
            Button(action: { showToolPicker = true }) {
                Label("Add Tool", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.bordered)

            Button(action: { showSkillPicker = true }) {
                Label("Add Skill", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)

            Button(action: { showMCPConfigSheet = true }) {
                Label("Add MCP Server", systemImage: "server.rack")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Basic Information")
                .font(.headline)

            VStack(spacing: 8) {
                HStack {
                    Text("Name")
                        .frame(width: 100, alignment: .trailing)
                    TextField("Agent name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .top) {
                    Text("Description")
                        .frame(width: 100, alignment: .trailing)
                    TextField("Optional description", text: $description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)

            HStack {
                Picker("Model", selection: $modelID) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Picker("Speed", selection: $selectedSpeed) {
                    Text("Standard").tag(ModelSpeed.standard)
                    Text("Fast").tag(ModelSpeed.fast)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("System Prompt")
                    .font(.headline)
                Spacer()
                Text("\(systemPrompt.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tools")
                    .font(.headline)
                Spacer()
                Text("\(tools.count) configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if tools.isEmpty {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.tertiary)
                    Text("No tools configured")
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                    EditorToolRow(
                        tool: tool,
                        onRemove: { tools.remove(at: index) }
                    )
                    .contextMenu {
                        Button("Copy Tool Name") {
                            if case .custom(let ct) = tool {
                                NSPasteboard.general.setString(ct.name, forType: .string)
                            }
                        }
                        Button("Remove", role: .destructive) {
                            tools.remove(at: index)
                        }
                    }
                }
            }
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Skills")
                    .font(.headline)
                Spacer()
                Text("\(skills.count) configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if skills.isEmpty {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tertiary)
                    Text("No skills configured")
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(skills.enumerated()), id: \.offset) { index, skill in
                    EditorSkillRow(
                        skill: skill,
                        onRemove: { skills.remove(at: index) }
                    )
                    .contextMenu {
                        Button("Copy Skill ID") {
                            NSPasteboard.general.setString(skill.identifier, forType: .string)
                        }
                        Button("Remove", role: .destructive) {
                            skills.remove(at: index)
                        }
                    }
                }
            }
        }
    }

    private var mcpServersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP Servers")
                    .font(.headline)
                Spacer()
                Text("\(mcpServers.count) configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if mcpServers.isEmpty {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.tertiary)
                    Text("No MCP servers configured")
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(mcpServers.enumerated()), id: \.offset) { index, server in
                    EditorMCPServerRow(
                        server: server,
                        onRemove: { mcpServers.remove(at: index) }
                    )
                    .contextMenu {
                        Button("Copy Server URL") {
                            if let url = server.config?.url {
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                        }
                        Button("Remove", role: .destructive) {
                            mcpServers.remove(at: index)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func saveAgent() async {
        isSaving = true
        defer { isSaving = false }

        let params = CreateAgentParams(
            name: name,
            model: modelID,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            description: description.isEmpty ? nil : description,
            tools: tools.isEmpty ? nil : tools,
            skills: skills.isEmpty ? nil : skills,
            mcpServers: mcpServers.isEmpty ? nil : mcpServers
        )

        do {
            _ = try await onSave(params)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Editor Tool Row

private struct EditorToolRow: View {
    let tool: AgentTool
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.blue)

            switch tool {
            case .agentToolset(let config):
                VStack(alignment: .leading) {
                    Text("Toolset")
                        .font(.subheadline.bold())
                    if let defaultConfig = config.defaultConfig,
                       let policy = defaultConfig.permissionPolicy {
                        Text("Policy: \(policy.type)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .custom(let customTool):
                VStack(alignment: .leading) {
                    Text(customTool.name)
                        .font(.subheadline.bold())
                    if let description = customTool.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Editor Skill Row

private struct EditorSkillRow: View {
    let skill: AgentSkill
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)

            VStack(alignment: .leading) {
                Text(skill.identifier)
                    .font(.subheadline)
                if let config = skill.config, !config.isEmpty {
                    Text("\(config.count) settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Editor MCP Server Row

private struct EditorMCPServerRow: View {
    let server: MCPServer
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(.orange)

            VStack(alignment: .leading) {
                Text(server.name ?? server.type)
                    .font(.subheadline)
                if let config = server.config, let url = config.url {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
