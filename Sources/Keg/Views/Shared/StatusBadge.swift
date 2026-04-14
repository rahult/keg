import SwiftUI

struct StatusBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let status: String

    private var color: Color {
        switch status.lowercased() {
        case "running": return contrast == .increased ? .primary : .green
        case "stopped", "exited": return contrast == .increased ? .primary : .red
        case "created": return contrast == .increased ? .primary : .blue
        case "paused": return contrast == .increased ? .primary : .yellow
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
