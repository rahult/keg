import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Why sandboxes
//
// `keg sandbox run` launches an agent harness (default: pi, the
// @mariozechner/pi-coding-agent npm package) inside a Keg microVM container
// with the user's repo bind-mounted at /work, attached to the terminal.
// The harness is just a command: `--harness claude -- some args` runs any
// CLI the same way, which is what makes this harness-agnostic.
//
// The interactive attach deliberately does NOT go through Keg's
// Docker-socket hijack channel (that path still has the intermittent
// request-swallow bug documented in AGENTS.md); it shells out to Apple's
// `container` CLI for the exec instead, inheriting the user's
// stdin/stdout/stderr. Everything around the attach — create/start/stop/
// remove/list/image build — goes over the existing unix-socket HTTP client.

// MARK: - Errors

public struct KegSandboxError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Configuration constants

public enum KegSandboxConfig {
    public static let defaultImage = "keg-sandbox:latest"
    public static let defaultHarness = "pi"
    /// The repo's mount point inside the container; the exec lands here.
    public static let workDir = "/work"
    public static let namePrefix = "kegsandbox-"

    public static let sandboxLabel = "dev.rahult.keg.sandbox"
    public static let dirLabel = "dev.rahult.keg.sandbox.dir"
    public static let harnessLabel = "dev.rahult.keg.sandbox.harness"
}

// MARK: - Naming

public enum KegSandboxNaming {
    /// The `<slug>` in `kegsandbox-<slug>`: lowercase, `[a-z0-9-]`,
    /// ≤63 chars including the prefix, Docker-name-safe. Mirrors
    /// AgentWorkspace.sessionSlug's approach.
    public static func slug(_ raw: String) -> String {
        let slug = raw
            .lowercased()
            .map { c in ("a"..."z").contains(c) || ("0"..."9").contains(c) ? c : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-")
            .joined(separator: "-")
        let budget = 63 - KegSandboxConfig.namePrefix.count
        return slug.count > budget ? String(slug.prefix(budget)) : slug
    }

    /// `kegsandbox-<slug-of-dir-basename>`; a dir whose basename sanitizes
    /// to nothing (root "/", ".", all punctuation) falls back to "work".
    public static func containerName(dir: URL) -> String {
        let base = dir.lastPathComponent
        let raw = slug(base).isEmpty ? "work" : base
        return KegSandboxConfig.namePrefix + slug(raw)
    }

    /// `stop`/`rm` accept either the full name (`kegsandbox-todo`) or the
    /// short form (`todo`); returns the full name when it matches a known
    /// sandbox container, nil otherwise.
    public static func resolve(_ input: String, existingNames: [String]) -> String? {
        if existingNames.contains(input) { return input }
        let full = input.hasPrefix(KegSandboxConfig.namePrefix) ? input : KegSandboxConfig.namePrefix + input
        return existingNames.contains(full) ? full : nil
    }
}

// MARK: - Env parsing

public enum KegSandboxEnv {
    /// Turns `--env` specs into `KEY=VAL` strings for the container Env
    /// list and the exec `-e` flags. `KEY=VAL` passes through; a bare
    /// `KEY` inherits KEY's value from the keg process environment (so
    /// `keg sandbox run --env ANTHROPIC_API_KEY` forwards the user's shell
    /// key). A bare key that isn't set is a clear error naming the key.
    public static func resolve(_ specs: [String], environment: [String: String]) throws -> [String] {
        try specs.map { spec in
            if let eq = spec.firstIndex(of: "=") {
                let key = String(spec[..<eq])
                guard !key.isEmpty else {
                    throw KegSandboxError("--env '\(spec)' has an empty key")
                }
                return spec
            }
            guard !spec.isEmpty else {
                throw KegSandboxError("--env needs KEY or KEY=VAL")
            }
            guard let value = environment[spec] else {
                throw KegSandboxError("--env \(spec): no such variable in the environment — pass \(spec)=… explicitly")
            }
            return "\(spec)=\(value)"
        }
    }
}

// MARK: - Run plan (pure decisions, unit-tested)

public enum KegSandboxPlan: Equatable, Sendable {
    /// Container exists and is running: exec straight in.
    case execRunning
    /// Container exists but is stopped: start, then exec.
    case startThenExec
    /// No container: ensure image, create, start, exec.
    case createStartExec

