import Foundation
#if canImport(Darwin)
import Darwin
#endif
import KegCLICore

/// `keg sandbox` — run an agent harness inside a Keg microVM container
/// with a repo bind-mounted at /work, attached to the terminal.
///
/// Default harness is pi (https://pi.dev, bundled into the keg-sandbox
/// image built from the repo's Dockerfile); any command can be the
/// harness. The interactive attach shells out to Apple's `container` CLI
/// with inherited stdio — see KegSandbox.swift for why not the socket.
enum KegCLISandbox {
    static func run(_ operands: [String], socketOverride: String?, print: (String) -> Void) -> Int32 {
        var args = operands
        guard let sub = args.first else {
            usage(print)
            return 2
        }
        args.removeFirst()
        do {
            switch sub {
            case "run":
                return try runSandbox(args, socketOverride: socketOverride, print: print)
            case "ls", "list":
                return try list(args, socketOverride: socketOverride, print: print)
            case "stop":
                return try stop(args, socketOverride: socketOverride, print: print)
            case "rm", "remove":
                return try remove(args, socketOverride: socketOverride, print: print)
            case "help", "--help", "-h":
                usage(print)
                return 0
            default:
                print("unknown sandbox subcommand '\(sub)'")
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
            keg sandbox — run an agent harness in a Keg container, repo at /work

              run [options]            Launch (or re-enter) a sandbox; the harness
                                     attaches to this terminal
                --dir <path>           Repo to mount at /work (default: cwd)
                --name <name>          Container name (default: kegsandbox-<dir>)
                --image <ref>          Image (default: keg-sandbox:latest, built
                                       automatically from the bundled Dockerfile)
                --env KEY[=VAL]        Set env in the container; a bare KEY
                                       inherits KEY from this shell (repeatable)
                --keep                 Keep the container after the harness exits
                                       (default: removed, like docker run --rm)
                --harness <cmd> [args…]  Harness command — consumes the REST of
                                       the arguments (default: pi). One bare
                                       "--" separator is dropped, so both
                                       `--harness claude -- --model x` and
                                       `--harness claude --model x` work.
              ls                       Sandbox containers (name, state, dir, age)
              stop <name>              Stop a sandbox (short or full name)
              rm <name>                Stop + remove a sandbox (explicit opt-in)

            The harness runs with cwd /work inside the container; edits are
            live two-way through the bind mount. API keys reach it via
            --env:  keg sandbox run --env ANTHROPIC_API_KEY
            """
        )
    }

    // MARK: - run

    private static func runSandbox(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        let options = try KegSandboxParser.parseRun(operands)
        if options.help {
            usage(print)
            return 0
        }

        // --dir: default cwd, must exist; absolute-ize for the mount spec
        // and the label (a relative path would dangle once we spawn).
        let cwd = FileManager.default.currentDirectoryPath
        let rawDir = options.dir ?? cwd
        let expanded = NSString(string: rawDir).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : cwd + "/" + expanded
        let dir = URL(fileURLWithPath: absolute).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw KegSandboxError("--dir does not exist or is not a directory: \(rawDir)")
        }

        let name = try options.name.map(validate(name:)) ?? KegSandboxNaming.containerName(dir: URL(fileURLWithPath: dir))
        let image = options.image ?? KegSandboxConfig.defaultImage
        let harness = options.harness
        let env = try KegSandboxEnv.resolve(options.envSpecs, environment: ProcessInfo.processInfo.environment)

        let client = try requireClient(socketOverride, print: print)
        let existing = try client.containers(all: true)
        let match = existing.first(where: { $0.displayName == name })
        let plan = KegSandboxPlan.plan(exists: match != nil, running: match?.state == "running")

        switch plan {
        case .execRunning:
            break
        case .startThenExec:
            print("starting \(name)")
            try KegSandboxRecoveredCreate.start(client: client, name: name) { note in
                emitErrorLine(note)
            }
        case .createStartExec:
            try ensureImage(client, image: image, print: print)
            print("creating \(name) (\(image), \(dir) → \(KegSandboxConfig.workDir))")
            let request = KegSandboxContainers.createRequest(
                image: image, name: name, dir: dir, harness: harness, env: env
            )
            try KegSandboxRecoveredCreate.create(
                client: client, request: request, name: name, expectedImage: image
            ) { note in
                emitErrorLine(note)
            }
            try KegSandboxRecoveredCreate.start(client: client, name: name) { note in
                emitErrorLine(note)
            }
        }

        let exitCode = try attach(name: name, env: env, harness: harness)

        if !options.keep {
            try? client.stop(id: name, timeoutSeconds: 300)
            try? client.remove(id: name, force: true, timeoutSeconds: 300)
        }
        return exitCode
    }

    /// Interactive attach via Apple's container CLI, replacing the keg
    /// process image with `container exec` (fork + execve), NOT spawning
    /// it as a child.
    ///
    /// Why re-exec instead of Foundation `Process` (verified live): a
    /// `container exec` that is a GRANDCHILD of the pty session (keg →
    /// Process → CLI) lands outside the terminal's foreground process
    /// group — its tty reads suspend on SIGTTIN while writes still render,
    /// so the prompt draws but every keystroke is ignored. A direct exec
    /// under the pty works; the same command spawned by Process does not;
    /// an `sh -c 'exec …'` middle layer does not help. fork+execve keeps
    /// the CLI as the direct continuation of the keg process, inside the
    /// shared foreground group, so line input and Ctrl+C reach it exactly
    /// as they would a directly exec'd program.
    private static func attach(name: String, env: [String], harness: [String]) throws -> Int32 {
        guard let cli = KegSandboxRuntime.resolveCLI() else {
            throw KegSandboxError(
                "Apple's container CLI not found — install it (brew install container) or open Keg → Settings → Container CLI"
            )
        }
        let isTTY = isatty(STDOUT_FILENO) == 1
        let argv = KegSandboxExec.argv(cli: cli, isTTY: isTTY, env: env, name: name, harness: harness)

        let pin = KegSandboxRuntime.appRootPin()
        let environment = KegSandboxRuntime.execEnvironment(
            processEnvironment: ProcessInfo.processInfo.environment,
            pin: pin
        )

        // Build the C argv/envp BEFORE fork: between fork and execve the
        // child may only call async-signal-safe functions, and strdup /
        // Swift string work is not on that list.
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnvp: [UnsafeMutablePointer<CChar>?] = KegSandboxRuntime.environmentPairs(environment).map { strdup($0) }
        cEnvp.append(nil)
        defer {
            for pointer in cArgv { free(pointer) }
            for pointer in cEnvp { free(pointer) }
        }

        // fork() is annotated unavailable in Swift's macOS overlay ("use
        // threads or posix_spawn"), but a re-exec is precisely what this
        // needs — posix_spawn/Process would make the CLI a *child* (and
        // Process additionally backgrounds it into a fresh process
        // group, the bug above). dlsym is the standard escape hatch; keg
        // is single-threaded at this point, so the async-signal-safe
        // child path below is sound.
        let pid = systemFork()
        if pid == 0 {
            // Child: reset the dispositions the parent masks below (they
            // may be inherited as ignored across execve), then exec.
            signal(SIGINT, SIG_DFL)
            signal(SIGQUIT, SIG_DFL)
            signal(SIGTSTP, SIG_DFL)
            signal(SIGTTIN, SIG_DFL)
            signal(SIGTTOU, SIG_DFL)
            cArgv.withUnsafeBufferPointer { argvBuffer in
                cEnvp.withUnsafeBufferPointer { envBuffer in
                    _ = execve(
                        cli,
                        UnsafeMutablePointer(mutating: argvBuffer.baseAddress),
                        UnsafeMutablePointer(mutating: envBuffer.baseAddress)
                    )
                }
            }
            // Reached only when execve fails. Async-signal-safe reporting.
            let bytes = Array("keg: execve of the container CLI failed\n".utf8)
            bytes.withUnsafeBufferPointer { buffer in
                _ = write(STDERR_FILENO, buffer.baseAddress, buffer.count)
            }
            _exit(127)
        }
        guard pid > 0 else {
            throw KegSandboxError("fork failed before attach (errno \(errno))")
        }

        // Parent: stay out of the keyboard's way. Ctrl+C / Ctrl+\ / Ctrl+Z
        // must reach the exec'd child through the shared foreground process
        // group (the tty delivers SIGINT to the group, and a parent with
        // default dispositions would die alongside the child, orphaning
        // the cleanup below). Handlers restore via defer before the
        // post-exit stop/remove runs.
        let oldINT = signal(SIGINT, SIG_IGN)
        let oldQUIT = signal(SIGQUIT, SIG_IGN)
        let oldTSTP = signal(SIGTSTP, SIG_IGN)
        defer {
            signal(SIGINT, oldINT)
            signal(SIGQUIT, oldQUIT)
            signal(SIGTSTP, oldTSTP)
        }

        var status: Int32 = 0
        var waited: pid_t
        repeat {
            waited = waitpid(pid, &status, 0)
        } while waited == -1 && errno == EINTR
        guard waited != -1 else {
            throw KegSandboxError("waitpid failed after attach (errno \(errno))")
        }
        return decodeExitStatus(status)
    }

    /// fork() via dlsym — see the call site for why not the overlay's
    /// (unavailable) wrapper or posix_spawn.
    private static let systemFork: @convention(c) () -> pid_t = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else {
            fatalError("fork is missing from libSystem")
        }
        return unsafeBitCast(pointer, to: (@convention(c) () -> pid_t).self)
    }()

    /// waitpid status → process exit code. The WIFEXITED/WEXITSTATUS/
    /// WIFSIGNALED/WTERMSIG macros are not imported into Swift; these
    /// are their Darwin definitions.
    private static func decodeExitStatus(_ status: Int32) -> Int32 {
        let termSignal = status & 0x7f
        if termSignal == 0 { return (status >> 8) & 0xff }   // exited
        if termSignal != 0x7f { return 128 + termSignal }    // killed by signal
        return 1                                             // stopped/continued: no WUNTRACED, shouldn't happen
    }

    /// Default image: build from the bundled Dockerfile. Anything else:
    /// pull from the registry.
    private static func ensureImage(_ client: KegAPIClient, image: String, print: (String) -> Void) throws {
        let images = try client.images()
        guard !images.contains(where: { $0.repoTags?.contains(image) ?? false }) else { return }
        if image == KegSandboxConfig.defaultImage {
            emitErrorLine("building \(image) (node:22-alpine + pi) — first run only…")
            try SandboxImageBuilder.build(client: client) { line in
                emitErrorLine(line)
            }
        } else {
            emitErrorLine("pulling \(image)…")
            try client.pullImage(reference: image)
        }
    }

    private static func validate(name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), !name.contains(" "), !name.hasPrefix("-") else {
            throw KegSandboxError("invalid --name '\(name)' (no spaces, '/', or leading '-')")
        }
        return name
    }

    // MARK: - ls

    private static func list(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        _ = operands
        let client = try requireClient(socketOverride, print: print)
        let sandboxes = try client.containers(all: true)
            .filter { $0.displayName.hasPrefix(KegSandboxConfig.namePrefix) }
            .sorted { $0.displayName < $1.displayName }
        guard !sandboxes.isEmpty else {
            print("no sandboxes — start one with: keg sandbox run")
            return 0
        }
        var rows: [[String]] = []
        for container in sandboxes {
            // Name-prefix match finds the sandboxes; labels carry the dir.
            // Inspects are best-effort so a wedged inspect still lists the row.
            let labels = sandboxLabels(client: client, name: container.displayName)
            rows.append([
                container.displayName,
                OutputFormatting.stateBadge(container.state),
                labels[KegSandboxConfig.dirLabel] ?? "—",
                OutputFormatting.ago(epochSeconds: container.created),
            ])
        }
        print(OutputFormatting.table(headers: ["NAME", "STATE", "DIR", "CREATED"], rows: rows))
        return 0
    }

    /// Labels for one sandbox, tolerant of both failure modes seen live:
    /// a swallowed inspect decodes as nil (retry once on a fresh request),
    /// and the bridge carries labels under Config.Labels rather than
    /// top-level Labels (merge both — see CLIContainerInspect).
    private static func sandboxLabels(client: KegAPIClient, name: String) -> [String: String] {
        for attempt in 0..<2 {
            if let inspect = try? client.inspect(id: name) {
                return inspect.effectiveLabels
            }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.5) }
        }
        return [:]
    }

    // MARK: - stop / rm

    private static func stop(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        guard let name = try resolveName(operands, socketOverride: socketOverride, print: print) else { return 2 }
        let client = try requireClient(socketOverride, print: print)
        try client.stop(id: name, timeoutSeconds: 300)
        print("\(name) stopped")
        return 0
    }

    private static func remove(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> Int32 {
        guard let name = try resolveName(operands, socketOverride: socketOverride, print: print) else { return 2 }
        let client = try requireClient(socketOverride, print: print)
        // Removing a running sandbox means its harness dies mid-thought —
        // stop first so the teardown is orderly, then force-remove.
        try? client.stop(id: name, timeoutSeconds: 300)
        try client.remove(id: name, force: true, timeoutSeconds: 300)
        print("\(name) removed")
        return 0
    }

    private static func resolveName(_ operands: [String], socketOverride: String?, print: (String) -> Void) throws -> String? {
        guard let input = operands.first, !input.hasPrefix("-") else {
            print("usage: keg sandbox \(operands.isEmpty ? "stop|rm" : "stop|rm") <name>   (see: keg sandbox ls)")
            return nil
        }
        let client = try requireClient(socketOverride, print: print)
        let existing = try client.containers(all: true)
            .filter { $0.displayName.hasPrefix(KegSandboxConfig.namePrefix) }
            .map(\.displayName)
        guard let name = KegSandboxNaming.resolve(input, existingNames: existing) else {
            throw KegSandboxError("no sandbox named '\(input)' — see: keg sandbox ls")
        }
        return name
    }

    // MARK: - Helpers

    private static func requireClient(_ socketOverride: String?, print: (String) -> Void) throws -> KegAPIClient {
        let path = socketOverride ?? KegSocketResolver.resolve()
        guard let path else {
            print("Keg is not running — no Docker API socket found.")
            print("Open the Keg app (or run: keg open), then retry.")
            throw KegSandboxError("no socket")
        }
        return KegAPIClient(socketPath: path, timeoutSeconds: 60)
    }

    /// Build/pull progress goes to stderr so piped stdout stays clean
    /// for smoke tests (`keg sandbox run … | grep …`).
    private static func emitErrorLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
