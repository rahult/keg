import Foundation

/// Source for model inference
public enum ModelSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case cloud
    case local
    case auto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloud: return "Cloud"
        case .local: return "Local"
        case .auto: return "Auto"
        }
    }

    public var description: String {
        switch self {
        case .cloud: return "Use cloud inference (Anthropic)"
        case .local: return "Use local llama.cpp inference"
        case .auto: return "Automatically select based on request"
        }
    }

    public var iconName: String {
        switch self {
        case .cloud: return "cloud"
        case .local: return "desktopcomputer"
        case .auto: return "wand.and.stars"
        }
    }
}

/// Routing decision with reason
public struct RoutingDecision: Sendable {
    public let source: ModelSource
    public let reason: String
    public let confidence: Double

    public init(source: ModelSource, reason: String, confidence: Double = 1.0) {
        self.source = source
        self.reason = reason
        self.confidence = confidence
    }
}

/// Request characteristics for routing decisions
public struct RoutingContext: Sendable {
    /// Whether the request contains sensitive data (API keys, passwords, tokens)
    public var containsSensitiveData: Bool

    /// Whether the request involves complex reasoning or multi-step tasks
    public var isComplexReasoning: Bool

    /// Whether the request is time-sensitive
    public var isTimeSensitive: Bool

    /// Preferred response format
    public var preferredFormat: ResponseFormat

    /// Request priority (1-10, higher = more important)
    public var priority: Int

    /// Whether offline mode is acceptable
    public var offlineAcceptable: Bool

    public init(
        containsSensitiveData: Bool = false,
        isComplexReasoning: Bool = false,
        isTimeSensitive: Bool = false,
        preferredFormat: ResponseFormat = .text,
        priority: Int = 5,
        offlineAcceptable: Bool = false
    ) {
        self.containsSensitiveData = containsSensitiveData
        self.isComplexReasoning = isComplexReasoning
        self.isTimeSensitive = isTimeSensitive
        self.preferredFormat = preferredFormat
        self.priority = priority
        self.offlineAcceptable = offlineAcceptable
    }

