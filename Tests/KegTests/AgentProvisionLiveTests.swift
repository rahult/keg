import XCTest
@testable import Keg
import KegCLICore

/// Live end-to-end test of session environment provisioning against the
/// real runtime: a world recipe becomes running containers named
/// `kegagent-<slug>-<service>-1`, and teardown removes them. Opt-in:
/// KEG_RUN_AGENT_PROVISION_E2E=1 with the runtime up (~/.keg/docker.sock
/// answering). Default `swift test` skips it.
final class AgentProvisionLiveTests: XCTestCase {
    var baseDirectory: URL!
    let sessionId = "provision-live-\(UUID().uuidString.prefix(6))"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_AGENT_PROVISION_E2E"] == "1" else {
            throw XCTSkip("Set KEG_RUN_AGENT_PROVISION_E2E=1 to run the provisioning live test")
        }
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.keg/docker.sock") else {
            throw XCTSkip("Keg's Docker API socket is not present (runtime down?)")
        }
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-agent-provision-live-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let baseDirectory {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }

    private func makeRecipe() -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: "https://github.com/example/demo.git", branch: "main", commit: "abc123"),
            kegYAML: """
            name: demo
            services:
              web:
                image: alpine:latest
                command: ["sleep", "300"]
            """
        )
    }

    func testRecipeBecomesRunningContainersAndTeardownRemovesThem() async throws {
        let provisioner = AgentEnvironmentProvisioner(
            workspace: AgentWorkspace(baseDirectory: baseDirectory)
        )
        let recipe = makeRecipe()

        let result = try await provisioner.provision(sessionId: sessionId, recipe: recipe)

        let expected = AgentWorkspace.containerName(sessionId: sessionId) + "-web-1"
        XCTAssertTrue(
            result.containers.contains(expected),
            "expected \(expected) in \(result.containers)"
        )

        // Verify the container actually exists via the Docker API socket.
        let client = KegAPIClient(socketPath: NSHomeDirectory() + "/.keg/docker.sock", timeoutSeconds: 30)
        let containers = try client.containers(all: true)
        XCTAssertTrue(
            containers.contains { $0.names.contains(where: { $0.contains(expected) }) },
            "expected \(expected) among running containers"
        )

        try await provisioner.teardown(sessionId: sessionId, recipe: recipe)

        let after = try client.containers(all: true)
        XCTAssertFalse(after.contains { $0.names.contains(where: { $0.contains(expected) }) })
    }
}
