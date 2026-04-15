import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyInput = ""
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var accountInfo: AccountInfo?

    var body: some View {
        Form {
            Section("Container System") {
                HStack {
                    switch appState.systemStatus {
                    case .running(let health):
                        Circle().fill(Color.green).frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text("Running")
                                .font(.headline)
                            Text("Version: \(health.apiServerVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Build: \(health.apiServerBuild)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop System") {
                            Task { await appState.stopSystem() }
                        }
                        .controlSize(.small)

                    case .stopped:
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text("Stopped")
                            .font(.headline)
                        Spacer()
                        Button("Start System") {
                            Task { await appState.startSystem() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    case .error(let message):
                        Circle().fill(Color.orange).frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text("Error")
                                .font(.headline)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retry") {
                            Task { await appState.startSystem() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Docker API") {
                HStack {
                    Circle().fill(appState.isDockerAPIRunning ? Color.green : Color.gray).frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(appState.isDockerAPIRunning ? "Running" : "Stopped")
                            .font(.headline)
                        HStack(spacing: 4) {
                            Text(appState.dockerSocketPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(appState.dockerSocketPath, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("Copy socket path")
                        }
                        HStack(spacing: 4) {
                            Text("export DOCKER_HOST=unix://\(appState.dockerSocketPath)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Button {
                                let cmd = "export DOCKER_HOST=unix://\(appState.dockerSocketPath)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("Copy DOCKER_HOST command")
                        }
                    }
                    Spacer()
                    if appState.isDockerAPIRunning {
                        Button("Stop") {
                            appState.stopDockerAPI()
                        }
                        .controlSize(.small)
                    } else {
                        Button("Start") {
                            appState.startDockerAPI()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Section("Claude Agents API") {
                agentAPISection
            }

            Section("About") {
                LabeledContent("App", value: "Keg")
                LabeledContent("Description", value: "Docker Desktop replacement for macOS — native containers, Docker API, Compose, and Kubernetes")
                LabeledContent("Runtime", value: "Apple Containerization")
                LabeledContent("Requirements", value: "macOS 26+, Apple Silicon, Apple container CLI")
                LabeledContent("License", value: "Apache 2.0")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        .task {
            await appState.checkSystemStatus()
            if appState.isAgentAuthenticated {
                await loadAccountInfo()
            }
        }
        .alert("Connection Error", isPresented: .init(
            get: { connectionError != nil },
            set: { if !$0 { connectionError = nil } }
        )) {
            Button("OK") { connectionError = nil }
        } message: {
            Text(connectionError ?? "")
        }
    }

    @ViewBuilder
    private var agentAPISection: some View {
        if appState.isAgentAuthenticated {
            authenticatedView
        } else {
            unauthenticatedView
        }
    }

    private var authenticatedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
                    .font(.headline)
                Spacer()
                Button("Disconnect") {
                    disconnect()
                }
                .controlSize(.small)
            }

            if let info = accountInfo {
                LabeledContent("Account") {
                    Text(info.email ?? info.userId)
                        .foregroundStyle(.secondary)
                }
                if let plan = info.plan {
                    LabeledContent("Plan") {
                        Text(plan)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var unauthenticatedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Not Connected")
                    .font(.headline)
            }

            Text("Enter your Claude API key to use Agents")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("API Key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.isEmpty || isConnecting)

                Button {
                    openAPIKeyHelp()
                } label: {
                    Text("Get API Key")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }

        do {
            try AgentAuth.storeAPIKey(apiKeyInput)

            // Test connection
            let client = try await ManagedAgentsClient.fromKeychain()
            _ = try await client.listAgents()

            apiKeyInput = ""
            await loadAccountInfo()
        } catch {
            // Clear key on failure
            try? AgentAuth.deleteAPIKey()
            connectionError = error.localizedDescription
        }
    }

    private func disconnect() {
        try? AgentAuth.deleteAPIKey()
        accountInfo = nil
    }

    private func loadAccountInfo() async {
        do {
            let client = try await ManagedAgentsClient.fromKeychain()
            accountInfo = try await client.getAccountInfo()
        } catch {
            // Silently fail - not critical
            accountInfo = nil
        }
    }

    private func openAPIKeyHelp() {
        if let url = URL(string: "https://console.anthropic.com/settings/keys") {
            NSWorkspace.shared.open(url)
        }
    }
}