    public static func plan(exists: Bool, running: Bool) -> KegSandboxPlan {
        switch (exists, running) {
        case (true, true): return .execRunning
        case (true, false): return .startThenExec
        case (false, _): return .createStartExec
        }
    }
}

// MARK: - Argument grammar (pure, unit-tested)

public struct KegSandboxRunOptions: Equatable, Sendable {
    /// Raw `--dir`; nil means the current working directory.
    public var dir: String?
    public var name: String?
    public var image: String?
    public var envSpecs: [String] = []
    public var keep = false
    /// Everything after `--harness` to end-of-args (one bare `--` separator
    /// is dropped); ["pi"] when absent.
    public var harness: [String] = [KegSandboxConfig.defaultHarness]
    public var help = false

    public init() {}
}

public enum KegSandboxParser {
    /// `keg sandbox run` operands. `--harness` consumes the REST of argv
    /// verbatim (options-looking tokens included) — the documented
    /// convention is `keg sandbox run [options] --harness <cmd> [args…]`,
    /// where a leading `--` separator after the harness name is dropped.
    public static func parseRun(_ operands: [String]) throws -> KegSandboxRunOptions {
        var options = KegSandboxRunOptions()
        var index = 0
        while index < operands.count {
            let arg = operands[index]
            func value() throws -> String {
                guard index + 1 < operands.count else {
                    throw KegSandboxError("\(arg) needs a value")
                }
                return operands[index + 1]
            }
            switch arg {
            case "--dir":
                options.dir = try value(); index += 2
            case "--name":
                options.name = try value(); index += 2
            case "--image":
                options.image = try value(); index += 2
            case "--env", "-e":
                options.envSpecs.append(try value()); index += 2
            case "--keep":
                options.keep = true; index += 1
            case "--harness":
                var rest = Array(operands[(index + 1)...])
                // A single bare "--" separator is dropped wherever it
                // appears (harnesses essentially never take a literal
                // bare "--" as their own argument).
                if let separator = rest.firstIndex(of: "--") {
                    rest.remove(at: separator)
                }
                options.harness = rest.isEmpty ? [KegSandboxConfig.defaultHarness] : rest
                index = operands.count
            case "help", "--help", "-h":
                options.help = true; index += 1
            default:
                if arg.hasPrefix("-") {
                    throw KegSandboxError("unknown option '\(arg)' — see: keg sandbox run --help")
                }
                throw KegSandboxError("unexpected argument '\(arg)' (the harness goes after --harness) — see: keg sandbox run --help")
            }
        }
        return options
    }
}

// MARK: - Container spec

public enum KegSandboxContainers {
    /// Docker create body for a sandbox container. No published ports;
    /// the repo bind-mounts at /work; OpenStdin+StdinOnce+Tty so the
    /// interactive exec attach has a live stdin/pty path.
    public static func createRequest(
        image: String,
        name: String,
        dir: String,
        harness: [String],
        env: [String]
    ) -> KegContainerCreateRequest {
        KegContainerCreateRequest(
            image: image,
            cmd: ["sleep", "infinity"],
            env: env,
            labels: [
                KegSandboxConfig.sandboxLabel: "true",
                KegSandboxConfig.dirLabel: dir,
                KegSandboxConfig.harnessLabel: harness.joined(separator: " "),
            ],
            entrypoint: nil,
            workingDir: nil,
            platform: "linux/arm64",
            openStdin: true,
            stdinOnce: true,
            tty: true,
            hostConfig: .init(
                portBindings: [:],
                binds: ["\(dir):\(KegSandboxConfig.workDir)"],
                restartPolicy: nil
            )
        )
    }
}

// MARK: - Exec attach argv (pure, unit-tested)

public enum KegSandboxExec {
    /// argv for Apple's `container` CLI attach. `isTTY` is injected so
    /// tests cover both attach shapes: `-it` on a terminal, `-i` piped.
    /// Env pairs are already `KEY=VAL` (see KegSandboxEnv.resolve).
    public static func argv(
        cli: String,
        isTTY: Bool,
        env: [String],
        name: String,
        harness: [String]
    ) -> [String] {
        var args = [cli, "exec", isTTY ? "-it" : "-i", "-w", KegSandboxConfig.workDir]
        for pair in env {
            args += ["-e", pair]
        }
        args.append(name)
        args.append(contentsOf: harness)
        return args
    }
}

// MARK: - Runtime: container CLI resolution + app-root pin

public enum KegSandboxRuntime {
    /// Known install locations, highest priority first (mirrors the app's
    /// ContainerCLI.candidatePaths; PATH is searched first).
    public static let candidateCLIs: [String] = [
        "/opt/homebrew/bin/container",    // Apple Silicon Homebrew
        "/usr/local/bin/container",       // Intel Homebrew / official .pkg
        NSHomeDirectory() + "/.keg/platform/bin/container", // Keg-managed user install
        "/opt/container/bin/container",   // Apple .pkg install target
        "/usr/bin/container"              // system (unlikely but covered)
    ]

