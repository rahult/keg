import Foundation
import XCTest

/// Benchmark tests for Docker CLI compatibility via Keg's Docker API socket.
/// These tests verify that standard Docker CLI commands work through
/// Keg's Unix socket at ~/.keg/docker.sock using curl as the transport.
///
/// Run with: KEG_RUN_DOCKER_API=1 swift test --filter DockerCLIBenchmarkTests
final class DockerCLIBenchmarkTests: XCTestCase {

    private let socketPath = "\(NSHomeDirectory())/.keg/docker.sock"
    private let testContainerName = "keg-bench-cli-test"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_DOCKER_API"] == "1" else {
            throw XCTSkip("Set KEG_RUN_DOCKER_API=1 to run Docker CLI benchmark tests")
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("Docker API socket not found at \(socketPath)")
        }
        // Verify the socket is actually accepting connections
        let (pingCode, _) = try pingSocket()
        guard pingCode == 0 else {
            throw XCTSkip("Docker API socket exists but is not responding (Keg Docker API server may not be running)")
        }
        try await super.setUp()
    }

    override func tearDown() async throws {
        // Clean up the test container if it exists
        if ProcessInfo.processInfo.environment["KEG_RUN_DOCKER_API"] == "1" {
            _ = try? curlSocket("http://localhost/containers/\(testContainerName)/stop", method: "POST")
            _ = try? curlSocket("http://localhost/containers/\(testContainerName)?force=true", method: "DELETE")
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Quick connectivity check against the socket.
    private func pingSocket() throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "curl", "--unix-socket", socketPath,
            "-s", "--max-time", "2",
            "http://localhost/_ping"
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func runProcess(_ args: [String], environment: [String: String]? = nil) throws -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// Execute a curl request against the Docker API Unix socket.
    /// Returns (exitCode, responseBody).
    @discardableResult
    private func curlSocket(
        _ url: String,
        method: String = "GET",
        body: String? = nil
    ) throws -> (Int32, String) {
        var args = [
            "curl", "--unix-socket", socketPath,
            "-s", "-X", method
        ]
        if let body {
            args += ["-H", "Content-Type: application/json", "-d", body]
        }
        args.append(url)
        return try runProcess(args)
    }

    /// Parse a JSON response body, failing the test if it is not valid JSON.
    private func parseJSON(_ body: String, file: StaticString = #file, line: UInt = #line) -> Any? {
        guard let data = body.data(using: .utf8) else {
            XCTFail("Response is not valid UTF-8", file: file, line: line)
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            XCTFail("Response is not valid JSON: \(error) — body: \(body.prefix(500))", file: file, line: line)
            return nil
        }
    }

    /// Try running a docker CLI command via DOCKER_HOST. Returns nil if docker CLI is unavailable.
    private func tryDockerCLI(_ args: [String]) -> (Int32, String)? {
        let dockerHost = "unix://\(socketPath)"
        let fullArgs = ["docker"] + args
        guard let result = try? runProcess(fullArgs, environment: ["DOCKER_HOST": dockerHost]) else {
            return nil
        }
        // Exit code 127 or "not found" means docker CLI is not installed
        if result.0 == 127 || result.1.contains("not found") {
            return nil
        }
        return result
    }

    /// Measure and print timing for a named operation.
    private func timed<T>(_ label: String, block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("  \(label): \(String(format: "%.1f", elapsed))ms")
        return result
    }

    // MARK: - 1. docker ps → GET /containers/json

    func testDockerPS() throws {
        print("--- docker ps ---")

        let (code, output) = try timed("curl /containers/json") {
            try curlSocket("http://localhost/containers/json")
        }
        XCTAssertEqual(code, 0, "curl should succeed")

        let json = parseJSON(output)
        XCTAssertTrue(json is [Any], "/containers/json should return a JSON array")
        print("  containers (running): \((json as? [Any])?.count ?? 0)")

        if let cli = timed("docker ps (CLI)", block: { tryDockerCLI(["ps", "--format", "json"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 2. docker ps -a → GET /containers/json?all=true

    func testDockerPSAll() throws {
        print("--- docker ps -a ---")

        let (code, output) = try timed("curl /containers/json?all=true") {
            try curlSocket("http://localhost/containers/json?all=true")
        }
        XCTAssertEqual(code, 0, "curl should succeed")

        let json = parseJSON(output)
        XCTAssertTrue(json is [Any], "/containers/json?all=true should return a JSON array")
        print("  containers (all): \((json as? [Any])?.count ?? 0)")

        if let cli = timed("docker ps -a (CLI)", block: { tryDockerCLI(["ps", "-a", "--format", "json"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 3. docker images → GET /images/json

    func testDockerImages() throws {
        print("--- docker images ---")

        let (code, output) = try timed("curl /images/json") {
            try curlSocket("http://localhost/images/json")
        }
        XCTAssertEqual(code, 0, "curl should succeed")

        let json = parseJSON(output)
        XCTAssertTrue(json is [Any], "/images/json should return a JSON array")
        print("  images: \((json as? [Any])?.count ?? 0)")

        if let cli = timed("docker images (CLI)", block: { tryDockerCLI(["images", "--format", "json"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 4. docker run -d --name cli-test nginx → POST /containers/create + /start

    func testDockerRun() throws {
        print("--- docker run -d --name \(testContainerName) nginx ---")

        // Step 1: Create the container
        let createBody = """
        {"Image":"nginx:latest","Hostname":"\(testContainerName)"}
        """
        let (createCode, createOutput) = try timed("POST /containers/create") {
            try curlSocket(
                "http://localhost/containers/create?name=\(testContainerName)",
                method: "POST",
                body: createBody
            )
        }
        XCTAssertEqual(createCode, 0, "curl create should succeed")

        let createJSON = parseJSON(createOutput) as? [String: Any]
        XCTAssertNotNil(createJSON, "create response should be a JSON object")
        let containerID = createJSON?["Id"] as? String ?? testContainerName
        print("  created container: \(containerID.prefix(12))")

        // Step 2: Start the container
        let (startCode, _) = try timed("POST /containers/{id}/start") {
            try curlSocket(
                "http://localhost/containers/\(testContainerName)/start",
                method: "POST"
            )
        }
        XCTAssertEqual(startCode, 0, "curl start should succeed")
        print("  container started")

        // Step 3: Verify it appears in the running containers list
        let (listCode, listOutput) = try timed("GET /containers/json (verify)") {
            try curlSocket("http://localhost/containers/json")
        }
        XCTAssertEqual(listCode, 0)

        if let containers = parseJSON(listOutput) as? [[String: Any]] {
            let found = containers.contains { container in
                let names = container["Names"] as? [String] ?? []
                let id = container["Id"] as? String ?? ""
                return names.contains("/\(testContainerName)") ||
                       names.contains(testContainerName) ||
                       id.hasPrefix(containerID.prefix(12).description)
            }
            XCTAssertTrue(found, "newly created container should appear in running list")
            print("  verified in container list")
        }
    }

    // MARK: - 5. docker stop cli-test → POST /containers/{id}/stop

    func testDockerStop() throws {
        print("--- docker stop \(testContainerName) ---")

        // Ensure container exists and is running
        let createBody = """
        {"Image":"nginx:latest"}
        """
        try curlSocket(
            "http://localhost/containers/create?name=\(testContainerName)",
            method: "POST",
            body: createBody
        )
        try curlSocket(
            "http://localhost/containers/\(testContainerName)/start",
            method: "POST"
        )

        // Stop the container
        let (code, output) = try timed("POST /containers/{id}/stop") {
            try curlSocket(
                "http://localhost/containers/\(testContainerName)/stop",
                method: "POST"
            )
        }
        XCTAssertEqual(code, 0, "curl stop should succeed: \(output)")
        print("  container stopped")

        if let cli = timed("docker stop (CLI)", block: { tryDockerCLI(["stop", testContainerName]) }) {
            // May fail if already stopped, that's fine
            print("  docker CLI exit: \(cli.0)")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 6. docker rm cli-test → DELETE /containers/{id}

    func testDockerRM() throws {
        print("--- docker rm \(testContainerName) ---")

        // Ensure container exists (stopped)
        let createBody = """
        {"Image":"nginx:latest"}
        """
        try curlSocket(
            "http://localhost/containers/create?name=\(testContainerName)",
            method: "POST",
            body: createBody
        )

        // Remove the container
        let (code, output) = try timed("DELETE /containers/{id}") {
            try curlSocket(
                "http://localhost/containers/\(testContainerName)?force=true",
                method: "DELETE"
            )
        }
        XCTAssertEqual(code, 0, "curl rm should succeed: \(output)")
        print("  container removed")
    }

    // MARK: - 7. docker logs cli-test → GET /containers/{id}/logs

    func testDockerLogs() throws {
        print("--- docker logs \(testContainerName) ---")

        // Create and start a container that produces output
        let createBody = """
        {"Image":"alpine:latest","Cmd":["sh","-c","echo hello-from-keg && sleep 30"]}
        """
        try curlSocket(
            "http://localhost/containers/create?name=\(testContainerName)",
            method: "POST",
            body: createBody
        )
        try curlSocket(
            "http://localhost/containers/\(testContainerName)/start",
            method: "POST"
        )

        // Wait for the container to produce output
        Thread.sleep(forTimeInterval: 2)

        // Fetch logs
        let (code, output) = try timed("GET /containers/{id}/logs") {
            try curlSocket(
                "http://localhost/containers/\(testContainerName)/logs?stdout=true&stderr=true"
            )
        }
        XCTAssertEqual(code, 0, "curl logs should succeed")
        // Log output may contain Docker stream framing bytes; check the text is present
        XCTAssertTrue(output.contains("hello-from-keg"), "logs should contain expected output, got: \(output.prefix(200))")
        print("  logs retrieved successfully")
    }

    // MARK: - 8. docker inspect cli-test → GET /containers/{id}/json

    func testDockerInspect() throws {
        print("--- docker inspect \(testContainerName) ---")

        // Ensure a container exists
        let createBody = """
        {"Image":"nginx:latest"}
        """
        try curlSocket(
            "http://localhost/containers/create?name=\(testContainerName)",
            method: "POST",
            body: createBody
        )

        let (code, output) = try timed("GET /containers/{id}/json") {
            try curlSocket("http://localhost/containers/\(testContainerName)/json")
        }
        XCTAssertEqual(code, 0, "curl inspect should succeed")

        let json = parseJSON(output) as? [String: Any]
        XCTAssertNotNil(json, "inspect should return a JSON object")
        XCTAssertNotNil(json?["Id"], "inspect should have an Id field")
        XCTAssertNotNil(json?["Config"], "inspect should have a Config field")
        print("  inspect returned: Id=\((json?["Id"] as? String ?? "").prefix(12))")

        if let cli = timed("docker inspect (CLI)", block: { tryDockerCLI(["inspect", testContainerName]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 9. docker pull alpine:3.19 → POST /images/create?fromImage=alpine&tag=3.19

    func testDockerPull() throws {
        print("--- docker pull alpine:3.19 ---")

        let (code, output) = try timed("POST /images/create") {
            try curlSocket(
                "http://localhost/images/create?fromImage=alpine&tag=3.19",
                method: "POST"
            )
        }
        XCTAssertEqual(code, 0, "curl pull should succeed: \(output.prefix(300))")
        // Pull responses are streamed JSON objects; at minimum curl should succeed
        print("  pull completed")

        if let cli = timed("docker pull (CLI)", block: { tryDockerCLI(["pull", "alpine:3.19"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 10. docker network ls → GET /networks

    func testDockerNetworkLS() throws {
        print("--- docker network ls ---")

        let (code, output) = try timed("curl /networks") {
            try curlSocket("http://localhost/networks")
        }
        XCTAssertEqual(code, 0, "curl should succeed")

        let json = parseJSON(output)
        XCTAssertTrue(json is [Any], "/networks should return a JSON array")
        print("  networks: \((json as? [Any])?.count ?? 0)")

        if let cli = timed("docker network ls (CLI)", block: { tryDockerCLI(["network", "ls", "--format", "json"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 11. docker volume ls → GET /volumes

    func testDockerVolumeLS() throws {
        print("--- docker volume ls ---")

        let (code, output) = try timed("curl /volumes") {
            try curlSocket("http://localhost/volumes")
        }
        XCTAssertEqual(code, 0, "curl should succeed")

        // Docker API returns {"Volumes": [...], "Warnings": [...]}, but Keg may vary
        let jsonObj = parseJSON(output)
        XCTAssertNotNil(jsonObj, "/volumes should return valid JSON")
        if let dict = jsonObj as? [String: Any] {
            print("  volumes response keys: \(dict.keys.sorted())")
        } else if let arr = jsonObj as? [Any] {
            print("  volumes (array): \(arr.count)")
        }

        if let cli = timed("docker volume ls (CLI)", block: { tryDockerCLI(["volume", "ls", "--format", "json"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 12. docker info → GET /info

    func testDockerInfo() throws {
        print("--- docker info ---")

        let (code, output) = try timed("curl /info") {
            try curlSocket("http://localhost/info")
        }
        XCTAssertEqual(code, 0, "curl should succeed")

        let json = parseJSON(output) as? [String: Any]
        XCTAssertNotNil(json, "/info should return a JSON object")
        // Keg may not populate all Docker info fields; just verify it's valid JSON
        print("  OS: \(json?["OperatingSystem"] ?? "not set")")
        print("  Containers: \(json?["Containers"] ?? "not set")")
        print("  Images: \(json?["Images"] ?? "not set")")

        if let cli = timed("docker info (CLI)", block: { tryDockerCLI(["info", "--format", "json"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }

    // MARK: - 13. docker version → GET /version

    func testDockerVersion() throws {
        print("--- docker version ---")

        let (code, output) = try timed("curl /version") {
            try curlSocket("http://localhost/version")
        }
        XCTAssertEqual(code, 0, "curl should succeed")

        let json = parseJSON(output) as? [String: Any]
        XCTAssertNotNil(json, "/version should return a JSON object")
        // Keg may not populate all Docker version fields; just verify it's valid JSON
        print("  ApiVersion: \(json?["ApiVersion"] ?? "not set")")
        print("  Version: \(json?["Version"] ?? "not set")")
        print("  Os: \(json?["Os"] ?? "not set")")
        print("  Arch: \(json?["Arch"] ?? "not set")")

        if let cli = timed("docker version (CLI)", block: { tryDockerCLI(["version", "--format", "json"]) }) {
            print("  docker CLI exit: \(cli.0)\(cli.0 == 0 ? " (OK)" : "")")
        } else {
            print("  docker CLI: not available, skipped")
        }
    }
}
