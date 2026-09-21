import FoundationModels
import SwiftUI

/// Cooper's settings: which brain to use, the remote model's connectivity
/// (any OpenAI-compatible server), how much thinking to request, and the
/// permission gate. The on-device path needs no connectivity setup; the
/// remote path exists so Cooper still works when Apple Intelligence is
/// off or this Mac isn't eligible.
struct CooperSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var clearedNotice = false
    @State private var isClearing = false

    // Remote configuration (debounced save to UserDefaults + Keychain).
    @State private var preference: CooperBackendPreference = .auto
    @State private var config = CooperRemoteConfig()
    @State private var apiKey = ""
    @State private var selectedPresetID = "custom"
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 14) {
            group("Model backend", caption: backendCaption) {
                Picker("", selection: $preference) {
                    ForEach(CooperBackendPreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 340)
                .onChange(of: preference) { _, newValue in
                    CooperRemoteConfigStore.savePreference(newValue)
                    scheduleSave()
                }
            }

            if preference != .onDevice {
                remoteModelGroup
            }

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
                Text("Erases the Cooper transcript (~/.keg/cooper), for whichever backend is active. Cooper starts a fresh conversation; nothing else is affected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            privacyFooter
        }
        .padding(.vertical, 4)
        .task {
            preference = CooperRemoteConfigStore.loadPreference()
            config = CooperRemoteConfigStore.loadConfig()
            apiKey = CooperKeychain.loadAPIKey()
            selectedPresetID = CooperProviderPreset.all.first { $0.baseURL == config.baseURL }?.id ?? "custom"
        }
    }

    // MARK: - Remote model group

    private var remoteModelGroup: some View {
        group("Remote model", caption: remoteCaption) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider", selection: $selectedPresetID) {
                    ForEach(CooperProviderPreset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .frame(width: 280)
                .onChange(of: selectedPresetID) { _, newID in
                    if let preset = CooperProviderPreset.all.first(where: { $0.id == newID }) {
                        config.baseURL = preset.baseURL
                        fetchedModels = []
                        scheduleSave()
                    }
                }

                LabeledContent("Server URL") {
                    TextField("https://api.openai.com/v1", text: $config.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .onChange(of: config.baseURL) { _, _ in scheduleSave() }
                }

                LabeledContent("Model") {
                    HStack(spacing: 8) {
                        TextField(modelPlaceholder, text: $config.model)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onChange(of: config.model) { _, _ in scheduleSave() }
                        Button {
                            fetchModels()
                        } label: {
                            if isFetchingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("List")
                            }
                        }
                        .disabled(isFetchingModels || !CooperRemoteConfig.isValidBaseURL(config.baseURL))
                        .help("Ask the server for its available models")
                    }
                }

                if !fetchedModels.isEmpty {
                    LabeledContent("Available") {
                        Picker("", selection: Binding(
                            get: { config.model },
                            set: { config.model = $0; scheduleSave() }
                        )) {
                            ForEach(fetchedModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .frame(width: 280)
                        .labelsHidden()
                    }
                }
                if let fetchError {
                    Text(fetchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                LabeledContent("API key") {
                    SecureField(preset?.needsKey == false ? "not needed for local servers" : "sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .onChange(of: apiKey) { _, _ in scheduleSave() }
                }

                LabeledContent("Thinking") {
                    Picker("", selection: $config.thinking) {
                        ForEach(CooperThinkingPreference.allCases) { thinking in
                            Text(thinking.label).tag(thinking)
                        }
                    }
                    .frame(width: 280)
                    .labelsHidden()
                    .onChange(of: config.thinking) { _, _ in scheduleSave() }
                }

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extra request JSON (merged into every request, overrides everything above — for provider-specific switches like {\"enable_thinking\": false} or {\"temperature\": 0.2}).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $config.extraBodyJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 64)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                            .onChange(of: config.extraBodyJSON) { _, _ in scheduleSave() }
                        if let issue = CooperRemoteConfig.extraBodyIssue(config.extraBodyJSON) {
                            Text(issue)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var privacyFooter: some View {
        let systemAvailability = CooperAvailability.from(systemModel: .default)
        if preference == .onDevice || (preference == .auto && systemAvailability == .ready) {
            Text("The on-device path runs entirely on Apple's FoundationModels — requests never leave this Mac. Destructive actions always ask, in every mode.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Text("Requests on the remote path go to \(config.hostDisplay.isEmpty ? "the configured server" : config.hostDisplay) and include your Keg state snapshot. The API key is stored in this Mac's Keychain. Destructive actions always ask, in every mode.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private var preset: CooperProviderPreset? {
        CooperProviderPreset.all.first { $0.id == selectedPresetID }
    }

    private var modelPlaceholder: String {
        (CooperProviderPreset.all.first { $0.id == selectedPresetID })?.exampleModels.first ?? "model id"
    }

    private func fetchModels() {
        isFetchingModels = true
        fetchError = nil
        Task {
            do {
                fetchedModels = try await CooperOpenAIBackend.listModels(config: config, apiKey: apiKey)
                if fetchedModels.isEmpty {
                    fetchError = "The server listed no models."
                }
            } catch {
                fetchError = error.localizedDescription
            }
            isFetchingModels = false
        }
    }

    /// Debounced auto-save, mirroring the sliders pattern: rapid keystrokes
    /// coalesce, and a save re-resolves Cooper's active backend.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            CooperRemoteConfigStore.saveConfig(config)
            CooperKeychain.storeAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            appState.cooper.checkAvailability()
            appState.cooper.prewarmIfNeeded()
        }
    }

    // MARK: - Captions

    private var backendCaption: String {
        switch preference {
        case .onDevice:
            "Cooper only uses Apple's on-device model. If Apple Intelligence is off or unavailable, the panel says so."
        case .auto:
            "On-device when Apple Intelligence is available; otherwise the remote model below. Recommended."
        case .remote:
            "Always use the remote model, even on-device is available. Useful when you want one consistent brain."
        }
    }

    private var remoteCaption: String {
        if config.isConfigured {
            return "Cooper falls back to \(config.model) at \(config.hostDisplay). Tool calling, approvals, and thinking all work through the OpenAI chat-completions API."
        }
        return "Not configured yet — pick a provider, paste its URL and model, and an API key if needed."
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
