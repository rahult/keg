import SwiftUI

/// Unified empty-state for list and detail panes. Wraps `ContentUnavailableView`
/// with a consistent tone and an optional primary action button so every
/// "No X" screen in Keg looks and reads the same way.
struct EmptyState: View {
    let title: String
    let description: String?
    let systemImage: String
    let action: Action?

    struct Action {
        let label: String
        let systemImage: String?
        let isDestructive: Bool
        let handler: () -> Void

        init(_ label: String, systemImage: String? = nil, isDestructive: Bool = false, handler: @escaping () -> Void) {
            self.label = label
            self.systemImage = systemImage
            self.isDestructive = isDestructive
            self.handler = handler
        }
    }

    init(_ title: String, description: String? = nil, systemImage: String, action: Action? = nil) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: description.map(Text.init)
            )

            if let action {
                Button {
                    action.handler()
                } label: {
                    if let icon = action.systemImage {
                        Label(action.label, systemImage: icon)
                    } else {
                        Text(action.label)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(action.isDestructive ? .red : .accentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}
