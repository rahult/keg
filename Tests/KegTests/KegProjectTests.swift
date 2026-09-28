import XCTest
@testable import KegCLICore

/// The keg.yaml project config: parsing, validation, interpolation,
/// ordering, the create-request contract, scaffolding, and the agent skill.
/// Pure logic — no sockets, no runtime.
final class KegProjectTests: XCTestCase {

    // MARK: - Parsing

    let fullConfig = """
    name: shop
    services:
      web:
        image: nginx:1.27
        ports:
          - "8080:80"
          - "127.0.0.1:8443:443"
          - "5353:53/udp"
        environment:
          - NGINX_PORT=80
        labels:
          team: platform
        restart: unless-stopped
      api:
        build:
          context: ./api
          dockerfile: Containerfile
          args:
            FLAVOR: dev
        command: ["./server", "--port", "9000"]
        workdir: /srv
        depends_on: [web]
        volumes:
          - ./data:/var/lib/api
          - apicache:/var/cache
    """

    func testParseFullConfig() throws {
        let config = try KegProjectLoader.parse(text: fullConfig, directory: "/tmp/shop")
        XCTAssertEqual(config.name, "shop")
        XCTAssertEqual(config.services.count, 2)

        let web = try XCTUnwrap(config.services["web"])
        XCTAssertEqual(web.image, "nginx:1.27")
        XCTAssertEqual(web.ports, [
            KegPortMapping(hostPort: 8080, containerPort: 80),
            KegPortMapping(hostIP: "127.0.0.1", hostPort: 8443, containerPort: 443),
            KegPortMapping(hostPort: 5353, containerPort: 53, proto: "udp"),
        ])
        XCTAssertEqual(web.environment["NGINX_PORT"], "80")
        XCTAssertEqual(web.labels["team"], "platform")
        XCTAssertEqual(web.restart, "unless-stopped")

        let api = try XCTUnwrap(config.services["api"])
        XCTAssertEqual(api.build, KegBuild(context: "./api", dockerfile: "Containerfile", args: ["FLAVOR": "dev"]))
        XCTAssertEqual(api.command, ["./server", "--port", "9000"])
        XCTAssertEqual(api.workdir, "/srv")
        XCTAssertEqual(api.dependsOn, ["web"])
        XCTAssertEqual(api.volumes, ["./data:/var/lib/api", "apicache:/var/cache"])
    }

    func testParseStringCommandSplitsOnWhitespace() throws {
        let config = try KegProjectLoader.parse(
            text: "services:\n  a:\n  \n    image: alpine\n    command: sleep 3600\n",
            directory: "/tmp"
        )
        XCTAssertEqual(config.services["a"]?.command, ["sleep", "3600"])
    }

    func testParseEnvironmentMapForm() throws {
        let config = try KegProjectLoader.parse(
            text: "services:\n  a:\n    image: alpine\n    environment:\n      KEY: value\n      COUNT: 3\n",
            directory: "/tmp"
        )
        XCTAssertEqual(config.services["a"]?.environment, ["KEY": "value", "COUNT": "3"])
    }

    func testParseStandaloneBuildString() throws {
        let config = try KegProjectLoader.parse(
            text: "services:\n  a:\n    build: .\n",
            directory: "/tmp"
        )
        XCTAssertEqual(config.services["a"]?.build, KegBuild(context: "."))
    }

    func testParseErrors() {
        XCTAssertThrowsError(try KegProjectLoader.parse(
            text: "services:\n  a: {}\n", directory: "/tmp"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("image"), "\(error)")
        }
        XCTAssertThrowsError(try KegProjectLoader.parse(
            text: "version: 9\nservices:\n  a:\n    image: alpine\n", directory: "/tmp"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("version"), "\(error)")
        }
        XCTAssertThrowsError(try KegProjectLoader.parse(
            text: "services: {}\n", directory: "/tmp"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("no services"), "\(error)")
        }
        XCTAssertThrowsError(try KegProjectLoader.parse(
            text: "services:\n  BadName:\n    image: alpine\n", directory: "/tmp"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("invalid service name"), "\(error)")
        }
    }

    // MARK: - Ports

    func testPortParsingRejectsUnpublishableAndUnsafePorts() {
        XCTAssertThrowsError(try KegProjectLoader.parsePort("80", service: "a"))
        XCTAssertThrowsError(try KegProjectLoader.parsePort("80:80", service: "a")) // host ≤1024
        XCTAssertThrowsError(try KegProjectLoader.parsePort("http:80", service: "a"))
        XCTAssertThrowsError(try KegProjectLoader.parsePort("8080:80/icmp", service: "a"))
        XCTAssertNoThrow(try KegProjectLoader.parsePort("1025:80", service: "a"))
        XCTAssertEqual(try KegProjectLoader.parsePort("1.2.3.4:8080:80", service: "a").hostIP, "1.2.3.4")
    }

