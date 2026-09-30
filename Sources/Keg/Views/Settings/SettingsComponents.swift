import SwiftUI

/// Shared layout metrics for the Settings screen. One spacing rhythm
/// everywhere, so every pane reads the same way.
enum SettingsMetrics {
    /// Space between labeled groups inside a section view.
    static let groupSpacing: CGFloat = 12
    /// Vertical padding for a labeled group within its section.
    static let groupPadding: CGFloat = 4
    /// Standard width for standalone menu pickers trailing a value row.
    static let pickerWidth: CGFloat = 200
    /// Inner padding of a `SettingsCard`.
    static let cardPadding: CGFloat = 10
    /// Vertical padding of a `SettingsValueRow`.
    static let rowPadding: CGFloat = 8
}

/// The one descriptive-text style in Settings. Replaces the ad-hoc mix of
/// caption/caption2 and secondary/tertiary that varied per section.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A titled group of related controls with an optional explanatory caption.
/// The labeled-group idiom every pane uses. `isDanger` tints the title red
/// for the bottom "danger zone" groups that hold destructive controls.
struct SettingsGroup<Content: View>: View {
    let title: String
    let caption: String?
    let isDanger: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: String, caption: String? = nil, isDanger: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.isDanger = isDanger
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDanger ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            content()
            if let caption {
                SettingsCaption(caption)
            }
        }
        .padding(.vertical, SettingsMetrics.groupPadding)
    }
}

/// The convergent Settings row: leading label + one-line description, control
/// trailing right, hairline separator between stacked rows. Stack rows in a
/// `VStack(spacing: 0)` inside a `SettingsCard`; pass `isLast: true` on the
/// final row. Rows outside a card use `isLast: true` as well.
struct SettingsValueRow<Control: View>: View {
    let label: String
    var description: String?
    var isLast: Bool
    @ViewBuilder var control: () -> Control

    init(
        _ label: String,
        description: String? = nil,
        isLast: Bool = false,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.label = label
        self.description = description
        self.isLast = isLast
        self.control = control
    }

    /// A row whose control fills the width (forms, editors) — no label.
    init(isLast: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.init("", description: nil, isLast: isLast, control: control)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                if !label.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.callout.weight(.medium))
                        if let description {
                            SettingsCaption(description)
                        }
                    }
                    Spacer(minLength: 16)
                }
                control()
                    .frame(maxWidth: label.isEmpty ? .infinity : nil, alignment: label.isEmpty ? .leading : .trailing)
            }
            .padding(.vertical, SettingsMetrics.rowPadding)
            if !isLast {
                Divider()
            }
        }
    }
}

/// Semantic status colors per DESIGN.md §14. File-scoped (not nested in the
/// generic card) so state properties can be annotated without fixing the
/// card's generic parameters.
enum SettingsStatusState {
    case ok
    case stopped
    case warning
    case inactive
    case info

    var color: Color {
        switch self {
        case .ok: .green
        case .stopped: .red
        case .warning: .orange
        case .inactive: .gray
        case .info: .blue
        }
    }
}

/// Colored dot + title + detail lines, with the pane's primary action in the
/// trailing header slot (DESIGN.md §18: status cards crown their pane).
struct SettingsStatusCard<Detail: View, HeaderAction: View>: View {
    typealias State = SettingsStatusState

    let state: State
    let title: String
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var headerAction: () -> HeaderAction

    init(
        _ state: State,
        title: String,
        @ViewBuilder detail: @escaping () -> Detail,
        @ViewBuilder headerAction: @escaping () -> HeaderAction
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.headerAction = headerAction
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(state.color)
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 8)
                    headerAction()
                }
                detail()
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius))
    }
}

extension SettingsStatusCard where Detail == EmptyView {
    init(_ state: State, title: String, @ViewBuilder headerAction: @escaping () -> HeaderAction) {
        self.init(state, title: title, detail: { EmptyView() }, headerAction: headerAction)
    }
}

extension SettingsStatusCard where HeaderAction == EmptyView {
    init(_ state: State, title: String, @ViewBuilder detail: @escaping () -> Detail) {
        self.init(state, title: title, detail: detail, headerAction: { EmptyView() })
    }
}

extension SettingsStatusCard where Detail == EmptyView, HeaderAction == EmptyView {
    init(_ state: State, title: String) {
        self.init(state, title: title, detail: { EmptyView() }, headerAction: { EmptyView() })
    }
}

/// A monospaced, selectable value with a one-click copy button — the
/// clipboard idiom from DESIGN.md §4. `.subtle` tints tertiary for
/// secondary lines (e.g. the `export DOCKER_HOST=…` hint).
struct SettingsCopyLine: View {
    enum Emphasis {
        case standard
        case subtle
    }

    let value: String
    var emphasis: Emphasis = .standard
    var accessibilityLabel: String = "Copy"

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(emphasis == .subtle ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(accessibilityLabel)
        }
    }
}

extension SettingsMetrics {
    /// Corner radius for `SettingsCard` and `SettingsStatusCard` surfaces
    /// (macOS 26 grouped-content convention).
    static let cardCornerRadius: CGFloat = 10
}

/// A subtle rounded container for grouped rows and auxiliary content (value
/// rows, install instructions, advanced JSON editors) inside a pane.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(SettingsMetrics.cardPadding)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius))
    }
}

// MARK: - Sidebar

/// A Settings pane in the window's grouped sidebar.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case softwareUpdate
    case about
    case appleContainers
    case docker
    case kubernetes
    case gateway
    case cooper
    case agents

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .softwareUpdate: return "Software Update"
        case .about: return "About"
        case .appleContainers: return "Apple Containers"
        case .docker: return "Docker API"
        case .kubernetes: return "Kubernetes"
        case .gateway: return "Gateway"
        case .cooper: return "Cooper"
        case .agents: return "Agents"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .softwareUpdate: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        case .appleContainers: return "shippingbox"
        case .docker: return "square.stack.3d.up"
        case .kubernetes: return "helm"
        case .gateway: return "globe"
        case .cooper: return "sparkle"
        case .agents: return "bubble.left.and.bubble.right"
        }
    }

    var sidebarGroup: SettingsSidebarGroup {
        switch self {
        case .general, .softwareUpdate, .about: return .general
        case .appleContainers, .docker, .kubernetes: return .runtime
        case .gateway, .cooper, .agents: return .features
        }
    }

    /// Panes in sidebar order; `agents` only exists when the managed-agents
    /// feature is enabled.
    static func panes(agentsEnabled: Bool) -> [SettingsPane] {
        allCases.filter { $0 != .agents || agentsEnabled }
    }
}

enum SettingsSidebarGroup: String, CaseIterable, Identifiable {
    case general = "General"
    case runtime = "Runtime"
    case features = "Features"

    var id: String { rawValue }
}

/// The grouped Settings sidebar: SF Symbol icon + label per row, an orange
/// attention badge on panes that need it (boot kernel unregistered).
struct SettingsNavList: View {
    @Binding var selection: SettingsPane
    let panes: [SettingsPane]
    var bootKernelNeedsAttention = false

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSidebarGroup.allCases) { group in
                let groupPanes = panes.filter { $0.sidebarGroup == group }
                if !groupPanes.isEmpty {
                    Section(header: Text(group.rawValue).font(.caption)) {
                        ForEach(groupPanes) { pane in
                            HStack(spacing: 6) {
                                Label(pane.label, systemImage: pane.icon)
                                if pane == .appleContainers && bootKernelNeedsAttention {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                        .help("Boot kernel needs attention")
                                }
                            }
                            .tag(pane)
                        }
                    }
                }
            }
        }
    }
}