    /// The Apple `container` CLI: PATH search first, then known locations.
    public static func resolveCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let pathEnv = environment["PATH"] {
            for directory in pathEnv.split(separator: ":") {
                let candidate = String(directory) + "/container"
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return candidateCLIs.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Mirror of the house rule in ContainerCLI.makeProcess: Keg-originated
    /// `container` calls pin CONTAINER_APP_ROOT to the configured data root
    /// so a stray CLI-side write can't split-brain against the apiserver.
    /// Exec is a non-start op, so env-var pinning is the right shape (only
    /// `container system start` needs the `--app-root` argument). The CLI
    /// process reads the same default from the app's domain.
    public static func appRootPin(
        home: String = NSHomeDirectory(),
        defaults: UserDefaults? = UserDefaults(suiteName: "dev.rahult.keg")
    ) -> (key: String, value: String)? {
        guard let raw = defaults?.string(forKey: "container.app-root")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return nil }
        return ("CONTAINER_APP_ROOT", NSString(string: raw).expandingTildeInPath)
    }

    /// Environment for the re-exec'd container CLI: the keg process
    /// environment plus the app-root pin. Pure so the composition is
    /// unit-testable; the C-string conversion happens at the fork site.
    public static func execEnvironment(
        processEnvironment: [String: String],
        pin: (key: String, value: String)?
    ) -> [String: String] {
        var environment = processEnvironment
        if let pin {
            environment[pin.key] = pin.value
        }
        return environment
    }

    /// `K=V` strings, sorted, for the execve envp. Sorted so the built
    /// envp is deterministic (and the fork site has no ordering surprises).
    public static func environmentPairs(_ environment: [String: String]) -> [String] {
        environment.map { "\($0.key)=\($0.value)" }.sorted()
    }
}

// MARK: - Swallow-proof create/start
//
// Keg's DockerHijackHTTPChannel intermittently swallows a connection's first
// request (see AGENTS.md known limitations): the accepted socket's bytes are
// never read, the client gives up as a timeout/EOF — while the server may
// have processed the request anyway. A lost create response with a created
// container is exactly the failure that pattern produces. The mitigation is
// client-side, same as the project engine's create/start path: verify state
// over a fresh request, adopt what actually landed, retry once on a fresh
// connection, and only then fail with the original error.

/// What an inspect-by-name found relative to what the create intended.
public enum KegSandboxCreateVerification: Equatable, Sendable {
    /// No container by that name — the create did not land.
    case missing
    /// A container with that name exists but its config doesn't match
    /// (image ref or sandbox label) — never adopt an unrelated container.
    case mismatched(reason: String)
    /// Exists with the intended image ref and the sandbox label — the
    /// create landed; its response was lost.
    case matching
}

/// The next step after a create/start call threw.
public enum KegSandboxRecovery: Equatable, Sendable {
    /// The operation landed server-side; continue without redoing it.
    case adopt
    /// Re-issue the operation once on a fresh connection.
    case retry
    /// Nothing landed and the retry budget is spent; surface the error.
    case fail
}

public enum KegSandboxRecoveredCreate {
    /// Strict match: exact name (the inspect targeted it), the intended
    /// image reference, and the sandbox label. `inspect == nil` (container
    /// absent OR inspect itself unreachable) reports .missing so the caller
    /// retries; a retry against a genuinely wedged socket fails with the
    /// original create error, which is the honest outcome.
    public static func verify(
        inspect: CLIContainerInspect?,
        expectedImage: String
    ) -> KegSandboxCreateVerification {
        guard let inspect else { return .missing }
        guard inspect.labels?[KegSandboxConfig.sandboxLabel] == "true" else {
            return .mismatched(reason: "container exists but lacks the \(KegSandboxConfig.sandboxLabel) label")
        }
        guard let image = inspect.config?.image, !image.isEmpty else {
            return .mismatched(reason: "container exists but its image reference is unknown")
        }
        guard image == expectedImage else {
            return .mismatched(reason: "container exists with image '\(image)', expected '\(expectedImage)'")
        }
        return .matching
    }

