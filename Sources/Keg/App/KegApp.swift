import AppKit
import SwiftUI

@main
struct KegApp: App {
    @State private var appState = AppState()

    init() {
        if let icon = KegIcon.image {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private var shortContainerID: String {
        appState.selectedContainerID.map { String($0.prefix(12)) } ?? "Container"
    }

    var body: some Scene {
        // Main window
        WindowGroup {
            MainView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandMenu("Container") {
                Button("Run Container...") {
                    NotificationCenter.default.post(name: .kegRunContainer, object: nil)
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
                .disabled(appState.selectedSection != .containers)

                Divider()

                Button(appState.selectedContainerID == nil ? "Stop Selected Container" : "Stop \(shortContainerID)") {
                    NotificationCenter.default.post(name: .kegStopContainer, object: nil)
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(appState.selectedSection != .containers || appState.selectedContainerID == nil)

                Button(appState.selectedContainerID == nil ? "Delete Selected Container" : "Delete \(shortContainerID)") {
                    NotificationCenter.default.post(name: .kegDeleteContainer, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(appState.selectedSection != .containers || appState.selectedContainerID == nil)

                Divider()

                Button("Refresh") {
                    NotificationCenter.default.post(name: .kegRefresh, object: nil)
                }
                .keyboardShortcut("R", modifiers: .command)
            }

            CommandMenu("Image") {
                Button("Pull Image...") {
                    NotificationCenter.default.post(name: .kegPullImage, object: nil)
                }
                .keyboardShortcut("P", modifiers: [.command, .shift])
                .disabled(appState.selectedSection != .images)
            }

            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .kegToggleSidebar, object: nil)
                }
                .keyboardShortcut("S", modifiers: [.command, .control])
            }
        }

        // Menu bar
        MenuBarExtra {
            MenuBarPopover()
                .environment(appState)
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
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .environment(appState)
        } detail: {
            DetailView()
                .environment(appState)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await appState.checkSystemStatus()
            appState.startRefreshing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
        }
        .onDisappear {
            appState.stopRefreshing()
        }
    }
}

// MARK: - Detail Routing

struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.selectedSection {
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
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
