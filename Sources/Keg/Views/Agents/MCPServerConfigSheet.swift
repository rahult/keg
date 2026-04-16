import SwiftUI

// MARK: - MCP Server Config Sheet

/// Configuration sheet for managing MCP servers
/// Supports adding, editing, removing servers and viewing discovered tools
struct MCPServerConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var servers: [MCPServer]
    let mcpRegistry: MCPServerRegistry?
    let onDismiss: () -> Void

    @State private var selectedServerIndex: Int?
    @State private var showingAddSheet = false
    @State private var showingEditSheet = false
    @State private var editingServer: MCPServer?
    @State private var serverTools: [String: [MCPServerRegistry.ToolEntry]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            serverList
            Divider()
            actions
        }
        .frame(width: 600, height: 500)
        .navigationTitle("MCP Servers")
        .accessibilityLabel("MCP server configuration sheet")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                    onDismiss()
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddMCPServerSheet(servers: $servers) {
                loadServerTools()
            }
        }
        .sheet(item: $editingServer) { server in
            EditMCPServerSheet(server: server, servers: $servers) {
                loadServerTools()
            }
        }
        .onAppear {
            loadServerTools()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP Server Configuration")
                        .font(.headline)
                    Text("Connect external tools via Model Context Protocol servers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { showingAddSheet = true }) {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if servers.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(servers.enumerated()), id: \.offset) { index, server in
                        ServerRowView(
                            server: server,
                            tools: serverTools[server.name ?? "unknown"] ?? [],
                            onEdit: { editingServer = server },
                            onDelete: { deleteServer(at: index) }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No MCP Servers")
                .font(.headline)
            Text("Add a server to connect external tools and services")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add Server") {
                showingAddSheet = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var actions: some View {
        HStack {
            if mcpRegistry != nil {
                let toolCount = serverTools.values.reduce(0) { $0 + $1.count }
                Text("\(servers.count) servers, \(toolCount) tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private func loadServerTools() {
        guard let registry = mcpRegistry else { return }
        Task {
            for server in servers {
                let name = server.name ?? "unknown"
                let tools = await registry.listTools(serverName: name)
                await MainActor.run {
                    serverTools[name] = tools
                }
            }
        }
    }

    private func deleteServer(at index: Int) {
        servers.remove(at: index)
        loadServerTools()
    }
}

// MARK: - Server Row View

private struct ServerRowView: View {
    let server: MCPServer
    let tools: [MCPServerRegistry.ToolEntry]
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                serverIcon
                serverInfo
                Spacer()
                toolCountBadge
                editButton
                deleteButton
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded && !tools.isEmpty {
                toolList
            }
        }
    }

    private var serverIcon: some View {
        Image(systemName: server.type == "stdio" ? "terminal" : "globe")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 32)
    }

    private var serverInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.name ?? "Unnamed Server")
                .font(.subheadline)
                .fontWeight(.medium)
            Text(serverConfigDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serverConfigDescription: String {
        if let config = server.config {
            if let url = config.url {
                return url
            }
            if let auth = config.auth, !auth.isEmpty {
                return "\(auth.count) auth parameter(s)"
            }
        }
        return "No configuration"
    }

    private var toolCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "wrench.and.screwdriver")
            Text("\(tools.count)")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1))
        .foregroundStyle(.secondary)
        .clipShape(Capsule())
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Edit server")
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete server")
    }

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.leading, 44)
            ForEach(tools) { tool in
                ToolRowView(entry: tool)
                    .padding(.leading, 44)
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Tool Row View

private struct ToolRowView: View {
    let entry: MCPServerRegistry.ToolEntry

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.caption)
                    .fontWeight(.medium)
                if let desc = entry.description {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !entry.tags.isEmpty {
                ForEach(entry.tags.prefix(2), id: \.self) { tag in
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Add MCP Server Sheet

private struct AddMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var servers: [MCPServer]
    let onDismiss: () -> Void

    @State private var serverType = "stdio"
    @State private var serverName = ""
    @State private var serverURL = ""
    @State private var authToken = ""
    @State private var command = ""
    @State private var args = ""

    private let serverTypes = [
        ("stdio", "Stdio", "Local process communication via stdin/stdout"),
        ("http", "HTTP", "Remote MCP server via HTTP/HTTPS"),
        ("sse", "SSE", "Server-Sent Events for streaming responses"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            serverConfig
            Divider()
            actions
        }
        .frame(width: 500, height: 420)
        .navigationTitle("Add MCP Server")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configure an MCP Server")
                .font(.headline)
            Text("MCP servers extend your agent's capabilities by connecting to external tools and services.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var serverConfig: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                serverTypeSelector
                serverNameField
                switch serverType {
                case "stdio":
                    stdioConfig
                case "http", "sse":
                    httpConfig
                default:
                    EmptyView()
                }
            }
            .padding()
        }
    }

    private var serverTypeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Type")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Type", selection: $serverType) {
                ForEach(serverTypes, id: \.0) { type in
                    Text(type.1).tag(type.0)
                }
            }
            .pickerStyle(.segmented)
            if let selectedType = serverTypes.first(where: { $0.0 == serverType }) {
                Text(selectedType.2)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var serverNameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Name")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Optional name for this server", text: $serverName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var stdioConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("e.g., npx, python, node", text: $command)
                .textFieldStyle(.roundedBorder)
            Text("Arguments")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("e.g., -m mcp_server", text: $args)
                .textFieldStyle(.roundedBorder)
            Text("For local MCP servers like npx -y @modelcontextprotocol/server-filesystem")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var httpConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server URL")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("https://mcp.example.com", text: $serverURL)
                .textFieldStyle(.roundedBorder)
            Text("Auth Token (optional)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SecureField("Bearer token or API key", text: $authToken)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Button("Add Server") {
                addServer()
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.return)
            .disabled(!canAddServer)
        }
        .padding()
    }

    private var canAddServer: Bool {
        switch serverType {
        case "stdio":
            return !command.isEmpty
        case "http", "sse":
            return !serverURL.isEmpty
        default:
            return false
        }
    }

    private func addServer() {
        var config: MCPServerConfig?

        switch serverType {
        case "stdio":
            var cmdArgs: [String: String] = [:]
            if !args.isEmpty {
                cmdArgs["args"] = args
            }
            config = MCPServerConfig(url: command, auth: cmdArgs)
        case "http", "sse":
            var auth: [String: String]?
            if !authToken.isEmpty {
                auth = ["Authorization": "Bearer \(authToken)"]
            }
            config = MCPServerConfig(url: serverURL, auth: auth)
        default:
            break
        }

        let server = MCPServer(
            type: serverType,
            name: serverName.isEmpty ? nil : serverName,
            config: config
        )
        servers.append(server)
    }
}

