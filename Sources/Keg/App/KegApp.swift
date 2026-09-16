import AppKit
import SwiftUI

@main
struct KegApp: App {
    @State private var appState = AppState()
    @State private var updater = SoftwareUpdater()

    init() {
        if let icon = KegIcon.image {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func presentRunContainer() {
        appState.currentArea = .keg
        appState.selectedKegSection = .containers
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .kegRunContainer, object: nil)
        }
    }

    private func presentPullImage() {
        appState.currentArea = .keg
        appState.selectedKegSection = .images
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .kegPullImage, object: nil)
        }
    }

    private func presentNewAgent() {
        appState.currentArea = .agents
        appState.selectedAgentSection = .agents
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .kegNewAgent, object: nil)
        }
    }

    private func openKegDocumentation() {
        guard let url = URL(string: "https://github.com/rahult/keg#readme") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openReleaseNotes() {
        guard let url = URL(string: "https://github.com/rahult/keg/blob/main/CHANGELOG.md") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openIssueTracker() {
        guard let url = URL(string: "https://github.com/rahult/keg/issues/new") else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some Scene {
        // Main window
        WindowGroup(id: "main") {
            MainView()
                .environment(appState)
                .environment(updater)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            CommandGroup(after: .newItem) {
                Button("Run Container…") {
                    presentRunContainer()
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
            }

            CommandGroup(after: .importExport) {
                Button("Pull Image…") {
                    presentPullImage()
                }
                .keyboardShortcut("P", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Find") {
                    NotificationCenter.default.post(name: .kegFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            SidebarCommands()

            CommandGroup(after: .sidebar) {
                Divider()

                Button("System Dashboard") {
                    appState.showDashboard()
                }
            }

            CommandGroup(after: .help) {
                Divider()

                Button("Keg Documentation") {
                    openKegDocumentation()
                }

                Button("Release Notes") {
                    openReleaseNotes()
                }

                Button("Report an Issue") {
                    openIssueTracker()
                }
            }
        }

        // Menu bar
        MenuBarExtra {
            MenuBarPopover()
                .environment(appState)
                .environment(updater)
        } label: {
            if let icon = KegIcon.menuBarImage {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .accessibilityLabel("Keg")
            } else {
                Image(systemName: "shippingbox.fill")
                    .accessibilityLabel("Keg")
            }
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
                .environment(appState)
                .environment(updater)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let kegRunContainer = Notification.Name("keg.runContainer")
    static let kegStopContainer = Notification.Name("keg.stopContainer")
    static let kegDeleteContainer = Notification.Name("keg.deleteContainer")
    static let kegRefresh = Notification.Name("keg.refresh")
    static let kegPullImage = Notification.Name("keg.pullImage")
    static let kegToggleSidebar = Notification.Name("keg.toggleSidebar")
    static let kegNewAgent = Notification.Name("keg.newAgent")
    static let kegFocusSearch = Notification.Name("keg.focusSearch")
}

// MARK: - Icons

private enum KegIcon {
    static let image = Bundle.main.url(forResource: "Keg", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))

    static let menuBarImage: NSImage? = {
        guard let image = Bundle.main.url(forResource: "KegMenuBarTemplate", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:)) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

// MARK: - Main View

struct MainView: View {
    @Environment(AppState.self) private var appState
    @SceneStorage("main.sidebar-visible") private var isSidebarVisible = true

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isSidebarVisible ? .doubleColumn : .detailOnly },
            set: { isSidebarVisible = $0 != .detailOnly }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .environment(appState)
        } detail: {
            DetailView()
                .environment(appState)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await appState.ensureReady()
            appState.startRefreshing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegToggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegPlatformInstalled)) { _ in
            Task { await appState.ensureReady() }
        }
        .onDisappear {
            appState.stopRefreshing()
        }
    }

    private func toggleSidebar() {
        isSidebarVisible.toggle()
    }
}

// MARK: - Detail Routing

struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        KegDetailView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Keg Detail View

struct KegDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedKegSection {
        case .dashboard:
            SystemDashboardDetailView()
        case .containers:
            ContainerListView()
        case .images:
            ImageListView()
        case .builds:
            BuildView()
        case .compose:
            ComposeView()
        case .terminal:
            QuickTerminalView()
        case .ports:
            PortDashboardView()
        case .networks:
            NetworkListView()
        case .volumes:
            VolumeListView()
        case .registries:
            RegistryListView()
        case .health:
            HealthDashboardView()
        case .devcontainers:
            DevContainerView()
        case .kubernetes:
            KubernetesView()
        case .logs:
            MultiContainerLogsView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Agent Area View (routing)

struct AgentAreaView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedAgentSection {
        case .dashboard:
            AgentDashboardView()
        case .useCases:
            AgentUseCaseLibraryView()
        case .agents:
            AgentListView()
        case .sessions:
            SessionListView()
        case .sources:
            SourceListView()
        case .skills:
            SkillListView()
        }
    }
}
