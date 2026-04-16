import XCTest
import ContainerAPIClient
import ContainerResource

/// Shadow tests for Docker-compatible container operations.
/// These tests exercise the full container lifecycle using real container CLI commands,
/// verifying that Keg's container platform works end-to-end with practical examples.
///
/// Run with: KEG_RUN_CONTAINER_E2E=1 swift test --filter DockerShadowTests
final class DockerShadowTests: XCTestCase {

    private let testPrefix = "keg-shadow"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_CONTAINER_E2E"] == "1" else {
            throw XCTSkip("Set KEG_RUN_CONTAINER_E2E=1 to run container-backed shadow tests")
        }
        try await super.setUp()
        try await ensureSystemRunning()
    }

    override func tearDown() async throws {
        // Clean up any leftover test containers
        await cleanupTestContainers()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func ensureSystemRunning() async throws {
        let (code, _) = try runProcess(["container", "system", "status", "--format", "json"])
        guard code == 0 else {
            throw XCTSkip("container system not running")
        }
    }

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

    private func cleanupTestContainers() async {
        let names = [
            "\(testPrefix)-nginx",
            "\(testPrefix)-alpine",
            "\(testPrefix)-env",
            "\(testPrefix)-ports",
            "\(testPrefix)-logs",
            "\(testPrefix)-exec",
            "\(testPrefix)-restart",
            "\(testPrefix)-redis",
            "\(testPrefix)-postgres",
            "\(testPrefix)-multi-1",
            "\(testPrefix)-multi-2",
        ]
        for name in names {
            _ = try? runProcess(["container", "rm", "-f", name])
        }
        // Clean up test volumes and networks
        _ = try? runProcess(["container", "volume", "rm", "\(testPrefix)-data"])
        _ = try? runProcess(["container", "network", "rm", "\(testPrefix)-net"])
    }

    // MARK: - Container Lifecycle Tests

    /// Test: Run nginx web server, verify it starts and serves HTTP
    func testRunNginxWebServer() async throws {
        let name = "\(testPrefix)-nginx"

        // Run nginx in detached mode with port mapping
        let (runCode, runOut) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "-p", "18080:80",
            "nginx:latest"
        ])
        XCTAssertEqual(runCode, 0, "nginx container should start: \(runOut)")
        print("✅ Started nginx container: \(name)")

        // Wait for container to be ready
        try await Task.sleep(for: .seconds(2))

        // Verify container is running via API
        let client = ContainerClient()
        let container = try await client.get(id: name)
        XCTAssertEqual(container.status, .running, "nginx should be running")
        print("✅ nginx is running, image: \(container.configuration.image.reference)")

        // Verify container appears in list
        let all = try await client.list(filters: .all)
        let found = all.contains { $0.id == name || $0.id.contains(name) }
        XCTAssertTrue(found, "nginx should appear in container list")
        print("✅ nginx visible in container list")

        // Get resource stats
        let stats = try await client.stats(id: name)
        XCTAssertNotNil(stats.memoryUsageBytes, "should have memory stats")
        print("✅ Stats: mem=\(stats.memoryUsageBytes ?? 0) bytes")

        // Stop container
        try await client.stop(id: name)
        let stopped = try await client.get(id: name)
        XCTAssertNotEqual(stopped.status, .running, "nginx should be stopped")
        print("✅ nginx stopped")

        // Remove container
        try await client.delete(id: name, force: true)
        print("✅ nginx removed")
    }

    /// Test: Run alpine with environment variables and verify they're set
    func testContainerWithEnvironmentVariables() async throws {
        let name = "\(testPrefix)-env"

        let (code, output) = try runProcess([
            "container", "run",
            "--name", name,
            "-e", "MY_VAR=hello_keg",
            "-e", "DB_HOST=localhost",
            "alpine:latest",
            "env"
        ])
        XCTAssertEqual(code, 0, "env command should succeed: \(output)")
        XCTAssertTrue(output.contains("MY_VAR=hello_keg"), "MY_VAR should be set")
        XCTAssertTrue(output.contains("DB_HOST=localhost"), "DB_HOST should be set")
        print("✅ Environment variables passed correctly")
    }

    /// Test: Container logs capture stdout/stderr
    func testContainerLogs() async throws {
        let name = "\(testPrefix)-logs"

        // Run a container that outputs to both stdout and stderr
        let (runCode, _) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sh", "-c", "echo 'stdout-line-1' && echo 'stdout-line-2' && echo 'stderr-line' >&2 && sleep 30"
        ])
        XCTAssertEqual(runCode, 0)

        // Wait for output
        try await Task.sleep(for: .seconds(1))

        // Fetch logs
        let (logCode, logOutput) = try runProcess([
            "container", "logs", name
        ])
        XCTAssertEqual(logCode, 0)
        XCTAssertTrue(logOutput.contains("stdout-line-1"), "should capture stdout line 1")
        XCTAssertTrue(logOutput.contains("stdout-line-2"), "should capture stdout line 2")
        print("✅ Logs captured: \(logOutput.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Cleanup
        _ = try? runProcess(["container", "rm", "-f", name])
    }

    /// Test: Execute command inside a running container
    func testContainerExec() async throws {
        let name = "\(testPrefix)-exec"

        // Start a long-running container
        let (runCode, _) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sleep", "120"
        ])
        XCTAssertEqual(runCode, 0)
        try await Task.sleep(for: .seconds(1))

        // Exec a command inside it
        let (execCode, execOutput) = try runProcess([
            "container", "exec", name,
            "cat", "/etc/os-release"
        ])
        XCTAssertEqual(execCode, 0, "exec should succeed: \(execOutput)")
        XCTAssertTrue(execOutput.contains("Alpine"), "should be Alpine Linux")
        print("✅ Exec inside container works: Alpine detected")

        // Exec another command: write and read a file
        let (writeCode, _) = try runProcess([
            "container", "exec", name,
            "sh", "-c", "echo 'keg-test' > /tmp/keg-test.txt"
        ])
        XCTAssertEqual(writeCode, 0)

        let (readCode, readOutput) = try runProcess([
            "container", "exec", name,
            "cat", "/tmp/keg-test.txt"
        ])
        XCTAssertEqual(readCode, 0)
        XCTAssertTrue(readOutput.contains("keg-test"), "file content should match")
        print("✅ File write/read via exec works")

        _ = try? runProcess(["container", "rm", "-f", name])
    }

    /// Test: Stop and restart a container
    func testContainerStopAndRestart() async throws {
        let name = "\(testPrefix)-restart"

        // Start container
        let (runCode, _) = try runProcess([
            "container", "run", "-d",
            "--name", name,
            "alpine:latest",
            "sleep", "120"
        ])
        XCTAssertEqual(runCode, 0)

        let client = ContainerClient()

        // Verify running
        try await Task.sleep(for: .seconds(1))
        let running = try await client.get(id: name)
        XCTAssertEqual(running.status, .running)
        print("✅ Container running")

        // Stop
        try await client.stop(id: name)
        let stopped = try await client.get(id: name)
        XCTAssertNotEqual(stopped.status, .running)
        print("✅ Container stopped")

        // Restart
        let (restartCode, _) = try runProcess(["container", "start", name])
        XCTAssertEqual(restartCode, 0)

        try await Task.sleep(for: .seconds(1))
        let restarted = try await client.get(id: name)
        XCTAssertEqual(restarted.status, .running)
        print("✅ Container restarted successfully")

        _ = try? runProcess(["container", "rm", "-f", name])
    }

    // MARK: - Image Tests

    /// Test: Pull, inspect, and delete an image
    func testImageLifecycle() async throws {
        let ref = "busybox:latest"

        // Pull
        let normalized = try ClientImage.normalizeReference(ref)
        let image = try await ClientImage.pull(reference: normalized)
        XCTAssertFalse(image.reference.isEmpty)
        print("✅ Pulled image: \(image.reference)")

        // List and verify it exists
        let images = try await ClientImage.list()
        let found = images.contains { $0.reference.contains("busybox") }
        XCTAssertTrue(found, "busybox should be in image list")
        print("✅ Image visible in list")

        // Delete
        let (delCode, _) = try runProcess(["container", "image", "rm", ref])
        XCTAssertEqual(delCode, 0)
        print("✅ Image deleted")
    }

    /// Test: Pull multiple images and verify counts
    func testMultipleImagePull() async throws {
        let refs = ["alpine:3.19", "alpine:3.20"]

        for ref in refs {
            let normalized = try ClientImage.normalizeReference(ref)
            let image = try await ClientImage.pull(reference: normalized)
            XCTAssertFalse(image.reference.isEmpty)
            print("✅ Pulled \(ref)")
        }

        let images = try await ClientImage.list()
        let alpineCount = images.filter { $0.reference.contains("alpine") }.count
        XCTAssertGreaterThanOrEqual(alpineCount, 2, "should have at least 2 alpine images")
        print("✅ Multiple images present: \(alpineCount) alpine variants")

        // Cleanup
        for ref in refs {
            _ = try? runProcess(["container", "image", "rm", ref])
        }
    }

    // MARK: - Network Tests

    /// Test: Create, list, and delete a custom network
    func testNetworkCRUD() async throws {
        let name = "\(testPrefix)-net"

        // Create network
        let (createCode, createOut) = try runProcess([
            "container", "network", "create", name
        ])
        XCTAssertEqual(createCode, 0, "network create should succeed: \(createOut)")
        print("✅ Created network: \(name)")

        // List and verify
        let networks = try await ClientNetwork.list()
        let found = networks.contains { $0.id == name }
        XCTAssertTrue(found, "network should appear in list")
        print("✅ Network visible in list")

        // Delete
        let (delCode, _) = try runProcess(["container", "network", "rm", name])
        XCTAssertEqual(delCode, 0)
        print("✅ Network deleted")
    }

    /// Test: Run container on a custom network
    func testContainerOnCustomNetwork() async throws {
        let netName = "\(testPrefix)-net"
        let containerName = "\(testPrefix)-alpine"

        // Create network
        _ = try runProcess(["container", "network", "create", netName])

        // Run container on that network
        let (runCode, _) = try runProcess([
            "container", "run", "-d",
            "--name", containerName,
            "--network", netName,
            "alpine:latest",
            "sleep", "30"
        ])
        XCTAssertEqual(runCode, 0)
        print("✅ Container running on custom network")

        // Verify via inspect
        let (inspectCode, inspectOut) = try runProcess([
            "container", "inspect", containerName
        ])
        XCTAssertEqual(inspectCode, 0, "inspect should succeed: \(inspectOut.prefix(200))")
        print("✅ Container on custom network verified via inspect")

        // Cleanup
        _ = try? runProcess(["container", "rm", "-f", containerName])
        _ = try? runProcess(["container", "network", "rm", netName])
    }

    // MARK: - Volume Tests

    /// Test: Create a volume, mount it, write data, verify persistence
    func testVolumePersistence() async throws {
        let volName = "\(testPrefix)-data"
        let container1 = "\(testPrefix)-multi-1"
        let container2 = "\(testPrefix)-multi-2"

        // Create volume
        let vol = try await ClientVolume.create(name: volName)
        XCTAssertEqual(vol.name, volName)
        print("✅ Created volume: \(volName)")

        // Run container 1: write data to volume
        let (writeCode, writeOut) = try runProcess([
            "container", "run",
            "--name", container1,
            "-v", "\(volName):/data",
            "alpine:latest",
            "sh", "-c", "echo 'persistent-data-from-keg' > /data/test.txt"
        ])
        XCTAssertEqual(writeCode, 0, "write container should succeed: \(writeOut)")
        print("✅ Container 1 wrote data to volume")

        // Run container 2: read data from same volume
        let (readCode, readOut) = try runProcess([
            "container", "run",
            "--name", container2,
            "-v", "\(volName):/data",
            "alpine:latest",
            "cat", "/data/test.txt"
        ])
        XCTAssertEqual(readCode, 0, "read container should succeed: \(readOut)")
        XCTAssertTrue(readOut.contains("persistent-data-from-keg"), "data should persist across containers")
        print("✅ Container 2 read persisted data: \(readOut.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Cleanup
        _ = try? runProcess(["container", "rm", "-f", container1])
        _ = try? runProcess(["container", "rm", "-f", container2])
        try await ClientVolume.delete(name: volName)
        print("✅ Volume cleaned up")
    }

    // MARK: - Docker API Compatibility Tests

    /// Test: Docker API server starts and responds to health check
    func testDockerAPIHealth() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_DOCKER_API"] == "1" else {
            throw XCTSkip("Set KEG_RUN_DOCKER_API=1 to run Docker API tests (requires Keg app running with Docker API enabled)")
        }

        let socketPath = "\(NSHomeDirectory())/.keg/docker.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Docker API socket not found at \(socketPath)")
        }

        // Use curl to hit the Docker API via Unix socket
        let (code, output) = try runProcess([
            "curl", "--unix-socket", socketPath,
            "-s", "http://localhost/_ping"
        ])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(output.contains("OK"), "Docker API should respond OK to _ping")
        print("✅ Docker API health: OK")
    }

    /// Test: Docker API /containers/json returns valid JSON
    func testDockerAPIListContainers() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_DOCKER_API"] == "1" else {
            throw XCTSkip("Set KEG_RUN_DOCKER_API=1 to run Docker API tests")
        }

        let socketPath = "\(NSHomeDirectory())/.keg/docker.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Docker API socket not found")
        }

        let (code, output) = try runProcess([
            "curl", "--unix-socket", socketPath,
            "-s", "http://localhost/containers/json?all=true"
        ])
        XCTAssertEqual(code, 0)

        // Should be valid JSON array
        guard let data = output.data(using: .utf8) else {
            XCTFail("Output is not valid UTF-8")
            return
        }
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Should be a JSON array")
        print("✅ Docker API /containers/json returned valid JSON array")
    }

    /// Test: Docker API /images/json returns valid JSON
    func testDockerAPIListImages() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_DOCKER_API"] == "1" else {
            throw XCTSkip("Set KEG_RUN_DOCKER_API=1 to run Docker API tests")
        }

        let socketPath = "\(NSHomeDirectory())/.keg/docker.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Docker API socket not found")
        }

        let (code, output) = try runProcess([
            "curl", "--unix-socket", socketPath,
            "-s", "http://localhost/images/json"
        ])
        XCTAssertEqual(code, 0)

        guard let data = output.data(using: .utf8) else {
            XCTFail("Output is not valid UTF-8")
            return
        }
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Should be a JSON array")
        print("✅ Docker API /images/json returned valid JSON array")
    }

    /// Test: Docker API /info returns system info
    func testDockerAPISystemInfo() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_DOCKER_API"] == "1" else {
            throw XCTSkip("Set KEG_RUN_DOCKER_API=1 to run Docker API tests")
        }

        let socketPath = "\(NSHomeDirectory())/.keg/docker.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Docker API socket not found")
        }

        let (code, output) = try runProcess([
            "curl", "--unix-socket", socketPath,
            "-s", "http://localhost/info"
        ])
        XCTAssertEqual(code, 0)

        guard let data = output.data(using: .utf8) else {
            XCTFail("Output is not valid UTF-8")
            return
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "Should be a JSON object")
        XCTAssertNotNil(json?["OperatingSystem"], "Should have OperatingSystem field")
        print("✅ Docker API /info: OS=\(json?["OperatingSystem"] ?? "unknown")")
    }

    /// Test: Docker API /networks returns valid data
    func testDockerAPIListNetworks() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_DOCKER_API"] == "1" else {
            throw XCTSkip("Set KEG_RUN_DOCKER_API=1 to run Docker API tests")
        }

        let socketPath = "\(NSHomeDirectory())/.keg/docker.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Docker API socket not found")
        }

        let (code, output) = try runProcess([
            "curl", "--unix-socket", socketPath,
            "-s", "http://localhost/networks"
        ])
        XCTAssertEqual(code, 0)

        guard let data = output.data(using: .utf8) else {
            XCTFail("Output is not valid UTF-8")
            return
        }
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Should be a JSON array")
        print("✅ Docker API /networks returned valid JSON")
    }

    // MARK: - Practical Workflow Tests

    /// Test: Run a real-world web app stack (nginx + alpine worker)
    func testMultiContainerWorkflow() async throws {
        let webName = "\(testPrefix)-nginx"
        let workerName = "\(testPrefix)-alpine"

        // Start web server
        let (webCode, _) = try runProcess([
            "container", "run", "-d",
            "--name", webName,
            "-p", "18081:80",
            "nginx:latest"
        ])
        XCTAssertEqual(webCode, 0)

        // Start worker
        let (workerCode, _) = try runProcess([
            "container", "run", "-d",
            "--name", workerName,
            "alpine:latest",
            "sleep", "120"
        ])
        XCTAssertEqual(workerCode, 0)

        try await Task.sleep(for: .seconds(1))

        // Both should be running
        let client = ContainerClient()
        let running = try await client.list(filters: ContainerListFilters(status: .running))
        let runningIDs = running.map { $0.id }
        XCTAssertTrue(runningIDs.contains(webName) || running.contains { $0.id.contains("nginx") })
        XCTAssertTrue(runningIDs.contains(workerName) || running.contains { $0.id.contains("alpine") })
        print("✅ Multi-container stack running: web + worker")

        // Stop both
        try await client.stop(id: webName)
        try await client.stop(id: workerName)
        print("✅ Both containers stopped")

        // Remove both
        try await client.delete(id: webName, force: true)
        try await client.delete(id: workerName, force: true)
        print("✅ Both containers removed")
    }
}
