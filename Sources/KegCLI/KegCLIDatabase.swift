import Foundation
#if canImport(Darwin)
import Darwin
#endif
import KegCLICore

/// `keg db` — shared, reusable database server containers.
///
/// One container per engine (`kegdb-<engine>`) hosts many logical
/// databases; coding agents ensure a database idempotently and get a
/// loopback connection URL. See KegDatabase.swift for the model and the
/// runtime constraints that motivate it.
enum KegCLIDatabase {
    static func run(_ operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        var args = operands
        guard let sub = args.first else {
            usage(print)
            return 2
        }
        args.removeFirst()
        do {
            switch sub {
            case "list":
                return try list(args, socketOverride: socketOverride, print: print)
            case "ensure":
                return try ensure(args, socketOverride: socketOverride, print: print)
            case "drop":
                return try drop(args, socketOverride: socketOverride, print: print)
            case "url":
                return try url(args, print: print)
            case "run":
                return try runCommand(args, socketOverride: socketOverride, print: print)
            case "remove":
                return try remove(args, socketOverride: socketOverride, print: print)
            case "help", "--help", "-h":
                usage(print)
                return 0
            default:
                print("unknown db subcommand '\(sub)'")
                usage(print)
                return 2
            }
        } catch {
            print("\(error)")
            return 1
        }
    }

    static func usage(_ print: (String) -> Void) {
        print(
            """
            keg db — shared database servers (one container per engine, many databases each)

              list                     Shared servers, their state, port, and databases
              ensure <engine>          Create/start the shared server (idempotent)
                --database <name>      Also create the database if missing (default: none)
                --user <role>          Per-database login role (postgres), with
                --password <pw>        its password (default: generated)
                --json                 Machine-readable result
              drop <engine> <db>       Drop a database (connected clients are evicted)
              url <engine> [db]        Print the connection URL (no server changes)
              run <engine> -- <cmd>    Run a command inside the server container
              remove <engine>          Stop + remove the shared server (data kept)
                --delete-data          Also erase the server's data volume

            engines: postgres · mysql · redis
            Databases are reached from the Mac at 127.0.0.1:<port> — containers
            cannot reach each other, so app code runs on the host (or uses a
            keg.yaml service when it needs no peers).
            """
        )
    }

    // MARK: - list

    private static func list(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        let client = try requireClient(socketOverride, print: print)
        let registry = KegDatabaseRegistry().load()
        let existing = try client.containers(all: true)
        var lines: [String] = []
        for engine in KegDatabaseEngine.all {
            let container = existing.first(where: { $0.displayName == engine.containerName })
            guard let container else { continue }
            let server = registry.server(for: engine)
            let port = server?.port ?? -1
            let dbList: String
            if container.state == "running", let server {
                let result = try? KegExecCapture.run(
                    socketPath: client.http.socketPath,
                    container: engine.containerName,
                    command: KegDatabaseStatements.listDatabasesCommand(
                        engine: engine, superuser: server.superuser, password: server.password
                    )
                )
                let names = (result?.stdout ?? "")
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { $0 != "postgres" }
                dbList = names.isEmpty ? "—" : names.joined(separator: ", ")
            } else {
                dbList = "—"
            }
            lines.append("\(engine.id)\t\(container.state)\t\(port > 0 ? "127.0.0.1:\(port)" : "—")\t\(dbList)")
        }
        guard !lines.isEmpty else {
            print("no shared database servers — create one with: keg db ensure postgres --database <name>")
            return 0
        }
        print("ENGINE\tSTATE\tADDRESS\tDATABASES")
        for line in lines { print(line) }
        return 0
    }

    // MARK: - ensure

