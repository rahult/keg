import SwiftUI

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LaunchDiagnostics.mark("MenuBarPopover.body")
        return VStack(alignment: .leading, spacing: 12) {
            headerSection

            Divider()

            quickActionsSection

            if appState.isSystemRunning {
                Divider()
                runningContainersSection
            }

            Divider()

            agentStatusSection

            Divider()

            approvalsSection
        }
        .padding(12)
        .frame(width: 340)
        .task {
            await appState.checkSystemStatus()
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            statusCircle

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                Text(approvalSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !appState.pendingAgentApprovals.isEmpty {
                ApprovalCountBadge(count: appState.pendingAgentApprovals.count)
            }
        }
    }

    private var quickActionsSection: some View {
        HStack(spacing: 8) {
            if appState.isSystemRunning {
                Button("Stop") {
                    Task { await appState.stopSystem() }
                }
                .controlSize(.small)
            } else {
                Button("Start") {
                    Task { await appState.startSystem() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            Button("Open Keg") {
                openWindow(id: "main")
            }
            .controlSize(.small)

            Button("Settings") {
                appState.openSettings()
            }
            .controlSize(.small)
        }
    }

    private var statusCircle: some View {
        Circle()
            .fill(appState.isSystemRunning ? Color.green : Color.red)
            .frame(width: 10, height: 10)
    }

    private var statusText: String {
        switch appState.systemStatus {
        case .running:
            return "Container System Running"
        case .stopped:
            return "Container System Stopped"
        case .error(let msg):
            return msg
        }
    }

    private var approvalSummaryText: String {
        let pending = appState.pendingAgentApprovals.count
        if pending == 0 {
            return "No pending approval items"
        }
        return pending == 1 ? "1 pending approval item" : "\(pending) pending approval items"
    }

    private var runningContainersSection: some View {
        Group {
            Text("Quick Access")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "terminal")
                        .frame(width: 16)
                    Text("Terminal")
                        .font(.caption)
                    Spacer()
                }
                HStack {
                    Image(systemName: "cube.box")
                        .frame(width: 16)
                    Text("Containers")
                        .font(.caption)
                    Spacer()
                }
            }
        }
    }

    private var agentStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agents")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if appState.isAgentAuthenticated {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.badge.gearshape")
                            .font(.caption)
                            .foregroundStyle(.purple)
                        Text("Active Agents")
                            .font(.caption)
                        Spacer()
                        Text("\(appState.activeAgentCount)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Running Sessions")
                        .font(.caption)
                    Spacer()
                    Text("\(appState.activeSessionCount)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Not configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Settings") {
                        appState.openSettings()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                }
            }
        }
    }

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval Inbox")
                        .font(.subheadline.weight(.semibold))
                    Text("Review risky agent actions before they touch files or apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if resolvedApprovalCount > 0 {
                    Button("Clear Resolved") {
                        appState.clearResolvedAgentApprovals()
                    }
                    .controlSize(.small)
                }
            }

            if appState.pendingAgentApprovals.isEmpty {
                ContentUnavailableView {
                    Label("No Pending Approvals", systemImage: "checkmark.shield")
                } description: {
                    Text("Queued reviews will appear here for quick menu bar triage.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.pendingAgentApprovals.prefix(3)) { item in
                        AgentApprovalRow(item: item) {
                            appState.approveAgentApproval(item.id)
                        } onReject: {
                            appState.rejectAgentApproval(item.id)
                        }
                    }
                }
            }

            if resolvedApprovalCount > 0 {
                HStack(spacing: 8) {
                    ApprovalStatusPill(title: "Approved", count: approvedCount, tint: .green)
                    ApprovalStatusPill(title: "Rejected", count: rejectedCount, tint: .red)
                }
            }
        }
    }

    private var approvedCount: Int {
        appState.agentApprovalItems.filter { $0.status == .approved }.count
    }

    private var rejectedCount: Int {
        appState.agentApprovalItems.filter { $0.status == .rejected }.count
    }

    private var resolvedApprovalCount: Int {
        approvedCount + rejectedCount
    }
}

private struct AgentApprovalRow: View {
    let item: AgentApprovalItem
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                    Text(item.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(item.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(item.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Reject", role: .destructive, action: onReject)
                    .controlSize(.small)

                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). Source \(item.source). \(item.summary)")
    }
}

private struct ApprovalCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor)
            .clipShape(Capsule())
            .accessibilityLabel("\(count) pending approvals")
    }
}

private struct ApprovalStatusPill: View {
    let title: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text("\(title) \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}