    /// Pure adopt/retry/fail decision: matching always adopts, mismatched
    /// always fails (a same-name foreign container must not be clobbered
    /// by a blind retry), missing retries until `maxRetries` are spent.
    public static func decision(
        verification: KegSandboxCreateVerification,
        attemptsMade: Int,
        maxRetries: Int = 1
    ) -> KegSandboxRecovery {
        switch verification {
        case .matching: return .adopt
        case .mismatched: return .fail
        case .missing: return attemptsMade < maxRetries ? .retry : .fail
        }
    }

    /// Create with swallow recovery. `onNote` receives human-readable
    /// progress (the caller routes it to stderr).
    public static func create(
        client: KegAPIClient,
        request: KegContainerCreateRequest,
        name: String,
        expectedImage: String,
        maxRetries: Int = 1,
        onNote: (String) -> Void = { _ in }
    ) throws {
        var attempts = 0
        var originalError: Error?
        while true {
            do {
                try client.createContainer(request: request, name: name)
                return
            } catch {
                if originalError == nil { originalError = error }
                let verification = Self.verify(
                    inspect: try? client.inspect(id: name),
                    expectedImage: expectedImage
                )
                switch Self.decision(verification: verification, attemptsMade: attempts, maxRetries: maxRetries) {
                case .adopt:
                    onNote("create response was lost (known socket issue); \(name) exists — continuing")
                    return
                case .retry:
                    attempts += 1
                    onNote("create response lost; retrying on a fresh connection (\(attempts)/\(maxRetries))")
                    Thread.sleep(forTimeInterval: 1)
                case .fail:
                    throw originalError ?? error
                }
            }
        }
    }

    /// Start with swallow recovery: a lost start response is fine when the
    /// container is in fact running; otherwise retry once, then fail.
    public static func start(
        client: KegAPIClient,
        name: String,
        maxRetries: Int = 1,
        onNote: (String) -> Void = { _ in }
    ) throws {
        var attempts = 0
        var originalError: Error?
        while true {
            do {
                try client.start(id: name, timeoutSeconds: 300)
                return
            } catch {
                if originalError == nil { originalError = error }
                let running = (try? client.inspect(id: name))?.state.running == true
                let verification: KegSandboxCreateVerification = running
                    ? .matching
                    : .missing
                switch Self.decision(verification: verification, attemptsMade: attempts, maxRetries: maxRetries) {
                case .adopt:
                    onNote("start response was lost (known socket issue); \(name) is running — continuing")
                    return
                case .retry:
                    attempts += 1
                    onNote("start response lost; retrying on a fresh connection (\(attempts)/\(maxRetries))")
                    Thread.sleep(forTimeInterval: 1)
                case .fail:
                    throw originalError ?? error
                }
            }
        }
    }
}

// MARK: - Image build

public enum SandboxImageBuilder {
    /// Anchor for `Bundle(for:)` — finds the bundle holding KegCLICore code.
    private final class BundleMarker {}

