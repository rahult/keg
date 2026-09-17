import XCTest
@testable import Keg
import ContainerAPIClient

/// Diagnostic probe: does the container-apiserver XPC service answer this
/// (unsigned, adhoc-signed) test binary? Determines whether the Docker API
/// server's XPC-backed routes (start/wait/exec/stats) can work in debug
/// builds or require a signed app bundle.
final class XPCProbeTests: XCTestCase {
    func testContainerListResponds() async throws {
        // CI runners have no Apple container runtime — these probes only
        // mean anything on machines where the apiserver exists.
        guard ContainerCLI.isInstalled else {
            throw XCTSkip("container CLI not installed")
        }
        let client = ContainerClient()
        let probe = Task {
            try await client.list()
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            probe.cancel()
        }
        do {
            let containers = try await probe.value
            XCTAssertNotNil(containers)
        } catch is CancellationError {
            XCTFail("XPC list() timed out after 15s — apiserver did not answer this binary")
        }
        timeout.cancel()
    }

    /// bootstrap on a freshly created (not started) container is exactly
    /// what the Docker API start route does; it must reply, not hang.
    func testBootstrapRepliesOnCreatedContainer() async throws {
        guard ContainerCLI.isInstalled else {
            throw XCTSkip("container CLI not installed")
        }
        let unique = "keg-xpc-probe-\(UUID().uuidString.prefix(6))"
        _ = try await ContainerCLI.run(["container", "create", "--name", unique, "alpine:latest", "sleep", "30"])
        do {
            let client = ContainerClient()
            let probe = Task<Void, Error> {
                let process = try await client.bootstrap(id: unique, stdio: [nil, nil, nil])
                try await process.start()
            }
            let timeout = Task {
                try await Task.sleep(for: .seconds(20))
                probe.cancel()
            }
            do {
                try await probe.value
            } catch is CancellationError {
                XCTFail("XPC bootstrap+start timed out after 20s")
            } catch {
                XCTFail("XPC bootstrap failed: \(error)")
            }
            timeout.cancel()
        } catch {
            _ = try? await ContainerCLI.run(["container", "delete", "-f", unique])
            throw error
        }
        _ = try? await ContainerCLI.run(["container", "delete", "-f", unique])
    }
}
