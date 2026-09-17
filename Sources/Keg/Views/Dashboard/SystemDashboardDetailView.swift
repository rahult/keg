import SwiftUI

/// Full system dashboard view for detail area
struct SystemDashboardDetailView: View {
    @Environment(AppState.self) private var appState
    @State private var metrics: SystemMetrics.Metrics?
    @State private var isLoading = true
    @State private var autoRefresh = true
    @AppStorage("hasSeenAgentDiscovery") private var hasSeenAgentDiscovery = false

    private let metricsService = SystemMetrics.shared
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                if !ContainerCLI.isInstalled {
                    PlatformSetupCard()
                }

                // Key metrics grid
                metricsGridSection

                // Live services and disk usage
                RunningServicesSection()
                    .environment(appState)
                DiskUsageSection()

                // System status section
                systemStatusSection

                // Quick actions
                quickActionsSection

                // Agent discovery
                if !hasSeenAgentDiscovery && appState.activeAgentCount == 0 {
                    agentDiscoverySection
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: KegSection.dashboard)
            }
        }
        .task {
            await refreshMetrics()
        }
        .onReceive(timer) { _ in
            if autoRefresh {
                Task { await refreshMetrics() }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keg Dashboard")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                if let metrics = metrics {
                    Text("Last updated: \(metrics.timestamp, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await refreshMetrics() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Toggle("Auto-refresh", isOn: $autoRefresh)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Metrics Grid

    private var metricsGridSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            MetricTile(
                title: "CPU",
                value: formatPercent(metrics?.cpuUsagePercent),
                subtitle: "Host share",
                icon: "cpu",
                color: cpuColor
            )

            MetricTile(
                title: "Memory",
                value: formatMemory(metrics),
                subtitle: "Containers",
                icon: "memorychip",
                color: memoryColor
            )

            MetricTile(
                title: "Storage",
                value: formatStorage(metrics),
                subtitle: "Images",
                icon: "internaldrive",
                color: .purple
            )

            MetricTile(
                title: "Latency",
                value: formatLatency(metrics?.latencyMs),
                subtitle: "Container API",
                icon: "speedometer",
                color: .blue
            )
        }
    }

    // MARK: - System Status

    private var systemStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runtime Status")
                .font(.headline)

            HStack(spacing: 16) {
                StatusCard(
                    title: "Containers",
                    value: "\(metrics?.containerCount ?? 0)",
                    subtitle: "\(metrics?.totalContainerCount ?? 0) total",
                    icon: "cube.box.fill",
                    color: .blue
                )

                StatusCard(
                    title: "Images",
                    value: "\(metrics?.imageCount ?? 0)",
                    subtitle: "\(metrics?.activeImageCount ?? 0) in use",
                    icon: "photo.stack.fill",
                    color: .purple
                )

                StatusCard(
                    title: "Container Runtime",
                    value: statusText,
                    subtitle: statusSubtitle,
                    icon: statusIcon,
                    color: statusColor
                )
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            HStack(spacing: 12) {
                ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                    Task { await refreshMetrics() }
                }

                ActionButton(title: appState.isSystemRunning ? "Stop System" : "Start System", icon: appState.isSystemRunning ? "stop.fill" : "play.fill") {
                    Task {
                        if appState.isSystemRunning {
                            await appState.stopSystem()
                        } else {
                            await appState.startSystem()
                        }
                        await refreshMetrics()
                    }
                }

                ActionButton(title: "Containers", icon: "cube.box") {
                    appState.currentArea = .keg
                    appState.selectedKegSection = .containers
                }

                ActionButton(title: "Terminal", icon: "terminal") {
                    appState.currentArea = .keg
                    appState.selectedKegSection = .terminal
                }
            }
        }
    }

    // MARK: - Agent Discovery

    private var agentDiscoverySection: some View {
        GroupBox {
            HStack(spacing: 16) {
                Image(systemName: "cpu")
                    .font(.largeTitle)
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Run AI Agents")
                        .font(.headline)
                    Text("Run AI agents in hardware-isolated containers. Each agent gets its own sandbox.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(spacing: 8) {
                    Button("Get Started") {
                        appState.currentArea = .agents
                        appState.selectedAgentSection = .dashboard
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Dismiss") {
                        hasSeenAgentDiscovery = true
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run AI Agents. Run AI agents in hardware-isolated containers. Each agent gets its own sandbox.")
    }

    // MARK: - Computed Properties

    private var cpuColor: Color {
        guard let usage = metrics?.cpuUsagePercent else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 70 { return .orange }
        return .green
    }

    private var memoryColor: Color {
        guard let usage = metrics?.memoryUsagePercent else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 70 { return .orange }
        return .green
    }

    private var statusText: String {
        switch metrics?.containerCount {
        case .none: return "Unknown"
        case 0: return "Idle"
        default: return "Running"
        }
    }

    private var statusSubtitle: String {
        switch metrics?.containerCount {
        case .none: return "No data"
        case 0: return "No containers"
        default: return "\(metrics!.containerCount) active"
        }
    }

    private var statusIcon: String {
        switch metrics?.containerCount {
        case .none, 0: return "pause.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch metrics?.containerCount {
        case .none: return .gray
        case 0: return .orange
        default: return .green
        }
    }

    // MARK: - Helpers

    private func formatPercent(_ value: Double?) -> String {
        guard let value = value else { return "--" }
        return String(format: "%.0f%%", min(value, 100))
    }

    private func formatMemory(_ metrics: SystemMetrics.Metrics?) -> String {
        guard let m = metrics else { return "--" }
        return String(format: "%.1f GB", m.memoryUsedGB)
    }

    private func formatStorage(_ metrics: SystemMetrics.Metrics?) -> String {
        guard let m = metrics else { return "--" }
        // diskUsedGB is computed in GiB; re-expand to bytes and format with
        // the decimal .file style so the tile matches `container system df`
        // and the Disk Usage section below.
        let bytes = Int64(m.diskUsedGB * 1_073_741_824)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatLatency(_ ms: Double?) -> String {
        guard let ms = ms else { return "--" }
        if ms < 1 {
            return String(format: "%.0f µs", ms * 1000)
        }
        return String(format: "%.0f ms", ms)
    }

    private func refreshMetrics() async {
        isLoading = true
        defer { isLoading = false }

        metrics = await metricsService.getMetrics(forceRefresh: true)
    }
}

// MARK: - Metric Tile

struct MetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Status Card

struct StatusCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(color)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.headline)
                    .monospacedDigit()

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
