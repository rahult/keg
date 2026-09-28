import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import KegCLICore

final class KegDatabaseTests: XCTestCase {

    // MARK: - Engines

    func testEngineLookup() throws {
        XCTAssertEqual(try KegDatabaseEngine.engine("postgres").id, "postgres")
        XCTAssertEqual(try KegDatabaseEngine.engine("Postgres").id, "postgres")
        XCTAssertEqual(KegDatabaseEngine.all.count, 3)
        XCTAssertThrowsError(try KegDatabaseEngine.engine("oracle"))
    }

    func testContainerNamingContract() {
        for engine in KegDatabaseEngine.all {
            XCTAssertEqual(engine.containerName, "kegdb-\(engine.id)", "naming contract")
            XCTAssertTrue(engine.image.contains(":"), "\(engine.id) image must be pinned to a tag")
        }
    }

    // MARK: - Name validation

    func testValidDatabaseNames() throws {
        XCTAssertEqual(try KegDatabaseNames.validateDatabaseName("todo_app"), "todo_app")
        XCTAssertEqual(try KegDatabaseNames.validateDatabaseName("TodoApp"), "todoapp", "lowercased")
        XCTAssertEqual(try KegDatabaseNames.validateDatabaseName("_private"), "_private")
        XCTAssertEqual(try KegDatabaseNames.validateDatabaseName("a"), "a")
    }

    func testInvalidDatabaseNames() {
        for bad in ["", "9lives", "with-dash", "with space", "with.dot", "semi;colon", String(repeating: "a", count: 49)] {
            XCTAssertThrowsError(try KegDatabaseNames.validateDatabaseName(bad), "'\(bad)' must be rejected")
        }
    }

    func testRedisIndexValidation() throws {
        XCTAssertEqual(try KegDatabaseNames.validateRedisIndex(0), 0)
        XCTAssertEqual(try KegDatabaseNames.validateRedisIndex(15), 15)
        XCTAssertThrowsError(try KegDatabaseNames.validateRedisIndex(16))
        XCTAssertThrowsError(try KegDatabaseNames.validateRedisIndex(-1))
        XCTAssertEqual(KegDatabaseNames.redisIndex(nil), 0)
        XCTAssertEqual(KegDatabaseNames.redisIndex("3"), 3)
    }

    // MARK: - Statements

    func testPostgresStatements() {
        let e = KegDatabaseEngine.postgres
        XCTAssertEqual(
            KegDatabaseStatements.databaseExistsCommand(engine: e, name: "todo", superuser: "keg", password: "pw"),
            ["psql", "-U", "keg", "-d", "postgres", "-tAc", "SELECT 1 FROM pg_database WHERE datname='todo'"]
        )
        XCTAssertEqual(
            KegDatabaseStatements.createDatabaseCommand(engine: e, name: "todo", superuser: "keg", password: "pw")[6],
            "CREATE DATABASE \"todo\""
        )
        let drop = KegDatabaseStatements.dropDatabaseCommand(engine: e, name: "todo", superuser: "keg", password: "pw")
        XCTAssertTrue(drop.contains("-c"), "drop must evict clients first")
        XCTAssertTrue(drop.joined(separator: " ").contains("pg_terminate_backend"))
        XCTAssertEqual(drop.last, "DROP DATABASE IF EXISTS \"todo\"")
        XCTAssertEqual(drop.filter { $0 == "-c" }.count, 2, "each statement needs its own -c (one -c = one transaction)")
    }

    func testStatementQuotingIsSafe() {
        // Names are validated upstream, but the builders must still not
        // produce injectable SQL from a hostile name that slipped through.
        let e = KegDatabaseEngine.postgres
        let create = KegDatabaseStatements.createDatabaseCommand(
            engine: e, name: "x\"); DROP TABLE users; --", superuser: "keg", password: "pw"
        ).joined(separator: " ")
        XCTAssertTrue(create.contains("\"x\"\"); DROP TABLE users; --\""), "double quotes must be escaped")
        let role = KegDatabaseStatements.createRoleCommand(
            engine: e, role: "app", password: "p'w", database: "app", superuser: "keg"
        ).joined(separator: " ")
        XCTAssertTrue(role.contains("'p''w'"), "single quotes in password must be escaped")
        XCTAssertTrue(role.contains("GRANT ALL PRIVILEGES ON DATABASE \"app\" TO \"app\""))
    }

