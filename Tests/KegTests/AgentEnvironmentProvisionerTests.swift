import XCTest
@testable import Keg
import KegCLICore

final class AgentEnvironmentProvisionerTests: XCTestCase {
    var baseDirectory: URL!

    override func setUp() async throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-agent-provisioner-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private final class Recorder: @unchecked Sendable {
        var upCalls: [(config: KegProjectConfig, workspace: URL)] = []
        var downCalls: [(config: KegProjectConfig, workspace: URL)] = []
        var upContainers: [String] = []
        var upError: Error?
    }

    private func makeProvisioner(
        _ recorder: Recorder,
        workspace: AgentWorkspace? = nil
    ) -> AgentEnvironmentProvisioner {
        let up: AgentEnvironmentProvisioner.UpFn = { config, dir in
            recorder.upCalls.append((config, dir))
            if let error = recorder.upError { throw error }
            return recorder.upContainers
        }
        let down: AgentEnvironmentProvisioner.DownFn = { config, dir in
            recorder.downCalls.append((config, dir))
        }
        return AgentEnvironmentProvisioner(
            workspace: workspace ?? AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces")),
            up: up,
            down: down
        )
    }

    private func makeRecipe() -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: "/tmp/keg-test-repo", branch: "main", commit: "abc123"),
            kegYAML: "name: demo\nservices:\n  web:\n    image: nginx:alpine\n"
        )
    }

    // MARK: -

    func testProvisionLoadsRecipeAndReturnsContainers() async throws {
        let recorder = Recorder()
        recorder.upContainers = ["kegagent-sess-1-web-1"]
        let provisioner = makeProvisioner(recorder)

        let result = try await provisioner.provision(sessionId: "sess-1", recipe: makeRecipe())

        XCTAssertEqual(result.containers, ["kegagent-sess-1-web-1"])
        XCTAssertEqual(recorder.upCalls.count, 1)
    }

    func testProvisionOverridesProjectNameToSessionSlug() async throws {
        let recorder = Recorder()
        let provisioner = makeProvisioner(recorder)

        try await provisioner.provision(sessionId: "My Session!", recipe: makeRecipe())

        XCTAssertEqual(recorder.upCalls.first?.config.name, "kegagent-my-session")
    }

    func testProvisionPassesMaterializedWorkspaceContainingKegYAML() async throws {
        let recorder = Recorder()
        let provisioner = makeProvisioner(recorder)

        let result = try await provisioner.provision(sessionId: "sess-2", recipe: makeRecipe())

        let written = try String(contentsOf: result.workspace.appendingPathComponent("keg.yaml"), encoding: .utf8)
        XCTAssertTrue(written.contains("nginx:alpine"))
        XCTAssertEqual(recorder.upCalls.first?.workspace, result.workspace)
    }

    func testProvisionRejectsInvalidRecipeWithoutInvokingUp() async throws {
        let recorder = Recorder()
        var bad = makeRecipe()
        bad.kegYAML = "::: broken :::"
        let provisioner = makeProvisioner(recorder)

        do {
            try await provisioner.provision(sessionId: "sess-3", recipe: bad)
            XCTFail("expected error")
        } catch WorldRecipeError.invalidKegYAML {
            // expected
        }
        XCTAssertTrue(recorder.upCalls.isEmpty)
    }

    func testFailedProvisionTearsDownWhatItStarted() async throws {
        let recorder = Recorder()
        recorder.upError = ProvisioningFailure()
        let provisioner = makeProvisioner(recorder)

        do {
            try await provisioner.provision(sessionId: "sess-4", recipe: makeRecipe())
            XCTFail("expected error")
        } catch is ProvisioningFailure {
            // expected
        }

        XCTAssertEqual(recorder.downCalls.count, 1)
        XCTAssertEqual(recorder.downCalls.first?.config.name, "kegagent-sess-4")
    }

    func testTeardownRunsDownForSession() async throws {
        let recorder = Recorder()
        let provisioner = makeProvisioner(recorder)

        try await provisioner.teardown(sessionId: "sess-5", recipe: makeRecipe())

        XCTAssertEqual(recorder.downCalls.count, 1)
        XCTAssertEqual(recorder.downCalls.first?.config.name, "kegagent-sess-5")
    }

    struct ProvisioningFailure: Error {}
}
