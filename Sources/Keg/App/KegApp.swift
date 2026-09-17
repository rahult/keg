import AppKit
import SwiftUI

/// Launch-time delegate: brings the container backend and Docker API up
/// without waiting for the main window. Previously `ensureReady()` only ran
/// from the window's `.task`, so a menu-bar-only launch (or a relaunch where
/// macOS didn't restore the window) left the Docker socket unbound and the
/// `docker` CLI dead until the user opened the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        Self.installExceptionLogger()
    }

    /// Record uncaught NSExceptions (AppKit layout faults surface this way —
    /// e.g. the 2026-09-16 SIGABRT in `_postWindowNeedsUpdateConstraints`)
    /// with their reason and stack, so a crash report alone isn't a riddle.
    private static func installExceptionLogger() {
        NSSetUncaughtExceptionHandler { exception in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let report = """
            [\(timestamp)] Uncaught NSException
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "(none)")
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            let logDir = URL(filePath: NSHomeDirectory()).appendingPathComponent(".keg")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logURL = logDir.appendingPathComponent("exceptions.log")
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data((report + "\n\n").utf8))
                try? handle.close()
            } else {
                try? (report + "\n\n").write(to: logURL, atomically: true, encoding: .utf8)
            }
            FileHandle.standardError.write(Data((report + "\n").utf8))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [appState] in
            await appState.ensureReady()
            appState.startRefreshing()
        }
    }

    /// Quitting Keg must never leave a stale socket behind: the kernel keeps
    /// accepting connects on an unlinked-but-bound socket, and every Docker
    /// client then hangs until timeout instead of failing fast. Stop the
    /// server and unlink the resolved path while the process still owns it.
    func applicationWillTerminate(_ notification: Notification) {
        appState.stopDockerAPI()
    }
}

@main
struct KegApp: App {
    @State private var appState: AppState
    @State private var updater = SoftwareUpdater()
    /// Keeps the launch delegate alive for the app's lifetime. (NSApplication
    /// only weakly references its delegate.)
    private let appDelegate: AppDelegate

    init() {
        if let icon = KegIcon.image {
            NSApplication.shared.applicationIconImage = icon
        }
        let state = AppState()
        _appState = State(initialValue: state)
        let delegate = AppDelegate(appState: state)
        appDelegate = delegate
        NSApplication.shared.delegate = delegate
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
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
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
    static let kegRunImage = Notification.Name("keg.runImage")
    static let kegStopContainer = Notification.Name("keg.stopContainer")
    static let kegDeleteContainer = Notification.Name("keg.deleteContainer")
    static let kegRefresh = Notification.Name("keg.refresh")
    static let kegPullImage = Notification.Name("keg.pullImage")
    static let kegToggleSidebar = Notification.Name("keg.toggleSidebar")
    static let kegNewAgent = Notification.Name("keg.newAgent")
    static let kegFocusSearch = Notification.Name("keg.focusSearch")
    static let kegShowWelcome = Notification.Name("keg.showWelcome")
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
    @AppStorage("keg.welcomeSeen") private var hasSeenWelcome = false
    @State private var showWelcome = false

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
            if !hasSeenWelcome {
                showWelcome = true
            }
        }
        .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeSheet { image in
                quickRun(image: image)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegShowWelcome)) { _ in
            showWelcome = true
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

    /// Navigate to Containers and open the Run sheet prefilled with the
    /// given image (welcome-sheet quick starts).
    private func quickRun(image: String) {
        appState.pendingRunImage = image
        appState.currentArea = .keg
        appState.selectedKegSection = .containers
        // Belt-and-braces if the list is already alive: it consumes
        // pendingRunImage on appear, this only covers the already-visible case.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .kegRunImage, object: image)
        }
    }
}

// MARK: - Detail Routing

struct DetailView: View {
    @Environment(AppState.self) private var appState
    @SceneStorage("main.sidebar-visible") private var isSidebarVisible = true

    var body: some View {
        KegDetailView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The standard sidebar toggle disappears once the sidebar
            // collapses (.detailOnly), leaving no way to reopen it. Provide
            // our own toggle in that state so the sidebar is always
            // recoverable. Hidden while the sidebar is visible to avoid
            // duplicating the standard toggle.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if !isSidebarVisible {
                        Button {
                            withAnimation {
                                isSidebarVisible = true
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .help("Show Sidebar")
                        .accessibilityLabel("Show Sidebar")
                    }
                }
            }
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
