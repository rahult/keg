import SwiftUI

/// Title bar at the top of every detail pane. Renders a title (optionally with
/// a trailing status badge) on the left, an optional subtitle underneath, and
/// a trailing HStack of action buttons on the right.
struct DetailHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let statusLabel: String?
    @ViewBuilder let actions: () -> Actions

    init(
        _ title: String,
        subtitle: String? = nil,
        statusLabel: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.statusLabel = statusLabel
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if let statusLabel {
                        StatusBadge(status: statusLabel)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions() }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