    // MARK: - Interpolation

    func testInterpolationForms() throws {
        let vars = ["HOST": "db.example", "EMPTY": ""]
        XCTAssertEqual(try KegProjectLoader.interpolate("http://${HOST}:8080", vars: vars, context: "t"),
                       "http://db.example:8080")
        XCTAssertEqual(try KegProjectLoader.interpolate("${MISSING:-fallback}", vars: vars, context: "t"),
                       "fallback")
        XCTAssertEqual(try KegProjectLoader.interpolate("$HOST/x", vars: vars, context: "t"),
                       "db.example/x")
        XCTAssertEqual(try KegProjectLoader.interpolate("v=${EMPTY}", vars: vars, context: "t"),
                       "v=")
        XCTAssertThrowsError(try KegProjectLoader.interpolate("${MISSING}", vars: vars, context: "svc: env"))
        XCTAssertThrowsError(try KegProjectLoader.interpolate("$MISSING", vars: vars, context: "t"))
        XCTAssertThrowsError(try KegProjectLoader.interpolate("dead${{beef", vars: vars, context: "t"))
    }

    func testDotEnvLoading() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        # comment
        PLAIN=value
        export EXPORTED=yes
        QUOTED="double quoted"
        SINGLE='single'
        SPACED  =  trimmed
        INVALID_LINE
        """.write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let loaded = DotEnvFile.load(url: dir.appendingPathComponent(".env"))
        XCTAssertEqual(loaded["PLAIN"], "value")
        XCTAssertEqual(loaded["EXPORTED"], "yes")
        XCTAssertEqual(loaded["QUOTED"], "double quoted")
        XCTAssertEqual(loaded["SINGLE"], "single")
        XCTAssertEqual(loaded["SPACED"], "trimmed")
        XCTAssertEqual(loaded.count, 5)
    }

    // MARK: - End-to-end load (interpolation + .env + env_file + binds)

    func testLoadResolvesEnvAndRelativeBinds() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "SECRET=s3cret\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "EXTRA=fromfile\n".write(to: dir.appendingPathComponent("more.env"), atomically: true, encoding: .utf8)
        try """
        name: demo
        services:
          app:
            image: alpine:${TAG:-3.20}
            environment:
              - SECRET=${SECRET}
            env_file: ./more.env
            volumes:
              - ./data:/data
              - ./../outside:/outside:ro
              - named:/var/lib
        """.write(to: dir.appendingPathComponent("keg.yaml"), atomically: true, encoding: .utf8)

        // env_file values join the container env (not the interpolation
        // source) — compose semantics.
        let config = try KegProjectLoader.load(directory: dir.path, environment: [:])
        let app = try XCTUnwrap(config.services["app"])
        XCTAssertEqual(app.image, "alpine:3.20")
        XCTAssertEqual(app.environment["SECRET"], "s3cret")
        XCTAssertEqual(app.environment["EXTRA"], "fromfile")
        XCTAssertEqual(app.volumes, [
            "\(dir.appendingPathComponent("data").path):/data",
            "\(dir.deletingLastPathComponent().appendingPathComponent("outside").standardizedFileURL.path):/outside:ro",
            "named:/var/lib",
        ])
    }

    func testLoadFailsOnMissingInterpolationVariable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        services:
          app:
            image: alpine
            environment:
              - NEEDS=${NOT_SET_ANYWHERE}
        """.write(to: dir.appendingPathComponent("keg.yaml"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try KegProjectLoader.load(directory: dir.path, environment: [:])) { error in
            XCTAssertTrue(String(describing: error).contains("NOT_SET_ANYWHERE"), "\(error)")
        }
    }

