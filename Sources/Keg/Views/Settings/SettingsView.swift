import AppKit
import SwiftUI

/// The Settings window: a grouped sidebar (General / Runtime / Features) and
/// stacked pane groups — the macOS 26 System Settings idiom. The same view is
/// embedded as the main window's `.settings` detail; the sidebar column is
/// width-constrained so the narrow embedding stays readable.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @SceneStorage("settings.selectedPane") private var selection = SettingsPane.general
    @State private var apiKeyInput = ""
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var accountInfo: AccountInfo?
    @State private var storedAPIKeyPreview: String?

    private var availablePanes: [SettingsPane] {
        SettingsPane.panes(agentsEnabled: AppState.isAgentsEnabled)
    }

    /// Sidebar badge source: an unregistered boot kernel blocks new
    /// containers, so the Apple Containers pane flags it.
    private var bootKernelNeedsAttention: Bool {
        if case .missing = appState.bootKernelStatus { return true }
        return false
    }

    var body: some View {
        NavigationSplitView {
            SettingsNavList(
                selection: $selection,
                panes: availablePanes,
                bootKernelNeedsAttention: bootKernelNeedsAttention
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                    Text(paneTitle)
                        .font(.title2.weight(.semibold))
                    paneContent
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .frame(minWidth: 380)
        }
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

    private var paneTitle: String {
        if selection == .agents && !AppState.isAgentsEnabled { return SettingsPane.general.label }
        return selection.label
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selection {
        case .general:
            GeneralSettingsPane()
        case .softwareUpdate:
            SoftwareUpdateSection()
        case .about:
            AboutSettingsPane()
        case .appleContainers:
            AppleContainersSettingsPane()
        case .docker:
            DockerSettingsPane()
        case .kubernetes:
            KubernetesSettingsSection()
        case .gateway:
            GatewaySettingsSection()
        case .cooper:
            CooperSettingsSection()
        case .agents:
            if AppState.isAgentsEnabled {
                agentsPane
            } else {
                GeneralSettingsPane()
            }
        }
    }

    // MARK: - Agents pane

    @ViewBuilder
    private var agentsPane: some View {
        if appState.isAgentAuthenticated {
            authenticatedView
        } else {
            unauthenticatedView
        }
    }

    private var authenticatedView: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Connection", caption: "The API key is stored in your login keychain and validated against the Claude service.") {
                SettingsStatusCard(.ok, title: "Connected", headerAction: {
                    Button("Disconnect") {
                        disconnect()
                    }
                    .controlSize(.small)
                })

                VStack(alignment: .leading, spacing: SettingsMetrics.groupPadding) {
                    if let storedAPIKeyPreview {
                        SettingsValueRow("Stored API Key", isLast: true) {
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

                    if let info = accountInfo {
                        SettingsValueRow("Account", isLast: true) {
                            Text(info.email ?? info.userId)
                                .foregroundStyle(.secondary)
                        }
                        if let plan = info.plan {
                            SettingsValueRow("Plan", isLast: true) {
                                Text(plan)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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
            }
        }
    }

    private var unauthenticatedView: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Connection", caption: "The API key is stored in your login keychain and validated against the Claude service.") {
                SettingsStatusCard(.stopped, title: "Not Connected")

                SettingsCaption("Enter your Claude API key to use Agents")

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
    }

    private var apiKeyValidation: APIKeyValidation {
        APIKeyValidation(apiKey: apiKeyInput)
    }

    private var apiKeyValidationMessage: String? {
        let trimmed = apiKeyValidation.trimmedAPIKey
        guard !trimmed.isEmpty else { return nil }
        return apiKeyValidation.message
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

// MARK: - Docker API pane

/// Settings → Docker API: the Docker Engine-compatible socket that makes the
/// `docker` CLI work against Keg.
struct DockerSettingsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Socket", caption: "Enables Docker CLI compatibility via Unix socket — point `docker` at this socket and every standard command works.") {
                SettingsStatusCard(
                    appState.isDockerAPIRunning ? .ok : .inactive,
                    title: appState.isDockerAPIRunning ? "Running" : "Stopped"
                ) {
                    SettingsCopyLine(value: appState.dockerSocketPath, accessibilityLabel: "Copy socket path")
                    SettingsCopyLine(
                        value: "export DOCKER_HOST=unix://\(appState.dockerSocketPath)",
                        emphasis: .subtle,
                        accessibilityLabel: "Copy DOCKER_HOST command"
                    )
                } headerAction: {
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

            SettingsGroup("Startup", caption: "Starts the socket when Keg launches, so the `docker` CLI works without opening the app first.") {
                @Bindable var state = appState
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsValueRow("Start Docker API automatically", isLast: true) {
                            Toggle("Start Docker API automatically", isOn: $state.dockerAPIAutoStart)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
    }
}