    func testMySQLStatements() {
        let e = KegDatabaseEngine.mysql
        XCTAssertEqual(
            KegDatabaseStatements.createDatabaseCommand(engine: e, name: "todo", superuser: "root", password: "pw"),
            ["mysql", "-u", "root", "-ppw", "-e", "CREATE DATABASE IF NOT EXISTS `todo`"]
        )
        XCTAssertEqual(KegDatabaseStatements.readinessCommand(engine: e, superuser: "root", password: "pw"),
                       ["mysqladmin", "-u", "root", "-ppw", "ping"])
    }

    func testRedisStatementsArePingBased() {
        let e = KegDatabaseEngine.redis
        XCTAssertEqual(KegDatabaseStatements.readinessCommand(engine: e, superuser: "", password: ""), ["redis-cli", "ping"])
        XCTAssertEqual(KegDatabaseStatements.listDatabasesCommand(engine: e, superuser: "", password: ""), [])
    }

    // MARK: - URLs

    func testURLs() throws {
        let server = KegDatabaseServer(
            engine: "postgres", containerName: "kegdb-postgres", port: 5433,
            superuser: "keg", password: "s3cret", volume: "kegdb-postgres-data"
        )
        XCTAssertEqual(
            KegDatabaseURLs.url(engine: .postgres, server: server, database: "todo"),
            "postgresql://keg:s3cret@127.0.0.1:5433/todo"
        )
        XCTAssertEqual(
            KegDatabaseURLs.display(engine: .postgres, server: server, database: "todo"),
            "postgresql://keg@127.0.0.1:5433/todo"
        )
        XCTAssertEqual(
            KegDatabaseURLs.url(engine: .redis, server: server, database: "2"),
            "redis://127.0.0.1:5433/2"
        )
    }

    // MARK: - Registry

    func testRegistryRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var registry = KegDatabaseRegistry()
        registry.registryPathOverride = dir.appendingPathComponent("registry.json").path
        registry.record(KegDatabaseServer(
            engine: "postgres", containerName: "kegdb-postgres", port: 5432,
            superuser: "keg", password: "pw", volume: "kegdb-postgres-data"
        ))
        try registry.save()

        var loader = KegDatabaseRegistry()
        loader.registryPathOverride = registry.registryPathOverride
        var loaded = loader.load()
        loaded.registryPathOverride = registry.registryPathOverride
        let server = loaded.server(for: .postgres)
        XCTAssertEqual(server?.port, 5432)
        XCTAssertEqual(server?.superuser, "keg")

