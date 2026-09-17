import SwiftUI

/// First-launch quick select: pick how you want to use Keg, see exactly
/// what the sidebar will look like, and optionally jump straight into a
/// guided first action. Shown once; replayable from Settings.
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
            .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How do you want to use Keg?")
                        .font(.headline)
                    ForEach(ExperienceLevel.allCases) { level in
                        levelCard(level)
                    }
                }
                .frame(width: 330)

                sidebarPreview
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

            Text("You can change this anytime — the switch lives at the bottom of the sidebar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 660, height: selectedLevel == .gettingStarted ? 660 : 580)
        .onAppear { selectedLevel = appState.experienceLevel }
    }

    // MARK: - Level cards

    private func levelCard(_ level: ExperienceLevel) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                selectedLevel = level
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: level.iconName)
                    .font(.title3)
                    .foregroundStyle(selectedLevel == level ? Color.accentColor : .secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(level.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(level.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: selectedLevel == level ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedLevel == level ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
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

    // MARK: - Live sidebar preview

    /// Shows the actual sidebar the chosen level produces, using the same
    /// structure the app renders — the preview can't drift from reality.
    private var sidebarPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your sidebar")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(KegSidebarStructure.sections(for: selectedLevel)) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.name.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            ForEach(section.items) { item in
                                Label(item.rawValue, systemImage: item.iconName)
                                    .font(.callout)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("APP".uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Label("Settings", systemImage: "gearshape")
                            .font(.callout)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .frame(height: 280)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar preview for \(selectedLevel.rawValue)")
        }
        .frame(width: 250)
        .animation(.snappy(duration: 0.2), value: selectedLevel)
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
