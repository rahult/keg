import SwiftUI

struct SidebarView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            SystemDashboardView()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)

            KegSidebarContent()
        }
        .listStyle(.sidebar)
        .navigationTitle("Keg")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityHint("Choose a section")
    }
}

// MARK: - Keg Sidebar Content

struct KegSidebarContent: View {
    @Environment(AppState.self) private var appState

    private struct SidebarSection {
        let name: String
        let items: [KegSection]
    }

    private let sections: [SidebarSection] = [
        SidebarSection(name: "Overview", items: [.dashboard]),
        SidebarSection(name: "Workloads", items: [.containers, .compose, .kubernetes, .logs]),
        SidebarSection(name: "Content", items: [.images, .builds]),
        SidebarSection(name: "System", items: [.networks, .volumes, .registries]),
        SidebarSection(name: "Tools", items: [.terminal, .devcontainers, .health]),
    ]

    var body: some View {
        List(selection: Binding<KegSection?>(
            get: { appState.selectedKegSection },
            set: { if let section = $0 { appState.selectedKegSection = section } }
        )) {
            ForEach(sections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.items) { item in
                        sidebarLabel(for: item)
                            .tag(item)
                    }
                }
            }

            Section("App") {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityHint("Open app settings")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Keg sections")
        .accessibilityHint("Use arrow keys to move between Keg sections")
    }

    @ViewBuilder
    private func sidebarLabel(for item: KegSection) -> some View {
        switch item {
        case .containers:
            Label(item.rawValue, systemImage: item.iconName)
                .badge(appState.runningContainerCount)
        case .health:
            Label(item.rawValue, systemImage: item.iconName)
                .badge(appState.unhealthyContainerCount)
        default:
            Label(item.rawValue, systemImage: item.iconName)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView()
            .frame(width: 250)
    } detail: {
        Text("Select an item")
    }
}
