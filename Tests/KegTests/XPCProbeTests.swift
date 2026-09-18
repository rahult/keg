import XCTest
@testable import Keg
import ContainerAPIClient

/// Diagnostic probes: does the container-apiserver XPC service answer this
/// (unsigned, adhoc-signed) test binary? Determines whether the Docker API
/// server's XPC-backed routes (start/wait/exec/stats) can work in debug
/// builds or require a signed app bundle.
///
/// Both probes pre-flight the runtime with a CLI subprocess watchdog: a
/// wedged runtime (vmnet stuck after heavy churn) would otherwise block
/// the XPC send forever — task cancellation can't interrupt it.
final class XPCProbeTests: XCTestCase {
    /// True when the runtime answers a CLI call within `seconds`. Runs the
    /// CLI on a background thread with a hard wall-clock timeout.
    nonisolated static func runtimeIsResponsive(seconds: Double = 5) -> Bool {
        guard let binary = ContainerCLI.resolve() else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockIsolatedBool(false)
        Thread.detachNewThread {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["network", "list"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                process.waitUntilExit()
                box.set(process.terminationStatus == 0)
            }
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + seconds) == .success && box.wrappedValue
    }

    func testContainerListResponds() async throws {
        // CI runners have no runtime; wedged runtimes hang the XPC send.
        guard ContainerCLI.isInstalled else {
            throw XCTSkip("container CLI not installed")
        }
        guard Self.runtimeIsResponsive() else {
            throw XCTSkip("container runtime not responsive (wedged or starting)")
        }
        let client = ContainerClient()
        let containers = try await client.list()
        XCTAssertNotNil(containers)
    }

    /// bootstrap on a freshly created (not started) container is exactly
    /// what the Docker API start route does; it must reply, not hang.
    func testBootstrapRepliesOnCreatedContainer() async throws {
        guard ContainerCLI.isInstalled else {
            throw XCTSkip("container CLI not installed")
        }
        guard Self.runtimeIsResponsive() else {
            throw XCTSkip("container runtime not responsive (wedged or starting)")
        }
        let unique = "keg-xpc-probe-\(UUID().uuidString.prefix(6))"
        _ = try await ContainerCLI.run(["container", "create", "--name", unique, "alpine:latest", "sleep", "30"])
        do {
            let client = ContainerClient()
            let process = try await client.bootstrap(id: unique, stdio: [nil, nil, nil])
            try await process.start()
        } catch {
            _ = try? await ContainerCLI.run(["container", "delete", "-f", unique])
            throw error
        }
        _ = try? await ContainerCLI.run(["container", "delete", "-f", unique])
    }
}

/// Tiny thread-safe bool for the watchdog thread.
final class LockIsolatedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ newValue: Bool) {
        lock.lock(); value = newValue; lock.unlock()
    }
    var wrappedValue: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
