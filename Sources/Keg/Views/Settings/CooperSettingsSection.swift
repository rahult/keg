import SwiftUI

/// Cooper's settings: how much agency the on-device agent has, plus
/// conversation maintenance. Cooper runs entirely on-device via Apple's
/// FoundationModels — no cloud calls — so there is nothing to configure
/// about connectivity; the meaningful choice is the permission gate.
struct CooperSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var clearedNotice = false
    @State private var isClearing = false

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 14) {
            group("Permission mode", caption: permissionCaption(for: appState.agentPermissionMode)) {
                Picker("", selection: $appState.agentPermissionMode) {
                    ForEach(AgentPermissionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            group("Conversation") {
                HStack(spacing: 10) {
                    Button {
                        isClearing = true
                        Task {
                            await appState.cooper.clearConversation()
                            isClearing = false
                            clearedNotice = true
                            try? await Task.sleep(for: .seconds(3))
                            clearedNotice = false
                        }
                    } label: {
                        if isClearing { ProgressView().controlSize(.small) }
                        Text("Clear Conversation")
                    }
                    .disabled(isClearing)
                }
                Text("Erases the on-device transcript (~/.keg/cooper). Cooper starts a fresh conversation; nothing else is affected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("Cooper runs entirely on-device via Apple's FoundationModels — requests never leave this Mac. Destructive actions always ask, in every mode.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func permissionCaption(for mode: AgentPermissionMode) -> String {
        switch mode {
        case .explore:
            "Cooper can look around and answer questions, but never changes anything."
        case .ask:
            "Cooper proposes actions and asks before every change."
        case .execute:
            "Cooper applies routine actions on its own; destructive actions still ask."
        }
    }

    private func group(_ name: String, caption: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            content()
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
