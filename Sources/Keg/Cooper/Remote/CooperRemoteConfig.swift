import Foundation

/// Which brain Cooper should use. `auto` prefers the on-device model and
/// falls back to the configured remote server; the other two force a path.
enum CooperBackendPreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case onDevice
    case auto
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice: return "On-device (Apple)"
        case .auto: return "Automatic"
        case .remote: return "Remote server"
        }
    }
}

/// How much thinking to request from a reasoning-capable model. Remote
/// providers disagree on the switch, so Keg only sends the one de-facto
/// standard (`reasoning_effort` on chat/completions): levels send it, and
/// both `providerDefault` and `off` send nothing — `off` additionally
/// strips `<think>` blocks and reasoning deltas from the visible reply,
/// which covers models that always think. Provider-specific switches
/// (e.g. Qwen's `enable_thinking`) go through Extra Request JSON.
enum CooperThinkingPreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case providerDefault
    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .providerDefault: return "Provider default"
        case .off: return "Off (don't request, don't show)"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The value for the OpenAI `reasoning_effort` parameter, or nil when
    /// nothing should be sent.
    var reasoningEffort: String? {
        switch self {
        case .providerDefault, .off: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

/// One OpenAI-compatible inference provider. Presets only fill the base
/// URL — the model and key are always user-supplied (except local servers,
/// which need no key).
struct CooperProviderPreset: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let needsKey: Bool
    /// Example model ids shown as the model field's placeholder.
    let exampleModels: [String]

    static let all: [CooperProviderPreset] = [
        CooperProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", needsKey: true,
                             exampleModels: ["gpt-4o-mini", "gpt-4.1-mini", "o4-mini"]),
        CooperProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true,
                             exampleModels: ["anthropic/claude-sonnet-4", "deepseek/deepseek-r1", "qwen/qwen3-32b"]),
        CooperProviderPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", needsKey: true,
                             exampleModels: ["llama-3.3-70b-versatile", "qwen-2.5-32b"]),
        CooperProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", needsKey: true,
                             exampleModels: ["deepseek-chat", "deepseek-reasoner"]),
        CooperProviderPreset(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", needsKey: true,
                             exampleModels: ["mistral-large-latest", "magistral-small-latest"]),
        CooperProviderPreset(id: "together", name: "Together", baseURL: "https://api.together.xyz/v1", needsKey: true,
                             exampleModels: ["Qwen/Qwen3-32B", "meta-llama/Llama-4-Scout-17B-16E-Instruct"]),
        CooperProviderPreset(id: "fireworks", name: "Fireworks", baseURL: "https://api.fireworks.ai/inference/v1", needsKey: true,
                             exampleModels: ["accounts/fireworks/models/qwen3-32b"]),
        CooperProviderPreset(id: "ollama", name: "Ollama (local)", baseURL: "http://127.0.0.1:11434/v1", needsKey: false,
                             exampleModels: ["qwen3:14b", "llama3.1:8b"]),
        CooperProviderPreset(id: "lmstudio", name: "LM Studio (local)", baseURL: "http://127.0.0.1:1234/v1", needsKey: false,
                             exampleModels: ["qwen3-14b", "mistral-small-3"]),
        CooperProviderPreset(id: "vllm", name: "vLLM (local)", baseURL: "http://127.0.0.1:8000/v1", needsKey: false,
                             exampleModels: ["Qwen/Qwen3-14B"]),
        CooperProviderPreset(id: "custom", name: "Custom", baseURL: "", needsKey: true, exampleModels: []),
    ]
}

/// The remote model Cooper falls back to when the on-device model is
/// unavailable (or when the user forces the remote path). Anything that
/// speaks the OpenAI chat-completions dialect works. The API key lives in
/// the Keychain, never here.
struct CooperRemoteConfig: Codable, Equatable, Sendable {
    var baseURL: String = ""
    var model: String = ""
    var thinking: CooperThinkingPreference = .providerDefault
    /// Advanced escape hatch: a JSON object merged into every request body
    /// last, for provider-specific switches (`enable_thinking`, temperature,
    /// `max_tokens`, prompt caches, …). Invalid JSON disables the remote
    /// path (surfaced in Settings), never half-applied.
    var extraBodyJSON: String = ""

    var isConfigured: Bool {
        Self.isValidBaseURL(baseURL) && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.extraBodyIssue(extraBodyJSON) == nil
    }

    var effectiveBaseURL: URL? {
        Self.normalizedBaseURL(baseURL)
    }

    var hostDisplay: String {
        effectiveBaseURL?.host ?? baseURL
    }

    /// Normalizes user input: trims whitespace, drops a trailing slash so
    /// appending `/chat/completions` can't double up.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    static func isValidBaseURL(_ raw: String) -> Bool {
        normalizedBaseURL(raw) != nil
    }

    /// Returns a human-readable problem with the extra-body JSON, or nil.
    static func extraBodyIssue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            return "Extra request JSON must be a JSON object, e.g. {\"temperature\": 0.2}"
        }
        return nil
    }
}

/// The user's backend choice plus the remote config, persisted as one
/// blob; the API key is stored separately in the Keychain.
enum CooperRemoteConfigStore {
    static let defaultsKey = "cooper.remote"
    static let backendKey = "cooper.remote.backend"

    static func loadConfig() -> CooperRemoteConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(CooperRemoteConfig.self, from: data) else {
            return CooperRemoteConfig()
        }
        return config
    }

    static func saveConfig(_ config: CooperRemoteConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func loadPreference() -> CooperBackendPreference {
        guard let raw = UserDefaults.standard.string(forKey: backendKey),
              let preference = CooperBackendPreference(rawValue: raw) else { return .auto }
        return preference
    }

    static func savePreference(_ preference: CooperBackendPreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: backendKey)
    }
}

/// API key storage for the remote provider. Same generic-password shape as
/// the dormant AgentAuth, but self-contained so Cooper doesn't couple to
/// that stack's service/migration logic.
enum CooperKeychain {
    private static let service = "com.keg.cooper"
    private static let account = "remote.api-key"

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func storeAPIKey(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Which brain a turn should run on, and what the panel should claim.
enum CooperBrainKind: Equatable, Sendable {
    case onDevice
    case remote
}

/// Pure backend resolution — the single place that decides whether Cooper
/// can talk and which path a turn takes. Testable without any model.
enum CooperBackendResolver {
    struct Resolution: Equatable, Sendable {
        /// What the panel gates on: `.ready` means at least one path works.
        var availability: CooperAvailability
        var brain: CooperBrainKind
        /// Non-nil when the remote path is the active one.
        var remoteConfig: CooperRemoteConfig?
    }

    static func resolve(
        systemAvailability: CooperAvailability,
        preference: CooperBackendPreference,
        remote: CooperRemoteConfig
    ) -> Resolution {
        let systemReady = systemAvailability == .ready
        let remoteReady = remote.isConfigured

        // Forced on-device: exactly the pre-remote behavior.
        if preference == .onDevice {
            return Resolution(availability: systemAvailability, brain: .onDevice, remoteConfig: nil)
        }
        // Remote works (auto-fallback, or explicitly forced while healthy
        // on-device). An unconfigured remote preference degrades to auto.
        if remoteReady && (preference == .remote || !systemReady) {
            return Resolution(availability: .ready, brain: .remote, remoteConfig: remote)
        }
        return Resolution(availability: systemAvailability, brain: .onDevice, remoteConfig: nil)
    }
}
