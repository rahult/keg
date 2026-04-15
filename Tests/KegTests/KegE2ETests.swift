import XCTest
import ContainerAPIClient
import ContainerResource

final class KegE2ETests: XCTestCase {

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KEG_RUN_CONTAINER_E2E"] == "1" else {
            throw XCTSkip("Set KEG_RUN_CONTAINER_E2E=1 to run container-backed end-to-end tests")
        }

        try await super.setUp()

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["container", "system", "status", "--format", "json"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw XCTSkip("container CLI unavailable: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown error"
            throw XCTSkip("container system not ready: \(output)")
        }
    }

    func testHealthCheck() async throws {
        let health = try await ClientHealthCheck.ping(timeout: .seconds(5))
        XCTAssertEqual(health.apiServerVersion.isEmpty, false)
        print("✅ Health check: version=\(health.apiServerVersion), build=\(health.apiServerBuild)")
    }

    func testListContainers() async throws {
        let client = ContainerClient()
        let all = try await client.list(filters: .all)
        print("✅ List containers: \(all.count) total")
    }

    func testListRunningContainers() async throws {
        let client = ContainerClient()
        let running = try await client.list(filters: ContainerListFilters(status: .running))
        print("✅ List running: \(running.count)")
    }

    func testListImages() async throws {
        let images = try await ClientImage.list()
        print("✅ List images: \(images.count)")
        for img in images {
            print("   - \(img.reference)")
        }
    }

    func testPullImage() async throws {
        let ref = try ClientImage.normalizeReference("alpine:latest")
        let img = try await ClientImage.pull(reference: ref)
        print("✅ Pulled: \(img.reference)")
        XCTAssertFalse(img.reference.isEmpty)
    }

    func testListNetworks() async throws {
        let networks = try await ClientNetwork.list()
        print("✅ List networks: \(networks.count)")
        XCTAssertFalse(networks.isEmpty)
        let defaultNet = networks.first { $0.id == "default" }
        XCTAssertNotNil(defaultNet)
    }

    func testListVolumes() async throws {
        let volumes = try await ClientVolume.list()
        print("✅ List volumes: \(volumes.count)")
    }

    func testRunAndManageContainer() async throws {
        let client = ContainerClient()

        // Run a container via CLI (run requires complex config setup)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["container", "run", "-d", "--name", "keg-e2e-test", "alpine:latest", "sleep", "60"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "container run should succeed")
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("✅ Ran container: \(output)")

        // Verify it appears in list
        try await Task.sleep(for: .milliseconds(500))
        let container = try await client.get(id: "keg-e2e-test")
        XCTAssertEqual(container.status, .running)
        XCTAssertEqual(container.configuration.image.reference.contains("alpine"), true)
        print("✅ Container visible: id=\(container.id), status=\(container.status.rawValue)")

        // Get stats
        let stats = try await client.stats(id: "keg-e2e-test")
        XCTAssertNotNil(stats.cpuUsageUsec)
        print("✅ Stats: cpu=\(stats.cpuUsageUsec ?? 0)µs, mem=\(ByteCountFormatter.string(fromByteCount: Int64(stats.memoryUsageBytes ?? 0), countStyle: .memory))")

        // Stop
        try await client.stop(id: "keg-e2e-test")
        print("✅ Stopped container")

        // Delete
        try await client.delete(id: "keg-e2e-test", force: true)
        print("✅ Deleted container")
    }

    func testVolumeCRUD() async throws {
        // Create
        let vol = try await ClientVolume.create(name: "keg-test-vol")
        XCTAssertEqual(vol.name, "keg-test-vol")
        print("✅ Created volume: \(vol.name)")

        // List
        let volumes = try await ClientVolume.list()
        XCTAssertTrue(volumes.contains { $0.name == "keg-test-vol" })
        print("✅ Volume appears in list")

        // Delete
        try await ClientVolume.delete(name: "keg-test-vol")
        print("✅ Deleted volume")
    }

    func testSystemStatus() async throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["container", "system", "status", "--format", "json"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("running"))
        print("✅ System status: running")
    }
}
