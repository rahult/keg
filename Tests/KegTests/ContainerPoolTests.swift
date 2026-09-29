import XCTest
@testable import Keg

final class ContainerPoolTests: XCTestCase {

    /// Records every argv handed to the runner and returns canned output.
    private final class FakeRunner: @unchecked Sendable {
        var calls: [[String]] = []
        var result: (Int32, String) = (0, "ok")
    }

    private func makePool(
        config: ContainerPool.Config = ContainerPool.Config(),
        runner: @escaping @Sendable ([String]) async throws -> (Int32, String)
    ) -> ContainerPool {
        ContainerPool(config: config, runner: runner)
    }

    // MARK: - Arg shape

    func testCreateArgsCarryNameImageAndShell() {
        XCTAssertEqual(
            ContainerPool.createArgs(name: "agent-pool-1", image: "alpine:latest"),
            ["create", "--name", "agent-pool-1", "alpine:latest", "sh"]
        )
    }

    func testStartArgsReferenceName() {
        XCTAssertEqual(ContainerPool.startArgs(name: "agent-pool-2"), ["start", "agent-pool-2"])
    }

    func testExecArgsWrapCommandInShell() {
        XCTAssertEqual(
            ContainerPool.execArgs(name: "agent-pool-3", command: "ls -la"),
            ["exec", "agent-pool-3", "sh", "-c", "ls -la"]
        )
    }

    func testRmArgsForceRemove() {
        XCTAssertEqual(ContainerPool.rmArgs(name: "agent-pool-4"), ["rm", "-f", "agent-pool-4"])
    }

    // MARK: - Pooling behavior (injected runner — no real containers)

    func testColdStartCreatesStartsThenExecs() async throws {
        let fake = FakeRunner()
        let pool = makePool { args in
            fake.calls.append(args)
            return fake.result
        }

        _ = try await pool.exec(command: "echo hi")

        XCTAssertEqual(fake.calls.map(\.first), ["create", "start", "exec"])
        let stats = await pool.getStats()
        XCTAssertEqual(stats.coldStarts, 1)
        XCTAssertEqual(stats.warmHits, 0)
        XCTAssertEqual(stats.totalExecutions, 1)
    }

    func testSecondExecReusesWarmContainer() async throws {
        let fake = FakeRunner()
        let pool = makePool { args in
            fake.calls.append(args)
            return fake.result
        }

        _ = try await pool.exec(command: "one")
        _ = try await pool.exec(command: "two")

        XCTAssertEqual(fake.calls.filter { $0.first == "create" }.count, 1)
        let stats = await pool.getStats()
        XCTAssertEqual(stats.warmHits, 1)
        XCTAssertEqual(stats.coldStarts, 1)
        XCTAssertEqual(stats.warmHitRate, 50)
    }

    func testPrewarmFillsPoolToMinSize() async throws {
        let fake = FakeRunner()
        let pool = makePool(config: ContainerPool.Config(minSize: 2, maxSize: 4)) { args in
            fake.calls.append(args)
            return fake.result
        }

        try await pool.prewarm()

        XCTAssertEqual(fake.calls.filter { $0.first == "create" }.count, 2)
        let stats = await pool.getStats()
        XCTAssertEqual(stats.readyContainers, 2)
    }

    func testCleanupRemovesIdleContainers() async throws {
        let fake = FakeRunner()
        let pool = makePool(config: ContainerPool.Config(idleTimeout: 60)) { args in
            fake.calls.append(args)
            return fake.result
        }

        _ = try await pool.exec(command: "work")
        await pool.cleanup(now: Date().addingTimeInterval(120))

        XCTAssertTrue(fake.calls.contains(ContainerPool.rmArgs(name: "agent-pool-1")))
        let stats = await pool.getStats()
        XCTAssertEqual(stats.poolSize, 0)
    }

    func testCleanupKeepsRecentlyUsedContainers() async throws {
        let fake = FakeRunner()
        let pool = makePool(config: ContainerPool.Config(idleTimeout: 300)) { args in
            fake.calls.append(args)
            return fake.result
        }

        _ = try await pool.exec(command: "work")
        await pool.cleanup(now: Date().addingTimeInterval(10))

        let stats = await pool.getStats()
        XCTAssertEqual(stats.poolSize, 1)
    }
}
