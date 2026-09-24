import SwiftUI

/// The Apps section: one-click installs of curated open-source apps.
/// Installed apps render as live cards (status + Open); everything else in
/// the catalog installs through a short wizard that hides ports, env, and
/// volumes behind plain-language questions.
struct AppsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var installTarget: CatalogApp?
    @State private var selectedAppID: String?
    @State private var selectedCatalogApp: CatalogAppRoute?
    @State private var errorMessage: String?

    private var apps: AppStoreManager { appState.apps }

    /// Where a card click goes: installed apps open their management page,
    /// catalog apps open the "what will this do" preflight page.
    private func openDetails(for app: CatalogApp) {
        if apps.installation(withID: app.id) != nil {
            selectedAppID = app.id
        } else {
            selectedCatalogApp = CatalogAppRoute(id: app.id)
        }
    }

    private var filteredCatalog: [CatalogApp] {
        apps.catalog.filter { app in
            // Hidden entries (retired in the registry) stay resolvable for
            // installed apps but are not offered for install.
            guard !app.hidden else { return false }
            guard !searchText.isEmpty else { return true }
            return app.name.localizedCaseInsensitiveContains(searchText)
                || app.tagline.localizedCaseInsensitiveContains(searchText)
                || app.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Install popular open-source apps with one click. Each app runs sealed in its own virtual machine on this Mac — no terminal, no configuration files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if !apps.catalogWarnings.isEmpty {
                        catalogWarningsBanner
                    }

                    installedSection
                    catalogSection
                }
                .padding(20)
            }
            .navigationTitle("Apps")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search apps")
            .toolbar {
                ToolbarItem(id: "refresh", placement: .automatic) {
                    Button {
                        Task { await apps.refreshStatuses() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh app status (⌘R)")
                    .accessibilityLabel("Refresh app status")
                }
                ToolbarItem(id: "help", placement: .automatic) {
                    SectionHelpButton(section: .apps)
                }
            }
            .navigationDestination(item: $selectedAppID) { id in
                AppDetailView(appID: id)
            }
            .navigationDestination(item: $selectedCatalogApp) { route in
                AppCatalogDetailView(appID: route.id)
            }
        }
        .sheet(item: $installTarget) { app in
            AppInstallSheet(app: app)
        }
        .errorBanner($errorMessage)
        .task {
            apps.prepare()
            await apps.maybeRefreshRemoteCatalog()
            await apps.refreshStatuses()
        }
        .task(id: appState.selectedKegSection) {
            // Light periodic refresh while the section is visible; the task
            // is cancelled by SwiftUI when the section changes.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                await apps.refreshStatuses()
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var installedSection: some View {
        GroupBox("Installed") {
            if apps.installations.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing installed yet")
                        .font(.subheadline.weight(.medium))
                    Text("Pick an app below — installing takes one click and a download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .accessibilityElement(children: .combine)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(apps.installations.sorted { $0.name < $1.name }) { installation in
                        InstalledAppCard(installation: installation) {
                            selectedAppID = installation.appID
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        GroupBox("App Catalog") {
            VStack(alignment: .leading, spacing: 12) {
                registryStatusRow

                if filteredCatalog.isEmpty {
                    Text(searchText.isEmpty ? "The catalog is empty." : "No apps match “\(searchText)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(filteredCatalog) { app in
                        let installation = apps.installation(withID: app.id)
                        CatalogAppCard(
                            app: app,
                            installation: installation,
                            status: installation.map { apps.status(for: $0.appID) },
                            definitionChanged: installation.map { apps.definitionChanged(for: $0) } ?? false
                        ) {
                            openDetails(for: app)
                        } onInstall: {
                            installTarget = app
                        } onOpen: {
                            if let installation {
                                apps.openWebUI(for: installation)
                            }
                        }
                    }
                }
                }
            }
            .padding(.top, 4)
        }
    }

    /// Registry sync state + the manual refresh control.
    private var registryStatusRow: some View {
        HStack(spacing: 8) {
            switch apps.remoteCatalogState {
            case .syncing:
                ProgressView()
                    .controlSize(.small)
                Text("Syncing registry…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .synced(let date, let count):
                Image(systemName: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(count) app\(count == 1 ? "" : "s") · synced \(Self.relativeTime(date)) from \(hostName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Registry unreachable — using the last synced catalog (\(message))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(message)
            case .idle:
                Image(systemName: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Using the built-in catalog — the registry hasn't synced yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await apps.refreshRemoteCatalog() }
            } label: {
                Label("Refresh Registry", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .disabled(apps.remoteCatalogState.isSyncing)
            .help("Re-download the app registry now (automatic once a day)")
            .accessibilityLabel("Refresh the app registry")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Registry status")
    }

    private var hostName: String {
        (apps.catalogRemoteBaseOverride ?? RemoteCatalog.configuredBaseURL).host ?? "registry"
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var catalogWarningsBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(apps.catalogWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityLabel("Catalog warnings")
    }
}

// MARK: - Installed Card

struct InstalledAppCard: View {
    @Environment(AppState.self) private var appState
    let installation: AppInstallation
    let onOpenDetails: () -> Void

    private var apps: AppStoreManager { appState.apps }
    private var status: AppStoreManager.AppStatus { apps.status(for: installation.appID) }
    private var icon: String { apps.app(withID: installation.appID)?.icon ?? "shippingbox" }

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(symbolName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(installation.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    StatusBadge(status: status.label)
                    if let port = installation.webPort {
                        Text("127.0.0.1:\(port)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fontDesign(.monospaced)
                    }
                }
            }
            Spacer()
            if let url = apps.webURL(for: installation), status == .running {
                Button("Open") {
                    apps.openWebUI(for: installation)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open \(url.absoluteString)")
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetails)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(installation.name), status \(status.label)")
        .accessibilityHint("Show app details")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Show Details", action: onOpenDetails)
            if let url = apps.webURL(for: installation) {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if let app = apps.app(withID: installation.appID) {
                if let homepage = app.homepage, let url = URL(string: homepage) {
                    Button("Website") { NSWorkspace.shared.open(url) }
                }
                if let source = app.source, let url = URL(string: source) {
                    Button("Source Code") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

// MARK: - Catalog Card

struct CatalogAppCard: View {
    let app: CatalogApp
    let installation: AppInstallation?
    let status: AppStoreManager.AppStatus?
    /// The registry changed this app's template since it was installed.
    let definitionChanged: Bool
    let onOpenDetails: () -> Void
    let onInstall: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIcon(symbolName: app.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.headline)
                    Text(app.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }

            Text(app.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)

            HStack(spacing: 8) {
                Text(app.category)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                if definitionChanged {
                    Text("Template updated")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("The registry changed this app's template — Update re-creates it with your settings kept")
                }
                Spacer()
                if installation != nil {
                    if let status, status == .running, app.webUI != nil {
                        Button("Open", action: onOpen)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button("Details", action: onOpenDetails)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Install…", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                tileMenu
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetails)
        .contextMenu {
            Button("About This App…", action: onOpenDetails)
            linkMenuItems
            Divider()
            if installation != nil {
                Button("Show App Details", action: onOpenDetails)
            } else {
                Button("Install…", action: onInstall)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name): \(app.tagline)")
    }

    /// ⋯ menu: the app detail page plus the project's own links.
    private var tileMenu: some View {
        Menu {
            Button("About This App…", action: onOpenDetails)
            linkMenuItems
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .controlSize(.small)
        .help("More options")
        .accessibilityLabel("More options for \(app.name)")
    }

    @ViewBuilder
    private var linkMenuItems: some View {
        if let homepage = app.homepage, let url = URL(string: homepage) {
            Button("Website") {
                NSWorkspace.shared.open(url)
            }
        }
        if let source = app.source, let url = URL(string: source) {
            Button("Source Code") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Shared Bits

/// Rounded accent tile for an app's SF Symbol.
struct AppIcon: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.title3)
            .foregroundStyle(Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
