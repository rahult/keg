import XCTest
@testable import Keg

final class ModelRouterTests: XCTestCase {
    var router: ModelRouter!

    override func setUp() async throws {
        router = ModelRouter()
    }

    // MARK: - Model Source Enum Tests

    func testModelSourceDisplayNames() {
        XCTAssertEqual(ModelSource.cloud.displayName, "Cloud")
        XCTAssertEqual(ModelSource.local.displayName, "Local")
        XCTAssertEqual(ModelSource.auto.displayName, "Auto")
    }

    func testModelSourceDescriptions() {
        XCTAssertFalse(ModelSource.cloud.description.isEmpty)
        XCTAssertFalse(ModelSource.local.description.isEmpty)
        XCTAssertFalse(ModelSource.auto.description.isEmpty)
    }

    func testModelSourceIcons() {
        XCTAssertEqual(ModelSource.cloud.iconName, "cloud")
        XCTAssertEqual(ModelSource.local.iconName, "desktopcomputer")
        XCTAssertEqual(ModelSource.auto.iconName, "wand.and.stars")
    }

    // MARK: - Local Model Config Tests

    func testLocalModelConfigDefaults() {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")

        XCTAssertEqual(config.quantization, "Q4_K_M")
        XCTAssertEqual(config.port, 8080)
        XCTAssertEqual(config.contextSize, 4096)
        XCTAssertEqual(config.gpuLayers, -1)
        XCTAssertEqual(config.threads, 0)
        XCTAssertEqual(config.batchSize, 512)
        XCTAssertTrue(config.flashAttention)
        XCTAssertEqual(config.maxConcurrentRequests, 4)
    }

    func testLocalModelConfigServerURL() {
        let config = LocalModelConfig(modelPath: "/models/test.gguf", port: 8080)
        XCTAssertEqual(config.serverURL.absoluteString, "http://127.0.0.1:8080")
    }

    func testLocalModelConfigAPIURL() {
        let config = LocalModelConfig(modelPath: "/models/test.gguf", port: 8080)
        XCTAssertEqual(config.apiBaseURL.absoluteString, "http://127.0.0.1:8080/v1")
    }

    func testLocalModelConfigInferenceName() {
        let config = LocalModelConfig(
            modelPath: "/models/Mistral-7B-v0.3-Q4_K_M.gguf",
            modelName: nil
        )
        XCTAssertEqual(config.modelName, "Mistral-7B-v0.3-Q4_K_M")
    }

    func testLocalModelConfigCustomName() {
        let config = LocalModelConfig(
            modelPath: "/models/test.gguf",
            modelName: "My Custom Model"
        )
        XCTAssertEqual(config.modelName, "My Custom Model")
    }

    func testQuantizationPresets() {
        XCTAssertTrue(LocalModelConfig.quantizationPresets.contains("Q4_K_M"))
        XCTAssertTrue(LocalModelConfig.quantizationPresets.contains("Q8_0"))
        XCTAssertTrue(LocalModelConfig.quantizationPresets.contains("F16"))
    }

    func testContextSizePresets() {
        XCTAssertTrue(LocalModelConfig.contextSizePresets.contains(2048))
        XCTAssertTrue(LocalModelConfig.contextSizePresets.contains(4096))
        XCTAssertTrue(LocalModelConfig.contextSizePresets.contains(8192))
    }

    // MARK: - Routing Context Tests