    func testShellEnvironmentOverridesDotEnv() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "WHO=dotenv\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try """
        services:
          app:
            image: alpine
            environment:
              - WHO=${WHO}
        """.write(to: dir.appendingPathComponent("keg.yaml"), atomically: true, encoding: .utf8)

        let config = try KegProjectLoader.load(directory: dir.path, environment: ["WHO": "shell"])
        XCTAssertEqual(config.services["app"]?.environment["WHO"], "shell")
    }

    // MARK: - Ordering + naming

    func testDependencyOrdering() throws {
        let config = try KegProjectLoader.parse(
            text: """
            services:
              web:
                image: a
                depends_on: [api, db]
              api:
                image: b
                depends_on: [db]
              db:
                image: c
            """,
            directory: "/tmp"
        )
        XCTAssertEqual(try KegProjectLoader.orderedServiceNames(in: config), ["db", "api", "web"])
    }

    func testCycleDetection() throws {
        let config = try KegProjectLoader.parse(
            text: """
            services:
              a:
                image: x
                depends_on: [b]
              b:
                image: y
                depends_on: [a]
            """,
            directory: "/tmp"
        )
        XCTAssertThrowsError(try KegProjectLoader.orderedServiceNames(in: config)) { error in
            XCTAssertTrue(String(describing: error).contains("circular"), "\(error)")
        }
    }

    func testUnknownDependencyRejected() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        services:
          app:
            image: alpine
            depends_on: [ghost]
        """.write(to: dir.appendingPathComponent("keg.yaml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try KegProjectLoader.load(directory: dir.path, environment: [:]))
    }

    func testNamingConventions() {
        XCTAssertEqual(KegProjectLoader.sanitizeName("My Fancy App!"), "my-fancy-app")
        // Underscores become dashes and runs collapse — valid for containers.
        XCTAssertEqual(KegProjectLoader.sanitizeName("---weird__name---"), "weird-name")
        XCTAssertEqual(KegProjectLoader.containerName(project: "shop", service: "api"), "shop-api-1")
        XCTAssertEqual(KegProjectLoader.builtImageTag(project: "shop", service: "api"), "shop-api:local")
        XCTAssertTrue(KegProjectLoader.validServiceName("web-1"))
        XCTAssertTrue(KegProjectLoader.validServiceName("1web")) // digits are fine (compose parity)
        XCTAssertFalse(KegProjectLoader.validServiceName("has space"))
        XCTAssertFalse(KegProjectLoader.validServiceName("-leading"))
        XCTAssertFalse(KegProjectLoader.validServiceName(""))
    }

    // MARK: - Volumes

    func testVolumeResolution() throws {
        let dir = URL(filePath: "/tmp/proj")
        XCTAssertEqual(
            try KegProjectLoader.resolveVolume("./data:/x", name: "a", projectDir: dir),
            "\(dir.appendingPathComponent("data").path):/x"
        )
        // Bare sources are named volumes (compose semantics) — passthrough.
        XCTAssertEqual(
            try KegProjectLoader.resolveVolume("data:/x", name: "a", projectDir: dir),
            "data:/x"
        )
        XCTAssertEqual(
            try KegProjectLoader.resolveVolume("/abs:/x:ro", name: "a", projectDir: dir),
            "/abs:/x:ro"
        )
        XCTAssertEqual(
            try KegProjectLoader.resolveVolume("named:/x", name: "a", projectDir: dir),
            "named:/x"
        )
        XCTAssertThrowsError(try KegProjectLoader.resolveVolume("onlysource", name: "a", projectDir: dir))
        XCTAssertThrowsError(try KegProjectLoader.resolveVolume("a:relative/target", name: "a", projectDir: dir))
    }

    // MARK: - Create request contract (wire shape)

    func testCreateRequestWireShape() throws {
        var service = KegService()
        service.image = "redis:7"
        service.ports = [KegPortMapping(hostPort: 6379, containerPort: 6379)]
        service.environment = ["B": "2", "A": "1"]
        service.volumes = ["data:/data"]
        service.restart = "unless-stopped"
        service.command = ["redis-server"]
        service.entrypoint = ["docker-entrypoint.sh", "--verbose"]

        let request = KegContainerCreateRequest.make(for: service, name: "cache", project: "shop")
        XCTAssertEqual(request.image, "redis:7")
        XCTAssertEqual(request.entrypoint, ["docker-entrypoint.sh", "--verbose"])
        // Commands run via non-login `sh -c` with `exec` — the runtime
        // can't resolve relative command names without it.
        XCTAssertEqual(request.cmd, ["/bin/sh", "-c", "exec redis-server"])
        XCTAssertEqual(request.env, ["A=1", "B=2"]) // sorted, stable
        XCTAssertEqual(request.labels["com.docker.compose.project"], "shop")
        XCTAssertEqual(request.labels["com.docker.compose.service"], "cache")
        XCTAssertEqual(request.hostConfig.restartPolicy?.name, "unless-stopped")
        XCTAssertEqual(request.hostConfig.binds, ["data:/data"])
        XCTAssertEqual(request.hostConfig.portBindings["6379/tcp"]?.first?.hostPort, "6379")

        // The JSON must match what Keg's Docker API bridge decodes.
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["Image"] as? String, "redis:7")
        XCTAssertEqual(object["Entrypoint"] as? [String], ["docker-entrypoint.sh", "--verbose"])
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        let bindings = try XCTUnwrap(hostConfig["PortBindings"] as? [String: Any])
        let binding = try XCTUnwrap((bindings["6379/tcp"] as? [[String: Any]])?.first)
        XCTAssertEqual(binding["HostPort"] as? String, "6379")
    }

