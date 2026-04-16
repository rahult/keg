import SwiftUI

// MARK: - Tool Picker Sheet

/// Tool picker with MCP tool registry browsing, search, and schema preview
struct ToolPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTools: [AgentTool]
    let mcpRegistry: MCPServerRegistry?
    let onDismiss: () -> Void

    @State private var selectedTab = 0  // 0 = MCP Tools, 1 = Built-in, 2 = Custom
    @State private var searchQuery = ""
    @State private var selectedServerFilter: String?
    @State private var selectedTool: MCPServerRegistry.ToolEntry?
    @State private var mcpTools: [MCPServerRegistry.ToolEntry] = []
    @State private var servers: [MCPServerRegistry.ServerEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabSelector
            Divider()
            contentArea
            Divider()
            actions
        }
        .frame(width: 700, height: 550)
        .navigationTitle("Add Tool")
        .accessibilityLabel("Add tool sheet")
        .onAppear {
            loadTools()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Add Tool")
                    .font(.headline)
                Spacer()
                if !mcpTools.isEmpty {
                    Text("\(mcpTools.count) tools available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Browse MCP tools, use built-in toolsets, or create custom tools")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var tabSelector: some View {
        Picker("Tool Category", selection: $selectedTab) {
            Text("MCP Tools").tag(0)
            Text("Built-in").tag(1)
            Text("Custom").tag(2)
        }
        .pickerStyle(.segmented)
        .padding()
    }

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case 0:
            mcpToolsView
        case 1:
            builtinToolsView
        case 2:
            customToolView
        default:
            EmptyView()
        }
    }

    // MARK: - MCP Tools View

    private var mcpToolsView: some View {
        HStack(spacing: 0) {
            // Left panel: tool list with search
            VStack(spacing: 0) {
                searchField
                serverFilter
                toolList
            }
            .frame(width: 300)

            Divider()

            // Right panel: tool details
            toolDetailPanel
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search tools...", text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var serverFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    label: "All Servers",
                    isSelected: selectedServerFilter == nil,
                    action: { selectedServerFilter = nil }
                )

                ForEach(servers) { server in
                    FilterChip(
                        label: server.name,
                        count: server.toolCount,
                        isSelected: selectedServerFilter == server.name,
                        action: { selectedServerFilter = server.name }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var toolList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredTools) { tool in
                    ToolListItem(
                        entry: tool,
                        isSelected: selectedTool?.id == tool.id,
                        onSelect: { selectedTool = tool }
                    )
                    Divider()
                }

                if filteredTools.isEmpty {
                    emptyToolList
                }
            }
        }
    }

    private var emptyToolList: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No tools found")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !searchQuery.isEmpty {
                Text("Try adjusting your search")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var filteredTools: [MCPServerRegistry.ToolEntry] {
        var tools = mcpTools

        // Filter by server
        if let serverFilter = selectedServerFilter {
            tools = tools.filter { $0.serverName == serverFilter }
        }

        // Filter by search query
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            tools = tools.filter { tool in
                tool.name.lowercased().contains(query) ||
                tool.description?.lowercased().contains(query) == true ||
                tool.serverName.lowercased().contains(query)
            }
        }

        return tools.sorted { $0.name < $1.name }
    }

    private var toolDetailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tool = selectedTool {
                toolHeader(tool)
                Divider()
                toolSchemaPreview(tool)
                Spacer()
                addToolButton(tool)
            } else {
                noSelectionView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func toolHeader(_ tool: MCPServerRegistry.ToolEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tool.name)
                    .font(.headline)
                Spacer()
                Text(tool.serverName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())
            }

            if let description = tool.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if !tool.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tool.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func toolSchemaPreview(_ tool: MCPServerRegistry.ToolEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input Schema")
                .font(.subheadline)
                .fontWeight(.medium)

            if let properties = tool.inputSchema.properties, !properties.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(properties.keys.sorted()), id: \.self) { key in
                        if let prop = properties[key] {
                            HStack(alignment: .top, spacing: 8) {
                                Text(key)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.medium)
                                Text(prop.type)
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Spacer()
                            }
                            if let desc = prop.description {
                                Text(desc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("No input parameters required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addToolButton(_ tool: MCPServerRegistry.ToolEntry) -> some View {
        let isAlreadyAdded = selectedTools.contains { toolItem in
            if case .custom(let custom) = toolItem {
                return custom.name == "mcp_\(tool.serverName)_\(tool.name)"
            }
            return false
        }

        return Button(action: {
            addMCPTool(tool)
            dismiss()
            onDismiss()
        }) {
            HStack {
                Image(systemName: isAlreadyAdded ? "checkmark" : "plus")
                Text(isAlreadyAdded ? "Already Added" : "Add Tool")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isAlreadyAdded)
    }

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select a tool")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Click on a tool to see details")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Built-in Tools View

    private var builtinToolsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Built-in Toolsets")
                    .font(.headline)

                ForEach(builtinToolsets, id: \.name) { toolset in
                    BuiltinToolsetRow(
                        name: toolset.name,
                        description: toolset.description,
                        icon: toolset.icon,
                        isSelected: isToolsetSelected(toolset),
                        onToggle: { toggleToolset(toolset) }
                    )
                }
            }
            .padding()
        }
    }

    private var builtinToolsets: [(name: String, description: String, icon: String)] {
        [
            ("Read", "Read files and directories", "doc.text"),
            ("Write", "Write and edit files", "pencil"),
            ("Bash", "Execute shell commands", "terminal"),
            ("Web Search", "Search the web", "magnifyingglass"),
            ("Code Execution", "Run code in sandbox", "play.rectangle"),
        ]
    }

    private func isToolsetSelected(_ toolset: (name: String, description: String, icon: String)) -> Bool {
        selectedTools.contains { tool in
            if case .agentToolset = tool { return true }
            return false
        }
    }

    private func toggleToolset(_ toolset: (name: String, description: String, icon: String)) {
        let tool = AgentTool.agentToolset(
            ToolsetConfig(
                defaultConfig: ToolsetDefaultConfig(permissionPolicy: PermissionPolicy(type: "ask"))
            )
        )
        if isToolsetSelected(toolset) {
            selectedTools.removeAll { if case .agentToolset = $0 { return true }; return false }
        } else {
            selectedTools.append(tool)
        }
    }

    // MARK: - Custom Tool View

    @State private var customToolName = ""
    @State private var customToolDescription = ""

    private var customToolView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Custom Tool")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tool Name")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("e.g., my_custom_tool", text: $customToolName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("What does this tool do?", text: $customToolDescription, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...5)
                    }

                    Text("Custom tools require manual implementation in your agent runtime")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Button(action: {
                    addCustomTool()
                    dismiss()
                    onDismiss()
                }) {
                    Text("Add Custom Tool")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(customToolName.isEmpty)
            }
            .padding()
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.escape)
        }
        .padding()
    }

    // MARK: - Helpers

    private func loadTools() {
        guard let registry = mcpRegistry else { return }

        Task {
            let tools = await registry.listTools()
            let serverList = await registry.listServers()
            await MainActor.run {
                self.mcpTools = tools
                self.servers = serverList
            }
        }
    }

    private func addMCPTool(_ entry: MCPServerRegistry.ToolEntry) {
        let props = entry.inputSchema.properties?.mapValues { prop in
            SchemaProperty(type: prop.type, description: prop.description)
        }

        let customTool = CustomTool(
            name: "mcp_\(entry.serverName)_\(entry.name)",
            description: entry.description,
            inputSchema: InputSchema(
                type: "object",
                properties: props,
                required: entry.inputSchema.required
            )
        )

        let tool = AgentTool.custom(customTool)
        if !selectedTools.contains(where: { $0 == tool }) {
            selectedTools.append(tool)
        }
    }

    private func addCustomTool() {
        let tool = AgentTool.custom(
            CustomTool(
                name: customToolName,
                description: customToolDescription.isEmpty ? nil : customToolDescription
            )
        )
        selectedTools.append(tool)
    }
}

// MARK: - Supporting Views

private struct FilterChip: View {
    let label: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if let count = count {
                    Text("(\(count))")
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ToolListItem: View {
    let entry: MCPServerRegistry.ToolEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(entry.serverName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct BuiltinToolsetRow: View {
    let name: String
    let description: String
    let icon: String
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - AgentTool Equatable Conformance

extension AgentTool {
    static func == (lhs: AgentTool, rhs: AgentTool) -> Bool {
        switch (lhs, rhs) {
        case (.agentToolset, .agentToolset):
            return true
        case (.custom(let l), .custom(let r)):
            return l.name == r.name
        default:
            return false
        }
    }
}
