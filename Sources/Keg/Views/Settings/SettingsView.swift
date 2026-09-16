import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyInput = ""
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var accountInfo: AccountInfo?
    @State private var storedAPIKeyPreview: String?

    private var apiKeyValidation: APIKeyValidation {
        APIKeyValidation(apiKey: apiKeyInput)
    }

    private var apiKeyValidationMessage: String? {
        let trimmed = apiKeyValidation.trimmedAPIKey
        guard !trimmed.isEmpty else { return nil }
        return apiKeyValidation.message
    }

    var body: some View {
        Form {
            Section("Container CLI") {
                ContainerCLIStatusRow()
                if !ContainerCLI.isInstalled {
                    PlatformSetupCard()
                }
            }

            Section("Container System") {
                HStack {
                    switch appState.systemStatus {
                    case .running(let health):
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
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
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text("Stopped")
                            .font(.headline)
                        Spacer()
                        Button("Start System") {
                            Task { await appState.startSystem() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    case .error(let message):
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
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

            Section("Platform") {
                PlatformSettingsSection()
            }

            Section("Terminal") {
                TerminalPreferenceSection()
            }

            Section("Docker API") {
                HStack {
                    Circle()
                        .fill(appState.isDockerAPIRunning ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
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
                                let command = "export DOCKER_HOST=unix://\(appState.dockerSocketPath)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
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

                @Bindable var state = appState
                Toggle("Start Docker API automatically", isOn: $state.dockerAPIAutoStart)
                Text("Enables Docker CLI compatibility via Unix socket")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            appState.refreshAgentAuthentication()
            await appState.checkSystemStatus()
            if appState.isAgentAuthenticated {
                loadStoredAPIKeyPreview()
                await loadAccountInfo()
            } else {
                storedAPIKeyPreview = nil
                accountInfo = nil
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

            if let storedAPIKeyPreview {
                LabeledContent("Stored API Key") {
                    Text(storedAPIKeyPreview)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            SecureField("Replace API Key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)

            if let apiKeyValidationMessage {
                Text(apiKeyValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Update Key")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!apiKeyValidation.isValid || isConnecting)

                Button("Reload Account") {
                    Task {
                        loadStoredAPIKeyPreview()
                        await loadAccountInfo()
                    }
                }
                .controlSize(.small)
                .disabled(isConnecting)
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

            if let apiKeyValidationMessage {
                Text(apiKeyValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

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
                .disabled(!apiKeyValidation.isValid || isConnecting)

                Button("Get API Key") {
                    openAPIKeyHelp()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private func connect() async {
        guard apiKeyValidation.isValid else {
            connectionError = apiKeyValidation.message
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            try AgentAuth.storeAPIKey(apiKeyValidation.trimmedAPIKey)
            let client = try await ManagedAgentsClient.fromKeychain()
            try await client.validateCredentials()

            apiKeyInput = ""
            appState.refreshAgentAuthentication()
            loadStoredAPIKeyPreview()
            await loadAccountInfo()
        } catch {
            try? AgentAuth.deleteAPIKey()
            appState.refreshAgentAuthentication()
            storedAPIKeyPreview = nil
            connectionError = AgentIssuePresentation(error: error).message
        }
    }

    private func disconnect() {
        do {
            try AgentAuth.deleteAPIKey()
            apiKeyInput = ""
            storedAPIKeyPreview = nil
            accountInfo = nil
            appState.refreshAgentAuthentication()
        } catch {
            connectionError = AgentIssuePresentation(error: error).message
        }
    }

    private func loadAccountInfo() async {
        do {
            let client = try await ManagedAgentsClient.fromKeychain()
            accountInfo = try await client.getAccountInfo()
            appState.updateAgentServiceReachability(for: nil)
        } catch {
            let issue = AgentIssuePresentation(error: error)
            accountInfo = nil
            appState.updateAgentServiceReachability(for: issue.message)
            if issue.kind == .auth {
                connectionError = issue.message
            }
        }
    }

    private func loadStoredAPIKeyPreview() {
        guard let apiKey = try? AgentAuth.retrieveAPIKey() else {
            storedAPIKeyPreview = nil
            return
        }
        storedAPIKeyPreview = maskAPIKey(apiKey)
    }

    private func maskAPIKey(_ apiKey: String) -> String {
        guard apiKey.count > 8 else { return String(repeating: "•", count: apiKey.count) }
        let prefix = apiKey.prefix(6)
        let suffix = apiKey.suffix(4)
        return "\(prefix)••••••••\(suffix)"
    }

    private func openAPIKeyHelp() {
        guard let url = URL(string: "https://console.anthropic.com/settings/keys") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Detection + install flow for Apple's `container` CLI. Refreshes whenever the
/// Settings pane becomes active so users see the updated state after an install.
private struct ContainerCLIStatusRow: View {
    @State private var resolvedPath: String? = ContainerCLI.resolve()

    private let brewCommand = "brew install container"
    private let releasesURL = URL(string: "https://github.com/apple/container/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(resolvedPath != nil ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolvedPath != nil ? "Installed" : "Not Installed")
                        .font(.headline)
                    if let path = resolvedPath {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("Keg needs Apple's container CLI to manage containers, images, and Kubernetes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Re-check") { resolvedPath = ContainerCLI.resolve() }
                    .controlSize(.small)
            }

            if resolvedPath == nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(brewCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(brewCommand, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Copy install command")
                    }
                    HStack(spacing: 8) {
                        Button("Open in Terminal") { runBrewInstall() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Download from GitHub") { NSWorkspace.shared.open(releasesURL) }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }

    /// Open Terminal.app and prefill the brew install command. We don't run it
    /// directly because installing CLIs with sudo from a GUI app is hostile —
    /// the user should see what's being run and approve it themselves.
    private func runBrewInstall() {
        let script = "tell application \"Terminal\" to do script \"\(brewCommand)\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}