    func testBuiltServiceUsesProjectImageTag() {
        var service = KegService()
        service.build = KegBuild(context: ".")
        let request = KegContainerCreateRequest.make(for: service, name: "web", project: "shop")
        XCTAssertEqual(request.image, "shop-web:local")
        XCTAssertNil(request.cmd)
    }

    func testCommandTokensWithSpacesRoundTripThroughShellQuoting() {
        var service = KegService()
        service.image = "alpine"
        service.command = ["echo", "hello world", "it's"]
        let request = KegContainerCreateRequest.make(for: service, name: "a", project: "p")
        XCTAssertEqual(request.cmd, ["/bin/sh", "-c", "exec echo 'hello world' 'it'\\''s'"])
    }

    // MARK: - Scaffolding

    func testStackDetection() throws {
        func detectWith(_ files: [String]) throws -> KegProjectScaffold.Stack {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            for file in files {
                try "".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            return KegProjectScaffold.detect(directory: dir)
        }
        XCTAssertEqual(try detectWith(["package.json"]), .node)
        XCTAssertEqual(try detectWith(["requirements.txt"]), .python)
        XCTAssertEqual(try detectWith(["go.mod"]), .go)
        XCTAssertEqual(try detectWith(["Cargo.toml"]), .rust)
        XCTAssertEqual(try detectWith(["Package.swift"]), .swift)
        XCTAssertEqual(try detectWith(["Dockerfile"]), .dockerfile)
        XCTAssertEqual(try detectWith(["README.md"]), .generic)
        // A repo with both gets the app-stack template, not the Dockerfile one.
        XCTAssertEqual(try detectWith(["package.json", "Dockerfile"]), .node)
    }

    func testEveryScaffoldTemplateParses() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for stack in KegProjectScaffold.Stack.allCases {
            let text = KegProjectScaffold.template(for: stack, projectName: "acme")
            let config = try KegProjectLoader.parse(text: text, directory: dir.path)
            XCTAssertFalse(config.services.isEmpty, "stack \(stack) produced no services")
        }
    }

    func testWriteRefusesToOverwriteWithoutForce() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try KegProjectScaffold.write(directory: dir, force: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertThrowsError(try KegProjectScaffold.write(directory: dir, force: false))
        XCTAssertNoThrow(try KegProjectScaffold.write(directory: dir, force: true))
    }

    func testInitThenUpPathNamesAreConsistent() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try KegProjectScaffold.write(directory: dir, force: false)
        let config = try KegProjectLoader.load(directory: dir.path, environment: [:])
        XCTAssertEqual(config.name, KegProjectLoader.sanitizeName(dir.lastPathComponent))
        for service in config.services.keys {
            XCTAssertEqual(
                KegProjectLoader.containerName(project: config.name, service: service),
                "\(config.name)-\(service)-1"
            )
        }
    }

    // MARK: - Skill

    func testSkillShipsWithFrontmatterAndGuidance() throws {
        let text = try KegSkill.skillText()
        XCTAssertTrue(text.hasPrefix("---\nname: keg\n"), "skill must start with agent-skill frontmatter")
        XCTAssertTrue(text.contains("description:"), "frontmatter needs a discovery description")
        // The workflow an agent follows must be present with the real verbs.
        for needle in ["keg project up", "keg project down", "keg project status", "keg.yaml"] {
            XCTAssertTrue(text.contains(needle), "skill should mention \(needle)")
        }
    }

    func testSkillInstallRoundTrip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let packaged = try KegSkill.skillText()

        let created = try KegSkill.install(into: dir, packagedText: packaged)
        XCTAssertEqual(created, .created(dir.appendingPathComponent("SKILL.md")))
        XCTAssertEqual(KegSkill.state(at: dir, packagedText: packaged), .upToDate)

        try "stale".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(KegSkill.state(at: dir, packagedText: packaged), .outdated)
        let updated = try KegSkill.install(into: dir, packagedText: packaged)
        XCTAssertEqual(updated, .updated(dir.appendingPathComponent("SKILL.md")))

        let unchanged = try KegSkill.install(into: dir, packagedText: packaged)
        XCTAssertEqual(unchanged, .unchanged(dir.appendingPathComponent("SKILL.md")))

        try KegSkill.uninstall(from: dir)
        XCTAssertEqual(KegSkill.state(at: dir, packagedText: packaged), .missing)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-project-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
