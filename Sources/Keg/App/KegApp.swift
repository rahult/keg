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
        .onDisappear {
            appState.stopRefreshing()
        }
    }
}

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
            case .networks:
                NetworkListView()
            case .volumes:
                VolumeListView()
            case .registries:
                RegistryListView()
            case .kubernetes:
                KubernetesView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
