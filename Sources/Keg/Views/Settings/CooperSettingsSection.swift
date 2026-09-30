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

        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Model backend", caption: backendCaption) {
                Picker("", selection: $preference) {
                    ForEach(CooperBackendPreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: preference) { _, newValue in
                    CooperRemoteConfigStore.savePreference(newValue)
                    scheduleSave()
                }
            }

            if preference != .onDevice {
                remoteModelGroup
            }

            SettingsGroup("Permission mode", caption: permissionCaption(for: appState.agentPermissionMode)) {
                Picker("", selection: $appState.agentPermissionMode) {
                    ForEach(AgentPermissionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            privacyFooter

            dangerGroup
        }
        .padding(.vertical, 4)
        .task {
            preference = CooperRemoteConfigStore.loadPreference()
            config = CooperRemoteConfigStore.loadConfig()
            apiKey = CooperKeychain.loadAPIKey()
            selectedPresetID = CooperProviderPreset.all.first { $0.baseURL == config.baseURL }?.id ?? "custom"
        }
    }

    // MARK: - Danger zone

    private var dangerGroup: some View {
        SettingsGroup("Danger", caption: "Erases the Cooper transcript for whichever backend is active. Cooper starts a fresh conversation; nothing else is affected.", isDanger: true) {
            SettingsValueRow("Clear Conversation", description: clearedNotice ? "Conversation cleared." : "Erases the Cooper transcript.", isLast: true) {
                Button(role: .destructive) {
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
        }
    }

    // MARK: - Remote model group

    private var remoteModelGroup: some View {
        SettingsGroup("Remote model", caption: remoteCaption) {
            VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsValueRow("Provider", description: "Pick a preset or keep Custom.") {
                            Picker("Provider", selection: $selectedPresetID) {
                                ForEach(CooperProviderPreset.all) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: SettingsMetrics.pickerWidth)
                            .onChange(of: selectedPresetID) { _, newID in
                                if let preset = CooperProviderPreset.all.first(where: { $0.id == newID }) {
                                    config.baseURL = preset.baseURL
                                    fetchedModels = []
                                    scheduleSave()
                                }
                            }
                        }

                        SettingsValueRow("Server URL", description: "The server's OpenAI-compatible endpoint.") {
                            TextField("https://api.openai.com/v1", text: $config.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.pickerWidth)
                                .onChange(of: config.baseURL) { _, _ in scheduleSave() }
                        }

                        SettingsValueRow("Model", description: "The model id Cooper asks for.") {
                            TextField(modelPlaceholder, text: $config.model)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.pickerWidth)
                                .onChange(of: config.model) { _, _ in scheduleSave() }
                                .overlay(alignment: .trailing) {
                                    Button {
                                        fetchModels()
                                    } label: {
                                        if isFetchingModels {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "list.bullet")
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .padding(.trailing, 6)
                                    .disabled(isFetchingModels || !CooperRemoteConfig.isValidBaseURL(config.baseURL))
                                    .help("Ask the server for its available models")
                                }
                        }

                        if !fetchedModels.isEmpty {
                            SettingsValueRow("Available", description: "Models the server reported.") {
                                Picker("Available", selection: Binding(
                                    get: { config.model },
                                    set: { config.model = $0; scheduleSave() }
                                )) {
                                    ForEach(fetchedModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .frame(width: SettingsMetrics.pickerWidth)
                                .labelsHidden()
                            }
                        }
                        if let fetchError {
                            SettingsValueRow(isLast: true) {
                                Text(fetchError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        SettingsValueRow("API key", description: preset?.needsKey == false ? "Not needed for local servers." : "Stored in this Mac's Keychain.") {
                            SecureField(preset?.needsKey == false ? "not needed for local servers" : "sk-…", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.pickerWidth)
                                .onChange(of: apiKey) { _, _ in scheduleSave() }
                        }

                        SettingsValueRow("Thinking", description: "How much reasoning to request, when the server supports it.", isLast: true) {
                            Picker("Thinking", selection: $config.thinking) {
                                ForEach(CooperThinkingPreference.allCases) { thinking in
                                    Text(thinking.label).tag(thinking)
                                }
                            }
                            .frame(width: SettingsMetrics.pickerWidth)
                            .labelsHidden()
                            .onChange(of: config.thinking) { _, _ in scheduleSave() }
                        }
                    }
                }

                DisclosureGroup("Advanced") {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                            SettingsCaption("Extra request JSON (merged into every request, overrides everything above — for provider-specific switches like {\"enable_thinking\": false} or {\"temperature\": 0.2}).")
                            TextEditor(text: $config.extraBodyJSON)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 64)
                                .scrollContentBackground(.hidden)
                                .onChange(of: config.extraBodyJSON) { _, _ in scheduleSave() }
                            if let issue = CooperRemoteConfig.extraBodyIssue(config.extraBodyJSON) {
                                Text(issue)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
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
            SettingsCaption("The on-device path runs entirely on Apple's FoundationModels — requests never leave this Mac. Destructive actions always ask, in every mode.")
        } else {
            SettingsCaption("Requests on the remote path go to \(config.hostDisplay.isEmpty ? "the configured server" : config.hostDisplay) and include your Keg state snapshot. The API key is stored in this Mac's Keychain. Destructive actions always ask, in every mode.")
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
}
