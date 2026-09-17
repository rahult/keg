import SwiftUI

/// Single-row system summary for the top of the sidebar. The full metrics
/// dashboard lives in the Dashboard section; the sidebar only needs enough
/// context to answer "is anything running?" at a glance.
struct SystemDashboardView: View {
    var compact: Bool = false

    @State private var metrics: SystemMetrics.Metrics?

    private let metricsService = SystemMetrics.shared

    var body: some View {
        if compact {
            // Icon rail: just the two status glyphs, centered.
            HStack(spacing: 14) {
                Image(systemName: "cube.box")
                    .foregroundStyle(.secondary)
                    .help("Containers: \(containersLabel)")
                Image(systemName: "photo.stack")
                    .foregroundStyle(.secondary)
                    .help("Images: \(imagesLabel)")
            }
            .font(.caption)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Keg system summary: \(containersLabel) containers running, \(imagesLabel) images")
            .task { await pollMetrics() }
        } else {
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
            .task { await pollMetrics() }
        }
    }

    /// Metrics used to load once per appearance, which left the summary
    /// stale ("0/0") until the next relaunch. Poll so "is anything running?"
    /// stays answerable; .task cancels the loop when the row leaves the
    /// hierarchy. Non-forced reads share the metrics actor's 2s cache with
    /// the dashboard's auto-refresh.
    private func pollMetrics() async {
        while !Task.isCancelled {
            metrics = await metricsService.getMetrics()
            try? await Task.sleep(for: .seconds(5))
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
