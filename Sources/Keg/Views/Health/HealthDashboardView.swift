import SwiftUI

struct HealthDashboardView: View {
    @State private var vm = HealthScoreVM()
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Runtime facts are shown unconditionally: when the runtime is
            // wedged, this panel is the only thing on the page that can
            // explain why everything else is stuck.
            runtimeSection
            Divider()
            if vm.isLoading && vm.containerHealths.isEmpty {
                ProgressView("Loading health data...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.containerHealths.isEmpty {
                ContentUnavailableView(
                    "No Container Health Data",
                    systemImage: "heart.circle",
                    description: Text("Running containers will show health scores")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Overall health gauge
                overallSection
                Divider()
                // Per-container table
                containerTable
            }
        }
        .accessibilityLabel("Health Dashboard")
        .accessibilityHint("Overview of container health scores and resource usage")
        .navigationTitle("Health")
        .toolbar {
            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .health)
            }

            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload the health data (⌘R)")
                .accessibilityLabel("Refresh health data")
            }
        }
        .toolbarRole(.editor)
        .task {
            await vm.refresh()
        }
    }

    private var overallSection: some View {
        VStack(spacing: 12) {
            Gauge(value: Double(vm.overallScore), in: 0...100) {
                Text("Overall Health")
            } currentValueLabel: {
                Text("\(vm.overallScore)")
                    .font(.title2.monospaced().bold())
                    .monospacedDigit()
                    .foregroundStyle(scoreForeground(vm.overallScoreColor))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(scoreForeground(vm.overallScoreColor))

            Text(overallDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                HealthLegend(color: .green, label: "Healthy (80–100)")
                HealthLegend(color: .yellow, label: "Warning (50–79)")
                HealthLegend(color: .red, label: "Critical (0–49)")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var overallDescription: String {
        switch vm.overallScore {
        case 80...100: return "All systems healthy"
        case 50...79: return "Some containers need attention"
        default: return "Critical issues detected"
        }
    }

    /// Runtime facts you need when things look wrong: which status the
    /// runtime is in, where its data lives, and what the CLI actually did
    /// recently (commands, durations, timeouts).
    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Runtime")
                    .font(.headline)
                Spacer()
                CopyDiagnosticsButton()
            }

            HStack(spacing: 16) {
                Label(systemStatusText, systemImage: systemStatusIcon)
                    .foregroundStyle(appState.isRuntimeUnresponsive ? Color.orange : Color.primary)
                Label(appState.effectiveDataRootDescription, systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            let calls = ContainerCLI.recentCalls.suffix(6).reversed()
            if calls.isEmpty {
                Text("No CLI activity recorded yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(calls) { call in
                        HStack(alignment: .firstTextBaseline) {
                            Text(call.startedAt.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.tertiary)
                            Text(call.command)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(call.outcome)
                                .foregroundStyle(call.outcome.contains("timed out") ? Color.orange : .secondary)
                            if let duration = call.duration {
                                Text(String(format: "%.1fs", duration))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var systemStatusText: String {
        switch appState.systemStatus {
        case .running: return "Runtime answering"
        case .stopped: return "Runtime stopped"
        case .unresponsive: return "Runtime unresponsive"
        case .error: return "Runtime error"
        }
    }

    private var systemStatusIcon: String {
        switch appState.systemStatus {
        case .running: return "checkmark.circle"
        case .unresponsive: return "exclamationmark.triangle"
        case .stopped: return "stop.circle"
        case .error: return "xmark.circle"
        }
    }

    private var containerTable: some View {
        Table(vm.containerHealths, selection: .constant(nil as String?)) {
            TableColumn("Name") { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(scoreForeground(item.scoreColor))
                        .frame(width: 8, height: 8)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .width(min: 120)

            TableColumn("Image") { item in
                Text(item.image)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 150)

            TableColumn("Status") { item in
                StatusBadge(status: item.status.rawValue)
            }
            .width(min: 80, max: 100)

            TableColumn("Score") { item in
                Text("\(item.score)")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(scoreForeground(item.scoreColor))
            }
            .width(60)

            TableColumn("Memory") { item in
                Text(String(format: "%.0f%%", item.memPercent))
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(item.memPercent > 80 ? .red : .secondary)
            }
            .width(70)

            TableColumn("CPU") { item in
                Text(String(format: "%.0f%%", item.cpuPercent))
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(item.cpuPercent > 80 ? .red : .secondary)
            }
            .width(70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
    }

    private func scoreForeground(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .gray
        }
    }
}

struct HealthLegend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
