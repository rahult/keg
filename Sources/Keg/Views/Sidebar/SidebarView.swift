import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // System Dashboard at top
            SystemDashboardView()
                .padding(.horizontal, 8)
                .padding(.top, 8)

            AreaPicker()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()
                .padding(.horizontal, 12)

            switch appState.currentArea {
            case .keg:
                KegSidebarContent()
            case .agents:
                AgentSidebarContent()
            }

            Spacer()

            Divider()
                .padding(.horizontal, 12)

            // Settings always at bottom
            settingsButton
        }
        .listStyle(.sidebar)
        .navigationTitle("Keg")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }

    private var settingsButton: some View {
        Button {
            appState.currentArea = .keg
            appState.selectedKegSection = .settings
        } label: {
            Label(KegSection.settings.rawValue, systemImage: KegSection.settings.iconName)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(appState.currentArea == .keg && appState.selectedKegSection == .settings ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Area Picker

struct AreaPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Picker("Area", selection: Binding(
            get: { appState.currentArea },
            set: { appState.currentArea = $0 }
        )) {
            ForEach(AppArea.allCases) { area in
                Label {
                    Text(area.rawValue)
                } icon: {
                    Image(systemName: area.iconName)
                }
                .tag(area)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
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
        SidebarSection(name: "Workloads", items: [.containers, .compose, .kubernetes]),
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
        }
        .listStyle(.sidebar)
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

// MARK: - Agent Sidebar Content

struct AgentSidebarContent: View {
    @Environment(AppState.self) private var appState

    private struct SidebarSection {
        let name: String
        let items: [AgentSection]
    }

    private let sections: [SidebarSection] = [
        SidebarSection(name: "Overview", items: [.dashboard, .sessions]),
        SidebarSection(name: "Manage", items: [.agents, .skills, .sources]),
        SidebarSection(name: "Account", items: [.account]),
    ]

    var body: some View {
        List(selection: Binding<AgentSection?>(
            get: { appState.selectedAgentSection },
            set: { if let section = $0 { appState.selectedAgentSection = section } }
        )) {
            ForEach(sections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.items) { item in
                        Label(item.rawValue, systemImage: item.iconName)
                            .tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
