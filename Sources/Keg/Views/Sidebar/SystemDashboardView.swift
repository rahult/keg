import SwiftUI

/// Single-row system summary for the top of the sidebar. The full metrics
/// dashboard lives in the Dashboard section; the sidebar only needs enough
/// context to answer "is anything running?" at a glance.
struct SystemDashboardView: View {
    @State private var metrics: SystemMetrics.Metrics?

    private let metricsService = SystemMetrics.shared

    var body: some View {
        HStack(spacing: 12) {
            Label(containersLabel, systemImage: "cube.box")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Containers")
                .accessibilityValue(containersLabel)

            Label(imagesLabel, systemImage: "photo.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Images")
                .accessibilityValue(imagesLabel)

            Spacer()

            Text(formatLatency(metrics?.latencyMs))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Container API latency")
                .accessibilityValue(formatLatency(metrics?.latencyMs))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keg system summary")
        .task {
            metrics = await metricsService.getMetrics(forceRefresh: true)
        }
    }

    private var containersLabel: String {
        guard let metrics else { return "--" }
        return "\(metrics.containerCount)/\(metrics.totalContainerCount)"
    }

    private var imagesLabel: String {
        guard let metrics else { return "--" }
        return "\(metrics.imageCount)"
    }

    private func formatLatency(_ ms: Double?) -> String {
        guard let ms else { return "" }
        if ms < 1 {
            return String(format: "%.0f µs", ms * 1000)
        }
        return String(format: "%.0f ms", ms)
    }
}

// MARK: - Preview

#Preview {
    SystemDashboardView()
        .frame(width: 250)
        .padding()
}
