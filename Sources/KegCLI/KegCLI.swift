import Foundation
import KegCLICore

/// Command dispatch and implementations. `run` is the entry point from
/// main.swift; it returns a process exit code.
enum KegCLI {
    static let usage = """
    keg — companion CLI for the Keg app

    USAGE
      keg <command> [options]

    COMMANDS
      status                 App, socket and runtime health at a glance
      doctor                 Diagnostics with pass/fail checks and hints
      version                CLI version and the app's API version
      env                    Print shell exports for Docker tooling
      ps [-a]                List containers (all states with -a)
      images                 List images
      logs <id> [-f] [-n N]  Container logs (-f follows until it stops)
      exec [opts] <id> cmd…  Run a command in a container and stream its
                             output (-i stdin, -t tty, -e K=V, -w dir,
                             -u user); exit code propagates
      attach <id>            Attach to a running container's output (with
                             recent history); -i also forwards stdin
      start <id>…            Start containers
      stop <id>…             Stop containers
      restart <id>…          Restart containers
      rm [-f] <id>…          Remove containers (-f removes running ones)
      open [section]         Open the Keg app (containers, images, compose,
                             kubernetes, networks, volumes, logs, terminal,
                             dashboard, settings)
      install [dir]          Install keg onto PATH (default picks the best
                             writable location; prints a PATH hint when the
                             user-level fallback is used)
      uninstall              Remove the installed keg link
      help                   Show this help

    OPTIONS
      --socket <path>        Talk to a specific Keg socket
      --version              Print the CLI version

    The container operations speak Keg's Docker-compatible socket directly;
    no docker CLI is needed. Full docker workflows (run, exec, build) work
    with the docker CLI against the same socket — `keg env` prints the line.
    """

    // MARK: - Entry point

