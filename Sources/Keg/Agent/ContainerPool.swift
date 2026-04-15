import Foundation

/// Container Pool Manager - Firecracker-like VM pooling for agents
/// 
/// Key insight from benchmark:
/// - Cold start: ~650ms
/// - Warm exec: ~18ms (35x faster)
/// 
/// This pool keeps containers warm and reuses them via exec.
actor ContainerPool {
    /// Pool configuration
    struct Config {
        var minSize: Int = 2
        var maxSize: Int = 10
        var idleTimeout: TimeInterval = 300 // 5 minutes
        var image: String = "alpine:latest"
    }
    
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
    
    struct Stats {
        var totalExecutions = 0
        var warmHits = 0
        var coldStarts = 0
        var averageExecMs: Double = 0
        var totalExecMs: Double = 0
    }
    
    init(config: Config = Config()) {
        self.config = config
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
            stats.coldStarts += 1
        }
        
        // Execute the command
        let result = try await executeInContainer(name: container.name, command: command)
        
        // Update stats
        stats.totalExecutions += 1
        let duration = Date().timeIntervalSince(startTime) * 1000
        stats.totalExecMs += duration
        stats.averageExecMs = stats.totalExecMs / Double(stats.totalExecutions)
        
        return result
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
    func cleanup() async {
        let now = Date()
        containers.removeAll { container in
            let idle = now.timeIntervalSince(container.lastUsed) > config.idleTimeout
            if idle {
                Task {
                    await deleteContainer(name: container.name)
                }
            }
            return idle
        }
    }
    
    // MARK: - Private
    
    private func createWarmContainer() async throws -> PooledContainer {
        containerCounter += 1
        let name = "agent-pool-\(containerCounter)"
        
        // Create container
        try await runCommand("/usr/bin/env", args: ["container", "create", "--name", name, config.image, "sh"])
        
        // Start container
        try await runCommand("/usr/bin/env", args: ["container", "start", name])
        
        // Small delay for stability
        try await Task.sleep(for: .milliseconds(200))
        
        return PooledContainer(name: name)
    }
    
    private func executeInContainer(name: String, command: String) async throws -> ExecResult {
        let output = try await runCommand(
            "/usr/bin/env",
            args: ["container", "exec", name, "sh", "-c", command]
        )
        
        // Update last used
        if let index = containers.firstIndex(where: { $0.name == name }) {
            containers[index].lastUsed = Date()
        }
        
        return ExecResult(
            stdout: output,
            stderr: "",
            exitCode: 0
        )
    }
    
    private func deleteContainer(name: String) async {
        try? await runCommand("/usr/bin/env", args: ["container", "rm", "-f", name])
    }
    
    private func runCommand(_ path: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                continuation.resume(returning: output)
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