// MARK: - Edit MCP Server Sheet

private struct EditMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: MCPServer
    @Binding var servers: [MCPServer]
    let onDismiss: () -> Void

    @State private var serverName: String
    @State private var authToken: String
    @State private var args: String

    init(server: MCPServer, servers: Binding<[MCPServer]>, onDismiss: @escaping () -> Void) {
        self.server = server
        self._servers = servers
        self.onDismiss = onDismiss
        self._serverName = State(initialValue: server.name ?? "")
        self._args = State(initialValue: server.config?.auth?["args"] ?? "")
        self._authToken = State(initialValue: server.config?.auth?["Authorization"]?.replacingOccurrences(of: "Bearer ", with: "") ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            configForm
            Divider()
            actions
        }
        .frame(width: 500, height: 300)
        .navigationTitle("Edit MCP Server")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit MCP Server")
                .font(.headline)
            Text("Modify the configuration for \(server.type) server")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var configForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Name for this server", text: $serverName)
                        .textFieldStyle(.roundedBorder)
                }

                if server.type == "stdio" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Arguments")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Additional arguments", text: $args)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if server.type == "http" || server.type == "sse" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Auth Token")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        SecureField("Bearer token or API key", text: $authToken)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding()
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Button("Save") {
                saveChanges()
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.return)
        }
        .padding()
    }

    private func saveChanges() {
        guard let index = servers.firstIndex(where: { $0.name == server.name }) else { return }

        var updatedServer = servers[index]
        updatedServer.name = serverName.isEmpty ? nil : serverName

        if var config = updatedServer.config {
            if server.type == "stdio" {
                config.auth?["args"] = args.isEmpty ? nil : args
            } else if server.type == "http" || server.type == "sse" {
                config.auth?["Authorization"] = authToken.isEmpty ? nil : "Bearer \(authToken)"
            }
            updatedServer.config = config
        }

        servers[index] = updatedServer
    }
}
