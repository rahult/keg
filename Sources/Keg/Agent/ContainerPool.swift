import Foundation

/// Container Pool Manager - warm microVM pooling for agent command execution
///
/// Key insight from benchmark:
/// - Cold start: ~650ms
/// - Warm exec: ~18ms (35x faster)
///
/// This pool keeps containers warm and reuses them via exec.
///
/// All `container` invocations go through the injected `runner`, which
/// defaults to `ContainerCLI.run` (pins CONTAINER_APP_ROOT per the house
/// rule and bounds every call with a timeout). Tests inject a fake.
actor ContainerPool {
    /// Pool configuration
    struct Config {
        var minSize: Int = 2
        var maxSize: Int = 10
        var idleTimeout: TimeInterval = 300 // 5 minutes
        var image: String = "alpine:latest"

        init(minSize: Int = 2, maxSize: Int = 10, idleTimeout: TimeInterval = 300, image: String = "alpine:latest") {
            self.minSize = minSize
            self.maxSize = maxSize
            self.idleTimeout = idleTimeout
            self.image = image
        }
    }

    /// Runs one `container` CLI invocation: argv in, (exit code, output) out.
    typealias Runner = @Sendable ([String]) async throws -> (Int32, String)

    /// Container in the pool
    struct PooledContainer: Identifiable {
        let id: String
        let name: String
        var lastUsed: Date
        var isReady: Bool

        init(name: String) {
            self.id = UUID().uuidString
            self.name = name
            self.lastUsed = Date()
            self.isReady = true
        }
    }

    private var config: Config
    private var containers: [PooledContainer] = []
    private var containerCounter = 0
    private var stats = Stats()
    private let runner: Runner

    struct Stats {
        var totalExecutions = 0
        var warmHits = 0
        var coldStarts = 0
        var averageExecMs: Double = 0
        var totalExecMs: Double = 0
    }

    init(config: Config = Config(), runner: @escaping Runner = { try await ContainerCLI.run($0) }) {
        self.config = config
        self.runner = runner
    }

    // MARK: - Arg construction (unit-tested)

    static func createArgs(name: String, image: String) -> [String] {
        ["create", "--name", name, image, "sh"]
    }

    static func startArgs(name: String) -> [String] {
        ["start", name]
    }

    static func execArgs(name: String, command: String) -> [String] {
        ["exec", name, "sh", "-c", command]
    }

    static func rmArgs(name: String) -> [String] {
        ["rm", "-f", name]
    }

    // MARK: - Public API

    /// Execute a command in a warm container
    func exec(command: String) async throws -> ExecResult {
        let startTime = Date()

        // Get or create a warm container
        let container: PooledContainer
        if let warm = containers.first(where: { $0.isReady }) {
            container = warm
            stats.warmHits += 1
        } else {
            container = try await createWarmContainer()
            containers.append(container)
            stats.coldStarts += 1
        }

        // Execute the command
        let (_, output) = try await runner(Self.execArgs(name: container.name, command: command))

        // Update last used
        if let index = containers.firstIndex(where: { $0.name == container.name }) {
            containers[index].lastUsed = Date()
        }

        // Update stats
        stats.totalExecutions += 1
        let duration = Date().timeIntervalSince(startTime) * 1000
        stats.totalExecMs += duration
        stats.averageExecMs = stats.totalExecMs / Double(stats.totalExecutions)

        return ExecResult(
            stdout: output,
            stderr: "",
            exitCode: 0
        )
    }

    /// Get pool statistics
    func getStats() -> PoolStats {
        PoolStats(
            poolSize: containers.count,
            readyContainers: containers.filter { $0.isReady }.count,
            totalExecutions: stats.totalExecutions,
            warmHits: stats.warmHits,
            coldStarts: stats.coldStarts,
            averageExecMs: stats.averageExecMs
        )
    }

    /// Pre-warm the pool
    func prewarm() async throws {
        while containers.count < config.minSize {
            let container = try await createWarmContainer()
            containers.append(container)
        }
    }

    /// Cleanup idle containers
    func cleanup(now: Date = Date()) async {
        let idle = containers.filter { now.timeIntervalSince($0.lastUsed) > config.idleTimeout }
        guard !idle.isEmpty else { return }
        for container in idle {
            try? await runner(Self.rmArgs(name: container.name))
        }
        let idleNames = Set(idle.map(\.name))
        containers.removeAll { idleNames.contains($0.name) }
    }

    // MARK: - Private

    private func createWarmContainer() async throws -> PooledContainer {
        containerCounter += 1
        let name = "agent-pool-\(containerCounter)"

        _ = try await runner(Self.createArgs(name: name, image: config.image))
        _ = try await runner(Self.startArgs(name: name))

        // Small delay for stability
        try await Task.sleep(for: .milliseconds(200))

        return PooledContainer(name: name)
    }
}

// MARK: - Types

struct ExecResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct PoolStats {
    let poolSize: Int
    let readyContainers: Int
    let totalExecutions: Int
    let warmHits: Int
    let coldStarts: Int
    let averageExecMs: Double

    var warmHitRate: Double {
        guard totalExecutions > 0 else { return 0 }
        return Double(warmHits) / Double(totalExecutions) * 100
    }
}
