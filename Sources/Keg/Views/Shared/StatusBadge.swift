import SwiftUI

struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status.lowercased() {
        case "running": return .green
        case "stopped", "exited": return .red
        case "created": return .blue
        case "paused": return .yellow
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
