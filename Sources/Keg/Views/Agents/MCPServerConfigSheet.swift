import SwiftUI

// MARK: - MCP Server Config Sheet

struct MCPServerConfigSheet: View {
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
        .accessibilityLabel("Add MCP server configuration sheet")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    onDismiss()
                }
            }
        }
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Server Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Optional name for this server", text: $serverName)
                        .textFieldStyle(.roundedBorder)
                }

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
                onDismiss()
            }
            .keyboardShortcut(.escape)
            .accessibilityLabel("Cancel and close")

            Button("Add Server") {
                addServer()
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.return)
            .disabled(!canAddServer)
            .accessibilityLabel("Add MCP server to agent")
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
