import AppKit
import SwiftUI

/// The Cooper inspector: chat surface, approval cards, nudges, and the
/// permission-mode picker. Only exists while `appState.isCooperVisible`.
struct CooperPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
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
                    Text("Waking Cooper…")
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
            CooperBadgeIcon()
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
            if let label = appState.cooper.remoteLabel {
                // The remote brain is active: show which model is answering.
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quinary))
                    .help("Cooper is answering via an OpenAI-compatible server (set up in Settings → Cooper)")
            }
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
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("Thinking") {
                        Text(reasoning)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let chips = message.toolActivity, !chips.isEmpty {
                    FlowChipsView(labels: chips)
                }
                Text(message.text + (message.isStreaming && message.text.isEmpty ? "▍" : ""))
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

    private func submit(cooper: CooperController) {        let text = draft
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
                Button("Open Siri & Apple Intelligence Settings") {
                    // The Apple-Intelligence-specific anchor lands on
                    // General on macOS 27; the Siri pane hosts the
                    // intelligence controls.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            // The remote-backend recovery path: any OpenAI-compatible
            // server substitutes for the on-device model.
            if CooperRemoteConfigStore.loadConfig().isConfigured == false {
                VStack(spacing: 8) {
                    Divider().padding(.horizontal, 24)
                    Text("Cooper can also run on any OpenAI-compatible model server — OpenAI, OpenRouter, Groq, a local Ollama, and more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Set Up a Remote Model…") {
                        appState.captureSettingsFrame()
                        openSettings()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { cooper.checkAvailability() }
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
            return "Cooper normally runs on Apple's on-device model. Turn on Apple Intelligence in System Settings — or point Cooper at an OpenAI-compatible model server instead."
        case .deviceNotEligible:
            return "Apple Intelligence needs an Apple Silicon Mac with Apple Intelligence support enabled in this macOS version. Alternatively, Cooper can run on any OpenAI-compatible model server."
        case .modelNotReady:
            return "Apple Intelligence has been turned on, but its model assets are still downloading. This usually takes a few minutes. You can also use a remote model server in the meantime."
        default:
            return "The on-device model isn't available right now. Everything else in Keg keeps working; check back later, or configure a remote model server."
        }
    }
}

extension Notification.Name {
    static let kegCooperFocus = Notification.Name("keg.cooperFocus")
}

/// Cooper's icon — a play on the Keg barrel logo: the same outlined barrel
/// with its `>_` prompt, given a chat tail so the keg itself is talking.
/// Pure vectors (traced from the master logo's proportions), so it stays
/// crisp at every size and in dark mode.
struct CooperBadgeIcon: View {
    var size: CGFloat = 22

    private static let rust = Color(red: 0.54, green: 0.23, blue: 0.05)
    private static let cream = Color(red: 0.97, green: 0.94, blue: 0.89)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Self.cream)
            // Speech tail (filled) under the stroked mark
            CooperTailShape()
                .fill(Self.rust)
            TalkingKegShape()
                .stroke(Self.rust, style: StrokeStyle(
                    lineWidth: max(1, size * 0.068),
                    lineCap: .round,
                    lineJoin: .round
                ))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .help("Cooper — the Keg that talks")
    }
}

/// The keg-logo barrel: bowed top edge, bulged sides, near-rim arc, and
/// the `>_` prompt. Geometry is a trace of the master logo at badge
/// proportions (y-down fractions).
struct TalkingKegShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }

        // Silhouette: bowed top, bulged sides
        path.move(to: p(0.185, 0.075))
        path.addQuadCurve(to: p(0.815, 0.075), control: p(0.50, 0.0))
        path.addQuadCurve(to: p(0.815, 0.925), control: p(1.04, 0.50))
        path.addLine(to: p(0.185, 0.925))
        path.addQuadCurve(to: p(0.185, 0.075), control: p(-0.04, 0.50))

        // Near rim of the opening (single arc, clear of the top edge)
        path.move(to: p(0.26, 0.185))
        path.addQuadCurve(to: p(0.74, 0.185), control: p(0.50, 0.30))

        // `>_` prompt
        path.move(to: p(0.30, 0.34))
        path.addLine(to: p(0.50, 0.50))
        path.addLine(to: p(0.30, 0.66))
        path.move(to: p(0.55, 0.66))
        path.addLine(to: p(0.78, 0.66))

        return path
    }
}

/// Speech tail: a rounded wedge hugging the barrel wall's lower-left.
struct CooperTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.105, y: h * 0.745))
        path.addLine(to: CGPoint(x: w * 0.225, y: h * 0.88))
        path.addLine(to: CGPoint(x: w * 0.015, y: h * 0.985))
        path.closeSubpath()
        return path
    }
}

/// A compact wrap-line of tool-activity chips: ⚙ while a tool runs, ✓ once
/// its result landed. Shows the user *what* Cooper is doing mid-turn
/// instead of a bare caret.
struct FlowChipsView: View {
    let labels: [String]

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(label.hasPrefix("✓")
                            ? Color.green.opacity(0.14)
                            : Color.accentColor.opacity(0.12))
                    )
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Minimal wrap layout — `Layout` protocol, macOS 13+, enough for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
