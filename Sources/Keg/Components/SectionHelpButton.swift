import SwiftUI

/// Toolbar button that opens a help popover for the current section.
///
/// Copy adapts to the chosen experience level: Getting Started users get the
/// plain-language explanation first; Full Control users get the technical
/// description without the tutorial framing.
struct SectionHelpButton: View {
    let content: SectionHelpContent
    @State private var isShowingHelp = false

    init(section: KegSection) {
        self.content = SectionHelpGuide.content(for: section)
    }

    init(section: AgentSection) {
        self.content = SectionHelpGuide.content(for: section)
    }

    var body: some View {
        Button {
            isShowingHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .help("What is this?")
        .accessibilityLabel("Section help")
        .accessibilityHint("Explain what this screen is for")
        .popover(isPresented: $isShowingHelp, arrowEdge: .top) {
            SectionHelpPopover(content: content)
                .frame(width: 360)
        }
    }
}

struct SectionHelpPopover: View {
    @Environment(AppState.self) private var appState
    let content: SectionHelpContent

    private var beginnerFirst: Bool {
        appState.experienceLevel != .fullControl
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("About \(content.title)")
                    .font(.headline)

                if beginnerFirst {
                    Label {
                        Text(content.beginner)
                    } icon: {
                        Image(systemName: "text.book.closed")
                            .foregroundStyle(.secondary)
                    }
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                    if !content.firstSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Try this")
                                .font(.subheadline.weight(.semibold))
                            ForEach(Array(content.firstSteps.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "checkmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    Text(step)
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    if beginnerFirst {
                        Text("In technical terms")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(content.technical)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let tip = content.tip {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.orange)
                        Text(tip)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
    }
}
