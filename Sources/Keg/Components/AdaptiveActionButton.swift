import SwiftUI

/// A button that shows icon + title when there is room and collapses to
/// icon-only when horizontal space is tight (e.g. a narrow inspector header).
/// The full title remains available as a tooltip and accessibility label.
struct AdaptiveActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            labelButton.labelStyle(.titleAndIcon)
            labelButton.labelStyle(.iconOnly)
        }
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var labelButton: some View {
        if prominent {
            Button(role: role, action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(role: role, action: action) {
                Label(title, systemImage: systemImage)
            }
        }
    }
}
