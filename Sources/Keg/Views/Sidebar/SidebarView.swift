import SwiftUI

struct SidebarView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            AreaPicker()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if appState.currentArea == .agents {
                AgentPermissionModeControl()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if appState.currentArea == .keg {
                SystemDashboardView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()
                .padding(.horizontal, 12)

            switch appState.currentArea {
            case .keg:
                KegSidebarContent()
            case .agents:
                AgentSidebarContent()
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Keg")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
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
        .accessibilityHint("Switch between the Keg and Agents areas")
    }
}

// MARK: - Agent Permission Mode

struct AgentPermissionModeControl: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: appState.agentPermissionMode.iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Picker("Agent Permission Mode", selection: Binding(
                get: { appState.agentPermissionMode },
                set: { appState.agentPermissionMode = $0 }
            )) {
                ForEach(AgentPermissionMode.allCases) { mode in
                    Text(mode.rawValue)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .accessibilityHint("Choose how much autonomy agents have in this workspace")

            Text(appState.agentPermissionMode.summary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(appState.agentPermissionMode.summary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent permission mode")
        .accessibilityValue(appState.agentPermissionMode.rawValue)
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

            Section("App") {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
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
        SidebarSection(name: "Overview", items: [.dashboard, .useCases, .sessions]),
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

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView()
            .frame(width: 250)
    } detail: {
        Text("Select an item")
    }
}
