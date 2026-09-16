import SwiftUI

struct AgentDetailView: View {
    let agent: Agent
    let vm: AgentsVM

    @State private var showEditor = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

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
                Button {
                    showEditor = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                .accessibilityLabel("Edit agent")
            }
        }
        .sheet(isPresented: $showEditor) {
            AgentEditorView(agent: agent) { params in
                let client = try await ManagedAgentsClient.fromKeychain()
                let updated = try await client.updateAgent(id: agent.id, params: params)
                await vm.refresh()
                return updated
            }
        }
        .overlay(alignment: .top) {
            if let error = errorMessage {
                ErrorBanner(message: error) {
                    errorMessage = nil
                }
            }
        }
        .confirmationDialog("Archive Agent", isPresented: $showDeleteConfirmation) {
            Button("Archive", role: .destructive) {
                Task { await deleteAgent() }
            }
        } message: {
            Text("Are you sure you want to archive \(agent.name)? This action cannot be undone.")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(agent.name)
                .font(.title2.bold())
                .accessibilityLabel("Agent name: \(agent.name)")

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(buildHeaderAccessibilityLabel())
    }

    private func buildHeaderAccessibilityLabel() -> String {
        var parts: [String] = []
        parts.append("Agent: \(agent.name)")
        parts.append("ID: \(agent.id.prefix(8))...")
        parts.append("Version \(agent.version)")
        parts.append("Type: \(agent.type)")
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        parts.append("Created \(df.string(from: agent.createdAt))")
        parts.append("Updated \(df.string(from: agent.updatedAt))")
        return parts.joined(separator: ". ")
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.headline)

            HStack(spacing: 12) {
                Text(agent.model.id)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Model: \(agent.model.id)")

                if let speed = agent.model.speed {
                    Text(speed.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                        .accessibilityLabel("Model speed: \(speed.rawValue)")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model configuration: \(agent.model.id)")
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            Text(agent.description ?? "No description")
                .foregroundStyle(agent.description == nil ? .tertiary : .primary)
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.headline)

            if agent.tools.isEmpty {
                Text("No tools configured")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(agent.tools.enumerated()), id: \.offset) { _, tool in
                    ToolRow(tool: tool)
                }
            }
        }
    }

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skills")
                .font(.headline)

            if agent.skills.isEmpty {
                Text("No skills configured")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(agent.skills.enumerated()), id: \.offset) { _, skill in
                    SkillRow(skill: skill)
                }
            }
        }
    }

    private var mcpServersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP Servers")
                .font(.headline)

            if agent.mcpServers.isEmpty {
                Text("No MCP servers configured")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(agent.mcpServers.enumerated()), id: \.offset) { _, server in
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
            .accessibilityLabel("Archive this agent")
        }
    }

    @MainActor
    private func deleteAgent() async {
        await vm.archive(id: agent.id)
    }
}

struct ToolRow: View {
    let tool: AgentTool

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