    /// Locate the bundled Sandbox/Dockerfile. Mirrors KegSkill's manual
    /// bundle walk on purpose: the generated `Bundle.module` accessor
    /// `fatalError`s when the resource bundle wasn't copied, and a missing
    /// Dockerfile must degrade to an error message, never a crash.
    public static func dockerfileURL(
        fileManager: FileManager = .default,
        home: String = NSHomeDirectory()
    ) -> URL? {
        let bundleName = "Keg_KegCLICore.bundle"
        let resource = "Resources/Sandbox/Dockerfile"

        var baseDirectories: [URL] = []
        if let executableURL = Bundle.main.executableURL {
            baseDirectories.append(executableURL.deletingLastPathComponent())
        }
        let resolved = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        baseDirectories.append(resolved.deletingLastPathComponent())

        var candidates: [URL] = []
        for base in baseDirectories {
            candidates.append(base.appendingPathComponent(bundleName))
            candidates.append(
                base.deletingLastPathComponent()
                    .appendingPathComponent("Resources").appendingPathComponent(bundleName)
            )
            var directory = base
            for _ in 0..<12 {
                directory = directory.deletingLastPathComponent()
                candidates.append(directory.appendingPathComponent(bundleName))
                candidates.append(directory.appendingPathComponent("Sources/KegCLICore/\(resource)"))
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName))
        }
        // In test bundles the code lives inside KegTests.xctest and the
        // resource bundle is copied into its Resources — the class's
        // bundle knows that location.
        if let codeResourceURL = Bundle(for: BundleMarker.self).resourceURL {
            candidates.append(codeResourceURL.appendingPathComponent(bundleName))
        }

        for candidate in candidates {
            if candidate.pathExtension == "bundle" {
                for relative in ["Contents/Resources/\(resource)", "Contents/Resources/Sandbox/Dockerfile"] {
                    let direct = candidate.appendingPathComponent(relative)
                    if fileManager.fileExists(atPath: direct.path) { return direct }
                }
            } else if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Build `keg-sandbox:latest` from the bundled Dockerfile (a
    /// node:22-alpine base with the pi coding agent installed globally).
    /// The context is just the Dockerfile; build output lines stream to
    /// `onLine` so the user sees npm's progress.
    public static func build(
        client: KegAPIClient,
        onLine: @escaping (String) -> Void = { _ in }
    ) throws {
        guard let dockerfile = dockerfileURL() else {
            throw KegSandboxError(
                "the sandbox Dockerfile is missing from this installation — grab Sources/KegCLICore/Resources/Sandbox/Dockerfile from the Keg repository"
            )
        }
        let tar = try contextTar(dockerfile: dockerfile)
        try client.buildImage(
            contextTar: tar,
            tag: KegSandboxConfig.defaultImage,
            dockerfile: "Dockerfile",
            args: [:],
            onLine: onLine
        )
    }

    /// Tar a context containing only the Dockerfile, via the system
    /// bsdtar (same convention as KegBuildContext.archive).
    static func contextTar(dockerfile: URL) throws -> Data {
        let fileManager = FileManager.default
        let context = fileManager.temporaryDirectory
            .appendingPathComponent("keg-sandbox-context-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: context, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: context) }
        try fileManager.copyItem(at: dockerfile, to: context.appendingPathComponent("Dockerfile"))

        let tarURL = fileManager.temporaryDirectory
            .appendingPathComponent("keg-sandbox-\(UUID().uuidString.prefix(8)).tar")
        defer { try? fileManager.removeItem(at: tarURL) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-cf", tarURL.path, "-C", context.path, "."]
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw KegSandboxError("could not run /usr/bin/tar: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw KegSandboxError("failed to tar the sandbox build context: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try Data(contentsOf: tarURL)
    }
}

// MARK: - Image pull

extension KegAPIClient {
    /// POST /images/create?fromImage=… — pull a non-default sandbox image.
    /// Long timeout (inline pulls can run many minutes); the response is a
    /// JSON progress stream we don't render.
    public func pullImage(reference: String, timeoutSeconds: Int32 = 1250) throws {
        let response = try http.post(
            "/images/create?fromImage=\(Self.urlEncode(reference))&platform=linux%2Farm64",
            body: nil,
            timeoutSeconds: timeoutSeconds
        )
        guard (200..<300).contains(response.status) else {
            throw KegSandboxError(
                "pull \(reference) failed (HTTP \(response.status)): \(Self.errorText(response.body))"
            )
        }
    }
}
