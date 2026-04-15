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
                principlesSection

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(AgentUseCase.all) { useCase in
                        AgentUseCaseCard(useCase: useCase) {
                            selectedUseCase = useCase
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Use Cases")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.selectedAgentSection = .agents
                } label: {
                    Label("Manage Agents", systemImage: "person.2.badge.gearshape")
                }

                Button {
                    showBlankCreateSheet = true
                } label: {
                    Label("Blank Agent", systemImage: "plus")
                }
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
    }
}

private struct AgentUseCaseCard: View {
    let useCase: AgentUseCase
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

            Spacer(minLength: 0)

            Button(action: onCreate) {
                Label("Create Agent", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(useCase.title). \(useCase.summary) Why Mac specific: \(useCase.macAdvantage)")
    }
}

#Preview {
    AgentUseCaseLibraryView()
        .environment(AppState())
}