    /// Detect sensitive patterns in text
    public static func detectSensitiveData(in text: String) -> Bool {
        let patterns = [
            "api[_-]?key",
            "secret",
            "password",
            "token",
            "bearer",
            "auth",
            "credential",
            "\\b[A-Za-z0-9]{32,}\\b", // Long alphanumeric strings
            "-----BEGIN.*PRIVATE KEY-----",
            "-----BEGIN.*CERTIFICATE-----"
        ]

        let lowercased = text.lowercased()
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(lowercased.startIndex..., in: lowercased)
                if regex.firstMatch(in: lowercased, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Detect complex reasoning indicators
    public static func detectComplexReasoning(in text: String) -> Bool {
        let complexPatterns = [
            "explain.*why",
            "analyze",
            "compare.*and.*contrast",
            "evaluate",
            "synthesize",
            "prove",
            "derive",
            "reasoning",
            "step.?by.?step",
            "think.?through",
            "consider.*alternative",
            "what.*if",
            "how.*would.*you",
            "reason",
            "logical",
            "mathematical",
            "proof"
        ]

        let lowercased = text.lowercased()
        for pattern in complexPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(lowercased.startIndex..., in: lowercased)
                if regex.firstMatch(in: lowercased, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }
}

/// Response format preferences
public enum ResponseFormat: String, Sendable {
    case text
    case json
    case code
    case markdown
}

/// Model router for selecting between cloud and local inference
public actor ModelRouter {
    /// Available local models
    private var availableLocalModels: [LocalModelConfig] = []

    /// Default local model
    private var defaultLocalModel: LocalModelConfig?

    /// Whether local inference is available
    public var isLocalAvailable: Bool {
        !availableLocalModels.isEmpty && defaultLocalModel != nil
    }

    /// All available local models
    public var localModels: [LocalModelConfig] {
        availableLocalModels
    }

    // MARK: - Configuration

    /// Add a local model configuration
    public func addLocalModel(_ config: LocalModelConfig) {
        availableLocalModels.append(config)
        if defaultLocalModel == nil {
            defaultLocalModel = config
        }
    }

    /// Remove a local model by path
    public func removeLocalModel(at path: String) {
        availableLocalModels.removeAll { $0.modelPath == path }
        if defaultLocalModel?.modelPath == path {
            defaultLocalModel = availableLocalModels.first
        }
    }

    /// Set the default local model
    public func setDefaultModel(_ path: String) {
        if let model = availableLocalModels.first(where: { $0.modelPath == path }) {
            defaultLocalModel = model
        }
    }

    /// Load models from a directory
    public func loadModelsFromDirectory(_ directory: String) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: directory)

        for file in contents where file.hasSuffix(".gguf") {
            let fullPath = (directory as NSString).appendingPathComponent(file)
            let config = LocalModelConfig(modelPath: fullPath)
            if config.isValid {
                addLocalModel(config)
            }
        }
    }

    // MARK: - Routing

    /// Route a request to the appropriate model source
    public func route(
        prompt: String,
        context: RoutingContext? = nil
    ) -> RoutingDecision {
        let ctx = context ?? RoutingContext()

        // Force local for sensitive data (never send to cloud)
        if ctx.containsSensitiveData {
            if isLocalAvailable {
                return RoutingDecision(
                    source: .local,
                    reason: "Request contains sensitive data - routing to local model"
                )
            } else {
                // Cannot proceed - sensitive data but no local model
                return RoutingDecision(
                    source: .cloud,
                    reason: "Warning: Sensitive data will be sent to cloud (no local model available)"
                )
            }
        }

        // Force local for offline acceptable, low priority requests
        if ctx.offlineAcceptable && ctx.priority <= 3 {
            if isLocalAvailable {
                return RoutingDecision(
                    source: .local,
                    reason: "Low priority request - using local model for offline capability"
                )
            }
        }

        // Route complex reasoning to cloud
        if ctx.isComplexReasoning {
            return RoutingDecision(
                source: .cloud,
                reason: "Complex reasoning request - routing to cloud for best results",
                confidence: 0.9
            )
        }

        // Time-sensitive requests prefer local (lower latency)
        if ctx.isTimeSensitive && isLocalAvailable {
            return RoutingDecision(
                source: .local,
                reason: "Time-sensitive request - using local model for lower latency",
                confidence: 0.85
            )
        }

        // JSON/code formatting often better from local
        if ctx.preferredFormat == .json || ctx.preferredFormat == .code {
            if isLocalAvailable {
                return RoutingDecision(
                    source: .local,
                    reason: "Structured output requested - routing to local model"
                )
            }
        }

        // Default: auto - use local if available
        if isLocalAvailable {
            return RoutingDecision(
                source: .local,
                reason: "Auto-selected local model for efficiency",
                confidence: 0.7
            )
        }

        return RoutingDecision(
            source: .cloud,
            reason: "Defaulting to cloud inference (no local model available)"
        )
    }

    /// Get the appropriate local model config for a request
    public func getLocalModel(for decision: RoutingDecision) -> LocalModelConfig? {
        guard decision.source == .local else { return nil }
        return defaultLocalModel
    }

    /// Force route to specific source
    public func forceRoute(to source: ModelSource) -> RoutingDecision {
        switch source {
        case .cloud:
            return RoutingDecision(source: .cloud, reason: "User explicitly selected cloud inference")
        case .local:
            if isLocalAvailable {
                return RoutingDecision(source: .local, reason: "User explicitly selected local inference")
            } else {
                return RoutingDecision(
                    source: .cloud,
                    reason: "Local inference unavailable - falling back to cloud"
                )
            }
        case .auto:
            return RoutingDecision(source: .auto, reason: "Auto-selecting based on request characteristics")
        }
    }
}

// MARK: - Convenience Extensions

extension ModelRouter {
    /// Quick route for simple prompts
    public static func quickRoute(_ prompt: String) async -> ModelSource {
        let router = ModelRouter()
        let context = RoutingContext(
            containsSensitiveData: RoutingContext.detectSensitiveData(in: prompt),
            isComplexReasoning: RoutingContext.detectComplexReasoning(in: prompt)
        )
        let decision = await router.route(prompt: prompt, context: context)
        return decision.source
    }
}
