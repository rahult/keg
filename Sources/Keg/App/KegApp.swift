import SwiftUI

@main
struct KegApp: App {
    @State private var appState = AppState()

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
        MenuBarExtra("Keg", systemImage: "keg") {
            MenuBarPopover()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
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
            case .networks:
                NetworkListView()
            case .volumes:
                VolumeListView()
            case .registries:
                RegistryListView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
