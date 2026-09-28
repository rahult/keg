import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Why shared database servers
//
// Apple containers give every container its own VM with no inter-container
// name resolution and loopback-only published ports, so the Docker pattern
// of "one database container per project" pays a microVM per database and
// buys nothing — peers still cannot reach it by hostname. What does work
// well: ONE database server container per engine, reused across projects,
// with each project getting its own logical database (and optional role)
// inside it. Apps reach it from the Mac at 127.0.0.1:<port>, which is where
// coding agents run app code anyway. `keg db ensure` is idempotent so
// agents can call it on every session start; `keg db remove` is the
// explicit escape hatch, and a keg.yaml service is still there when a
// project genuinely needs a dedicated container.

// MARK: - Engines

/// A database engine served by one shared container (`kegdb-<id>`).
public struct KegDatabaseEngine: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let image: String
    public let scheme: String
    public let defaultPort: Int
    public let dataContainerPath: String
    /// Env vars the image needs to bootstrap its superuser.
    public let superuserEnv: String
    public let passwordEnv: String
    /// Client binary inside the image used for admin operations.
    public let adminCLI: String

    public var containerName: String { "kegdb-\(id)" }
    /// Server data lives in a runtime named volume — bind mounts refuse
    /// chown, which kills the database images' entrypoints (verified live:
    /// postgres chmod/chown "Operation not permitted" on a bind mount,
    /// same wall as Uptime Kuma). Named volumes are runtime-managed disk
    /// images where the entrypoint's chown succeeds.
    public func volumeName(home _: String = NSHomeDirectory()) -> String { "kegdb-\(id)-data" }

    public static let postgres = KegDatabaseEngine(
        id: "postgres",
        displayName: "PostgreSQL",
        image: "postgres:16-alpine",
        scheme: "postgresql",
        defaultPort: 5432,
        // Mount at the parent: initdb refuses a mount root because of
        // lost+found; PGDATA points at a subdirectory (below).
        dataContainerPath: "/var/lib/postgresql",
        superuserEnv: "POSTGRES_USER",
        passwordEnv: "POSTGRES_PASSWORD",
        adminCLI: "psql"
    )

    public static let mysql = KegDatabaseEngine(
        id: "mysql",
        displayName: "MySQL",
        image: "mysql:8.4",
        scheme: "mysql",
        defaultPort: 3306,
        dataContainerPath: "/var/lib/mysql",
        superuserEnv: "",
        passwordEnv: "MYSQL_ROOT_PASSWORD",
        adminCLI: "mysql"
    )

    public static let redis = KegDatabaseEngine(
        id: "redis",
        displayName: "Redis",
        image: "redis:7-alpine",
        scheme: "redis",
        defaultPort: 6379,
        dataContainerPath: "/data",
        superuserEnv: "",
        passwordEnv: "",
        adminCLI: "redis-cli"
    )

    public static let all: [KegDatabaseEngine] = [.postgres, .mysql, .redis]

    public static func engine(_ id: String) throws -> KegDatabaseEngine {
        let key = id.lowercased()
        guard let engine = all.first(where: { $0.id == key }) else {
            throw KegDatabaseError("unknown engine '\(id)' — one of: \(all.map(\.id).joined(separator: ", "))")
        }
        return engine
    }
}

// MARK: - Errors

public struct KegDatabaseError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Name + index validation

public enum KegDatabaseNames {
    /// Logical database names double as role names and URL path segments;
    /// keep them strict so generated SQL never needs escaping beyond
    /// double quotes.
    public static func validateDatabaseName(_ name: String) throws -> String {
        guard !name.isEmpty, name.count <= 48 else {
            throw KegDatabaseError("database name must be 1–48 characters")
        }
        guard let first = name.first, first.isLetter || first == "_" else {
            throw KegDatabaseError("database name must start with a letter or underscore")
        }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw KegDatabaseError("database name may contain only letters, numbers, underscores")
        }
        return name.lowercased()
    }

    /// Redis has no createable databases — clients pick an index 0...15.
    public static func validateRedisIndex(_ index: Int) throws -> Int {
        guard (0...15).contains(index) else {
            throw KegDatabaseError("redis database index must be 0...15")
        }
        return index
    }

    public static func redisIndex(_ name: String?) -> Int {
        guard let name, let index = Int(name) else { return 0 }
        return index
    }
}

