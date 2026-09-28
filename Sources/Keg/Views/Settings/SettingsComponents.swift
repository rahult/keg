import SwiftUI

/// Shared layout metrics for the Settings screen. One spacing rhythm and one
/// label/control grid everywhere, so every tab reads the same way.
enum SettingsMetrics {
    /// Space between labeled groups inside a section view.
    static let groupSpacing: CGFloat = 12
    /// Vertical padding for a labeled group within its section.
    static let groupPadding: CGFloat = 4
    /// Fixed label column in `SettingsRow`.
    static let labelColumnWidth: CGFloat = 140
    /// Fixed control column in `SettingsRow`: every control starts at the
    /// same x even though the controls themselves have different natural
    /// widths. A plain HStack — Grid centers cells in their columns and
    /// stretches Steppers, which scatters the controls across the row.
    static let controlColumnWidth: CGFloat = 280
    /// Standard width for standalone pickers inside a `SettingsGroup`.
    static let pickerWidth: CGFloat = 280
    /// Inner padding of a `SettingsCard`.
    static let cardPadding: CGFloat = 10
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
/// The labeled-group idiom every VStack-based section uses.
struct SettingsGroup<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
            if let caption {
                SettingsCaption(caption)
            }
        }
        .padding(.vertical, SettingsMetrics.groupPadding)
    }
}

/// A label column plus a control column, for content inside VStack-based
/// section views. The full-width leading frame keeps the Settings form from
/// centering the fixed-width row (which offsets controls differently on
/// every row).
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: SettingsMetrics.labelColumnWidth, alignment: .leading)
            HStack(spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
            .frame(width: SettingsMetrics.controlColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Colored dot + title + detail lines + trailing action. The standard
/// status display for every Settings tab (DESIGN.md: state lives next to
/// the object it describes, as dot + text).
struct SettingsStatusCard<Detail: View, Actions: View>: View {
    /// Semantic status colors per DESIGN.md §14.
    enum State {
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

    let state: State
    let title: String
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions

    init(
        _ state: State,
        title: String,
        @ViewBuilder detail: @escaping () -> Detail,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(state.color)
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                detail()
            }
            Spacer(minLength: 12)
            actions()
        }
    }
}

extension SettingsStatusCard where Detail == EmptyView {
    init(_ state: State, title: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(state, title: title, detail: { EmptyView() }, actions: actions)
    }
}

extension SettingsStatusCard where Actions == EmptyView {
    init(_ state: State, title: String, @ViewBuilder detail: @escaping () -> Detail) {
        self.init(state, title: title, detail: detail, actions: { EmptyView() })
    }
}

extension SettingsStatusCard where Detail == EmptyView, Actions == EmptyView {
    init(_ state: State, title: String) {
        self.init(state, title: title, detail: { EmptyView() }, actions: { EmptyView() })
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

/// A subtle rounded container for grouped auxiliary content (install
/// instructions, advanced JSON editors) inside a section.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(SettingsMetrics.cardPadding)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
