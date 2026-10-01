import SwiftUI
import KegCLICore

/// "New Session…": create and launch a local agent session from the Agents
/// section inbox. The form state lives in `AgentSessionDraft` (validated,
/// unit-tested); this view only renders it and calls `AgentService`.
///
/// The turn is launched, not awaited: the sheet dismisses as soon as the
/// session exists so approval cards (Cooper panel) and the streaming detail
/// view stay reachable — a modal sheet must never gate the permission gate.
struct NewAgentSessionSheet: View {
    /// Called after the session is created and its first turn is running.
    let onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AgentSessionDraft()
    @State private var stack: KegProjectScaffold.Stack = .generic
    @State private var errorMessage: String?
    @State private var isStarting = false
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 680)
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            adopt(folder: url)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session")
                    .font(.headline)
                Text("Run an agent on a repo, in its own containers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                repositorySection
                environmentSection
                kegYAMLSection
                brainSection
                instructionSection
            }
            .padding(20)
        }
    }

    private var repositorySection: some View {
        GroupBox("Repository") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source", selection: $draft.repoMode) {
                    ForEach(AgentSessionRepoMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch draft.repoMode {
                case .localFolder:
                    HStack(spacing: 8) {
                        TextField("Folder path", text: $draft.localPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Choose…") {
                            isChoosingFolder = true
                        }
                    }
                case .gitURL:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://github.com/owner/repo.git", text: $draft.gitURL)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            Text("Branch")
                            TextField("main", text: $draft.branch)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var environmentSection: some View {
        GroupBox("Environment") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($draft.env) { $entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            TextField("NAME", text: $entry.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 180)
                            TextField("value", text: $entry.value)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                draft.env.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove variable")
                        }
                        if let problem = AgentSessionDraft.envKeyProblem(entry.key) {
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Button {
                    draft.env.append(AgentSessionEnvEntry())
                } label: {
                    Label("Add variable", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)

                Text("Variables travel with the session's world recipe — never add secrets.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    private var kegYAMLSection: some View {
        GroupBox("keg.yaml") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Scaffold", selection: $stack) {
                        ForEach(KegProjectScaffold.Stack.allCases, id: \.rawValue) { stack in
                            Text(stack.rawValue).tag(stack)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
                TextEditor(text: $draft.kegYAML)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 150)
                    .border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("keg.yaml contents")
            }
            .padding(.top, 4)
        }
        .onChange(of: stack) { _, newStack in
            draft.kegYAML = draft.scaffoldedYAML(newStack)
        }
    }

    private var brainSection: some View {
        GroupBox("Brain") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Brain", selection: $draft.brain) {
                    ForEach(AgentSessionBrainChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(draft.brain.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var instructionSection: some View {
        GroupBox("First instruction") {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $draft.instruction)
                    .font(.body)
                    .frame(minHeight: 60)
                    .border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("First instruction (optional)")
                Text("Optional — when empty, the agent starts by getting oriented in the workspace.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isStarting)

            Spacer()

            Button {
                Task { await start() }
            } label: {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Start Session")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canStart || isStarting)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func adopt(folder: URL) {
        draft.localPath = folder.path
        // Prefer the repo's own keg.yaml; otherwise scaffold from detection.
        let existing = folder.appendingPathComponent(KegProjectConfig.fileName)
        if FileManager.default.fileExists(atPath: existing.path),
           let text = try? String(contentsOf: existing, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.kegYAML = text
        } else {
            let detected = KegProjectScaffold.detect(directory: folder)
            stack = detected
            draft.kegYAML = draft.scaffoldedYAML(detected)
        }
    }

    private func start() async {
        isStarting = true
        errorMessage = nil
        do {
            let recipe = try draft.makeRecipe()
            let service = appState.agentService
            let session = try await service.createSession(
                id: Self.newSessionID(),
                agentId: "keg-local",
                environmentId: "local",
                type: "agent"
            )
            let prompt = draft.makePrompt()
            let brain = draft.brain.resolved
            // Launch, don't await: the turn can run for minutes and needs
            // the Cooper panel (approvals) and the detail view (streaming)
            // reachable. Failures land on the session's status.
            Task { try? await service.runTurn(sessionId: session.id, recipe: recipe, prompt: prompt, brain: brain) }
            onCreated()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isStarting = false
        }
    }

    private static func newSessionID() -> String {
        "session-\(UUID().uuidString.prefix(12).lowercased())"
    }
}