// MARK: - SQL / command construction (pure, unit-tested)

public enum KegDatabaseStatements {
    /// Double-quote an identifier (names are pre-validated, so this is
    /// the only escaping needed for postgres).
    static func ident(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// MySQL identifiers use backticks.
    static func mysqlIdent(_ name: String) -> String {
        "`\(name.replacingOccurrences(of: "`", with: "``"))`"
    }

    /// Single-quote a literal.
    static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Admin command run inside the server container to check whether a
    /// logical database exists. Exit 0 + the name on stdout means yes.
    /// The superuser password rides in argv inside the container — local
    /// dev threat model, same as app secrets in app.yaml.
    public static func databaseExistsCommand(engine: KegDatabaseEngine, name: String, superuser: String, password: String) -> [String] {
        switch engine.id {
        case "postgres":
            return [engine.adminCLI, "-U", superuser, "-d", "postgres", "-tAc",
                    "SELECT 1 FROM pg_database WHERE datname='\(name)'"]
        case "mysql":
            return [engine.adminCLI, "-u", superuser, "-p\(password)", "-Nse",
                    "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='\(name)'"]
        default:
            return [engine.adminCLI, "ping"]
        }
    }

    public static func createDatabaseCommand(engine: KegDatabaseEngine, name: String, superuser: String, password: String) -> [String] {
        switch engine.id {
        case "postgres":
            return [engine.adminCLI, "-U", superuser, "-d", "postgres", "-c",
                    "CREATE DATABASE \(ident(name))"]
        case "mysql":
            return [engine.adminCLI, "-u", superuser, "-p\(password)", "-e",
                    "CREATE DATABASE IF NOT EXISTS \(mysqlIdent(name))"]
        default:
            return [engine.adminCLI, "ping"]
        }
    }

    /// Drop, forcibly evicting connected clients first (postgres).
    public static func dropDatabaseCommand(engine: KegDatabaseEngine, name: String, superuser: String, password: String) -> [String] {
        switch engine.id {
        case "postgres":
            // Two separate -c flags: psql wraps multiple statements in ONE
            // -c in a single implicit transaction, and DROP DATABASE refuses
            // to run inside one (verified live).
            return [engine.adminCLI, "-U", superuser, "-d", "postgres",
                    "-c", "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='\(name)' AND pid <> pg_backend_pid()",
                    "-c", "DROP DATABASE IF EXISTS \(ident(name))"]
        case "mysql":
            return [engine.adminCLI, "-u", superuser, "-p\(password)", "-e",
                    "DROP DATABASE IF EXISTS \(mysqlIdent(name))"]
        default:
            return [engine.adminCLI, "ping"]
        }
    }

    /// Create (or update the password of) a per-database login role,
    /// make it the database owner (PG 15+ grants the owner its public
    /// schema through pg_database_owner — plain GRANT ... ON DATABASE
    /// no longer does), and grant database-level privileges.
    public static func createRoleCommand(engine: KegDatabaseEngine, role: String, password: String, database: String, superuser: String) -> [String] {
        switch engine.id {
        case "postgres":
            return [engine.adminCLI, "-U", superuser, "-d", "postgres", "-c",
                    "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='\(role)') THEN "
                    + "CREATE ROLE \(ident(role)) LOGIN PASSWORD \(literal(password)); "
                    + "ELSE ALTER ROLE \(ident(role)) WITH LOGIN PASSWORD \(literal(password)); END IF; END $$; "
                    + "GRANT ALL PRIVILEGES ON DATABASE \(ident(database)) TO \(ident(role)); "
                    + "ALTER DATABASE \(ident(database)) OWNER TO \(ident(role))"]
        default:
            return []
        }
    }

    /// Engine-level readiness probe (run repeatedly right after start).
    public static func readinessCommand(engine: KegDatabaseEngine, superuser: String, password: String) -> [String] {
        switch engine.id {
        case "postgres":
            return ["pg_isready", "-U", superuser, "-q"]
        case "mysql":
            return ["mysqladmin", "-u", superuser, "-p\(password)", "ping"]
        default:
            return [engine.adminCLI, "ping"]
        }
    }

    /// List logical databases (for `keg db list`).
    public static func listDatabasesCommand(engine: KegDatabaseEngine, superuser: String, password: String) -> [String] {
        switch engine.id {
        case "postgres":
            return [engine.adminCLI, "-U", superuser, "-d", "postgres", "-tAc",
                    "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname"]
        case "mysql":
            return [engine.adminCLI, "-u", superuser, "-p\(password)", "-Nse",
                    "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema') ORDER BY SCHEMA_NAME"]
        default:
            return []
        }
    }
}

// MARK: - Connection URLs

public enum KegDatabaseURLs {
    public static func url(engine: KegDatabaseEngine, server: KegDatabaseServer, database: String) -> String {
        switch engine.id {
        case "postgres":
            return "postgresql://\(server.superuser):\(server.password)@127.0.0.1:\(server.port)/\(database)"
        case "mysql":
            return "mysql://\(server.superuser):\(server.password)@127.0.0.1:\(server.port)/\(database)"
        default:
            let index = KegDatabaseNames.redisIndex(database)
            return "redis://127.0.0.1:\(server.port)/\(index)"
        }
    }

