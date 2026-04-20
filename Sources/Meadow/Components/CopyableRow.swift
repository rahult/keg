import AppKit
import SwiftUI

/// Two-line label+value with an on-hover highlight, click-to-copy, and a copy
/// button. Use in detail panes for any identifier the user might paste elsewhere
/// (container ID, kubeconfig path, socket path, export commands, etc.).
struct CopyableRow: View {
    @State private var isHovered = false

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button { copyValue() } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Copy \(label)")
            }
        }
        .padding(8)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onTapGesture { copyValue() }
        .help("Click to copy \(label.lowercased())")
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
