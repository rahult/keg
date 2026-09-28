import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeyInput = ""
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var accountInfo: AccountInfo?
    @State private var storedAPIKeyPreview: String?
    @State private var loginItem = LoginItemController()

    private var apiKeyValidation: APIKeyValidation {
        APIKeyValidation(apiKey: apiKeyInput)
    }

    private var apiKeyValidationMessage: String? {
        let trimmed = apiKeyValidation.trimmedAPIKey
        guard !trimmed.isEmpty else { return nil }
        return apiKeyValidation.message
    }

    /// Moves the Settings window into the frame captured when settings was
    /// invoked: sized to fit the form content (the grouped form tops out
    /// around 690pt, so a 720pt window holds it without adopting the main
    /// window's width), centered over the main window, and taller than the
    /// 450pt default. Skipped when this view is embedded in the main window
    /// itself.
    private struct SettingsWindowFrame: NSViewRepresentable {
        let appState: AppState

        /// The height Settings should open at.
        private static let preferredHeight: CGFloat = 640
        /// The width that fits the settings form content.
        private static let preferredWidth: CGFloat = 720

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async { applyFrame(view.window) }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            applyFrame(nsView.window)
        }

        private func applyFrame(_ window: NSWindow?) {
            guard let window, window !== appState.mainWindow else { return }
            var target = window.frame
            target.size.height = max(target.height, Self.preferredHeight)
            if let frame = appState.pendingSettingsFrame {
                appState.pendingSettingsFrame = nil
                target.size.width = Self.preferredWidth
                target.origin.x = frame.midX - target.width / 2
                target.origin.y = frame.midY - target.height / 2
            }
            window.setFrame(target, display: true, animate: false)
        }
    }

    var body: some View {
        TabView {
            Form {
            Section("Experience") {
                Picker("Level", selection: Binding(
                    get: { appState.experienceLevel },
                    set: { appState.experienceLevel = $0 }
                )) {
                    ForEach(ExperienceLevel.allCases) { level in
                        Label(level.rawValue, systemImage: level.iconName)
                            .tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .help("Controls how many sections Keg shows and how much help you get")

                SettingsCaption(appState.experienceLevel.detail)

                HStack {
                    SettingsCaption("Not sure? Replay the welcome quick select.")
                    Spacer()
                    Button("Show Welcome…") {
                        NotificationCenter.default.post(name: .kegShowWelcome, object: nil)
                    }
                    .controlSize(.small)
                }
            }


            Section("Terminal") {
                TerminalPreferenceSection()
            }


            Section("Keg CLI") {
                KegCLIStatusRow()
            }


            Section("General") {
                Toggle("Launch Keg at login", isOn: $loginItem.isEnabled)
                SettingsCaption("Starts Keg (and its Docker socket) when you log in")
            }

            if AppState.isAgentsEnabled {
                Section("Claude Agents API") {
                    agentAPISection
                }
            }


            Section("Software Update") {
                SoftwareUpdateSection()
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Keg", systemImage: "slider.horizontal.3") }


            Form {
            Section("Container CLI") {
                ContainerCLIStatusRow()
                if !ContainerCLI.isInstalled {
                    PlatformSetupCard()
                }
            }


            Section("Container System") {
                systemStatusCard

                ContainerDataLocationRow()

                BootKernelStatusCard()
            }


            Section("Platform") {
                PlatformSettingsSection()
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Apple Containers", systemImage: "shippingbox") }


            Form {
            Section("Docker API") {
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
                } actions: {
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
                SettingsCaption("Enables Docker CLI compatibility via Unix socket")
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Docker", systemImage: "square.stack.3d.up") }


            Form {
            Section("Kubernetes") {
                KubernetesSettingsSection()
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Kubernetes", systemImage: "helm") }

            Form {
            Section("Cooper") {
                CooperSettingsSection()
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Cooper", systemImage: "sparkle") }


            Form {
            Section("Gateway") {
                GatewaySettingsSection()
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Gateway", systemImage: "globe") }


            Form {
            Section("About") {
                LabeledContent("App", value: "Keg")
                LabeledContent("Version", value: AppVersion.displayString)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Description")
                    Text("Docker Desktop replacement for macOS — native containers, Docker API, Compose, and Kubernetes")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Runtime", value: "Apple Containerization")
                LabeledContent("Requirements", value: "macOS 26+, Apple Silicon, Apple container CLI")
                LabeledContent("License", value: "Apache 2.0")
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsWindowFrame(appState: appState))
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
    private var systemStatusCard: some View {
        switch appState.systemStatus {
        case .running(let health):
            SettingsStatusCard(.ok, title: "Running") {
                SettingsCaption("Version: \(health.apiServerVersion)")
                SettingsCaption("Build: \(health.apiServerBuild)")
            } actions: {
                Button("Stop System") {
                    Task { await appState.stopSystem() }
                }
                .controlSize(.small)
            }

        case .stopped:
            SettingsStatusCard(.stopped, title: "Stopped", detail: { EmptyView() }, actions: {
                Button("Start System") {
                    Task { await appState.startSystem() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            })

        case .unresponsive:
            SettingsStatusCard(.warning, title: "Unresponsive") {
                SettingsCaption("Services are running but not answering. Lists will stay empty until it recovers.")
            } actions: {
                Button("Restart Services") {
                    Task {
                        await appState.stopSystem()
                        await appState.startSystem()
                    }
                }
                .controlSize(.small)
            }

        case .error(let message):
            SettingsStatusCard(.warning, title: "Error") {
                SettingsCaption(message)
            } actions: {
                Button("Retry") {
                    Task { await appState.startSystem() }
                }
                .controlSize(.small)
            }
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
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsStatusCard(.ok, title: "Connected", detail: { EmptyView() }, actions: {
                Button("Disconnect") {
                    disconnect()
                }
                .controlSize(.small)
            })

            if let storedAPIKeyPreview {
                SettingsRow("Stored API Key") {
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
                SettingsRow("Account") {
                    Text(info.email ?? info.userId)
                        .foregroundStyle(.secondary)
                }
                if let plan = info.plan {
                    SettingsRow("Plan") {
                        Text(plan)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var unauthenticatedView: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
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
/// Configures where the container runtime stores its data (the app-root
/// passed to `container system start`). Machine-specific: most installs stay
/// on the default `~/.container`, others keep it on a dedicated volume.
private struct ContainerDataLocationRow: View {
    @Environment(AppState.self) private var appState
    @AppStorage(ContainerCLI.appRootDefaultsKey) private var path = ""
    @State private var problem: String? = ContainerCLI.appRootProblem()

    private var isDefault: Bool {
        path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The path in effect right now: the configured override with ~ expanded,
    /// or the platform default when nothing is set.
    private var effectivePath: String {
        NSString(string: isDefault ? "~/.container" : path).expandingTildeInPath
    }

    /// The runtime answering with a different root than configured means the
    /// setting won't take effect until services restart.
    private var runningRootMismatch: String? {
        guard let configured = ContainerCLI.configuredAppRoot,
              let running = appState.lastKnownRuntimeAppRoot,
              running != configured else { return nil }
        return "Running runtime uses \(running) — restart services to apply \(configured)."
    }

    var body: some View {
        SettingsGroup("Data Location", caption: "Where the runtime keeps containers, images, and volumes. Change it while the system is stopped, then use Start System.") {
            HStack(spacing: 10) {
                Text(effectivePath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if isDefault {
                    Text("default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Button("Browse…") { browse() }
                    .controlSize(.small)
                if !isDefault {
                    Button("Reset") {
                        path = ""
                        problem = ContainerCLI.appRootProblem()
                    }
                    .controlSize(.small)
                }
            }

            if isDefault {
                SettingsCaption("Using the platform default. Pick a custom folder — for example a dedicated volume — with Browse.")
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let runningRootMismatch {
                Text(runningRootMismatch)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = "Choose Container Data Location"
        panel.message = "This folder will hold the runtime's containers, images, volumes, and snapshots."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // Start inside the current location when it exists, otherwise fall
        // back to the containing volume or home.
        var start = URL(fileURLWithPath: effectivePath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: start.path) {
            start = URL(filePath: NSHomeDirectory())
        }
        panel.directoryURL = start
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            path = url.path
            problem = ContainerCLI.appRootProblem()
        }
    }
}

private struct ContainerCLIStatusRow: View {    @State private var resolvedPath: String? = ContainerCLI.resolve()

    private let brewCommand = "brew install container"
    private let releasesURL = URL(string: "https://github.com/apple/container/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsStatusCard(
                resolvedPath != nil ? .ok : .stopped,
                title: resolvedPath != nil ? "Installed" : "Not Installed"
            ) {
                if let path = resolvedPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    SettingsCaption("Keg needs Apple's container CLI to manage containers, images, and Kubernetes.")
                }
            } actions: {
                Button("Re-check") { resolvedPath = ContainerCLI.resolve() }
                    .controlSize(.small)
            }

            if resolvedPath == nil {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsCopyLine(value: brewCommand, accessibilityLabel: "Copy install command")
                        HStack(spacing: 8) {
                            Button("Open in Terminal") { runBrewInstall() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Download from GitHub") { NSWorkspace.shared.open(releasesURL) }
                                .controlSize(.small)
                        }
                    }
                }
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

/// Keg's own companion CLI (`keg`): status + one-click PATH installation.
/// No privileges needed — the first writable of /usr/local/bin,
/// /opt/homebrew/bin, ~/.keg/bin wins (same rules the CLI itself uses).
private struct KegCLIStatusRow: View {
    @State private var installer = KegCLIInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsStatusCard(statusState, title: statusTitle) {
                AnyView(Text(statusDetail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled))
            } actions: {
                AnyView(Group {
                    switch installer.state {
                    case .installed:
                        Button("Uninstall") { installer.uninstall() }
                            .controlSize(.small)
                            .disabled(installer.isWorking)
                    case .notInstalled:
                        Button("Install") { installer.install() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(installer.isWorking)
                    case .unavailable:
                        EmptyView()
                    }
                })
            }

            if case .notInstalled = installer.state {
                SettingsCaption("Adds the `keg` command to your shell — status, ps, images, logs, start/stop/rm, doctor, and `keg open` to jump back into the app. No admin rights needed.")
            }

            if let hint = installer.pathHint {
                SettingsCopyLine(value: hint, accessibilityLabel: "Copy PATH line")
                SettingsCaption("Run this in your shell, then restart the terminal.")
            }

            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .onAppear { installer.refresh() }
    }

    private var statusState: SettingsStatusCard<AnyView, AnyView>.State {
        switch installer.state {
        case .installed: return .ok
        case .notInstalled: return .warning
        case .unavailable: return .inactive
        }
    }

    private var statusTitle: String {
        switch installer.state {
        case .installed: return "Installed"
        case .notInstalled: return "Not Installed"
        case .unavailable: return "Unavailable in this build"
        }
    }

    private var statusDetail: String {
        switch installer.state {
        case .installed(let link, _): return link
        case .notInstalled: return "keg — companion CLI for terminal control of Keg"
        case .unavailable: return "The keg binary ships inside Keg.app — run a make app build"
        }
    }
}
