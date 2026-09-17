import SwiftUI

/// First-launch quick select: pick how you want to use Keg and optionally
/// jump straight into a guided first action. Shown once; replayable from
/// Settings.
struct WelcomeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    /// Called with an image reference when the user picks a quick start
    /// that should open the Run sheet prefilled.
    var onQuickRun: (String) -> Void = { _ in }

    @State private var selectedLevel: ExperienceLevel = .gettingStarted

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("Welcome to Keg")
                    .font(.title.bold())
                Text("Containers on your Mac, without the learning curve.\nEach app runs in its own isolated container — safe to try anything.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Text("How do you want to use Keg?")
                .font(.headline)
                .padding(.bottom, 10)

            VStack(spacing: 10) {
                ForEach(ExperienceLevel.allCases) { level in
                    levelCard(level)
                }
            }
            .padding(.horizontal, 24)

            if selectedLevel == .gettingStarted {
                VStack(spacing: 8) {
                    quickStartRow(
                        icon: "play.circle",
                        title: "Try a demo container",
                        detail: "hello-world — the classic 5-second test",
                        action: { finish { onQuickRun("hello-world") } }
                    )
                    quickStartRow(
                        icon: "globe",
                        title: "Run a web server",
                        detail: "nginx — open http://localhost:8080 when it's up",
                        action: { finish { onQuickRun("nginx") } }
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 12)

            HStack {
                Button("Skip for now") { finish() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            Text("You can change this anytime in Settings → Experience.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 560, height: selectedLevel == .gettingStarted ? 640 : 480)
        .onAppear { selectedLevel = appState.experienceLevel }
    }

    private func levelCard(_ level: ExperienceLevel) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                selectedLevel = level
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: level.iconName)
                    .font(.title2)
                    .foregroundStyle(selectedLevel == level ? Color.accentColor : .secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(level.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(level.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: selectedLevel == level ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedLevel == level ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selectedLevel == level ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selectedLevel == level ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level.rawValue)
        .accessibilityHint(level.summary)
    }

    private func quickStartRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func finish(after: () -> Void = {}) {
        appState.experienceLevel = selectedLevel
        after()
        dismiss()
    }
}
