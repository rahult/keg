import SwiftUI

/// Consistent bottom-of-view error banner. Every detail view that tracks a
/// `var errorMessage: String?` can attach this to get the same pill shape,
/// copy, and dismiss behavior.
///
/// Usage:
///     ScrollView { ... }
///         .errorBanner($vm.errorMessage)
extension View {
    func errorBanner(_ message: Binding<String?>) -> some View {
        modifier(ErrorBannerModifier(message: message))
    }
}

private struct ErrorBannerModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text = message {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 8)
                    Button("Dismiss") { message = nil }
                        .controlSize(.small)
                }
                .padding(10)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .padding(12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: message)
    }
}
