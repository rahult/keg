import Foundation

/// One executed `container` CLI invocation, kept for the runtime activity
/// panel and the diagnostics report. A call that never returns is the
/// single most useful fact when the runtime wedges, so timeouts are
/// recorded here too.
struct ContainerCLICall: Identifiable {
    let id = UUID()
    let command: String
    let startedAt: Date
    var duration: TimeInterval?
    var outcome: String

    static let maxHistory = 50
}

/// Locates Apple's `container` CLI on disk so GUI subprocesses find it even when
/// launched with a stripped PATH (Finder/Dock apps don't inherit `$PATH` from the
/// user's shell). Also reports installation status for the Settings UI, owns the
/// configured data location (app-root), and bounds every invocation: a wedged
/// runtime used to hang the app forever because nothing ever killed the child.
enum ContainerCLI {
    /// Known install locations, highest priority first. The user-level path
    /// is where Keg's built-in installer (PlatformInstaller) places the CLI.
    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/container",    // Apple Silicon Homebrew
        "/usr/local/bin/container",       // Intel Homebrew / official .pkg
        NSHomeDirectory() + "/.keg/platform/bin/container", // Keg-managed user install
        "/opt/container/bin/container",   // Apple .pkg install target
        "/usr/bin/container"              // system (unlikely but covered)
    ]

    /// First existing executable path, or `nil` if the CLI isn't installed.
    static func resolve() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { resolve() != nil }

    // MARK: - Data Location (app-root)

    /// Machine-specific override for where the runtime stores containers,
    /// images, volumes and snapshots. Empty means the stock `~/.container`.
    /// Some setups (e.g. this project's dev machine) keep the data on a
    /// separate volume; see the "Container Runtime Data Location" section
    /// in AGENTS.md.
    static let appRootDefaultsKey = "container.app-root"

    static var configuredAppRoot: String? {
        let raw = UserDefaults.standard.string(forKey: appRootDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return NSString(string: raw).expandingTildeInPath
    }

    /// Arguments to append to `system start`-style invocations so the runtime
    /// opens the configured data root. Empty when the user is on the default.
    static var appRootArguments: [String] {
        guard let root = configuredAppRoot else { return [] }
        return ["--app-root", root]
    }

    /// Why the configured root can't be used right now, if so. Starting the
    /// runtime against a missing path would silently create an empty root on
    /// whatever volume the path resolves to (or none) and the user's
    /// containers would appear to vanish — so callers preflight with this.
    static func appRootProblem() -> String? {
        guard let root = configuredAppRoot else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "Configured container data location doesn't exist (volume not mounted?): \(root)"
        }
        return nil
    }

    // MARK: - Process Construction

    /// Builds a ready-to-run `Process` pointing at the resolved `container` binary.
    /// Drops the leading "container" token if the caller included it (most
    /// existing code prepends it for use with `env`, so accept both shapes).
    static func makeProcess(_ args: [String]) throws -> Process {
        guard let binary = resolve() else {
            throw ContainerCLIError.notInstalled
        }
        let normalized = args.first == "container" ? Array(args.dropFirst()) : args
        let process = Process()
        process.executableURL = URL(filePath: binary)
        process.arguments = normalized
        return process
    }

    // MARK: - Bounded Execution

    /// Runs the container CLI with the given arguments and returns (exit code, combined stdout+stderr).
    ///
    /// `timeout` is a hard bound: past it the child gets SIGTERM and, if it
    /// ignores that (wedged runtime CLIs do), SIGKILL, and
    /// `.unresponsive(command:)` is thrown. Without this bound a hung runtime
    /// stalled the caller forever and piled up zombie `container list`
    /// processes. Long operations (pulls, pushes) must pass an explicit
    /// larger timeout.
    static func run(_ args: [String], timeout: Duration = .seconds(30)) async throws -> (Int32, String) {
        let process = try makeProcess(args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        recordCallStart(args)
        try process.run()

        let timedOut = TimeoutFlag()
        let watchdog = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return // runner finished first and cancelled us
            }
            timedOut.set()
            process.terminate()
            // Wedged CLIs have been observed ignoring SIGTERM; escalate.
            try? await Task.sleep(for: .seconds(3))
            kill(process.processIdentifier, SIGKILL)
        }

        // Drain the pipe and wait for exit off the cooperative pool: both
        // calls block, and with the watchdog killing the child they always
        // finish eventually.
        let runner = Task.detached(priority: .userInitiated) {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        let result = await runner.value
        watchdog.cancel()

        if timedOut.get() {
            recordCallEnd(args, outcome: "timed out after \(describe(timeout))")
            throw ContainerCLIError.unresponsive(command: args.joined(separator: " "))
        }
        recordCallEnd(args, outcome: "exit \(result.0)")
        return result
    }

    private static func describe(_ timeout: Duration) -> String {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) * 1e-18
        return seconds >= 60 ? String(format: "%.0f min", seconds / 60) : String(format: "%.0f s", seconds)
    }

    // MARK: - Call History

    private static let history = CallHistory()

    static var recentCalls: [ContainerCLICall] {
        history.recent
    }

    private static func recordCallStart(_ args: [String]) {
        let command = normalizedCommand(args)
        history.append(ContainerCLICall(
            command: command,
            startedAt: Date(),
            duration: nil,
            outcome: "running"
        ))
    }

    private static func recordCallEnd(_ args: [String], outcome: String) {
        history.complete(command: normalizedCommand(args), outcome: outcome)
    }

    private static func normalizedCommand(_ args: [String]) -> String {
        args.filter { $0 != "--format" && $0 != "json" }.joined(separator: " ")
    }

    // MARK: - Diagnostics

    /// Whether the `container-apiserver` launchd service currently has a live
    /// process. Lets the app distinguish "stopped" (no service) from
    /// "unresponsive" (service alive but not answering) without spawning
    /// anything. Zombies have no executable path and never match.
    static func isAPIServerProcessRunning() -> Bool {
        let hint = proc_listallpids(nil, 0)
        guard hint > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(hint) + 1)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).contains { pid in
            proc_pidpath(pid, &path, UInt32(path.count)) > 0
                && String(cString: path).hasSuffix("/container-apiserver")
        }
    }

    /// Human-readable triage bundle for the Copy Diagnostics action: data
    /// location, live container processes, launchd service states, and the
    /// recent CLI call history. `ps` and `launchctl` run bounded like
    /// everything else; if they hang too the report says so.
    static func diagnosticsReport() async -> String {
        var lines: [String] = []
        lines.append("Keg container runtime diagnostics — \(Date())")
        lines.append("CLI: \(resolve() ?? "not installed")")

        if let root = configuredAppRoot {
            lines.append("Data location (configured): \(root)")
            lines.append("Data location problem: \(appRootProblem() ?? "none")")
        } else {
            lines.append("Data location: default (~/.container)")
        }

        lines.append("")
        lines.append("— container processes —")
        if let (code, psOutput) = try? await runProcess(
            executable: "/bin/ps", arguments: ["axo", "pid,etime,command"], timeout: .seconds(5)), code == 0 {
            let relevant = psOutput.split(separator: "\n").filter {
                $0.contains("container") && !$0.contains("grep")
            }
            lines.append(contentsOf: relevant.map(String.init))
        } else {
            lines.append("ps itself timed out — the machine is heavily wedged; reboot is the remedy")
        }

        lines.append("")
        lines.append("— launchd services —")
        let uid = getuid()
        if let (code, output) = try? await runProcess(
            executable: "/bin/launchctl", arguments: ["print", "gui/\(uid)"], timeout: .seconds(5)), code == 0 {
            let services = output.split(separator: "\n").filter { $0.contains("com.apple.container.") }
            lines.append(contentsOf: services.isEmpty ? ["none loaded"] : services.map(String.init))
        } else {
            lines.append("launchctl print timed out")
        }

        lines.append("")
        lines.append("— recent Keg CLI calls —")
        for call in recentCalls.suffix(10) {
            let duration = call.duration.map { String(format: "%.1fs", $0) } ?? "—"
            lines.append("[\(call.startedAt.formatted(date: .omitted, time: .standard))] \(call.command) → \(call.outcome) (\(duration))")
        }
        return lines.joined(separator: "\n")
    }

    /// Runs an arbitrary local binary with the same hard bound as `run`.
    /// Separate from `run` because `ps`/`launchctl` aren't the container CLI
    /// and shouldn't appear in its call history.
    private static func runProcess(executable: String, arguments: [String], timeout: Duration) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let runner = Task.detached(priority: .utility) {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        let watchdog = Task.detached(priority: .utility) {
            try? await Task.sleep(for: timeout)
            if !runner.isCancelled {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        let result = await runner.value
        watchdog.cancel()
        return result
    }
}

/// Lock-protected one-shot flag shared between the watchdog task and the
/// awaiting caller of `ContainerCLI.run`.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Bounded ring buffer of recent CLI invocations. A locked class (not static
/// state) because Swift 6 strict concurrency forbids mutable globals.
private final class CallHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ContainerCLICall] = []

    func append(_ call: ContainerCLICall) {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
        if calls.count > ContainerCLICall.maxHistory {
            calls.removeFirst(calls.count - ContainerCLICall.maxHistory)
        }
    }

    /// Completes the most recent still-running entry for `command`.
    func complete(command: String, outcome: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = calls.lastIndex(where: { $0.command == command && $0.outcome == "running" }) else {
            return
        }
        var call = calls[index]
        call.duration = Date().timeIntervalSince(call.startedAt)
        call.outcome = outcome
        calls[index] = call
    }

    var recent: [ContainerCLICall] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

enum ContainerCLIError: LocalizedError {
    case notInstalled
    case unresponsive(command: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Apple's `container` CLI is not installed. Open Settings → Container CLI to install."
        case .unresponsive(let command):
            return "The container runtime didn't answer `\(command)` in time. It may be wedged — try Restart Services, or copy diagnostics for the details."
        }
    }
}
