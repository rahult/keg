import XCTest

/// Reliability and edge-case tests for Meadow container operations.
/// These tests verify that Meadow handles error conditions gracefully without crashing.
///
/// Run with: MEADOW_RUN_CONTAINER_E2E=1 swift test --filter ReliabilityTests
final class ReliabilityTests: XCTestCase {

    private let testPrefix = "meadow-rel"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["MEADOW_RUN_CONTAINER_E2E"] == "1" else {
            throw XCTSkip("Set MEADOW_RUN_CONTAINER_E2E=1 to run container-backed reliability tests")
        }
        try await super.setUp()
        try await ensureSystemRunning()
    }

    override func tearDown() async throws {
        await cleanupTestResources()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func ensureSystemRunning() async throws {
        let (code, _) = try runProcess(["container", "system", "status", "--format", "json"])
        guard code == 0 else {
            throw XCTSkip("container system not running")
        }
    }

    /// Run a process and return (exitCode, combinedOutput).
    /// Also asserts the process did not terminate due to a signal (crash).
    private func runProcess(_ args: [String], file: StaticString = #file, line: UInt = #line) throws -> (Int32, String) {
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

        // Verify the process did not crash (uncaughtSignal means SIGABRT, SIGSEGV, etc.)
        XCTAssertNotEqual(
            process.terminationReason, .uncaughtSignal,
            "Process crashed with signal \(process.terminationStatus) — args: \(args). Output: \(output)",
            file: file, line: line
        )

        return (process.terminationStatus, output)
    }

    private func cleanupTestResources() async {
        let containers = [
            "\(testPrefix)-stop",
            "\(testPrefix)-rm",
            "\(testPrefix)-exec",
            "\(testPrefix)-invalid",
            "\(testPrefix)-longname-" + String(repeating: "a", count: 80),
        ]
        for name in containers {
            _ = try? runProcess(["container", "rm", "-f", name])
        }
    }

    // MARK: - Image Error Tests

    /// Pulling a non-existent image should return a non-zero exit code and an error message.
    func testPullNonExistentImage() throws {
        let (code, output) = try runProcess([
            "container", "image", "pull", "nonexistent-image-xyz:latest"
        ])

        XCTAssertNotEqual(code, 0, "Pulling a non-existent image should fail")
        XCTAssertFalse(output.isEmpty, "Should produce an error message")
        print("Pull non-existent image — exit code: \(code), output: \(output)")
    }

    // MARK: - Container Lifecycle Error Tests

    /// Stopping an already-stopped container should not crash.
    func testStopAlreadyStoppedContainer() async throws {
        let name = "\(testPrefix)-stop"

        // Start a container
        let (runCode, runOut) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sleep", "120"
        ])
        XCTAssertEqual(runCode, 0, "Container should start: \(runOut)")
        try await Task.sleep(for: .seconds(1))

        // First stop — should succeed
        let (stopCode1, stopOut1) = try runProcess(["container", "stop", name])
        XCTAssertEqual(stopCode1, 0, "First stop should succeed: \(stopOut1)")
        print("First stop — exit code: \(stopCode1), output: \(stopOut1)")

        // Second stop — should either succeed silently or return an error, but NOT crash
        let (stopCode2, stopOut2) = try runProcess(["container", "stop", name])
        print("Second stop — exit code: \(stopCode2), output: \(stopOut2)")
        // We only assert it didn't crash (checked inside runProcess); the exit code may vary.
    }

    /// Removing a running container without --force should fail with a helpful error.
    func testRemoveRunningContainerWithoutForce() async throws {
        let name = "\(testPrefix)-rm"

        // Start a container
        let (runCode, runOut) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sleep", "120"
        ])
        XCTAssertEqual(runCode, 0, "Container should start: \(runOut)")
        try await Task.sleep(for: .seconds(1))

        // Try removing without --force
        let (rmCode, rmOut) = try runProcess(["container", "rm", name])
        XCTAssertNotEqual(rmCode, 0, "Removing a running container without -f should fail")
        let lowered = rmOut.lowercased()
        let hasHelpfulMessage = lowered.contains("force") || lowered.contains("running") || lowered.contains("stop")
        XCTAssertTrue(hasHelpfulMessage, "Error should mention force/running/stop. Got: \(rmOut)")
        print("Remove running container — exit code: \(rmCode), output: \(rmOut)")

        // Clean up with force
        let (forceCode, _) = try runProcess(["container", "rm", "-f", name])
        XCTAssertEqual(forceCode, 0, "Force remove should succeed")
    }

    // MARK: - Inspect / Logs on Non-Existent Containers

    /// Inspecting a non-existent container should return non-zero, not crash.
    func testInspectNonExistentContainer() throws {
        let (code, output) = try runProcess([
            "container", "inspect", "nonexistent-container-xyz"
        ])

        XCTAssertNotEqual(code, 0, "Inspecting a non-existent container should fail")
        XCTAssertFalse(output.isEmpty, "Should produce an error message")
        print("Inspect non-existent — exit code: \(code), output: \(output)")
    }

    /// Running with an invalid image name should fail with a clear error.
    func testRunWithInvalidImage() throws {
        let (code, output) = try runProcess([
            "container", "run", "--name", "\(testPrefix)-invalid", "invalid!!!image"
        ])

        XCTAssertNotEqual(code, 0, "Running an invalid image should fail")
        XCTAssertFalse(output.isEmpty, "Should produce an error message")
        print("Run invalid image — exit code: \(code), output: \(output)")
    }

    /// Fetching logs for a non-existent container should return an error, not crash.
    func testLogsOnNonExistentContainer() throws {
        let (code, output) = try runProcess([
            "container", "logs", "nonexistent-container-xyz"
        ])

        XCTAssertNotEqual(code, 0, "Logs on a non-existent container should fail")
        XCTAssertFalse(output.isEmpty, "Should produce an error message")
        print("Logs non-existent — exit code: \(code), output: \(output)")
    }

    // MARK: - Exec on Stopped Container

    /// Exec on a stopped container should fail gracefully.
    func testExecOnStoppedContainer() async throws {
        let name = "\(testPrefix)-exec"

        // Start a container
        let (runCode, runOut) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sleep", "120"
        ])
        XCTAssertEqual(runCode, 0, "Container should start: \(runOut)")
        try await Task.sleep(for: .seconds(1))

        // Stop it
        let (stopCode, _) = try runProcess(["container", "stop", name])
        XCTAssertEqual(stopCode, 0, "Stop should succeed")

        // Try exec on the stopped container
        let (execCode, execOut) = try runProcess([
            "container", "exec", name, "echo", "hello"
        ])
        XCTAssertNotEqual(execCode, 0, "Exec on a stopped container should fail")
        XCTAssertFalse(execOut.isEmpty, "Should produce an error message")
        print("Exec on stopped — exit code: \(execCode), output: \(execOut)")
    }

    // MARK: - Volume Error Tests

    /// Deleting a non-existent volume should return an error, not crash.
    func testDeleteNonExistentVolume() throws {
        let (code, output) = try runProcess([
            "container", "volume", "rm", "nonexistent-volume-xyz"
        ])

        XCTAssertNotEqual(code, 0, "Deleting a non-existent volume should fail")
        XCTAssertFalse(output.isEmpty, "Should produce an error message")
        print("Delete non-existent volume — exit code: \(code), output: \(output)")
    }

    // MARK: - Edge Case Tests

    /// A container with a very long name (100 chars) should either work or fail clearly.
    func testContainerWithLongName() async throws {
        let longSuffix = String(repeating: "a", count: 80)
        let name = "\(testPrefix)-longname-\(longSuffix)"
        XCTAssertGreaterThanOrEqual(name.count, 100, "Name should be at least 100 characters")

        let (code, output) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sleep", "30"
        ])
        print("Long name container — exit code: \(code), output: \(output)")

        if code == 0 {
            // It worked — verify we can interact with it
            try await Task.sleep(for: .seconds(1))
            let (inspectCode, _) = try runProcess(["container", "inspect", name])
            XCTAssertEqual(inspectCode, 0, "Should be able to inspect a long-named container")
            print("Long name container created and inspectable")

            // Clean up
            _ = try? runProcess(["container", "rm", "-f", name])
        } else {
            // It failed — that's acceptable if the error is clear
            XCTAssertFalse(output.isEmpty, "Should produce an error about the name")
            print("Long name rejected with message: \(output)")
        }
    }
}
