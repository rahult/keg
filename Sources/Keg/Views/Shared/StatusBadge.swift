import SwiftUI

struct StatusBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let status: String

    /// Color grammar: green = serving, blue = provisioned, yellow = held,
    /// orange = transitional, gray = at rest. A deliberate stop is a normal
    /// state, not a failure — red stays reserved for dead/failed/error.
    private var color: Color {
        switch status.lowercased() {
        case "running": return contrast == .increased ? .primary : .green
        case "stopping": return contrast == .increased ? .primary : .orange
        case "created": return contrast == .increased ? .primary : .blue
        case "paused": return contrast == .increased ? .primary : .yellow
        case "dead", "failed", "error": return contrast == .increased ? .primary : .red
        case "stopped", "exited": return contrast == .increased ? .primary : .gray
        default: return contrast == .increased ? .primary : .gray
        }
    }

    private var textColor: Color {
        contrast == .increased ? .primary : .secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: contrast == .increased ? 8 : 6, height: contrast == .increased ? 8 : 6)
            Text(status)
                .font(.caption)
                .foregroundStyle(textColor)
        }
    }
}
