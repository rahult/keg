import XCTest
@testable import Keg

final class AgentEnvironmentTests: XCTestCase {
    var baseDirectory: URL!

    override func setUp() async throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-agent-env-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private func makeRecipe() -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: "/tmp/keg-test-repo", branch: "main", commit: "abc123"),
            kegYAML: "name: demo\nservices:\n  web:\n    image: nginx:alpine\n",
            env: ["NODE_ENV": "test"],
            databases: []
        )
    }

    // MARK: - Naming contract

    func testContainerNamePrefixesAndSanitizesSessionId() {
        XCTAssertEqual(AgentWorkspace.containerName(sessionId: "session-AbC 123_x"), "kegagent-session-abc-123-x")
    }

    func testContainerNameIsDeterministic() {
        XCTAssertEqual(
            AgentWorkspace.containerName(sessionId: "sess-one"),
            AgentWorkspace.containerName(sessionId: "sess-one")
        )
    }

    func testContainerNameFitsDockerNameLimits() {
        let long = String(repeating: "a", count: 300)
        let name = AgentWorkspace.containerName(sessionId: long)
        XCTAssertLessThanOrEqual(name.count, 63)
        XCTAssertTrue(name.hasPrefix("kegagent-"))
    }

    // MARK: - Workspace materialization

    func testMaterializeWritesKegYAMLIntoWorkspace() async throws {
        let env = AgentWorkspace(baseDirectory: baseDirectory)
        let recipe = makeRecipe()

        let workspace = try await env.materialize(sessionId: "sess-1", recipe: recipe)

        let written = try String(contentsOf: workspace.appendingPathComponent("keg.yaml"), encoding: .utf8)
        XCTAssertEqual(written, recipe.kegYAML)
    }

    func testMaterializeIsIdempotent() async throws {
        let env = AgentWorkspace(baseDirectory: baseDirectory)
        let recipe = makeRecipe()

        let first = try await env.materialize(sessionId: "sess-2", recipe: recipe)
        let second = try await env.materialize(sessionId: "sess-2", recipe: recipe)

        XCTAssertEqual(first, second)
        let written = try String(contentsOf: first.appendingPathComponent("keg.yaml"), encoding: .utf8)
        XCTAssertEqual(written, recipe.kegYAML)
    }

    func testMaterializeOverwritesChangedRecipe() async throws {
        let env = AgentWorkspace(baseDirectory: baseDirectory)
        _ = try await env.materialize(sessionId: "sess-3", recipe: makeRecipe())

        var changed = makeRecipe()
        changed.kegYAML = "name: demo\nservices:\n  web:\n    image: nginx:1.27\n"
        let workspace = try await env.materialize(sessionId: "sess-3", recipe: changed)

        let written = try String(contentsOf: workspace.appendingPathComponent("keg.yaml"), encoding: .utf8)
        XCTAssertEqual(written, changed.kegYAML)
    }

    func testMaterializeThrowsForInvalidRecipe() async throws {
        let env = AgentWorkspace(baseDirectory: baseDirectory)
        var bad = makeRecipe()
        bad.repo = RepoRef(url: "", branch: "main", commit: "abc123")

        await XCTAssertThrowsErrorAsync({ try await env.materialize(sessionId: "sess-4", recipe: bad) }) { error in
            guard case WorldRecipeError.emptyRepo = error else {
                return XCTFail("expected .emptyRepo, got \(error)")
            }
        }
    }

    func testWorkspacesAreIsolatedPerSession() async throws {
        let env = AgentWorkspace(baseDirectory: baseDirectory)
        let recipe = makeRecipe()

        let one = try await env.materialize(sessionId: "sess-a", recipe: recipe)
        let two = try await env.materialize(sessionId: "sess-b", recipe: recipe)

        XCTAssertNotEqual(one, two)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Any,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message() == "" ? "expected error" : message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