        var mutable = loaded
        mutable.registryPathOverride = registry.registryPathOverride
        mutable.remove(engine: .postgres)
        try mutable.save()
        var reloader = KegDatabaseRegistry()
        reloader.registryPathOverride = registry.registryPathOverride
        let reloaded = reloader.load()
        XCTAssertNil(reloaded.server(for: .postgres))
    }

    func testRegistryLoadMissingFileIsEmpty() {
        var registry = KegDatabaseRegistry()
        registry.registryPathOverride = "/nonexistent/\(UUID().uuidString).json"
        XCTAssertNil(registry.server(for: .postgres))
    }

    // MARK: - Planner

    func testEnsurePlanMatrix() {
        XCTAssertEqual(KegDatabasePlanner.ensurePlan(serverExists: false, serverRunning: false), .createAndStart)
        XCTAssertEqual(KegDatabasePlanner.ensurePlan(serverExists: false, serverRunning: true), .createAndStart)
        XCTAssertEqual(KegDatabasePlanner.ensurePlan(serverExists: true, serverRunning: false), .startExisting)
        XCTAssertEqual(KegDatabasePlanner.ensurePlan(serverExists: true, serverRunning: true), .alreadyRunning)
    }

    func testChoosePortSkipsBusy() throws {
        XCTAssertEqual(try KegDatabasePlanner.choosePort(default: 5432, busy: []), 5432)
        XCTAssertEqual(try KegDatabasePlanner.choosePort(default: 5432, busy: [5432, 5433]), 5434)
        XCTAssertThrowsError(try KegDatabasePlanner.choosePort(default: 5432, busy: Set(5432..<5452), attempts: 20))
    }

    // MARK: - Container spec

    func testCreateRequestShape() {
        let request = KegDatabaseContainers.createRequest(
            engine: .postgres, port: 5434, superuser: "keg", password: "pw"
        )
        XCTAssertEqual(request.image, "postgres:16-alpine")
        XCTAssertEqual(request.platform, "linux/arm64")
        XCTAssertEqual(request.env, [
            "POSTGRES_USER=keg", "POSTGRES_PASSWORD=pw", "PGDATA=/var/lib/postgresql/data",
        ])
        XCTAssertEqual(request.hostConfig.binds, ["kegdb-postgres-data:/var/lib/postgresql"])
        XCTAssertEqual(request.hostConfig.portBindings["5432/tcp"]?.first?.hostPort, "5434")
        XCTAssertEqual(request.hostConfig.portBindings["5432/tcp"]?.first?.hostIP, "127.0.0.1")
        XCTAssertEqual(request.labels[KegDatabaseContainers.engineLabel], "postgres")
        XCTAssertEqual(request.labels[KegDatabaseContainers.portLabel], "5434")
    }

    func testCreateRequestEncodesDockerPascalCase() throws {
        let request = KegDatabaseContainers.createRequest(
            engine: .mysql, port: 3306, superuser: "root", password: "pw"
        )
        let json = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        XCTAssertNotNil(object["HostConfig"], "wire format must use Docker's PascalCase keys")
        let hostConfig = object["HostConfig"] as? [String: Any]
        XCTAssertNotNil(hostConfig?["PortBindings"])
        XCTAssertEqual(hostConfig?["Binds"] as? [String], ["kegdb-mysql-data:/var/lib/mysql"])
    }

    // MARK: - Port probe polarity (regression: bind success = FREE)

    func testBusyPortsReportsBoundPortsOnly() throws {
        // Bind one real socket so its port is definitely busy.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThan(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        XCTAssertTrue(bound)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var addrCopy = addr
        let named = withUnsafeMutablePointer(to: &addrCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len) == 0
            }
        }
        let port = named ? Int(addrCopy.sin_port.bigEndian) : -1
        XCTAssertGreaterThan(port, 0)

        let probed = KegPortProbe.busyPorts(from: port, count: 1)
        XCTAssertTrue(probed.contains(port), "a port we hold must read as busy")
        let free = KegPortProbe.busyPorts(from: 59_000, count: 5)
        XCTAssertTrue(free.isEmpty, "unbound high ports must read as free")
    }

    // MARK: - Exec capture framing

    func testDockerStreamSplitterFrames() {
        let splitter = DockerStreamSplitter()
        func frame(_ channel: UInt8, _ payload: String) -> Data {
            var data = Data([channel, 0, 0, 0])
            var length = UInt32(payload.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { raw in
                for i in 0..<4 { data.append(raw.load(fromByteOffset: i, as: UInt8.self)) }
            }
            data.append(Data(payload.utf8))
            return data
        }
        let full = frame(1, "hel")
        var frames = splitter.append(Data(full.prefix(5)))
        XCTAssertTrue(frames.isEmpty, "partial frame must be buffered")
        var rest = Data(full.suffix(full.count - 5))
        rest.append(frame(2, "lo err"))
        frames = splitter.append(rest)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), "hel")
        XCTAssertEqual(frames[0].channel, .stdout)
        XCTAssertEqual(frames[1].channel, .stderr)
    }
}