    func testSensitiveDataDetection() {
        // API keys
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "api_key=sk-1234567890abcdef"))
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "API_KEY is my-secret-key"))
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "secret_key_12345"))

        // Passwords
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "password: supersecret123"))
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "my password is xyz"))

        // Tokens
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "auth token: abc123"))

        // Certificates
        XCTAssertTrue(RoutingContext.detectSensitiveData(in: "-----BEGIN PRIVATE KEY-----"))

        // Non-sensitive content
        XCTAssertFalse(RoutingContext.detectSensitiveData(in: "Hello, how are you today?"))
        XCTAssertFalse(RoutingContext.detectSensitiveData(in: "Write a function to add numbers"))
    }

    func testComplexReasoningDetection() {
        // Complex reasoning patterns
        XCTAssertTrue(RoutingContext.detectComplexReasoning(in: "Explain why this approach is better"))
        XCTAssertTrue(RoutingContext.detectComplexReasoning(in: "Analyze the tradeoffs"))
        XCTAssertTrue(RoutingContext.detectComplexReasoning(in: "Compare and contrast the options"))
        XCTAssertTrue(RoutingContext.detectComplexReasoning(in: "Step by step reasoning"))
        XCTAssertTrue(RoutingContext.detectComplexReasoning(in: "Think through this problem"))
        XCTAssertTrue(RoutingContext.detectComplexReasoning(in: "Proof by induction"))
        XCTAssertTrue(RoutingContext.detectComplexReasoning(in: "Derive the formula"))

        // Simple content
        XCTAssertFalse(RoutingContext.detectComplexReasoning(in: "What is the weather?"))
        XCTAssertFalse(RoutingContext.detectComplexReasoning(in: "Write hello world"))
    }

    // MARK: - Routing Decision Tests

    func testRoutingDecisionProperties() {
        let decision = RoutingDecision(
            source: .cloud,
            reason: "Test reason",
            confidence: 0.85
        )

        XCTAssertEqual(decision.source, .cloud)
        XCTAssertEqual(decision.reason, "Test reason")
        XCTAssertEqual(decision.confidence, 0.85)
    }

    // MARK: - Model Router Tests

    func testRouterInitialState() async {
        let available = await router.isLocalAvailable
        XCTAssertFalse(available)
        let models = await router.localModels
        XCTAssertTrue(models.isEmpty)
    }

    func testAddLocalModel() async {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")
        await router.addLocalModel(config)

        let available = await router.isLocalAvailable
        XCTAssertTrue(available)
        let models = await router.localModels
        XCTAssertEqual(models.count, 1)
    }

    func testRemoveLocalModel() async {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")
        await router.addLocalModel(config)
        await router.removeLocalModel(at: "/models/test.gguf")

        let available = await router.isLocalAvailable
        XCTAssertFalse(available)
    }

    func testSetDefaultModel() async {
        let config1 = LocalModelConfig(modelPath: "/models/model1.gguf")
        let config2 = LocalModelConfig(modelPath: "/models/model2.gguf")

        await router.addLocalModel(config1)
        await router.addLocalModel(config2)
        await router.setDefaultModel("/models/model2.gguf")

        let decision = await router.getLocalModel(
            for: RoutingDecision(source: .local, reason: "test")
        )

        XCTAssertEqual(decision?.modelPath, "/models/model2.gguf")
    }

    func testRouteSensitiveDataToLocal() async {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")
        await router.addLocalModel(config)

        let context = RoutingContext(containsSensitiveData: true)
        let decision = await router.route(prompt: "password: secret123", context: context)

        XCTAssertEqual(decision.source, .local)
        XCTAssertTrue(decision.reason.contains("sensitive"))
    }

    func testRouteComplexReasoningToCloud() async {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")
        await router.addLocalModel(config)

        let context = RoutingContext(isComplexReasoning: true)
        let decision = await router.route(
            prompt: "Explain why this approach is better with step by step reasoning",
            context: context
        )

        XCTAssertEqual(decision.source, .cloud)
        XCTAssertTrue(decision.reason.contains("Complex"))
    }

    func testRouteAutoSelectsLocal() async {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")
        await router.addLocalModel(config)

        let decision = await router.route(prompt: "Hello, how are you?")

        XCTAssertEqual(decision.source, .local)
    }

    func testForceRouteCloud() async {
        let decision = await router.forceRoute(to: .cloud)
        XCTAssertEqual(decision.source, .cloud)
    }

    func testForceRouteLocalWithNoModel() async {
        let decision = await router.forceRoute(to: .local)
        XCTAssertEqual(decision.source, .cloud) // Falls back to cloud
        XCTAssertTrue(decision.reason.contains("unavailable"))
    }

    func testForceRouteLocalWithModel() async {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")
        await router.addLocalModel(config)

        let decision = await router.forceRoute(to: .local)
        XCTAssertEqual(decision.source, .local)
    }

    func testForceRouteAuto() async {
        let decision = await router.forceRoute(to: .auto)
        XCTAssertEqual(decision.source, .auto)
    }

    func testTimeSensitiveRoutesLocal() async {
        let config = LocalModelConfig(modelPath: "/models/test.gguf")
        await router.addLocalModel(config)

        let context = RoutingContext(isTimeSensitive: true)
        let decision = await router.route(prompt: "Quick summary", context: context)

        XCTAssertEqual(decision.source, .local)
        XCTAssertTrue(decision.reason.contains("latency"))
    }

    // MARK: - Quick Route Tests

    func testQuickRouteShorthand() async {
        // This tests the convenience method
        let source = await ModelRouter.quickRoute("Hello world")
        // Will be cloud if no local model is configured
        XCTAssertTrue([ModelSource.cloud, .local].contains(source))
    }
}

// MARK: - Local Model Bridge Tests

final class LocalModelBridgeTests: XCTestCase {
    var bridge: LocalModelBridge!

    override func setUp() async throws {
        bridge = LocalModelBridge()
    }

    func testInitialState() async {
        let state = await bridge.currentState
        XCTAssertFalse(state.isRunning)
        let config = await bridge.currentConfig
        XCTAssertNil(config)
        let url = await bridge.serverURL
        XCTAssertNil(url)
    }

    func testGetStatusInitial() async {
        let status = await bridge.getStatus()

        XCTAssertFalse(status.isHealthy)
        XCTAssertNil(status.config)
    }
}

// MARK: - Routing Context Tests

final class RoutingContextTests: XCTestCase {
    func testDefaultValues() {
        let context = RoutingContext()

        XCTAssertFalse(context.containsSensitiveData)
        XCTAssertFalse(context.isComplexReasoning)
        XCTAssertFalse(context.isTimeSensitive)
        XCTAssertEqual(context.preferredFormat, .text)
        XCTAssertEqual(context.priority, 5)
        XCTAssertFalse(context.offlineAcceptable)
    }

    func testCustomValues() {
        let context = RoutingContext(
            containsSensitiveData: true,
            isComplexReasoning: true,
            isTimeSensitive: true,
            preferredFormat: .json,
            priority: 9,
            offlineAcceptable: true
        )

        XCTAssertTrue(context.containsSensitiveData)
        XCTAssertTrue(context.isComplexReasoning)
        XCTAssertTrue(context.isTimeSensitive)
        XCTAssertEqual(context.preferredFormat, .json)
        XCTAssertEqual(context.priority, 9)
        XCTAssertTrue(context.offlineAcceptable)
    }
}

// MARK: - Response Format Tests

final class ResponseFormatTests: XCTestCase {
    func testAllCases() {
        XCTAssertEqual(ResponseFormat.text.rawValue, "text")
        XCTAssertEqual(ResponseFormat.json.rawValue, "json")
        XCTAssertEqual(ResponseFormat.code.rawValue, "code")
        XCTAssertEqual(ResponseFormat.markdown.rawValue, "markdown")
    }
}
