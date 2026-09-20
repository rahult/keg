import AppKit
import SwiftUI

/// Launch-time delegate: brings the container backend and Docker API up
/// without waiting for the main window. Previously `ensureReady()` only ran
/// from the window's `.task`, so a menu-bar-only launch (or a relaunch where
/// macOS didn't restore the window) left the Docker socket unbound and the
/// `docker` CLI dead until the user opened the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here so the `@NSApplicationDelegateAdaptor` (which requires a
    /// no-argument init) can create it; the App struct injects the same
    /// instance into the scene environment.
    let appState = AppState()

    override init() {
        super.init()
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

    /// Only one Keg may ever run. LaunchServices dedupes ordinary launches,
    /// but `open -n` (dev targets, user commands) forces a second process,
    /// and stray bare binaries (a `.build/debug/Keg` left over from a dev
    /// session) aren't even visible to NSWorkspace's app list — so detect
    /// rivals at the process level by executable path instead. The lowest
    /// pid always survives a simultaneous race, and both racers compute the
    /// same winner. Zombies have no executable path and never match.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let myPid = ProcessInfo.processInfo.processIdentifier
        guard let rival = Self.otherKegProcesses(excluding: myPid).min(), rival < myPid else {
            return
        }
        NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == rival }?
            .activate()
        exit(0)
    }

    /// Pids of other live processes whose executable file is named `Keg`
    /// (case-sensitive, so the `keg` CLI never matches).
    private static func otherKegProcesses(excluding myPid: pid_t) -> [pid_t] {
        let hint = proc_listallpids(nil, 0)
        guard hint > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(hint) + 1)
        let bufferSize = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = proc_listallpids(&pids, bufferSize)
        guard count > 0 else { return [] }
        // PROC_PIDPATHINFO_MAXSIZE (= 4 * MAXPATHLEN) isn't exposed to Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid != myPid,
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path).hasSuffix("/Keg") else {
                return nil
            }
            return pid
        }
    }

    /// Dock-icon clicks with no visible window come here. A `Window` scene
    /// keeps exactly one window but doesn't recreate it after the user closes
    /// it, so re-order the tracked window front ourselves. Returning true
    /// lets AppKit finish its normal activation.
    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = appState.mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
        return true
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
    /// The adaptor (not `NSApplication.shared.delegate = …`) is load-bearing:
    /// SwiftUI installs its own app delegate during setup, which silently
    /// overwrote a manual assignment, so none of our delegate callbacks —
    /// including the single-instance guard and the socket bring-up — ran.
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    /// Same instance for the app's lifetime — the delegate owns it.
    private var appState: AppState { appDelegate.appState }
    @State private var updater = SoftwareUpdater()
    @Environment(\.openSettings) private var openSettingsWindow

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
        // Main window. A `Window` scene (not `WindowGroup`) is the whole
        // point: the system enforces exactly one instance of this window, so
        // there is no New Window menu item and every `openWindow(id:)` /
        // `keg://` deep link resolves to the same window instead of spawning
        // a second one.
        Window("Keg", id: "main") {
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

            // Opens the Settings window aligned with the main window (the
            // frame is captured by AppState, adopted by SettingsView) instead
            // of letting macOS drop it mid-screen.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.captureSettingsFrame()
                    openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
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

            CommandMenu("Cooper") {
                Button(appState.isCooperPanelVisible ? "Hide Cooper" : "Show Cooper") {
                    appState.isCooperPanelVisible.toggle()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Ask Cooper…") {
                    appState.isCooperPanelVisible = true
                    NotificationCenter.default.post(name: .kegCooperFocus, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift, .option])

                Divider()

                Button("Clear Conversation") {
                    appState.cooper.clearConversation()
                }
                .disabled(appState.cooper.isStreaming)
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
        @Bindable var appState = appState
        return NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .environment(appState)
        } detail: {
            // Cooper is a hand-composed trailing column, not `.inspector`:
            // on macOS 27 a root-level inspector on this split view triggers
            // AppKit's "Update Constraints in Window pass" loop and aborts
            // the window (see ~/.keg/exceptions.log). Plain HStack layout
            // gives the same always-visible-across-sections behavior.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Banner lives in a plain VStack: safeAreaInset(.top) on the
                    // split view overlaps content on macOS 26 instead of insetting.
                    if appState.isRuntimeUnresponsive {
                        RuntimeUnresponsiveBanner()
                            .environment(appState)
                        Divider()
                    }
                    DetailView()
                }
                .environment(appState)

                if appState.isCooperPanelVisible {
                    Divider()
                    CooperPanelView()
                        .environment(appState)
                        .frame(width: 380)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await appState.ensureReady()
            appState.startRefreshing()
            if !hasSeenWelcome {
                showWelcome = true
            }
        }
        .sheet(isPresented: $showWelcome, onDismiss: {
            hasSeenWelcome = true
            openCooperForFirstRun()
        }) {
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
        .background(MainWindowAccessor(appState: appState))
        .onDisappear {
            appState.stopRefreshing()
        }
    }

    private func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    /// First-run discoverability: right after the welcome sheet, open the
    /// Cooper panel once so new users meet the agent. Existing users reach
    /// it through the toolbar or the Cooper menu.
    private func openCooperForFirstRun() {
        let key = "cooper.greetedOnce"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        appState.isCooperPanelVisible = true
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

// MARK: - Window Tracking

/// Records the scene's NSWindow on the app state so the application delegate
/// can re-show it after close (dock icon / `keg open`). SwiftUI owns the
/// window; we only keep a weak reference.
private struct MainWindowAccessor: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { appState.mainWindow = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        appState.mainWindow = nsView.window
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.isCooperPanelVisible.toggle()
                    } label: {
                        Image(systemName: appState.isCooperPanelVisible
                            ? "bubble.left.and.text.bubble.right.fill"
                            : "bubble.left.and.text.bubble.right")
                    }
                    .help("Toggle Cooper (⌘⇧A)")
                    .accessibilityLabel("Toggle Cooper")
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
