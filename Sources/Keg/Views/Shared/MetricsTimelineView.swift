import SwiftUI
import Charts

struct MetricsTimelineView: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let title: String
    let points: [MetricsHistoryVM.MetricPoint]
    let color: Color
    let valueFormatter: (Double) -> String

    init(title: String, points: [MetricsHistoryVM.MetricPoint], color: Color, unit: String = "%") {
        self.title = title
        self.points = points
        self.color = color
        self.valueFormatter = { value in
            switch unit {
            case "%":
                return String(format: "%.1f%%", value)
            case "bytes":
                return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
            case "bps":
                if value > 1_000_000 {
                    return String(format: "%.1f MB/s", value / 1_000_000)
                } else if value > 1_000 {
                    return String(format: "%.1f KB/s", value / 1_000)
                } else {
                    return String(format: "%.0f B/s", value)
                }
            default:
                return String(format: "%.1f", value)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let latest = points.last {
                    Text(valueFormatter(latest.value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }

            if points.count >= 2 {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value(title, point.value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value(title, point.value)
                    )
                    .foregroundStyle(color.gradient.opacity(0.15))
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 60)
            } else {
                Text("Collecting data...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(8)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        if contrast == .increased {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        return AnyShapeStyle(.quaternary)
    }
}
