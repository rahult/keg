import SwiftUI

struct SidebarView: View {

    @Environment(AppState.self) private var appState
    @State private var isCompact = false

    var body: some View {
        VStack(spacing: 0) {
            SystemDashboardView(compact: isCompact)
                .padding(.horizontal, isCompact ? 0 : 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, isCompact ? 0 : 12)

            KegSidebarContent(compact: isCompact)
        }
        .listStyle(.sidebar)
        .navigationTitle("Keg")
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            isCompact = width < 180
        }
        .navigationSplitViewColumnWidth(min: 76, ideal: 260, max: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityHint("Choose a section")
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
        .help("Switch between container management (Keg) and AI agents")
        .accessibilityLabel("Area picker")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent permission mode")
        .accessibilityValue(appState.agentPermissionMode.rawValue)
    }
}

struct AgentAccountStatusCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: appState.isAgentAuthenticated ? "checkmark.circle.fill" : "person.badge.key")
                    .font(.caption)
                    .foregroundStyle(appState.isAgentAuthenticated ? .green : .secondary)
                Text("Claude")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(appState.isAgentAuthenticated ? "Connected" : "Not connected")
                .font(.subheadline.weight(.medium))

            Text(appState.isAgentAuthenticated ? "Manage your Claude API key in Settings." : "Connect your Claude API key in Settings to use Agents.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Open Settings") {
                appState.openSettings()
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .padding(.top, 2)
            .accessibilityHint("Open app settings to manage the Claude API key")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            appState.refreshAgentAuthentication()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appState.isAgentAuthenticated ? "Claude connected. Open Settings to manage your API key." : "Claude not connected. Open Settings to connect your API key.")
    }
}

// MARK: - Sidebar Structure

/// What the sidebar shows at each experience level. Shared by the real
/// sidebar and the welcome sheet's live preview so the two can never drift.
enum KegSidebarStructure {
    struct Section: Identifiable {
        let name: String
        let items: [KegSection]
        var id: String { name }
    }

    /// Getting Started groups tasks, not internals: "My Apps" instead of
    /// "Workloads", and only the screens a newcomer needs. The operator
    /// levels share the full surface.
    static func sections(for level: ExperienceLevel) -> [Section] {
        switch level {
        case .gettingStarted:
            return [
                Section(name: "Overview", items: [.dashboard]),
                Section(name: "My Apps", items: [.containers, .compose, .logs]),
                Section(name: "Essentials", items: [.images, .terminal]),
            ]
        case .comfortable, .fullControl:
            return [
                Section(name: "Overview", items: [.dashboard]),
                Section(name: "Workloads", items: [.containers, .compose, .kubernetes, .logs]),
                Section(name: "Content", items: [.images, .builds]),
                Section(name: "System", items: [.networks, .ports, .volumes, .registries]),
                Section(name: "Tools", items: [.terminal, .devcontainers, .health]),
            ]
        }
    }
}

// MARK: - Keg Sidebar Content

struct KegSidebarContent: View {
    @Environment(AppState.self) private var appState
    var compact: Bool = false

    /// Sections visible for the current experience level. Getting Started
    /// shows a task-oriented subset; Comfortable and Full Control show the
    /// full operator surface.
    private var sections: [KegSidebarStructure.Section] {
        KegSidebarStructure.sections(for: appState.experienceLevel)
    }

    var body: some View {
        List(selection: Binding<KegSection?>(
            get: { appState.selectedKegSection },
            set: { if let section = $0 { appState.selectedKegSection = section } }
        )) {
            ForEach(sections) { section in
                if compact {
                    Section {
                        sectionRows(section.items)
                    }
                } else {
                    Section(section.name) {
                        sectionRows(section.items)
                    }
                }
            }

            if compact {
                Section {
                    SettingsLink {
                        sidebarRowLabel("Settings", systemImage: "gearshape")
                    }
                    .accessibilityHint("Open app settings")
                }
            } else {
                Section("App") {
                    SettingsLink {
                        sidebarRowLabel("Settings", systemImage: "gearshape")
                    }
                    .accessibilityHint("Open app settings")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Keg sections")
        .accessibilityHint("Use arrow keys to move between Keg sections")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !compact {
                ExperienceFooter()
            }
        }
    }

    @ViewBuilder
    private func sectionRows(_ items: [KegSection]) -> some View {
        ForEach(items) { item in
            sidebarLabel(for: item)
                .tag(item)
        }
    }

    @ViewBuilder
    private func sidebarRowLabel(_ title: String, systemImage: String) -> some View {
        if compact {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
                .help(title)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private func sidebarLabel(for item: KegSection) -> some View {
        switch item {
        case .containers where !compact:
            sidebarRowLabel(item.rawValue, systemImage: item.iconName)
                .badge(appState.runningContainerCount)
        case .health where !compact:
            sidebarRowLabel(item.rawValue, systemImage: item.iconName)
                .badge(appState.unhealthyContainerCount)
        default:
            sidebarRowLabel(item.rawValue, systemImage: item.iconName)
        }
    }
}

// MARK: - Experience Footer

/// Footer pinned to the bottom of the sidebar: names the current experience
/// level and switches between them in place, so casual users are always one
/// click from the full surface and experts can simplify just as fast — no
/// trip to Settings required.
struct ExperienceFooter: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: appState.experienceLevel.iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(appState.experienceLevel.rawValue) mode")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(ExperienceLevel.allCases) { level in
                        Button {
                            appState.experienceLevel = level
                        } label: {
                            if level == appState.experienceLevel {
                                Label(level.rawValue, systemImage: "checkmark")
                            } else {
                                Text(level.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .accessibilityLabel("Change experience level")
                .accessibilityHint("Switch between Getting Started, Comfortable, and Full Control")
            }
            Text(footerCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if appState.experienceLevel == .gettingStarted {
                Button("Show everything (Full Control)") {
                    appState.experienceLevel = .fullControl
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Experience level: \(appState.experienceLevel.rawValue)")
    }

    private var footerCaption: String {
        switch appState.experienceLevel {
        case .gettingStarted:
            return "Extra sections like Kubernetes and Ports are hidden."
        case .comfortable:
            return "Every section is visible."
        case .fullControl:
            return "Every section is visible, with full detail everywhere."
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

            Section("App") {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityHint("Open app settings")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Agent sections")
        .accessibilityHint("Use arrow keys to move between agent sections")
    }
}

// MARK: - Cross-Area Link

struct CrossAreaLink: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Switch to the other area")
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
