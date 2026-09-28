import XCTest

@testable import Keg

/// Live end-to-end test of the OpenAI-compatible backend against a real
/// server. Opt-in like the container E2E: set KEG_RUN_COOPER_REMOTE_E2E=1
/// with an OpenAI-compatible server reachable (KEG_COOPER_REMOTE_URL, by
/// default a local Ollama) to run it — everything here needs real network,
/// so CI and default `swift test` skip it.
final class CooperRemoteLiveTests: XCTestCase {
    private var config: CooperRemoteConfig {
        let url = ProcessInfo.processInfo.environment["KEG_COOPER_REMOTE_URL"]
            ?? "http://127.0.0.1:11434/v1"
        let model = ProcessInfo.processInfo.environment["KEG_COOPER_REMOTE_MODEL"]
            ?? "llama3.2:3b"
        return CooperRemoteConfig(baseURL: url, model: model)
    }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_COOPER_REMOTE_E2E"] == "1" else {
            throw XCTSkip("Set KEG_RUN_COOPER_REMOTE_E2E=1 to run the remote-model live test")
        }
    }

    private func serverConfigured(_ config: CooperRemoteConfig) async -> Bool {
        (try? await CooperOpenAIBackend.listModels(config: config, apiKey: "")) != nil
    }

    func testModelListing() async throws {
        let models = try await CooperOpenAIBackend.listModels(config: config, apiKey: "")
        XCTAssertFalse(models.isEmpty, "the server should list at least one model")
    }

    func testFullToolCallingTurn() async throws {
        guard await serverConfigured(config) else {
            throw XCTSkip("no OpenAI-compatible server at \(config.baseURL)")
        }
        let calculator = CooperToolSpec(
            name: "calculator",
            description: "Evaluate an arithmetic expression like \"2+2\" and return the result.",
            parameters: .objectSchema([
                "expression": .schema("The arithmetic expression to evaluate", type: "string"),
            ], required: ["expression"])
        ) { raw in
            struct Args: Decodable { var expression: String }
            let arguments = try CooperToolSpec.decode(Args.self, from: raw)
            return "The result of \(arguments.expression) is 4."
        }

        let history = [CooperChatMessage.system(
            "You are a helpful assistant. Use the provided tools to answer questions; never answer from memory."
        )]
        var updates = 0
        var finalHistory: [CooperChatMessage]?
        let stream = CooperOpenAIBackend.turn(
            config: config,
            apiKey: "",
            history: history,
            userPrompt: "What is 2+2? Use the calculator tool.",
            tools: [calculator]
        )
        for try await event in stream {
            switch event {
            case .update(let update):
                if update.toolStarted != nil || update.toolFinished != nil { updates += 1 }
            case .done(let newHistory):
                finalHistory = newHistory
            }
        }

        let result = try XCTUnwrap(finalHistory, "the turn must finish with a done event")
        XCTAssertEqual(result.first?.role, .system)
        XCTAssertTrue(result.contains { $0.role == .user }, "the user message must be in the history")
        XCTAssertTrue(result.contains { $0.role == .tool }, "the calculator tool must have run (got \(updates) tool events)")
        XCTAssertTrue(result.contains { $0.role == .tool && $0.content?.contains("is 4") == true },
                      "the tool result must carry the computed answer")
        let last = try XCTUnwrap(result.last)
        XCTAssertEqual(last.role, .assistant, "the turn must end on an assistant reply")
    }
}
