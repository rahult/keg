import SwiftUI

/// Error banner component that displays at the top of the view
struct ErrorBanner: View {
    let message: String
    let actionTitle: String?
    let onAction: (() -> Void)?
    let onDismiss: () -> Void

    init(
        message: String,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(3)
            
            Spacer()

            if let actionTitle, let onAction {
                Button(actionTitle) {
                    onAction()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
                .accessibilityLabel(actionTitle)
            }
            
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .padding(.horizontal)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
        .accessibilityAddTraits(.isButton)
    }
}



#Preview("Error Banner") {
    VStack {
        ErrorBanner(message: "Failed to load agents. Please try again.") {
            print("Dismissed")
        }
        
        Spacer()
        
        HStack {
            StatusBadge(status: "Active")
            StatusBadge(status: "Completed")
            StatusBadge(status: "Failed")
        }
    }
    .padding()
}
