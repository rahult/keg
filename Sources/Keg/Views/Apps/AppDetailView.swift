import SwiftUI

/// Detail for one installed app: status and web-UI access, start/stop/
/// update lifecycle with a live console, per-service states with logs and
/// restart, storage location, and uninstall (with an explicit data-deletion
/// choice).
struct AppDetailView: View {
    let appID: String

    @Environment(AppState.self) private var appState
    @State private var operationConsole = ""
    @State private var logsTarget: AppStoreManager.ServiceState?
    @State private var logsText = ""
    @State private var showUninstallDialog = false
    @State private var showsComposeFile = false
    @State private var composeFileText = ""
    @State private var errorMessage: String?

    private var apps: AppStoreManager { appState.apps }
    private var installation: AppInstallation? { apps.installation(withID: appID) }
    private var catalogApp: CatalogApp? { apps.app(withID: appID) }
    private var status: AppStoreManager.AppStatus { apps.status(for: appID) }
    private var states: [AppStoreManager.ServiceState] { apps.serviceStates[appID] ?? [] }
    private var isBusy: Bool { apps.activeOperations[appID] != nil }

    var body: some View {
        Group {
            if let installation, let catalogApp {
                content(installation: installation, app: catalogApp)
            } else {
                EmptyState(
                    "App removed",
                    description: "This app is no longer installed.",
                    systemImage: "shippingbox"
                )
            }
        }
        .navigationTitle(catalogApp?.name ?? appID)
        .toolbar {
            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await apps.refreshStatuses() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh status (⌘R)")
            }
            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .apps)
            }
        }
        .errorBanner($errorMessage)
        .sheet(item: $logsTarget) { state in
            logsSheet(state)
        }
        .sheet(isPresented: $showsComposeFile) {
            composeFileSheet
        }
        .confirmationDialog(
            "Remove \(catalogApp?.name ?? appID)?",
            isPresented: $showUninstallDialog,
            titleVisibility: .visible
        ) {
            Button("Remove, Keep Data") {
                Task { await uninstall(deleteData: false) }
            }
            Button("Remove and Delete Data", role: .destructive) {
                Task { await uninstall(deleteData: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Containers are removed. “Keep Data” preserves everything in \(installation?.dataRoot ?? "~/.keg/apps"). “Delete Data” erases that folder — folders you chose from elsewhere (like a media library) are never touched.")
        }
        .task {
            await apps.refreshStatuses()
        }
    }

    // MARK: Content

    private func content(installation: AppInstallation, app: CatalogApp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(installation: installation, app: app)

                if isBusy || !operationConsole.isEmpty {
                    GroupBox("Activity") {
                        ScrollView {
                            Text(operationConsole.isEmpty ? "Working…" : operationConsole)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 120, maxHeight: 240, alignment: .top)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                servicesSection
                storageSection(installation: installation)
                composeFileSection(installation: installation)
                aboutSection(app)
                uninstallSection
            }
            .padding(20)
        }
    }

    private func header(installation: AppInstallation, app: CatalogApp) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AppIcon(symbolName: app.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(app.name)
                                .font(.title3.weight(.semibold))
                            StatusBadge(status: status.label)
                        }
                        Text(app.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if apps.definitionChanged(for: installation) {
                    Label("The registry changed this app's template — Update re-creates it with your settings kept.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    if app.webUI != nil {
                        Button {
                            apps.openWebUI(for: installation)
                        } label: {
                            Label("Open", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(status != .running)
                        .help(status == .running
                              ? "Open the app in your browser"
                              : "Start the app first — it is not running")
                    }

                    if status == .running {
                        Button {
                            run { progress in
                                try await apps.stop(installation, progress: progress)
                            }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .disabled(isBusy)
                        .help("Stop the app (its data is kept)")
                    } else {
                        Button {
                            run { progress in
                                try await apps.start(installation, progress: progress)
                            }
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .disabled(isBusy)
                        .help("Start all services of the app")
                    }

                    Button {
                        run { progress in
                            try await apps.update(installation, progress: progress)
                        }
                    } label: {
                        Label("Update", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isBusy)
                    .help("Download the latest version and recreate the app (data is kept)")

                    Spacer()

                    if let url = apps.webURL(for: installation) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } label: {
                            Label(url.absoluteString.replacingOccurrences(of: "http://", with: ""), systemImage: "link")
                                .fontDesign(.monospaced)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Copy the app's address")
                    }

                    if status != .running {
                        Button {
                            appState.askCooper(
                                "The app “\(app.name)” is \(status.label.lowercased()) and I can't use it. "
                                    + "Its containers are named \(states.map(\.container).joined(separator: ", ")). "
                                    + "Can you look at what's wrong and suggest a fix?"
                            )
                        } label: {
                            Label("Ask Cooper", systemImage: "bubble.left.and.text.bubble.right")
                        }
                        .help("Ask Cooper to investigate why the app is not working")
                    }
                }

                Toggle(isOn: Binding(
                    get: { installation.autoStart },
                    set: { apps.setAutoStart(installation, enabled: $0) }
                )) {
                    Label("Start when Keg opens", systemImage: "power")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help("Recreate this app automatically whenever Keg starts and the runtime is up")
            }
            .padding(.top, 4)
        }
    }

    private var servicesSection: some View {
        GroupBox("Services") {
            if states.isEmpty {
                Text("No service information yet — refresh once the runtime is up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                Table(states) {
                    TableColumn("Service") { state in
                        Text(state.service)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100)
                    TableColumn("Container") { state in
                        Text(state.container)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 140)
                    TableColumn("State") { state in
                        HStack(spacing: 8) {
                            StatusBadge(status: state.state)
                            Button("Logs") {
                                Task { await loadLogs(state) }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(state.state == "not created")
                        }
                    }
                    .width(min: 130, max: 180)
                }
                .frame(minHeight: CGFloat(44 + states.count * 28))
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private func storageSection(installation: AppInstallation) -> some View {
        GroupBox("Storage") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installation.dataRoot)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("This folder holds the app's data. It survives updates and stopping the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(filePath: installation.dataRoot)]
                    )
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    /// The exact file the app boots from: view it, or find it on disk.
    private func composeFileSection(installation: AppInstallation) -> some View {
        GroupBox("Compose File") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installation.composePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("The rendered definition the app's services run from. Update rewrites it when the registry template changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("View") {
                    composeFileText = (try? String(contentsOfFile: installation.composePath, encoding: .utf8))
                        ?? "Could not read the file."
                    showsComposeFile = true
                }
                .controlSize(.small)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(filePath: installation.composePath)]
                    )
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private func aboutSection(_ app: CatalogApp) -> some View {
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text(app.summary)
                    .font(.callout)
                if app.homepage != nil || app.source != nil {
                    HStack(spacing: 12) {
                        if let homepage = app.homepage, let url = URL(string: homepage) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Website", systemImage: "safari")
                            }
                            .buttonStyle(.link)
                            .help(homepage)
                        }
                        if let source = app.source, let url = URL(string: source) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Source Code", systemImage: "curlybraces.square")
                            }
                            .buttonStyle(.link)
                            .help(source)
                        }
                    }
                    .font(.caption)
                }
                if let note = app.note {
                    Label {
                        Text(note)
                            .font(.caption)
                    } icon: {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var uninstallSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove \(catalogApp?.name ?? appID)")
                        .font(.subheadline.weight(.medium))
                    Text("Stops the app and removes its containers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove…", role: .destructive) {
                    showUninstallDialog = true
                }
                .disabled(isBusy)
                .help("Remove the app; you choose whether its data is deleted")
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Sheets & Actions

    private func logsSheet(_ state: AppStoreManager.ServiceState) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs — \(state.service)")
                    .font(.headline)
                Spacer()
                Button("Refresh") { Task { await loadLogs(state) } }
                Button("Done") { logsTarget = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(logsText.isEmpty ? "Loading…" : logsText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 640, height: 480)
    }

    private var composeFileSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compose File")
                    .font(.headline)
                Spacer()
                Button("Done") { showsComposeFile = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(composeFileText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 640, height: 480)
    }

    private func loadLogs(_ state: AppStoreManager.ServiceState) async {
        guard let installation else { return }
        logsText = await apps.logs(for: installation, service: state.service)
    }

    private func run(_ operation: @escaping (AppStoreManager.Progress?) async throws -> Void) {
        Task {
            operationConsole = ""
            do {
                try await operation { line in
                    operationConsole += (operationConsole.isEmpty ? "" : "\n") + line
                }
            } catch {
                errorMessage = AppInstallSheet.describe(error)
            }
            await apps.refreshStatuses()
        }
    }

    private func uninstall(deleteData: Bool) async {
        guard let installation else { return }
        do {
            try await apps.uninstall(installation, deleteData: deleteData)
        } catch {
            errorMessage = AppInstallSheet.describe(error)
        }
        await apps.refreshStatuses()
    }
}