    private static func ensure(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        guard let engineID = operands.first else {
            print("usage: keg db ensure <engine> [--database <name>] [--user <role>] [--password <pw>] [--json]")
            return 2
        }
        let engine = try KegDatabaseEngine.engine(engineID)
        let database: String? = try option(operands, "--database").map { try KegDatabaseNames.validateDatabaseName($0) }
        let role = option(operands, "--user")
        let passwordOption = option(operands, "--password")
        let json = operands.contains("--json")
        let client = try requireClient(socketOverride, print: print)

        if engine.id == "redis", let database {
            _ = try KegDatabaseNames.validateRedisIndex(KegDatabaseNames.redisIndex(database))
        }

        // Server container: create/start per plan.
        var registry = KegDatabaseRegistry().load()
        let existing = try client.containers(all: true)
        let container = existing.first(where: { $0.displayName == engine.containerName })
        let plan = KegDatabasePlanner.ensurePlan(
            serverExists: container != nil,
            serverRunning: container?.state == "running"
        )

        let server: KegDatabaseServer
        switch plan {
        case .alreadyRunning:
            guard let recorded = registry.server(for: engine) ?? adoptFromLabels(engine: engine, client: client) else {
                throw KegDatabaseError("server container is running but its record is missing — remove it (`keg db remove \(engine.id)`) and re-ensure")
            }
            registry.record(recorded)
            server = recorded

        case .startExisting:
            guard let recorded = registry.server(for: engine) ?? adoptFromLabels(engine: engine, client: client) else {
                throw KegDatabaseError("server container exists but its record is missing — remove it (`keg db remove \(engine.id)`) and re-ensure")
            }
            print("starting \(engine.containerName)")
            try client.start(id: engine.containerName, timeoutSeconds: 300)
            try waitReady(engine: engine, server: recorded, client: client)
            registry.record(recorded)
            server = recorded

        case .createAndStart:
            let port = try KegDatabasePlanner.choosePort(
                default: engine.defaultPort,
                busy: KegPortProbe.busyPorts(from: engine.defaultPort, count: 20)
            )
            let superuser = engine.id == "postgres" ? "keg" : "root"
            let password = passwordOption ?? randomToken()
            print("creating \(engine.containerName) (\(engine.image), 127.0.0.1:\(port))")
            let request = KegDatabaseContainers.createRequest(
                engine: engine, port: port, superuser: superuser, password: password
            )
            try client.createContainer(request: request, name: engine.containerName)
            try client.start(id: engine.containerName, timeoutSeconds: 300)
            let recorded = KegDatabaseServer(
                engine: engine.id,
                containerName: engine.containerName,
                port: port,
                superuser: superuser,
                password: password,
                volume: engine.volumeName()
            )
            try waitReady(engine: engine, server: recorded, client: client)
            registry.record(recorded)
            server = recorded
        }
        try registry.save()

        // Logical database (postgres/mysql).
        var rolePassword: String?
        if let database, engine.id != "redis" {
            let existsResult = try execAdmin(
                client: client, engine: engine,
                command: KegDatabaseStatements.databaseExistsCommand(
                    engine: engine, name: database, superuser: server.superuser, password: server.password
                ),
                idempotent: true
            )
            let exists = existsResult.stdout.split(whereSeparator: \.isNewline)
                .contains(where: { $0.trimmingCharacters(in: .whitespaces) == database || $0.trimmingCharacters(in: .whitespaces) == "1" })
            if exists {
                print("database '\(database)' already exists")
            } else {
                print("creating database '\(database)'")
                do {
                    let created = try execAdmin(
                        client: client, engine: engine,
                        command: KegDatabaseStatements.createDatabaseCommand(
                            engine: engine, name: database, superuser: server.superuser, password: server.password
                        ),
                        idempotent: false
                    )
                    if created.exitCode != 0 {
                        // A lost response on the original create surfaces
                        // here as the server reporting it already exists.
                        if created.stderr.contains("already exists") {
                            print("database '\(database)' already exists")
                        } else {
                            throw KegDatabaseError("CREATE DATABASE failed (exit \(created.exitCode)): \(created.stderr)")
                        }
                    }
                } catch let error as UnixSocketHTTPClient.ClientError {
                    // Lost response: the create may still have landed —
                    // verify against actual state instead of failing.
                    let verify = try? execAdmin(
                        client: client, engine: engine,
                        command: KegDatabaseStatements.databaseExistsCommand(
                            engine: engine, name: database, superuser: server.superuser, password: server.password
                        ),
                        idempotent: true
                    )
                    let landed = verify?.stdout.split(whereSeparator: \.isNewline)
                        .contains(where: { $0.trimmingCharacters(in: .whitespaces) == database || $0.trimmingCharacters(in: .whitespaces) == "1" }) == true
                    guard landed else { throw error }
                    print("database '\(database)' created (response was lost; verified)")
                }
            }

            if let role, engine.id == "postgres" {
                let validatedRole = try KegDatabaseNames.validateDatabaseName(role)
                rolePassword = passwordOption ?? randomToken()
                let roleResult = try execAdmin(
                    client: client, engine: engine,
                    command: KegDatabaseStatements.createRoleCommand(
                        engine: engine, role: validatedRole, password: rolePassword!,
                        database: database, superuser: server.superuser
                    ),
                    idempotent: true
                )
                guard roleResult.exitCode == 0 else {
                    throw KegDatabaseError("CREATE ROLE failed (exit \(roleResult.exitCode)): \(roleResult.stderr)")
                }
            }
        }

        // Output: URL first-class.
        let target = database ?? (engine.id == "redis" ? "0" : "")
        let url: String
        if engine.id == "redis" {
            url = KegDatabaseURLs.url(engine: engine, server: server, database: target)
        } else if let database {
            if let role, let rolePassword {
                url = "\(engine.scheme)://\(role):\(rolePassword)@127.0.0.1:\(server.port)/\(database)"
            } else {
                url = KegDatabaseURLs.url(engine: engine, server: server, database: database)
            }
        } else {
            url = KegDatabaseURLs.display(engine: engine, server: server, database: "")
        }

        if json {
            let object: [String: Any] = [
                "engine": engine.id,
                "container": engine.containerName,
                "port": server.port,
                "database": database ?? "",
                "url": url,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("")
            print("  \(engine.displayName) ready at 127.0.0.1:\(server.port)")
            if let database { print("  database:  \(database)") }
            if let role { print("  role:      \(role)") }
            print("")
            print("  export DATABASE_URL='\(url)'")
            print("")
        }
        return 0
    }

    // MARK: - drop / url / run / remove

    private static func drop(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        guard operands.count >= 2 else {
            print("usage: keg db drop <engine> <database>")
            return 2
        }
        let engine = try KegDatabaseEngine.engine(operands[0])
        let database = try KegDatabaseNames.validateDatabaseName(operands[1])
        let client = try requireClient(socketOverride, print: print)
        let server = try requireServer(engine, client: client)
        let result = try execAdmin(
            client: client, engine: engine,
            command: KegDatabaseStatements.dropDatabaseCommand(
                engine: engine, name: database, superuser: server.superuser, password: server.password
            ),
            idempotent: true
        )
        guard result.exitCode == 0 else {
            throw KegDatabaseError("DROP DATABASE failed (exit \(result.exitCode)): \(result.stderr)")
        }
        print("dropped '\(database)' from \(engine.containerName)")
        return 0
    }

    private static func url(_ operands: [String], print: (String) -> Void) throws -> Int32 {
        guard let engineID = operands.first else {
            print("usage: keg db url <engine> [database]")
            return 2
        }
        let engine = try KegDatabaseEngine.engine(engineID)
        let registry = KegDatabaseRegistry().load()
        guard let server = registry.server(for: engine) else {
            throw KegDatabaseError("no \(engine.id) server — run: keg db ensure \(engine.id)")
        }
        let database = operands.count > 1 ? operands[1] : ""
        print(KegDatabaseURLs.url(engine: engine, server: server, database: database))
        return 0
    }

    private static func runCommand(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        guard let engineID = operands.first, let dash = operands.firstIndex(of: "--"), dash + 1 < operands.count else {
            print("usage: keg db run <engine> -- <cmd…>")
            return 2
        }
        let engine = try KegDatabaseEngine.engine(engineID)
        let command = Array(operands[(dash + 1)...])
        let client = try requireClient(socketOverride, print: print)
        _ = try requireServer(engine, client: client)
        let result = try KegExecCapture.run(
            socketPath: client.http.socketPath,
            container: engine.containerName,
            command: command
        )
        if !result.stdout.isEmpty { FileHandle.standardOutput.write(Data(result.stdout.utf8)) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        return result.exitCode
    }

    private static func remove(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        guard let engineID = operands.first else {
            print("usage: keg db remove <engine> [--delete-data]")
            return 2
        }
        let engine = try KegDatabaseEngine.engine(engineID)
        let deleteData = operands.contains("--delete-data")
        let client = try requireClient(socketOverride, print: print)
        let existing = try client.containers(all: true)
        if existing.contains(where: { $0.displayName == engine.containerName }) {
            try? client.stop(id: engine.containerName, timeoutSeconds: 300)
            try client.remove(id: engine.containerName, force: true, timeoutSeconds: 300)
            print("removed \(engine.containerName)")
        } else {
            print("no \(engine.containerName) container")
        }
        var registry = KegDatabaseRegistry().load()
        registry.remove(engine: engine)
        try registry.save()
        if deleteData {
            // The server's data is a runtime named volume.
            _ = try? client.http.delete("/volumes/\(engine.volumeName())")
            print("deleted volume \(engine.volumeName())")
        } else {
            print("data kept in runtime volume \(engine.volumeName()) — pass --delete-data to erase")
        }
        return 0
    }

    // MARK: - Helpers

    private static func option(_ operands: [String], _ name: String) -> String? {
        guard let index = operands.firstIndex(of: name), index + 1 < operands.count else { return nil }
        return operands[index + 1]
    }

    private static func requireClient(_ socketOverride: String?, print: (String) -> Void) throws -> KegAPIClient {
        let path = socketOverride ?? KegSocketResolver.resolve()
        guard let path else {
            print("Keg is not running — no Docker API socket found.")
            print("Open the Keg app (or run: keg open), then retry.")
            throw KegDatabaseError("no socket")
        }
        return KegAPIClient(socketPath: path, timeoutSeconds: 60)
    }

    private static func requireServer(_ engine: KegDatabaseEngine, client: KegAPIClient) throws -> KegDatabaseServer {
        let registry = KegDatabaseRegistry().load()
        guard let server = registry.server(for: engine) else {
            throw KegDatabaseError("no \(engine.id) server — run: keg db ensure \(engine.id)")
        }
        let existing = try client.containers(all: true)
        guard existing.contains(where: { $0.displayName == engine.containerName && $0.state == "running" }) else {
            throw KegDatabaseError("\(engine.containerName) is not running — run: keg db ensure \(engine.id)")
        }
        return server
    }

    private static func adoptFromLabels(engine: KegDatabaseEngine, client: KegAPIClient) -> KegDatabaseServer? {
        guard let inspected = try? client.inspect(id: engine.containerName),
              let labels = inspected.labels,
              labels[KegDatabaseContainers.engineLabel] == engine.id,
              let port = labels[KegDatabaseContainers.portLabel].flatMap(Int.init) else { return nil }
        return KegDatabaseServer(
            engine: engine.id,
            containerName: engine.containerName,
            port: port,
            superuser: labels["com.keg.db.superuser"] ?? (engine.id == "postgres" ? "keg" : "root"),
            password: labels["com.keg.db.password"] ?? "",
            volume: engine.volumeName()
        )
    }

    /// Runs an admin exec inside the server container. A lost response (the
    /// intermittent channel swallow surfacing as a client-side timeout) is
    /// retried once on fresh connections when the command is idempotent;
    /// callers of non-idempotent commands verify state themselves.
    private static func execAdmin(
        client: KegAPIClient,
        engine: KegDatabaseEngine,
        command: [String],
        idempotent: Bool
    ) throws -> KegExecResult {
        do {
            return try KegExecCapture.run(
                socketPath: client.http.socketPath,
                container: engine.containerName,
                command: command
            )
        } catch let error as UnixSocketHTTPClient.ClientError {
            guard idempotent else { throw error }
            Thread.sleep(forTimeInterval: 1)
            return try KegExecCapture.run(
                socketPath: client.http.socketPath,
                container: engine.containerName,
                command: command
            )
        }
    }

    /// Poll the engine's readiness probe until it answers (image first boot
    /// runs initdb, which takes a while).
    private static func waitReady(engine: KegDatabaseEngine, server: KegDatabaseServer, client: KegAPIClient) throws {
        let command = KegDatabaseStatements.readinessCommand(
            engine: engine, superuser: server.superuser, password: server.password
        )
        for attempt in 0..<120 {
            Thread.sleep(forTimeInterval: attempt < 5 ? 1 : 2)
            if let result = try? KegExecCapture.run(
                socketPath: client.http.socketPath,
                container: engine.containerName,
                command: command,
                timeoutSeconds: 15
            ), result.exitCode == 0 {
                return
            }
        }
        throw KegDatabaseError("\(engine.containerName) did not become ready in time — check: keg logs \(engine.containerName)")
    }

    static func randomToken(length: Int = 24) -> String {
        let alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
