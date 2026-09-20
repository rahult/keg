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
    /// invoked: same width as the main window, centered over it, and taller
    /// than the 450pt default. Skipped when this view is embedded in the
    /// main window itself.
    private struct SettingsWindowFrame: NSViewRepresentable {
        let appState: AppState

        /// The height Settings should open at.
        private static let preferredHeight: CGFloat = 640

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
                target.size.width = frame.width
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

                Text(appState.experienceLevel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Not sure? Replay the welcome quick select.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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


            Section("Startup") {
                Toggle("Launch Keg at login", isOn: $loginItem.isEnabled)
                Text("Starts Keg (and its Docker socket) when you log in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .tabItem { Label("Keg", systemImage: "gearshape") }


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

                    case .unresponsive:
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text("Unresponsive")
                                .font(.headline)
                            Text("Services are running but not answering. Lists will stay empty until it recovers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restart Services") {
                            Task {
                                await appState.stopSystem()
                                await appState.startSystem()
                            }
                        }
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

                ContainerDataLocationRow()
            }


            Section("Platform") {
                PlatformSettingsSection()
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Apple Containers", systemImage: "shippingbox") }


            Form {
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

                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("About") {
                LabeledContent("App", value: "Keg")
                LabeledContent("Version", value: AppVersion.displayString)
                LabeledContent("Description", value: "Docker Desktop replacement for macOS — native containers, Docker API, Compose, and Kubernetes")
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Data Location")
                .font(.headline)
            Text("Where the runtime keeps containers, images, and volumes. Change it while the system is stopped, then use Start System.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(effectivePath + (isDefault ? "  (default)" : ""))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
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
                Text("Using the platform default. Pick a custom folder — for example a dedicated volume — with Browse.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        .padding(.vertical, 2)
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

/// Keg's own companion CLI (`keg`): status + one-click PATH installation.
/// No privileges needed — the first writable of /usr/local/bin,
/// /opt/homebrew/bin, ~/.keg/bin wins (same rules the CLI itself uses).
private struct KegCLIStatusRow: View {
    @State private var installer = KegCLIInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
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
            }

            if case .notInstalled = installer.state {
                Text("Adds the `keg` command to your shell — status, ps, images, logs, start/stop/rm, doctor, and `keg open` to jump back into the app. No admin rights needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let hint = installer.pathHint {
                HStack(spacing: 4) {
                    Text(hint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hint, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Copy PATH line")
                }
                Text("Run this in your shell, then restart the terminal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private var statusColor: Color {
        switch installer.state {
        case .installed: return .green
        case .notInstalled: return .orange
        case .unavailable: return .gray
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
