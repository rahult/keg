import SwiftUI

struct AgentLiveContextPanel: View {
    let automation: AgentAutomationState
    let pendingApprovalCount: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onRequestNotifications: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)
            ], spacing: 12) {
                AgentLiveContextTile(
                    title: "Active App",
                    iconName: AgentAutomationCapability.activeApp.iconName,
                    value: automation.context.activeAppName ?? "Not captured",
                    detail: automation.context.activeAppName == nil ? "Bring an app forward, then refresh context." : "Foreground app available for app-aware agent flows.",
                    tone: automation.context.activeAppName == nil ? .secondary : .accent
                )

                AgentLiveContextTile(
                    title: "Finder Selection",
                    iconName: AgentAutomationCapability.finderSelection.iconName,
                    value: finderValue,
                    detail: finderDetail,
                    tone: automation.context.selectedFileCount == 0 ? .secondary : .accent
                )

                AgentLiveContextTile(
                    title: "Terminal Snapshot",
                    iconName: AgentAutomationCapability.terminalSnapshot.iconName,
                    value: terminalValue,
                    detail: terminalDetail,
                    tone: automation.context.hasTerminalSnapshot ? .accent : .secondary
                )

                AgentLiveContextTile(
                    title: "Page Context",
                    iconName: AgentAutomationCapability.pageContext.iconName,
                    value: pageValue,
                    detail: pageDetail,
                    tone: automation.context.hasPageContext ? .accent : .secondary
                )
            }

            footer
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live macOS context panel")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Live Mac Context")
                    .font(.headline)
                Text("What agents can see from the current desktop right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh Context", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint("Capture the latest active app, Finder, terminal, and page context")
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: AgentAutomationCapability.notifications.iconName)
                    .foregroundStyle(notificationTone.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                        .font(.caption.weight(.semibold))
                    Text(automation.notificationStatus.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onRequestNotifications {
                    Button("Enable") {
                        onRequestNotifications()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if pendingApprovalCount > 0 {
                Label {
                    Text("\(pendingApprovalCount) pending approval \(pendingApprovalCount == 1 ? "item" : "items") queued for review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(lastCapturedText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var finderValue: String {
        automation.context.selectedFileCount == 0 ? "No selection" : "\(automation.context.selectedFileCount) item\(automation.context.selectedFileCount == 1 ? "" : "s")"
    }

    private var finderDetail: String {
        if automation.context.selectedFiles.isEmpty {
            return "Select files in Finder for file-aware use cases."
        }
        return automation.context.selectedFiles.prefix(2).joined(separator: " • ")
    }

    private var terminalValue: String {
        automation.context.terminalAppName ?? "No terminal app"
    }

    private var terminalDetail: String {
        guard let snapshot = automation.context.terminalSnapshot, !snapshot.isEmpty else {
            return "No recent shell transcript captured."
        }
        return trimmedPreview(snapshot)
    }

    private var pageValue: String {
        automation.context.pageTitle ?? automation.context.pageURL ?? "No page context"
    }

    private var pageDetail: String {
        if let selectedText = automation.context.selectedText, !selectedText.isEmpty {
            return trimmedPreview(selectedText)
        }
        if let url = automation.context.pageURL, !url.isEmpty {
            return url
        }
        return "Bring Safari or another browser forward to capture page-aware context."
    }

    private func trimmedPreview(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let prefix = String(normalized.prefix(100))
        return normalized.count > 100 ? prefix + "…" : prefix
    }

    private var lastCapturedText: String {
        "Last captured \(automation.context.capturedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var notificationTone: TileTone {
        switch automation.notificationStatus {
        case .authorized, .provisional:
            return .accent
        case .denied:
            return .warning
        case .unknown, .notDetermined:
            return .secondary
        }
    }
}

private struct AgentLiveContextTile: View {
    let title: String
    let iconName: String
    let value: String
    let detail: String
    let tone: TileTone

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tone.color)
                Spacer()
            }

            Text(value)
                .font(.headline)
                .lineLimit(2)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(tone.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private enum TileTone {
    case accent
    case secondary
    case warning

    var color: Color {
        switch self {
        case .accent: return .accentColor
        case .secondary: return .secondary
        case .warning: return .orange
        }
    }

    var background: Color {
        switch self {
        case .accent: return Color.accentColor.opacity(0.08)
        case .secondary: return Color(nsColor: .windowBackgroundColor)
        case .warning: return Color.orange.opacity(0.1)
        }
    }
}
