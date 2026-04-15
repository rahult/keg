import SwiftUI

struct CreateAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Agent) -> Void

    @State private var selectedUseCaseID: String
    @State private var name: String
    @State private var modelID: String
    @State private var description: String
    @State private var systemPrompt: String
    @State private var selectedSpeed: ModelSpeed = .standard
    @State private var templateMetadata: [String: String]?

    @State private var isCreating = false
    @State private var errorMessage: String?

    private let availableModels = [
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-haiku-4-5",
        "claude-sonnet-4-5",
        "claude-opus-4-5"
    ]

    init(initialUseCase: AgentUseCase? = nil, onCreated: @escaping (Agent) -> Void) {
        self.onCreated = onCreated

        let draft = initialUseCase?.draft ?? AgentUseCase.blankDraft
        _selectedUseCaseID = State(initialValue: initialUseCase?.id ?? "")
        _name = State(initialValue: draft.name)
        _modelID = State(initialValue: draft.modelID)
        _description = State(initialValue: draft.description)
        _systemPrompt = State(initialValue: draft.systemPrompt)
        _templateMetadata = State(initialValue: draft.metadata)
    }

    private var validation: AgentFormValidation {
        AgentFormValidation(name: name)
    }

    private var selectedUseCase: AgentUseCase? {
        AgentUseCase.byID(selectedUseCaseID.isEmpty ? nil : selectedUseCaseID)
    }

    var body: some View {
        Form {
            Section("Starting Point") {
                Picker("Use Case", selection: $selectedUseCaseID) {
                    Text("Blank Agent")
                        .tag("")

                    ForEach(AgentUseCase.all) { useCase in
                        Text(useCase.title)
                            .tag(useCase.id)
                    }
                }

                if let useCase = selectedUseCase {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(useCase.summary)
                            .font(.subheadline)

                        Label(useCase.macAdvantage, systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Surfaces: \(useCase.surfaces.map(\.rawValue).joined(separator: " • "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Example asks")
                            .font(.caption.weight(.semibold))
                        ForEach(useCase.samplePrompts, id: \.self) { prompt in
                            Text("• \(prompt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Selected use case \(useCase.title). \(useCase.summary) \(useCase.macAdvantage)")
                } else {
                    Text("Start from scratch, or pick a Mac-native use case to prefill name, description, and system prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Basic Information") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                if let message = validation.nameMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                TextField("Description (optional)", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Model") {
                Picker("Model", selection: $modelID) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                Picker("Speed", selection: $selectedSpeed) {
                    Text("Standard").tag(ModelSpeed.standard)
                    Text("Fast").tag(ModelSpeed.fast)
                }
            }

            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
            }

            Section {
                Text("Additional configuration (tools, skills, MCP servers) can be added after creation via the agent detail view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .navigationTitle("Create Agent")
        .onChange(of: selectedUseCaseID) { _, newValue in
            apply(useCase: AgentUseCase.byID(newValue.isEmpty ? nil : newValue))
        }
        .accessibilityLabel("Create new agent sheet")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isCreating)
                .keyboardShortcut(.escape)
                .accessibilityLabel("Cancel and close")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    Task { await createAgent() }
                }
                .disabled(!validation.isValid || isCreating)
                .keyboardShortcut(.return)
                .accessibilityLabel("Create new agent")
            }
        }
        .overlay {
            if isCreating {
                ZStack {
                    Color.black.opacity(0.3)
                    ProgressView("Creating agent...")
                        .padding()
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            if let error = errorMessage {
                ErrorBanner(message: error) {
                    errorMessage = nil
                }
            }
        }
    }

    @MainActor
    private func createAgent() async {
        isCreating = true
        defer { isCreating = false }

        do {
            let client = try await ManagedAgentsClient.fromKeychain()

            let params = CreateAgentParams(
                name: validation.trimmedName,
                model: modelID,
                system: systemPrompt.isEmpty ? nil : systemPrompt,
                description: description.isEmpty ? nil : description,
                metadata: templateMetadata
            )

            let agent = try await client.createAgent(params)
            onCreated(agent)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(useCase: AgentUseCase?) {
        let draft = useCase?.draft ?? AgentUseCase.blankDraft
        name = draft.name
        modelID = draft.modelID
        description = draft.description
        systemPrompt = draft.systemPrompt
        templateMetadata = draft.metadata
        selectedSpeed = .standard
    }
}
