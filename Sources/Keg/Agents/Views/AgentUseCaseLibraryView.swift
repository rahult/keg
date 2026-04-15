import SwiftUI

struct AgentUseCaseLibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedUseCase: AgentUseCase?
    @State private var showBlankCreateSheet = false

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                liveContextBar
                principlesSection

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(AgentUseCase.all) { useCase in
                        AgentUseCaseCard(
                            useCase: useCase,
                            checks: useCase.capabilityChecks(using: appState.agentAutomationState),
                            isRefreshingContext: appState.isRefreshingAgentAutomation,
                            pendingReviewCount: appState.pendingAgentApprovals.filter { $0.useCaseID == useCase.id }.count,
                            onRefreshContext: {
                                Task { await appState.refreshAgentAutomation() }
                            },
                            onRequestNotifications: {
                                Task { await appState.requestAgentNotificationAccess() }
                            },
                            onQueueReview: {
                                Task { await appState.queueApprovalPreview(for: useCase) }
                            },
                            onCreate: {
                                selectedUseCase = useCase
                            }
                        )
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Agent use case templates")
                .accessibilityValue("\(AgentUseCase.all.count) templates")
            }
            .padding(20)
        }
        .navigationTitle("Use Cases")
        .onExitCommand {
            if selectedUseCase != nil {
                selectedUseCase = nil
                return
            }

            if showBlankCreateSheet {
                showBlankCreateSheet = false
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.selectedAgentSection = .agents
                } label: {
                    Label("Manage Agents", systemImage: "person.2.badge.gearshape")
                }
                .accessibilityHint("Open the full agents list")

                Button {
                    showBlankCreateSheet = true
                } label: {
                    Label("Blank Agent", systemImage: "plus")
                }
                .accessibilityHint("Create a new agent without using a template")
            }
        }
        .sheet(item: $selectedUseCase) { useCase in
            CreateAgentSheet(initialUseCase: useCase) { _ in
                appState.selectedAgentSection = .agents
            }
        }
        .sheet(isPresented: $showBlankCreateSheet) {
            CreateAgentSheet { _ in
                appState.selectedAgentSection = .agents
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac-native agent starting points")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Start from concrete workflows instead of generic chat. These use cases prioritize active-app context, Finder handoff, notifications, and reviewable actions inspired by products like Sky.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac-native agent starting points. Start from concrete workflows instead of generic chat.")
    }

    private var liveContextBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Mac context")
                        .font(.headline)
                    Text(contextSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if appState.isRefreshingAgentAutomation {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await appState.refreshAgentAutomation() }
                } label: {
                    Label("Refresh Context", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                if appState.agentAutomationState.notificationStatus == .unknown || appState.agentAutomationState.notificationStatus == .notDetermined {
                    Button {
                        Task { await appState.requestAgentNotificationAccess() }
                    } label: {
                        Label("Request Notifications", systemImage: "bell.badge")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if !appState.pendingAgentApprovals.isEmpty {
                Text("\(appState.pendingAgentApprovals.count) review item(s) queued for approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var contextSummary: String {
        let context = appState.agentAutomationState.context
        let activeApp = context.activeAppName ?? "No active app"
        let files = context.selectedFileCount == 0 ? "no Finder items" : "\(context.selectedFileCount) Finder item(s)"
        let terminal = context.hasTerminalSnapshot ? "terminal ready" : "no terminal snapshot"
        return "\(activeApp) • \(files) • \(terminal) • \(appState.agentAutomationState.notificationStatus.summary)"
    }

    private var principlesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Implementation lens")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Label("Lead with explicit entry points like Finder, Shortcuts, menu bar, and the active app.", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                Label("Keep risky work reviewable with drafts, notifications, and approval queues.", systemImage: "checkmark.shield")
                Label("Use templates to seed strong agent prompts now, then layer deeper macOS automation behind them.", systemImage: "wand.and.stars")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Implementation lens. Lead with explicit entry points, keep risky work reviewable, and use templates to seed strong agent prompts.")
    }
}

private struct AgentUseCaseCard: View {
    let useCase: AgentUseCase
    let checks: [AgentCapabilityCheck]
    let isRefreshingContext: Bool
    let pendingReviewCount: Int
    let onRefreshContext: () -> Void
    let onRequestNotifications: () -> Void
    let onQueueReview: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(useCase.title)
                        .font(.headline)
                    Text(useCase.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: useCase.surfaces.first?.iconName ?? "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Why Mac-specific")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(useCase.macAdvantage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Surfaces")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(useCase.surfaces.map(\.rawValue).joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AgentCapabilityChecklistView(checks: checks)

            VStack(alignment: .leading, spacing: 6) {
                Text("Example asks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(useCase.samplePrompts, id: \.self) { prompt in
                    Text("• \(prompt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: onRefreshContext) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingContext)

                if checks.contains(where: { $0.capability == .notifications && $0.status != .ready }) {
                    Button(action: onRequestNotifications) {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if pendingReviewCount > 0 {
                    Text("\(pendingReviewCount) queued")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 8) {
                Button(action: onQueueReview) {
                    Label("Queue Review", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Queue review for \(useCase.title)")

                Button(action: onCreate) {
                    Label("Create Agent", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Create \(useCase.title) agent")
                .accessibilityHint("Opens the create agent sheet with this use case prefilled")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(useCase.title) template")
        .accessibilityHint(useCase.summary)
    }
}

#Preview {
    AgentUseCaseLibraryView()
        .environment(AppState())
}
