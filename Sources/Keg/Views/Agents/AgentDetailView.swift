import SwiftUI

struct AgentDetailView: View {
    let agent: Agent
    let vm: AgentsVM

    @State private var isEditing = false
    @State private var editedAgent: Agent
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    init(agent: Agent, vm: AgentsVM) {
        self.agent = agent
        self.vm = vm
        self._editedAgent = State(initialValue: agent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                modelSection
                Divider()
                descriptionSection
                Divider()
                toolsSection
                Divider()
                skillsSection
                Divider()
                mcpServersSection
                Divider()
                metadataSection
                Divider()
                dangerZone
            }
            .padding()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle(agent.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isEditing {
                    Button("Cancel") {
                        editedAgent = agent
                        isEditing = false
                    }
                    Button("Save") {
                        Task { await saveChanges() }
                    }
                    .disabled(isSaving)
                } else {
                    Button("Edit") {
                        isEditing = true
                    }
                }
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Delete Agent", isPresented: $showDeleteConfirmation) {
            Button("Archive", role: .destructive) {
                Task { await deleteAgent() }
            }
        } message: {
            Text("Are you sure you want to archive \(agent.name)? This action cannot be undone.")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                TextField("Name", text: $editedAgent.name)
                    .font(.title2.bold())
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(agent.name)
                    .font(.title2.bold())
            }

            HStack(spacing: 16) {
                Label("ID: \(agent.id.prefix(8))...", systemImage: "tag")
                Label("v\(agent.version)", systemImage: "number")
                Label(agent.type, systemImage: "person.badge.shield.checkmark")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Label("Created: \(agent.createdAt, format: .dateTime)", systemImage: "calendar")
                Label("Updated: \(agent.updatedAt, format: .dateTime)", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.headline)

            HStack {
                if isEditing {
                    TextField("Model ID", text: $editedAgent.model.id)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(agent.model.id)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let speed = (isEditing ? editedAgent.model.speed : agent.model.speed) {
                    Picker("Speed", selection: isEditing ? Binding(
                        get: { editedAgent.model.speed ?? .standard },
                        set: { editedAgent.model.speed = $0 }
                    ) : .constant(speed)) {
                        Text("Standard").tag(ModelSpeed.standard)
                        Text("Fast").tag(ModelSpeed.fast)
                    }
                    .labelsHidden()
                    .disabled(!isEditing)
                }
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            if isEditing {
                TextEditor(text: Binding(
                    get: { editedAgent.description ?? "" },
                    set: { editedAgent.description = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
            } else {
                Text(agent.description ?? "No description")
                    .foregroundStyle(agent.description == nil ? .tertiary : .primary)
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools")
                    .font(.headline)
                Spacer()
                if isEditing {
                    Button {
                        // TODO: Add tool picker
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if agent.tools.isEmpty {
                Text("No tools configured")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(agent.tools.enumerated()), id: \.offset) { index, tool in
                    ToolRow(tool: tool, isEditing: isEditing)
                }
            }
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skills")
                    .font(.headline)
                Spacer()
                if isEditing {
                    Button {
                        // TODO: Add skill picker
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if agent.skills.isEmpty {
                Text("No skills configured")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(agent.skills.enumerated()), id: \.offset) { index, skill in
                    SkillRow(skill: skill)
                }
            }
        }
    }

    private var mcpServersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MCP Servers")
                    .font(.headline)
                Spacer()
                if isEditing {
                    Button {
                        // TODO: Add MCP server
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if agent.mcpServers.isEmpty {
                Text("No MCP servers configured")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(agent.mcpServers.enumerated()), id: \.offset) { index, server in
                    MCPServerRow(server: server)
                }
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)

            if let metadata = agent.metadata, !metadata.isEmpty {
                ForEach(Array(metadata.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(metadata[key] ?? "")
                            .font(.caption)
                    }
                }
            } else {
                Text("No metadata")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Danger Zone")
                .font(.headline)
                .foregroundStyle(.red)

            Button("Archive Agent", role: .destructive) {
                showDeleteConfirmation = true
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    @MainActor
    private func saveChanges() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let client = try await ManagedAgentsClient.fromKeychain()
            let params = CreateAgentParams(
                name: editedAgent.name,
                model: editedAgent.model.id,
                system: editedAgent.system,
                description: editedAgent.description,
                tools: editedAgent.tools,
                skills: editedAgent.skills,
                mcpServers: editedAgent.mcpServers,
                metadata: editedAgent.metadata
            )
            _ = try await client.updateAgent(id: agent.id, params: params)
            await vm.refresh()
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteAgent() async {
        await vm.archive(id: agent.id)
    }
}

// MARK: - Row Components

struct ToolRow: View {
    let tool: AgentTool
    let isEditing: Bool

    var body: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)

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

            if isEditing {
                Button {
                    // TODO: Remove tool
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SkillRow: View {
    let skill: AgentSkill

    var body: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text(skill.identifier)
                .font(.subheadline)
            Spacer()
            if let config = skill.config, !config.isEmpty {
                Text("\(config.count) settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MCPServerRow: View {
    let server: MCPServer

    var body: some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(server.name ?? server.type)
                    .font(.subheadline)
                if let config = server.config, let url = config.url {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
