import SwiftUI

struct CreateAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Agent) -> Void

    @State private var name = ""
    @State private var modelID = "claude-sonnet-4-6"
    @State private var description = ""
    @State private var systemPrompt = ""
    @State private var selectedSpeed: ModelSpeed = .standard

    @State private var isCreating = false
    @State private var errorMessage: String?

    private let availableModels = [
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-haiku-4-5",
        "claude-sonnet-4-5",
        "claude-opus-4-5"
    ]

    var body: some View {
        Form {
            Section("Basic Information") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)

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
        .frame(width: 450, height: 400)
        .navigationTitle("Create Agent")
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
                .disabled(name.isEmpty || isCreating)
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
                name: name,
                model: modelID,
                system: systemPrompt.isEmpty ? nil : systemPrompt,
                description: description.isEmpty ? nil : description
            )

            let agent = try await client.createAgent(params)
            onCreated(agent)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
