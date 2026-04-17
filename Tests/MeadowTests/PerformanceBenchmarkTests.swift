import XCTest

/// Performance benchmark tests for Meadow container operations.
/// These tests measure wall-clock timing for core container lifecycle operations
/// and report results to stdout for regression tracking.
///
/// Run with: MEADOW_RUN_CONTAINER_E2E=1 swift test --filter PerformanceBenchmarkTests
final class PerformanceBenchmarkTests: XCTestCase {

    private let testPrefix = "meadow-bench"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["MEADOW_RUN_CONTAINER_E2E"] == "1" else {
            throw XCTSkip("Set MEADOW_RUN_CONTAINER_E2E=1 to run performance benchmark tests")
        }
        try await super.setUp()
        try await ensureSystemRunning()
    }

    override func tearDown() async throws {
        await cleanupAllBenchContainers()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func ensureSystemRunning() async throws {
        let (code, _) = try runProcess(["container", "system", "status", "--format", "json"])
        guard code == 0 else {
            throw XCTSkip("container system not running")
        }
    }

    @discardableResult
    private func runProcess(_ args: [String]) throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// Run a process and return (exitCode, output, elapsedSeconds)
    @discardableResult
    private func runProcessTimed(_ args: [String]) throws -> (Int32, String, Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let (code, output) = try runProcess(args)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return (code, output, elapsed)
    }

    private func cleanupAllBenchContainers() async {
        // Remove any containers matching our prefix pattern
        for i in 0..<10 {
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-start-\(i)"])
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-stop-\(i)"])
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-conc-\(i)"])
        }
        _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-exec"])
        for i in 0..<5 {
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-mem-\(i)"])
        }
    }

    private func formatMs(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private func printStats(label: String, times: [Double]) {
        guard !times.isEmpty else { return }
        let avg = times.reduce(0, +) / Double(times.count)
        let min = times.min()!
        let max = times.max()!
        print("  [BENCH] \(label): avg=\(formatMs(avg)), min=\(formatMs(min)), max=\(formatMs(max)), samples=\(times.count)")
    }

    // MARK: - Benchmarks

    /// Benchmark 1: Container start time - measure how long `container run -d` takes
    func testBenchContainerStartTime() async throws {
        let iterations = 5
        var times: [Double] = []

        print("\n=== Benchmark: Container Start Time ===")

        for i in 0..<iterations {
            let name = "\(testPrefix)-start-\(i)"
            let (code, _, elapsed) = try runProcessTimed([
                "container", "run", "-d",
                "--name", name,
                "alpine:latest",
                "sleep", "30"
            ])
            XCTAssertEqual(code, 0, "container run should succeed for iteration \(i)")
            times.append(elapsed)
            print("  Run \(i): \(formatMs(elapsed))")
        }

        printStats(label: "Container Start", times: times)

        // Cleanup
        for i in 0..<iterations {
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-start-\(i)"])
        }
    }

    /// Benchmark 2: Container stop time - start 5 containers then measure stop time for each
    func testBenchContainerStopTime() async throws {
        let iterations = 5
        var times: [Double] = []

        print("\n=== Benchmark: Container Stop Time ===")

        // Start all containers first
        for i in 0..<iterations {
            let name = "\(testPrefix)-stop-\(i)"
            let (code, output) = try runProcess([
                "container", "run", "-d",
                "--name", name,
                "alpine:latest",
                "sleep", "120"
            ])
            XCTAssertEqual(code, 0, "container start should succeed: \(output)")
        }

        // Wait for containers to be fully running
        try await Task.sleep(for: .seconds(1))

        // Measure stop time for each
        for i in 0..<iterations {
            let name = "\(testPrefix)-stop-\(i)"
            let (code, _, elapsed) = try runProcessTimed([
                "container", "stop", name
            ])
            XCTAssertEqual(code, 0, "container stop should succeed for \(name)")
            times.append(elapsed)
            print("  Stop \(i): \(formatMs(elapsed))")
        }

        printStats(label: "Container Stop", times: times)

        // Cleanup
        for i in 0..<iterations {
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-stop-\(i)"])
        }
    }

    /// Benchmark 3: Image pull time - remove alpine:3.18 if cached, then time pulling it
    /// Note: This test may be skipped if Docker Hub rate-limits unauthenticated pulls (429).
    func testBenchImagePullTime() async throws {
        let iterations = 3
        let imageRef = "alpine:3.18"
        var times: [Double] = []

        print("\n=== Benchmark: Image Pull Time (alpine:3.18) ===")

        for i in 0..<iterations {
            // Remove cached image first
            _ = try? runProcess(["container", "image", "rm", imageRef])
            try await Task.sleep(for: .milliseconds(500))

            let (code, output, elapsed) = try runProcessTimed([
                "container", "image", "pull", imageRef
            ])

            if code != 0 {
                if output.contains("429") || output.contains("Too Many Requests") || output.contains("TOOMANYREQUESTS") {
                    print("  Pull \(i): SKIPPED (Docker Hub rate limit 429)")
                    continue
                }
                XCTFail("image pull failed on iteration \(i) with unexpected error: \(output)")
                continue
            }
            times.append(elapsed)
            print("  Pull \(i): \(formatMs(elapsed))")
        }

        if times.isEmpty {
            print("  [BENCH] All pulls rate-limited by Docker Hub - benchmark skipped")
        } else {
            printStats(label: "Image Pull", times: times)
        }

        // Cleanup
        _ = try? runProcess(["container", "image", "rm", imageRef])
    }

    /// Benchmark 4: Container exec latency - start a container, then measure exec 10 times
    func testBenchContainerExecLatency() async throws {
        let iterations = 10
        let name = "\(testPrefix)-exec"
        var times: [Double] = []

        print("\n=== Benchmark: Container Exec Latency ===")

        // Start a long-running container
        let (runCode, runOutput) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sleep", "120"
        ])
        XCTAssertEqual(runCode, 0, "container start should succeed: \(runOutput)")
        try await Task.sleep(for: .seconds(1))

        for i in 0..<iterations {
            let (code, _, elapsed) = try runProcessTimed([
                "container", "exec", name,
                "echo", "hello"
            ])
            XCTAssertEqual(code, 0, "exec should succeed on iteration \(i)")
            times.append(elapsed)
            print("  Exec \(i): \(formatMs(elapsed))")
        }

        printStats(label: "Container Exec", times: times)

        // Cleanup
        _ = try? runProcess(["container", "rm", "-f", name])
    }

    /// Benchmark 5: System idle memory - check container runtime RSS when 0 containers are running
    func testBenchSystemIdleMemory() async throws {
        print("\n=== Benchmark: System Idle Memory ===")

        // Look for container runtime processes (container-apiserver, container-core-images, etc.)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", "ps aux | grep -E 'container-(apiserver|core-images|network-vmnet)|[K]eg\\.app' | grep -v grep | awk '{print $2, $6, $11}'"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("  [BENCH] No Meadow/container runtime processes found - skipping RSS measurement")
            print("  [BENCH] (This is informational only, not a pass/fail test)")
            return
        }

        // Parse RSS values from ps output (RSS is in KB in column 6)
        let lines = output.split(separator: "\n")
        var totalRSSKB: Int = 0
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 2)
            if parts.count >= 2, let rss = Int(parts[1]) {
                totalRSSKB += rss
                print("  [BENCH] PID \(parts[0]): RSS = \(rss) KB (\(String(format: "%.1f", Double(rss) / 1024.0)) MB) - \(parts.count > 2 ? String(parts[2]) : "unknown")")
            }
        }

        let totalMB = Double(totalRSSKB) / 1024.0
        print("  [BENCH] Total container runtime RSS (idle, 0 containers): \(String(format: "%.1f", totalMB)) MB")
        print("  [BENCH] (Informational only - not a pass/fail test)")
    }

    /// Benchmark 6: Per-container memory delta - measure memory with 0 vs 5 containers
    func testBenchPerContainerMemoryDelta() async throws {
        let containerCount = 5

        print("\n=== Benchmark: Per-Container Memory Delta ===")

        // Measure baseline memory (0 containers)
        let baselineMemory = try getSystemMemoryUsedMB()
        print("  [BENCH] Baseline memory (0 containers): \(String(format: "%.1f", baselineMemory)) MB")

        // Start 5 alpine containers
        for i in 0..<containerCount {
            let name = "\(testPrefix)-mem-\(i)"
            let (code, output) = try runProcess([
                "container", "run", "-d",
                "--name", name,
                "alpine:latest",
                "sleep", "120"
            ])
            XCTAssertEqual(code, 0, "container \(i) should start: \(output)")
        }

        // Wait for containers to stabilize
        try await Task.sleep(for: .seconds(2))

        // Measure memory with 5 containers
        let loadedMemory = try getSystemMemoryUsedMB()
        print("  [BENCH] Memory with \(containerCount) containers: \(String(format: "%.1f", loadedMemory)) MB")

        let delta = loadedMemory - baselineMemory
        let perContainer = delta / Double(containerCount)
        print("  [BENCH] Total delta: \(String(format: "%.1f", delta)) MB")
        print("  [BENCH] Per-container overhead: \(String(format: "%.1f", perContainer)) MB")

        // Cleanup
        for i in 0..<containerCount {
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-mem-\(i)"])
        }
    }

    /// Benchmark 7: Concurrent container starts - start 5 containers simultaneously
    func testBenchConcurrentContainerStarts() async throws {
        let containerCount = 5

        print("\n=== Benchmark: Concurrent Container Starts ===")

        let start = CFAbsoluteTimeGetCurrent()

        // Dispatch all container starts concurrently
        try await withThrowingTaskGroup(of: (Int, Int32, Double).self) { group in
            for i in 0..<containerCount {
                let name = "\(testPrefix)-conc-\(i)"
                group.addTask {
                    let taskStart = CFAbsoluteTimeGetCurrent()
                    let process = Process()
                    let pipe = Pipe()
                    process.executableURL = URL(filePath: "/usr/bin/env")
                    process.arguments = [
                        "container", "run", "-d",
                        "--name", name,
                        "alpine:latest",
                        "sleep", "30"
                    ]
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    _ = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let elapsed = CFAbsoluteTimeGetCurrent() - taskStart
                    return (i, process.terminationStatus, elapsed)
                }
            }

            for try await (i, code, elapsed) in group {
                XCTAssertEqual(code, 0, "concurrent container \(i) should start")
                print("  Container \(i): \(formatMs(elapsed))")
            }
        }

        let totalElapsed = CFAbsoluteTimeGetCurrent() - start
        print("  [BENCH] Total wall-clock for \(containerCount) concurrent starts: \(formatMs(totalElapsed))")
        print("  [BENCH] Average per container (wall-clock / count): \(formatMs(totalElapsed / Double(containerCount)))")

        // Cleanup
        for i in 0..<containerCount {
            _ = try? runProcess(["container", "rm", "-f", "\(testPrefix)-conc-\(i)"])
        }
    }

    // MARK: - Memory Measurement Helper

    /// Get approximate memory used by container runtime processes in MB.
    /// Measures RSS of container-apiserver, container-core-images, container-network-vmnet, and Meadow.app.
    /// Falls back to vm_stat active pages if no container processes are found.
    private func getSystemMemoryUsedMB() throws -> Double {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", "ps aux | grep -E 'container-(apiserver|core-images|network-vmnet)|[K]eg\\.app' | grep -v grep | awk '{sum += $6} END {print sum}'"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let rssKB = Double(output), rssKB > 0 {
            return rssKB / 1024.0
        }

        // Fallback: use vm_stat to get overall active memory pressure
        let vmProcess = Process()
        let vmPipe = Pipe()
        vmProcess.executableURL = URL(filePath: "/usr/bin/vm_stat")
        vmProcess.standardOutput = vmPipe
        vmProcess.standardError = vmPipe
        try vmProcess.run()
        let vmData = vmPipe.fileHandleForReading.readDataToEndOfFile()
        vmProcess.waitUntilExit()
        let vmOutput = String(data: vmData, encoding: .utf8) ?? ""

        // Parse "Pages active" line - each page is 16384 bytes on Apple Silicon
        var activePages: Double = 0
        for line in vmOutput.split(separator: "\n") {
            if line.contains("Pages active") {
                let parts = line.split(separator: ":")
                if parts.count == 2 {
                    let numStr = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
                    activePages = Double(numStr) ?? 0
                }
            }
        }

        // Assume 16KB pages (Apple Silicon)
        return (activePages * 16384) / (1024 * 1024)
    }
}
