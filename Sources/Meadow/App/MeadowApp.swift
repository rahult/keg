import AppKit
import SwiftUI

@main
struct MeadowApp: App {
    @State private var appState = AppState()

    init() {
        if let icon = MeadowIcon.image {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func presentRunContainer() {
        appState.selectedMeadowSection = .containers
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .meadowRunContainer, object: nil)
        }
    }

    private func presentPullImage() {
        appState.selectedMeadowSection = .images
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .meadowPullImage, object: nil)
        }
    }

    private func openMeadowDocumentation() {
        guard let url = URL(string: "https://github.com/rahult/meadow#readme") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openReleaseNotes() {
        guard let url = URL(string: "https://github.com/rahult/meadow/blob/main/CHANGELOG.md") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openIssueTracker() {
        guard let url = URL(string: "https://github.com/rahult/meadow/issues/new") else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some Scene {
        // Main window
        WindowGroup(id: "main") {
            MainView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Run Container...") {
                    presentRunContainer()
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
            }

            CommandGroup(after: .importExport) {
                Button("Pull Image...") {
                    presentPullImage()
                }
                .keyboardShortcut("P", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Find") {
                    NotificationCenter.default.post(name: .meadowFocusSearch, object: nil)
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

                Button("Meadow Documentation") {
                    openMeadowDocumentation()
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
        } label: {
            if let icon = MeadowIcon.menuBarImage {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .accessibilityLabel("Meadow")
            } else {
                Image(systemName: "shippingbox.fill")
                    .accessibilityLabel("Meadow")
            }
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let meadowRunContainer = Notification.Name("meadow.runContainer")
    static let meadowStopContainer = Notification.Name("meadow.stopContainer")
    static let meadowDeleteContainer = Notification.Name("meadow.deleteContainer")
    static let meadowRefresh = Notification.Name("meadow.refresh")
    static let meadowPullImage = Notification.Name("meadow.pullImage")
    static let meadowToggleSidebar = Notification.Name("meadow.toggleSidebar")
    static let meadowFocusSearch = Notification.Name("meadow.focusSearch")
}

// MARK: - Icons

private enum MeadowIcon {
    static let image = Bundle.main.url(forResource: "Meadow", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))

    static let menuBarImage: NSImage? = {
        guard let image = Bundle.main.url(forResource: "MeadowMenuBarTemplate", withExtension: "png")
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
            MeadowDetailView()
                .environment(appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Label(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .accessibilityLabel(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
            }
        }
        .task {
            await appState.ensureReady()
            appState.startRefreshing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meadowToggleSidebar)) { _ in
            toggleSidebar()
        }
        .onDisappear {
            appState.stopRefreshing()
        }
    }

    private func toggleSidebar() {
        isSidebarVisible.toggle()
    }
}

// MARK: - Meadow Detail Routing

struct MeadowDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedMeadowSection {
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