    /// Form for display in tables (no password).
    public static func display(engine: KegDatabaseEngine, server: KegDatabaseServer, database: String) -> String {
        switch engine.id {
        case "redis":
            return "redis://127.0.0.1:\(server.port)/\(KegDatabaseNames.redisIndex(database))"
        default:
            return "\(engine.scheme)://\(server.superuser)@127.0.0.1:\(server.port)/\(database)"
        }
    }
}

// MARK: - Server record + registry

public struct KegDatabaseServer: Codable, Sendable, Equatable {
    public let engine: String
    public let containerName: String
    public let port: Int
    public let superuser: String
    public let password: String
    /// Runtime named volume holding the engine's data dir.
    public let volume: String
    public let createdAt: Date

    public init(engine: String, containerName: String, port: Int, superuser: String, password: String, volume: String, createdAt: Date = Date()) {
        self.engine = engine
        self.containerName = containerName
        self.port = port
        self.superuser = superuser
        self.password = password
        self.volume = volume
        self.createdAt = createdAt
    }
}

/// Maps engine id -> running server. Persisted at ~/.keg/db/registry.json.
public struct KegDatabaseRegistry: Codable, Sendable {
    public private(set) var servers: [String: KegDatabaseServer]

    public init(servers: [String: KegDatabaseServer] = [:]) {
        self.servers = servers
    }

    public static var defaultPath: String {
        NSHomeDirectory() + "/.keg/db/registry.json"
    }

    /// Injectable for tests.
    public var registryPathOverride: String?

    public var path: String { registryPathOverride ?? Self.defaultPath }

    public func server(for engine: KegDatabaseEngine) -> KegDatabaseServer? {
        servers[engine.id]
    }

    public mutating func record(_ server: KegDatabaseServer) {
        servers[server.engine] = server
    }

    public mutating func remove(engine: KegDatabaseEngine) {
        servers.removeValue(forKey: engine.id)
    }

    public func load() -> KegDatabaseRegistry {
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(KegDatabaseRegistry.self, from: data) else {
            return KegDatabaseRegistry()
        }
        var registry = decoded
        registry.registryPathOverride = registryPathOverride
        return registry
    }

    public func save() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - Planning (pure decisions, unit-tested)

/// What `keg db ensure` must do for one engine, before touching anything.
public enum KegDatabasePlan: Equatable, Sendable {
    /// No server container yet: create (image, data dir, port) then start.
    case createAndStart
    /// Server exists but is stopped: just start it.
    case startExisting
    /// Server is already running.
    case alreadyRunning
}

public enum KegDatabasePlanner {
    public static func ensurePlan(serverExists: Bool, serverRunning: Bool) -> KegDatabasePlan {
        switch (serverExists, serverRunning) {
        case (false, _): return .createAndStart
        case (true, false): return .startExisting
        case (true, true): return .alreadyRunning
        }
    }

    /// First candidate port starting at the engine default, skipping any
    /// port in `busy` (e.g. ports already bound on this Mac).
    public static func choosePort(default def: Int, busy: Set<Int>, attempts: Int = 20) throws -> Int {
        for offset in 0..<attempts where !busy.contains(def + offset) {
            return def + offset
        }
        throw KegDatabaseError("no free port near \(def)")
    }
}

// MARK: - Container spec

public enum KegDatabaseContainers {
    public static let engineLabel = "com.keg.db.engine"
    public static let portLabel = "com.keg.db.port"

