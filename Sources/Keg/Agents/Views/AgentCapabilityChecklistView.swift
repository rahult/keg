import SwiftUI

struct AgentCapabilityChecklistView: View {
    let checks: [AgentCapabilityCheck]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capability Checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: iconName(for: check))
                        .foregroundStyle(color(for: check.status))
                        .frame(width: 14)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(check.capability.rawValue)
                                .font(.caption.weight(.medium))
                            Text(check.status.badgeText)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(color(for: check.status).opacity(0.14))
                                .clipShape(Capsule())
                        }

                        Text(check.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let remediation = check.remediation {
                            Text(remediation)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(check.capability.rawValue). \(check.status.badgeText). \(check.summary) \(check.remediation ?? "")")
            }
        }
    }

    private func iconName(for check: AgentCapabilityCheck) -> String {
        switch check.status {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    private func color(for status: AgentCapabilityStatus) -> Color {
        switch status {
        case .ready: return .green
        case .attention: return .orange
        case .unavailable: return .red
        }
    }
}
