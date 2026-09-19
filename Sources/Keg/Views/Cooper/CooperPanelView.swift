import AppKit
import SwiftUI

/// The Cooper inspector: chat surface, approval cards, nudges, and the
/// permission-mode picker. Only exists while `appState.isCooperVisible`.
struct CooperPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        let cooper = appState.cooper

        VStack(spacing: 0) {
            header(cooper: cooper)
            Divider()

            switch cooper.availability {
            case .ready:
                conversation(cooper: cooper)
            case .checking:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking Apple Intelligence…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                unavailable(cooper: cooper)
            }
        }
        .task { await cooper.prepare() }
        .onReceive(NotificationCenter.default.publisher(for: .kegCooperFocus)) { _ in
            inputFocused = true
        }
    }

    // MARK: - Header

    private func header(cooper: CooperController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .foregroundStyle(.tint)
            Text("Cooper")
                .font(.headline)
            availabilityBadge(cooper.availability)
            Spacer()
            Picker("Permission", selection: Binding(
                get: { appState.agentPermissionMode },
                set: { appState.agentPermissionMode = $0 }
            )) {
                Text("Explore").tag(AgentPermissionMode.explore)
                Text("Ask").tag(AgentPermissionMode.ask)
                Text("Execute").tag(AgentPermissionMode.execute)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help("Explore is read-only, Ask confirms every change, Execute acts on request without asking.")
            if !cooper.messages.isEmpty {
                Button {
                    cooper.clearConversation()
                } label: {
                    Image(systemName: "eraser")
                }
                .buttonStyle(.borderless)
                .help("Clear the conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func availabilityBadge(_ availability: CooperAvailability) -> some View {
        switch availability {
        case .ready:
            EmptyView()
        case .checking:
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .modelNotReady:
            Label("Loading model", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
        }
    }

    // MARK: - Conversation

    private func conversation(cooper: CooperController) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(cooper.messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: cooper.messages.count) { _, _ in
                    scrollToEnd(proxy)
                }
                .onChange(of: cooper.messages.last?.text) { _, _ in
                    scrollToEnd(proxy)
                }
            }

            ForEach(cooper.pendingApprovals) { request in
                approvalCard(request)
            }
            .padding(.horizontal, 12)

            ForEach(cooper.nudges) { nudge in
                nudgeCard(nudge)
            }
            .padding(.horizontal, 12)

            Divider()
            input(cooper: cooper)
        }
    }

    @ViewBuilder
    private func bubble(_ message: CooperController.Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 32)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 0) {
                Text(message.text + (message.isStreaming ? " ▍" : ""))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .info:
            Text(message.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = appState.cooper.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Approval & nudge cards

    private func approvalCard(_ request: CooperApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cooper wants to act", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            Text(request.summary)
                .font(.callout)
            if !request.details.isEmpty {
                Text(request.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Allow") { appState.cooper.approve(request.id) }
                    .keyboardShortcut(.defaultAction)
                Button("Deny", role: .destructive) { appState.cooper.deny(request.id) }
                Spacer()
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
    }

    private func nudgeCard(_ nudge: CooperController.Nudge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(nudge.headline, systemImage: "lightbulb")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    appState.cooper.dismissNudge(nudge.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            Text(nudge.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Ask Cooper") {
                appState.cooper.act(on: nudge)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
    }

    // MARK: - Input

    private func input(cooper: CooperController) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 38, maxHeight: 110)
                .focused($inputFocused)
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift) { return .ignored }
                    submit(cooper: cooper)
                    return .handled
                }
            if cooper.isStreaming {
                Button {
                    cooper.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop Cooper")
            } else {
                Button {
                    submit(cooper: cooper)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
                .help("Send (⏎)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func submit(cooper: CooperController) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        cooper.send(text)
        inputFocused = true
    }

    // MARK: - Unavailable states

    private func unavailable(cooper: CooperController) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(unavailableTitle(cooper.availability))
                .font(.headline)
            Text(unavailableDetail(cooper.availability))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            if case .appleIntelligenceOff = cooper.availability {
                Button("Open Apple Intelligence Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIntelligenceSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableTitle(_ availability: CooperAvailability) -> String {
        switch availability {
        case .appleIntelligenceOff:
            return "Apple Intelligence is off"
        case .deviceNotEligible:
            return "This Mac can't run Cooper"
        case .modelNotReady:
            return "The on-device model is still downloading"
        default:
            return "Cooper isn't available right now"
        }
    }

    private func unavailableDetail(_ availability: CooperAvailability) -> String {
        switch availability {
        case .appleIntelligenceOff:
            return "Cooper runs entirely on Apple's on-device model. Turn on Apple Intelligence in System Settings to chat."
        case .deviceNotEligible:
            return "Apple Intelligence (and therefore Cooper) needs an Apple Silicon Mac with Apple Intelligence support enabled in this macOS version."
        case .modelNotReady:
            return "Apple Intelligence has been turned on, but its model assets are still downloading. This usually takes a few minutes."
        default:
            return "The on-device model isn't available right now. Everything else in Keg keeps working; check back later."
        }
    }
}

extension Notification.Name {
    static let kegCooperFocus = Notification.Name("keg.cooperFocus")
}