    static func run(_ arguments: [String], print: (String) -> Void) -> Int32 {
        var args = arguments
        var socketOverride: String?

        // Global options can appear anywhere before the command's operands.
        var filtered: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--socket", index + 1 < args.count {
                socketOverride = args[index + 1]
                index += 2
                continue
            }
            if arg == "--version" {
                print("keg \(KegCLIVersion.current)")
                return 0
            }
            filtered.append(arg)
            index += 1
        }
        args = filtered

        guard let command = args.first else {
            print(usage)
            return 0
        }
        let operands = Array(args.dropFirst())

        switch command {
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "status": return status(socketOverride: socketOverride, print: print)
        case "doctor": return doctor(socketOverride: socketOverride, print: print)
        case "version": return version(socketOverride: socketOverride, print: print)
        case "env": return env(operands: operands, print: print)
        case "ps": return ps(operands: operands, socketOverride: socketOverride, print: print)
        case "images": return images(socketOverride: socketOverride, print: print)
        case "logs": return logs(operands: operands, socketOverride: socketOverride, print: print)
        case "exec": return exec(operands: operands, socketOverride: socketOverride, print: print)
        case "attach": return attach(operands: operands, socketOverride: socketOverride, print: print)
        case "start": return lifecycle(.start, operands: operands, socketOverride: socketOverride, print: print)
        case "stop": return lifecycle(.stop, operands: operands, socketOverride: socketOverride, print: print)
        case "restart": return lifecycle(.restart, operands: operands, socketOverride: socketOverride, print: print)
        case "rm": return remove(operands: operands, socketOverride: socketOverride, print: print)
        case "open": return openApp(operands: operands, print: print)
        case "install": return install(operands: operands, print: print)
        case "uninstall": return uninstall(print: print)
        default:
            print("unknown command: \(command)\n")
            print(usage)
            return 1
        }
    }

    // MARK: - Shared helpers

    private static func client(_ override: String?) -> KegAPIClient? {
        let path = override ?? KegSocketResolver.resolve()
        guard let path else { return nil }
        return KegAPIClient(socketPath: path)
    }

    private static func requireClient(_ override: String?, print: (String) -> Void) -> KegAPIClient? {
        if let client = client(override) {
            return client
        }
        print("Keg is not running — no Docker API socket found.")
        print("Open the Keg app (or run: keg open), then retry.")
        return nil
    }

    // MARK: - status / doctor / version

    static func status(socketOverride: String?, print: (String) -> Void) -> Int32 {
        guard let client = requireClient(socketOverride, print: print) else { return 1 }
        do {
            _ = try client.ping()
            let version = try client.systemVersion()
            let containers = try client.containers(all: true)
            let images = try client.images()
            let running = containers.filter { $0.state == "running" }.count

            print("Keg \(version.version)  ·  API \(version.apiVersion)  ·  \(httpSocket(client))")
            print("  Containers   \(running) running, \(containers.count - running) stopped")
            print("  Images       \(images.count)")
            print("  Isolation    one microVM per container (Apple Containerization)")
            return 0
        } catch {
            print("Keg socket found but unresponsive: \(error)")
            return 1
        }
    }

    static func doctor(socketOverride: String?, print: (String) -> Void) -> Int32 {
        var failures = 0

        func check(_ name: String, _ ok: Bool, hint: String) {
            if ok {
                print("  ✓ \(name)")
            } else {
                failures += 1
                print("  ✗ \(name)")
                print("      → \(hint)")
            }
        }

        // 1. Socket
        let socketPath = socketOverride ?? KegSocketResolver.resolve()
        check(
            "Keg Docker API socket",
            socketPath != nil,
            hint: "open the Keg app, or start the Docker API from Settings → Docker API"
        )

        guard let path = socketPath, let client = client(socketOverride) else {
            print("  ✗ remaining checks need the socket")
            return 1
        }
        print("     socket: \(path)")

        // 2. Ping + version negotiation
        let ping = (try? client.ping()) ?? false
        check("API answers /_ping", ping, hint: "restart the Docker API from Settings")

        // 3. Runtime CLI
        let containerCLI = [
            "/opt/homebrew/bin/container",
            "/usr/local/bin/container",
            NSHomeDirectory() + "/.keg/platform/bin/container",
            "/opt/container/bin/container",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
        check(
            "Apple container CLI installed",
            containerCLI != nil,
            hint: "brew install container, or Settings → Container CLI → Install"
        )
        if let containerCLI {
            print("     cli: \(containerCLI)")
        }

        // 4. keg itself on PATH
        let installed = KegCLIInstall.installedLink()
        check(
            "keg on PATH",
            installed != nil,
            hint: "run `keg install` (or Settings → Keg CLI → Install)"
        )
        if let installed {
            print("     link: \(installed.linkPath)")
        }

        // 5. Containers respond
        let containers = try? client.containers(all: true)
        check("container list responds", containers != nil, hint: "check ~/.keg/docker-api.log for errors")

        if failures == 0 {
            print("\n  all checks passed")
            return 0
        }
        print("\n  \(failures) check\(failures == 1 ? "" : "s") failed")
        return 1
    }

    static func version(socketOverride: String?, print: (String) -> Void) -> Int32 {
        print("keg \(KegCLIVersion.current)")
        if let client = client(socketOverride), let server = try? client.systemVersion() {
            print("Keg \(server.version) (Docker API \(server.apiVersion), \(server.os)/\(server.arch))")
        }
        return 0
    }

    // MARK: - env

    static func env(operands: [String], print: (String) -> Void) -> Int32 {
        guard let socket = KegSocketResolver.resolve() else {
            print("Keg is not running — no Docker API socket found.")
            return 1
        }
        let unset = operands.contains("--unset")
        if unset {
            print("unset DOCKER_HOST")
            return 0
        }
        print("export DOCKER_HOST=unix://\(socket)")
        return 0
    }

    // MARK: - ps / images

    static func ps(operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        guard let client = requireClient(socketOverride, print: print) else { return 1 }
        do {
            let all = operands.contains("-a") || operands.contains("--all")
            let containers = try client.containers(all: all)
            guard !containers.isEmpty else {
                print(all ? "no containers" : "no running containers (try: keg ps -a)")
                return 0
            }
            let rows = containers.map { container in
                [
                    container.displayName,
                    OutputFormatting.stateBadge(container.state),
                    container.image,
                    OutputFormatting.ago(epochSeconds: container.created),
                ]
            }
            print(OutputFormatting.table(headers: ["NAME", "STATE", "IMAGE", "CREATED"], rows: rows))
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    static func images(socketOverride: String?, print: (String) -> Void) -> Int32 {
        guard let client = requireClient(socketOverride, print: print) else { return 1 }
        do {
            let images = try client.images()
            guard !images.isEmpty else {
                print("no images (pull one from the Images screen or: docker pull alpine)")
                return 0
            }
            let rows = images.map { image in
                [
                    image.displayName,
                    OutputFormatting.byteCount(image.size),
                    OutputFormatting.ago(epochSeconds: image.created),
                ]
            }
            print(OutputFormatting.table(headers: ["IMAGE", "SIZE", "CREATED"], rows: rows))
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    // MARK: - logs

    static func logs(operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        var id: String?
        var tail: Int?
        var follow = false
        var index = 0
        while index < operands.count {
            switch operands[index] {
            case "-f", "--follow": follow = true
            case "-n", "--tail":
                index += 1
                if index < operands.count { tail = Int(operands[index]) }
            default:
                if id == nil { id = operands[index] }
            }
            index += 1
        }
        guard let id else {
            print("usage: keg logs <id> [-f] [-n N]")
            return 2
        }
        guard let client = requireClient(socketOverride, print: print) else { return 1 }

        func dump(_ data: Data) {
            let output = DockerLogDemuxer.demux(data)
            for text in [output.stdout, output.stderr] {
                if !text.isEmpty, let string = String(data: text, encoding: .utf8) {
                    FileHandle.standardOutput.write(Data(string.utf8))
                }
            }
        }

        do {
            var consumed = 0
            var firstPass = true
            while true {
                // Poll with the requested tail on the first pass (history),
                // then stream new bytes until the container stops. Offsets
                // track the raw framed stream — whole frames stay whole.
                let data = try client.logs(id: id, tail: firstPass ? tail : nil)
                firstPass = false
                if data.count > consumed {
                    dump(Data(data.dropFirst(consumed)))
                    consumed = data.count
                }
                guard follow else { break }

                if let inspect = try? client.inspect(id: id), !inspect.state.running {
                    break
                }
                Thread.sleep(forTimeInterval: 0.7)
            }
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    // MARK: - exec

    /// `keg exec [-i] [-t] [-e K=V]… [-w dir] [-u user] <id> cmd [args…]`
    /// Mirrors docker exec semantics through the hijack protocol; the
    /// command's exit code becomes keg's own.
    static func exec(operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        var interactive = false
        var tty = false
        var environment: [String] = []
        var workingDirectory: String?
        var user: String?
        var rest: [String] = []

        var index = 0
        while index < operands.count {
            let arg = operands[index]
            switch arg {
            case "-i", "--interactive": interactive = true
            case "-t", "--tty": tty = true
            case "-e", "--env":
                index += 1
                if index < operands.count { environment.append(operands[index]) }
            case "-w", "--workdir":
                index += 1
                if index < operands.count { workingDirectory = operands[index] }
            case "-u", "--user":
                index += 1
                if index < operands.count { user = operands[index] }
            default:
                rest.append(arg)
            }
            index += 1
        }

        guard rest.count >= 2, !rest[0].isEmpty else {
            print("usage: keg exec [-i] [-t] [-e K=V]… [-w dir] [-u user] <id> cmd [args…]")
            return 2
        }
        guard let socketPath = socketOverride ?? KegSocketResolver.resolve() else {
            print("Keg is not running — no Docker API socket found.")
            print("Open the Keg app (or run: keg open), then retry.")
            return 1
        }

        let options = KegExecOptions(
            command: Array(rest.dropFirst()),
            interactive: interactive,
            tty: tty,
            environment: environment,
            workingDirectory: workingDirectory,
            user: user
        )
        let session = KegExecSession(socketPath: socketPath, containerID: rest[0])
        do {
            return try session.run(options)
        } catch {
            print("\(error)")
            return 1
        }
    }

    // MARK: - attach

    /// `keg attach [-i] <id>` — stream a container's retained output
    /// (history first), forwarding stdin with -i.
    static func attach(operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        let interactive = operands.contains("-i") || operands.contains("--interactive")
        let ids = operands.filter { !$0.hasPrefix("-") }
        guard let id = ids.first, !id.isEmpty else {
            print("usage: keg attach [-i] <id>")
            return 2
        }
        guard let socketPath = socketOverride ?? KegSocketResolver.resolve() else {
            print("Keg is not running — no Docker API socket found.")
            return 1
        }
        let session = KegAttachSession(socketPath: socketPath, containerID: id)
        do {
            return try session.run(interactive: interactive)
        } catch {
            print("\(error)")
            return 1
        }
    }

    // MARK: - lifecycle

    private enum LifecycleAction {
        case start, stop, restart

        var verb: String {
            switch self {
            case .start: return "started"
            case .stop: return "stopped"
            case .restart: return "restarted"
            }
        }
    }

    private static func lifecycle(
        _ action: LifecycleAction,
        operands: [String],
        socketOverride: String?,
        print: (String) -> Void
    ) -> Int32 {
        let ids = operands.filter { !$0.hasPrefix("-") }
        guard !ids.isEmpty else {
            print("usage: keg \(action == .start ? "start" : action == .stop ? "stop" : "restart") <id>…")
            return 2
        }
        guard let client = requireClient(socketOverride, print: print) else { return 1 }

        var failures = 0
        for id in ids {
            do {
                switch action {
                case .start: try client.start(id: id)
                case .stop: try client.stop(id: id)
                case .restart: try client.restart(id: id)
                }
                print("\(id) \(action.verb)")
            } catch {
                failures += 1
                print("\(id): \(error)")
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func remove(operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        let force = operands.contains("-f") || operands.contains("--force")
        let ids = operands.filter { !$0.hasPrefix("-") }
        guard !ids.isEmpty else {
            print("usage: keg rm [-f] <id>…")
            return 2
        }
        guard let client = requireClient(socketOverride, print: print) else { return 1 }

        var failures = 0
        for id in ids {
            do {
                try client.remove(id: id, force: force)
                print("\(id) removed")
            } catch {
                failures += 1
                print("\(id): \(error)")
            }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: - open

    static let deepLinkSections: Set<String> = [
        "dashboard", "containers", "compose", "kubernetes", "logs", "images",
        "networks", "volumes", "terminal", "settings",
    ]

    static func openApp(operands: [String], print: (String) -> Void) -> Int32 {
        let section = operands.first.flatMap { deepLinkSections.contains($0) ? $0 : nil } ?? "containers"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["keg://\(section)"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                print("opening Keg → \(section)")
                return 0
            }
        } catch {}
        // No registered URL scheme (app not installed via normal means) —
        // fall back to a plain app activation.
        let fallback = Process()
        fallback.executableURL = URL(filePath: "/usr/bin/open")
        fallback.arguments = ["-a", "Keg"]
        do {
            try fallback.run()
            fallback.waitUntilExit()
            print("opening Keg")
            return fallback.terminationStatus == 0 ? 0 : 1
        } catch {
            print("could not open Keg: \(error)")
            return 1
        }
    }

    // MARK: - install / uninstall

    static func install(operands: [String], print: (String) -> Void) -> Int32 {
        let binary = KegCLIInstall.resolveRealBinary(arg0: CommandLine.arguments[0])

        let location: KegCLIInstall.Location
        if let dir = operands.first(where: { !$0.hasPrefix("-") }) {
            location = KegCLIInstall.Location(directory: dir, needsPATHSetup: dir == KegCLIInstall.userBinDirectory)
        } else if let preferred = KegCLIInstall.preferredLocation() {
            location = preferred
        } else {
            print("no writable install location found — pass one explicitly: keg install <dir>")
            return 1
        }

        do {
            let link = try KegCLIInstall.install(binaryPath: binary, into: location)
            print("installed \(link) → \(binary)")
            if location.needsPATHSetup {
                let hint = KegCLIInstall.pathHint(for: location, shell: ProcessInfo.processInfo.environment["SHELL"]?.components(separatedBy: "/").last ?? "zsh")
                print("add it to PATH: \(hint)")
            }
            return 0
        } catch {
            print("install failed: \(error.localizedDescription)")
            print("try a directory you can write: keg install \(KegCLIInstall.userBinDirectory)")
            return 1
        }
    }

    static func uninstall(print: (String) -> Void) -> Int32 {
        do {
            let link = try KegCLIInstall.uninstall()
            print("removed \(link)")
            return 0
        } catch {
            print("\(error.localizedDescription)")
            return 1
        }
    }

    private static func httpSocket(_ client: KegAPIClient) -> String {
        client.http.socketPath
    }
}
