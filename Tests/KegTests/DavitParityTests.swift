import XCTest
@testable import Keg

/// Pure-logic tests for the Davit-parity features: compose import preview
/// (plan), in-container `ls -la` parsing, and run-argument helpers. No
/// daemon or containers required.
final class DavitParityTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-parity-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Compose plan

    func testPlanOrdersServicesByDependency() async throws {
        let file = tempDir.appendingPathComponent("docker-compose.yml")
        try composeYAML.write(to: file, atomically: true, encoding: .utf8)

        let plan = try await ComposeOrchestrator().plan(filePath: file.path, projectName: "demo")

        XCTAssertEqual(plan.services.map(\.name), ["db", "api", "web"])
        XCTAssertEqual(plan.networks, ["demo-backend"])
        XCTAssertEqual(plan.volumes, ["demo-data"])
    }

    func testPlanWarnsAboutUnsupportedKeys() async throws {
        let file = tempDir.appendingPathComponent("docker-compose.yml")
        try composeYAML.write(to: file, atomically: true, encoding: .utf8)

        let plan = try await ComposeOrchestrator().plan(filePath: file.path, projectName: "demo")

        let web = try XCTUnwrap(plan.services.first { $0.name == "web" })
        XCTAssertTrue(web.warnings.contains { $0.contains("restart") })
        XCTAssertTrue(web.warnings.contains { $0.contains("healthcheck") })

        let api = try XCTUnwrap(plan.services.first { $0.name == "api" })
        XCTAssertTrue(api.warnings.contains { $0.contains("env_file") })
        XCTAssertTrue(api.warnings.isEmpty == false)
    }

    func testPlanCommandMatchesContainerRunShape() async throws {
        let file = tempDir.appendingPathComponent("docker-compose.yml")
        try composeYAML.write(to: file, atomically: true, encoding: .utf8)

        let plan = try await ComposeOrchestrator().plan(filePath: file.path, projectName: "demo")

        let web = try XCTUnwrap(plan.services.first { $0.name == "web" })
        XCTAssertTrue(web.command.hasPrefix("container run"))
        XCTAssertTrue(web.command.contains("--name demo-web-1"))
        XCTAssertTrue(web.command.contains("-p 8080:80"))
        XCTAssertTrue(web.command.contains("-e MODE=production"))
        XCTAssertTrue(web.command.contains("nginx:1.25"))
        XCTAssertTrue(web.command.contains("-v demo-data:/data"))

        let db = try XCTUnwrap(plan.services.first { $0.name == "db" })
        XCTAssertTrue(db.command.contains("postgres:16"))
        XCTAssertTrue(db.command.contains("--memory 1G"))
    }

    func testPlanHandlesCircularDependencies() async throws {
        let file = tempDir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          a:
            image: nginx
            depends_on: [b]
          b:
            image: nginx
            depends_on: [a]
        """.write(to: file, atomically: true, encoding: .utf8)

        do {
            _ = try await ComposeOrchestrator().plan(filePath: file.path, projectName: nil)
            XCTFail("Expected circular dependency error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Circular") || String(describing: error).contains("Circular"))
        }
    }

    // MARK: - ls -la parsing

    func testParseListingsSkipsTotalAndDots() {
        let output = """
        total 72
        drwxr-xr-x   1 root root 4096 Jan  1 00:00 .
        drwxr-xr-x   1 root root 4096 Jan  1 00:00 ..
        drwxr-xr-x   2 root root 4096 Jan  1 00:00 etc
        -rw-r--r--   1 root root  220 Jan  1 00:00 my file with spaces.txt
        lrwxrwxrwx   1 root root    7 Jan  1 00:00 lib -> usr/lib
        -rwxr-xr-x   1 root root 15288 Mar 10  2024 busybox
        """

        let entries = ContainerFilesVM.parseListings(output)

        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].name, "etc")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].name, "my file with spaces.txt")
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[1].size, 220)
        XCTAssertEqual(entries[2].name, "lib")
        XCTAssertTrue(entries[2].isSymlink)
        XCTAssertEqual(entries[3].size, 15288)
        XCTAssertEqual(entries[3].permissions, "-rwxr-xr-x")
    }

    // MARK: - Run arguments

    func testFormatMemoryUnits() {
        XCTAssertEqual(ContainerRunArguments.formatMemory(1 << 30), "1G")
        XCTAssertEqual(ContainerRunArguments.formatMemory(2 << 30), "2G")
        XCTAssertEqual(ContainerRunArguments.formatMemory(512 << 20), "512M")
        XCTAssertEqual(ContainerRunArguments.formatMemory(64 << 10), "64K")
    }

    func testBuildRunArgsIncludesAllFields() {
        let args = ContainerRunArguments.build(
            name: "web",
            env: ["A=1"],
            ports: ["8080:80"],
            volumes: ["/host:/data"],
            cpus: 2,
            memory: "1G",
            image: "nginx",
            command: ""
        )
        XCTAssertEqual(args, ["container", "run", "-d", "--name", "web", "-e", "A=1", "-p", "8080:80", "-v", "/host:/data", "--cpus", "2", "--memory", "1G", "nginx"])
    }

    // MARK: - Fixture

    private let composeYAML = """
    services:
      web:
        image: nginx:1.25
        ports:
          - "8080:80"
        environment:
          - MODE=production
        volumes:
          - data:/data
        depends_on: [api]
        restart: always
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost"]
      api:
        image: api:local
        build:
          context: .
        env_file:
          - .env
        depends_on: [db]
        networks: [backend]
      db:
        image: postgres:16
        deploy:
          resources:
            limits:
              memory: 1G
        networks: [backend]
    networks:
      backend:
    volumes:
      data:
    """
}
