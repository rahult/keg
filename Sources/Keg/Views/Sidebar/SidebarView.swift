import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    private struct SidebarSection {
        let name: String
        let items: [NavigationSection]
    }

    private let sections: [SidebarSection] = [
        SidebarSection(name: "Workloads", items: [.containers, .compose]),
        SidebarSection(name: "Content", items: [.images, .builds]),
        SidebarSection(name: "Networking", items: [.networks, .ports, .registries]),
        SidebarSection(name: "Storage", items: [.volumes]),
        SidebarSection(name: "Tools", items: [.terminal, .devcontainers, .kubernetes]),
        SidebarSection(name: "Health", items: [.health]),
    ]

    var body: some View {
        List(selection: Binding<NavigationSection?>(
            get: { appState.selectedSection },
            set: { appState.selectedSection = $0 ?? .containers }
        )) {
            ForEach(sections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.items) { item in
                        Label(item.rawValue, systemImage: item.iconName)
                            .tag(item)
                    }
                }
            }

            Section("System") {
                Label(NavigationSection.settings.rawValue, systemImage: NavigationSection.settings.iconName)
                    .tag(NavigationSection.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Keg")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }
}
