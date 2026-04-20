import AppKit
import SwiftUI

/// Dense 2-column key-value grid for detail panes. Each row is label + value,
/// with an optional copy icon that appears on hover. Wraps itself in a
/// titled `GroupBox` when a title is provided.
///
/// Rendered by every tab in `ContainerDetailView` and by Kubernetes/Builds
/// config sections, so tweaks here propagate everywhere.
struct SectionGrid: View {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let copyable: Bool
        let monospaced: Bool

        init(_ label: String, _ value: String, copyable: Bool = false, monospaced: Bool = true) {
            self.label = label
            self.value = value
            self.copyable = copyable
            self.monospaced = monospaced
        }
    }

    let title: String?
    let rows: [Row]

    init(_ title: String? = nil, rows: [Row]) {
        self.title = title
        self.rows = rows
    }

    var body: some View {
        if let title {
            GroupBox(title) { grid }
        } else {
            grid
        }
    }

    private var grid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    RowValue(row: row)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private struct RowValue: View {
        @State private var isHovered = false
        let row: Row

        var body: some View {
            HStack(spacing: 4) {
                Text(row.value)
                    .font(row.monospaced ? .system(.caption, design: .monospaced) : .caption)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.copyable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityLabel("Copy \(row.label)")
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
    }
}
