import SwiftUI

/// Compact system dashboard for sidebar
struct SystemDashboardView: View {
    @State private var metrics: SystemMetrics.Metrics?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .foregroundStyle(.secondary)
                Text("System")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let metrics = metrics {
                    Text(metrics.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Metrics grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                MetricCard(
                    icon: "cpu",
                    title: "CPU",
                    value: formatPercent(metrics?.cpuUsagePercent),
                    color: cpuColor
                )

                MetricCard(
                    icon: "memorychip",
                    title: "Memory",
                    value: formatMemory(metrics),
                    color: memoryColor
                )

                MetricCard(
                    icon: "internaldrive",
                    title: "Disk",
                    value: formatPercent(metrics?.diskUsagePercent),
                    color: diskColor
                )

                MetricCard(
                    icon: "speedometer",
                    title: "Latency",
                    value: formatLatency(metrics?.latencyMs),
                    color: .blue
                )
            }

            // Container stats
            if let metrics = metrics {
                HStack(spacing: 12) {
                    Label("\(metrics.containerCount)", systemImage: "cube.box")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Label("\(metrics.imageCount)", systemImage: "photo.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            await refreshMetrics()
        }
        .refreshable {
            await refreshMetrics()
        }
    }

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

    private var diskColor: Color {
        guard let usage = metrics?.diskUsagePercent else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 80 { return .orange }
        return .green
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value = value else { return "--" }
        return String(format: "%.0f%%", min(value, 100))
    }

    private func formatMemory(_ metrics: SystemMetrics.Metrics?) -> String {
        guard let m = metrics else { return "--" }
        return String(format: "%.1f GB", m.memoryUsedGB)
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

        let service = SystemMetrics()
        metrics = await service.getMetrics(forceRefresh: true)
    }
}

/// Individual metric card
struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Preview

#Preview {
    VStack {
        SystemDashboardView()
            .frame(width: 200)
    }
    .padding()
}

/// Status indicator dot
struct StatusDot: View {
    enum Status {
        case good, warning, critical, unknown
    }

    let status: Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .gray
        }
    }
}