    /// Docker create body for a fresh server container. Password is passed
    /// via env, mirrored into a label so a lost registry.json can be
    /// re-adopted from the container itself (local dev threat model, same
    /// as app secrets in app.yaml).
    public static func createRequest(
        engine: KegDatabaseEngine,
        port: Int,
        superuser: String,
        password: String
    ) -> KegContainerCreateRequest {
        var env: [String] = []
        switch engine.id {
        case "postgres":
            env = [
                "POSTGRES_USER=\(superuser)",
                "POSTGRES_PASSWORD=\(password)",
                "PGDATA=\(engine.dataContainerPath)/data",
            ]
        case "mysql":
            env = ["MYSQL_ROOT_PASSWORD=\(password)"]
        default:
            env = []
        }

        return KegContainerCreateRequest(
            image: engine.image,
            cmd: nil,
            env: env,
            labels: [
                engineLabel: engine.id,
                portLabel: String(port),
                "com.keg.db.superuser": superuser,
                "com.keg.db.password": password,
            ],
            entrypoint: nil,
            workingDir: nil,
            platform: "linux/arm64",
            hostConfig: .init(
                portBindings: ["\(engine.defaultPort)/tcp": [.init(hostIP: "127.0.0.1", hostPort: String(port))]],
                binds: ["\(engine.volumeName()):\(engine.dataContainerPath)"],
                restartPolicy: nil
            )
        )
    }
}

// MARK: - Port probing

public enum KegPortProbe {
    /// Which of `count` ports starting at `start` are already bound on this
    /// Mac's loopback. Polarity matters: a probe bind that SUCCEEDS means
    /// the port is free — only a FAILED bind means busy.
    public static func busyPorts(from start: Int, count: Int) -> Set<Int> {
        var busy = Set<Int>()
        for port in start..<(start + count) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let bindFailed = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) != 0
                }
            }
            if bindFailed { busy.insert(port) }
        }
        return busy
    }
}

// MARK: - Captured exec

public struct KegExecResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

/// Non-interactive `docker exec` with captured output, against Keg's
/// socket: create exec, POST /exec/{id}/start (plain request — the route
/// streams a stdcopy-framed chunked body), split frames, then read the
/// exit code from /exec/{id}/json. Used by `keg db` admin operations and
/// available to agents via `keg db run`.
public enum KegExecCapture {
    public static func run(
        socketPath: String,
        container: String,
        command: [String],
        timeoutSeconds: Int32 = 60
    ) throws -> KegExecResult {
        struct CreateResponse: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "Id" }
        }
        struct Inspect: Decodable {
            let running: Bool
            let exitCode: Int?
            enum CodingKeys: String, CodingKey {
                case running = "Running"
                case exitCode = "ExitCode"
            }
        }

        let http = UnixSocketHTTPClient(socketPath: socketPath, timeoutSeconds: timeoutSeconds)
        let payload: [String: Any] = [
            "Cmd": command,
            "AttachStdout": true,
            "AttachStderr": true,
            "Tty": false,
        ]
        let createBody = try JSONSerialization.data(withJSONObject: payload)
        let created = try http.post("/containers/\(container)/exec", body: createBody)
        guard created.status == 201, let createResponse = try? JSONDecoder().decode(CreateResponse.self, from: created.body) else {
            throw KegDatabaseError("exec create failed (HTTP \(created.status)): \(String(data: created.body, encoding: .utf8) ?? "")")
        }

        let stream = try http.post("/exec/\(createResponse.id)/start", body: Data(), timeoutSeconds: timeoutSeconds)
        guard (200..<300).contains(stream.status) else {
            throw KegDatabaseError("exec start failed (HTTP \(stream.status))")
        }
        let splitter = DockerStreamSplitter()
        var stdout = Data()
        var stderr = Data()
        for frame in splitter.append(stream.body) {
            switch frame.channel {
            case .stdout: stdout.append(frame.payload)
            case .stderr: stderr.append(frame.payload)
            }
        }

        var exitCode: Int32 = -1
        for _ in 0..<20 {
            let inspected = try http.get("/exec/\(createResponse.id)/json")
            if let detail = try? JSONDecoder().decode(Inspect.self, from: inspected.body), !detail.running {
                exitCode = Int32(detail.exitCode ?? -1)
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return KegExecResult(
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }
}
