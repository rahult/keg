import Foundation
import ContainerAPIClient
import ContainerResource
import ContainerizationOS
import NIOCore

// MARK: - ContainerBridge: exec, wait exit codes, stats, streaming
//
// The XPC client is preferred for operations where the CLI can't report
// what Docker clients need: real exit codes (`/wait`, exec inspect), exec
// process control (start/resize/wait with stdio file handles), and
// resource statistics. Everything degrades to the CLI when XPC fails.

extension ContainerBridge {
    /// Starts `id` via XPC (bootstrap + start, detached stdio) and keeps the
    /// process handle so `/wait` can report the real exit code. When an
    /// attach hijack registered pipes for this container (docker run), the
    /// bootstrap uses them as the container's stdio instead. Falls back to
    /// the `container start` CLI when the XPC service is unavailable.
    func startContainerWithExitTracking(id: String) async throws {
        if let pump = attachIntents.removeValue(forKey: id) {
            if let process = try? await Self.xpc.bootstrap(id: id, stdio: pump.stdioHandles) {
                do {
                    try await process.start()
                    pump.setProcess(process)
                    // Attach readers after the process handle exists — the
                    // reap task captures it. Pipe buffers hold any output
                    // produced in between.
                    pump.beginStreaming()
                    // The stored task lets /wait share the pump's single
                    // authoritative wait.
                    startedProcesses[id] = Task { await pump.completion() }
                    return
                } catch {
                    startedProcesses[id] = nil
                    pump.closePipes()
                    // Fall through to a detached start; the attached client
                    // will see the connection close.
                }
            } else {
                pump.closePipes()
            }
        }
        if let process = try? await Self.xpc.bootstrap(id: id, stdio: [nil, nil, nil]) {
            do {
                try await process.start()
                startedProcesses[id] = Task { (try? await process.wait()) ?? 0 }
                return
            } catch {
                startedProcesses[id] = nil
                // The start failed over XPC; surface via the CLI path so the
                // error message matches what users saw before.
            }
        }
        let (code, output) = try await runCLI(["container", "start", id])
        if code != 0 {
            throw DockerAPIError.containerStartFailed(output)
        }
    }

    /// Registers stdio pipes for a container that a client attached to
    /// before starting (the `docker run` flow).
    func registerAttachIntent(id: String, pump: ExecPump) {
        attachIntents[id] = pump
    }

    /// Waits for `id` to stop and returns its exit code. Blocks while the
    /// container is still in "created" state (never started) — Docker's
    /// wait must not resolve until the container has actually run and
    /// exited. Prefers a process handle from `startContainerWithExitTracking`;
    /// bootstraps idempotently for containers the CLI started, but NEVER
    /// while an attach intent is pending (that bootstrap must win the stdio
    /// race for `docker run` output to flow). Polling with exit code 0 is
    /// the last resort for already-reaped containers.
    func waitContainerWithExitCode(id: String) async throws -> Int32 {
        // Phase 1: block until the container has started at least once.
        while true {
            let (code, output) = try await runCLI(["container", "inspect", id])
            guard code == 0,
                  let data = output.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let entry = entries.first else {
                throw DockerAPIError.containerNotFound(id)
            }
            let statusObj = entry["status"] as? [String: Any]
            let state = (statusObj?["state"] as? String) ?? ""
            if state == "running" { break }
            let startedDate = statusObj?["startedDate"] as? String
            if state != "running" && startedDate != nil && !(startedDate ?? "").isEmpty {
                break // ran and exited
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        // Phase 2: resolve the exit code.
        if let exitTask = startedProcesses.removeValue(forKey: id) {
            return await exitTask.value
        }
        // A pending attach means the start route owns the bootstrap; poll
        // for the exit instead of stealing stdio.
        if attachIntents[id] != nil {
            while true {
                let (_, output) = try await runCLI(["container", "inspect", id])
                if let data = output.data(using: .utf8),
                   let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let entry = entries.first,
                   let state = (entry["status"] as? [String: Any])?["state"] as? String,
                   state != "running" {
                    return 0
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        if let process = try? await Self.xpc.bootstrap(id: id, stdio: [nil, nil, nil]) {
            if let code = try? await process.wait() {
                return code
            }
        }
        return try await waitContainer(id: id)
    }

    // MARK: - Exec

    /// Creates and starts an exec process in `containerID`, wiring its stdio
    /// to pipes. The returned pump delivers output and forwards stdin; the
    /// caller decides where bytes go (hijacked connection or HTTP stream).
    func startExec(
        containerID: String,
        execID: String,
        request: DockerExecCreateRequest
    ) async throws -> ExecPump {
        guard let cmd = request.cmd, let executable = cmd.first, !executable.isEmpty else {
            throw DockerAPIError.badRequest("exec requires a command")
        }

        // Docker execs inherit the container's environment; merge the
        // request's additions on top of the init process environment.
        var environment: [String] = []
        if let inspect = try? await inspectContainer(id: containerID) {
            environment = inspect.config?.env ?? []
        }
        if let extra = request.env {
            environment.append(contentsOf: extra)
        }

        let tty = request.effectiveTTY
        let user: ProcessConfiguration.User
        if let raw = request.user, !raw.isEmpty {
            // <uid>:<gid> numeric form maps directly; anything else is a
            // name the runtime resolves inside the container.
            let parts = raw.split(separator: ":", maxSplits: 1)
            if let uid = UInt32(parts[0]), parts.count == 2, let gid = UInt32(parts[1]) {
                user = .id(uid: uid, gid: gid)
            } else {
                user = .raw(userString: raw)
            }
        } else {
            user = .id(uid: 0, gid: 0)
        }

        let configuration = ProcessConfiguration(
            executable: executable,
            arguments: Array(cmd.dropFirst()),
            environment: environment,
            workingDirectory: request.workingDir ?? "/",
            terminal: tty,
            user: user
        )

        let pump = ExecPump(execID: execID, tty: tty, interactive: request.attachStdin ?? false)
        do {
            let process = try await Self.xpc.createProcess(
                containerId: containerID,
                processId: execID,
                configuration: configuration,
                stdio: pump.stdioHandles
            )
            try await process.start()
            pump.setProcess(process)
            pump.beginStreaming()
            activeExecPumps[execID] = pump
            // Drop the registry entry once the pump finishes so inspects
            // stop reporting it as running.
            Task { [weak self] in
                _ = await pump.completion()
                await self?.removeExecPump(id: execID)
            }
            return pump
        } catch {
            pump.closePipes()
            throw DockerAPIError.containerStartFailed("exec failed: \(error)")
        }
    }

    func removeExecPump(id: String) {
        activeExecPumps.removeValue(forKey: id)
    }

    /// Resizes the PTY of a running exec process.
    func resizeExec(execID: String, width: UInt16, height: UInt16) async throws {
        guard let pump = activeExecPumps[execID] else {
            throw DockerAPIError.badRequest("no such exec: \(execID)")
        }
        try await pump.process?.resize(Terminal.Size(width: width, height: height))
    }

    // MARK: - Stats

    /// Docker-shaped stats for `id`, sampled once over `interval` so the
    /// CLI can compute CPU% from the pre/post deltas.
    func containerStats(id: String, interval: TimeInterval = 1.0) async throws -> DockerContainerStats {
        let first = try await Self.xpc.stats(id: id)
        let systemFirst = Self.hostCPUTimeUsec()
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        let second = try await Self.xpc.stats(id: id)
        let systemSecond = Self.hostCPUTimeUsec()

        let formatter = ISO8601DateFormatter()
        let now = Date()

        return DockerContainerStats(
            read: formatter.string(from: now),
            preread: formatter.string(from: now.addingTimeInterval(-interval)),
            id: id,
            name: id,
            pidsStats: DockerPidsStats(current: second.numProcesses),
            cpuStats: Self.dockerCPU(from: second, systemUsec: systemSecond),
            precpuStats: Self.dockerCPU(from: first, systemUsec: systemFirst),
            memoryStats: DockerMemoryStats(
                usage: second.memoryUsageBytes,
                limit: second.memoryLimitBytes,
                stats: nil
            ),
            networks: Self.dockerNetworks(from: second)
        )
    }

    private static func dockerCPU(from stats: ContainerStats, systemUsec: UInt64) -> DockerCPUStats {
        DockerCPUStats(
            cpuUsage: DockerCPUUsage(
                totalUsage: stats.cpuUsageUsec ?? 0,
                usageInKernelmode: nil,
                usageInUsermode: nil
            ),
            systemCpuUsage: systemUsec,
            onlineCpus: nil
        )
    }

    private static func dockerNetworks(from stats: ContainerStats) -> [String: DockerNetworkStats]? {
        guard stats.networkRxBytes != nil || stats.networkTxBytes != nil else { return nil }
        return ["eth0": DockerNetworkStats(
            rxBytes: stats.networkRxBytes ?? 0,
            txBytes: stats.networkTxBytes ?? 0
        )]
    }

    /// Total host CPU time in microseconds, read from `kern.cp_time`.
    /// Docker clients derive CPU% from the delta of this value between
    /// samples, so absolute accuracy matters less than monotonicity.
    /// Uses `nonisolated(unsafe)` caches only for the tick-length lookup.
    private static func hostCPUTimeUsec() -> UInt64 {
        var size = 0
        guard sysctlbyname("kern.cp_time", nil, &size, nil, 0) == 0, size > 0 else { return 0 }
        var ticks = [Int64](repeating: 0, count: size / MemoryLayout<Int64>.size)
        guard sysctlbyname("kern.cp_time", &ticks, &size, nil, 0) == 0 else { return 0 }
        let total = ticks.reduce(0, +)
        // CLK_TCK is 100 on Darwin: one tick = 10 ms = 10_000 µs.
        return UInt64(clamping: total) * 10_000
    }

    // MARK: - Streaming image operations

    /// Streams `container image pull` output line by line (Docker progress
    /// JSON mapping happens in the server route).
    nonisolated func pullImageStream(from imageRef: String) throws -> StreamingProcess.Output {
        let binary = ContainerCLI.resolve() ?? "container"
        return try StreamingProcess.start(
            binary,
            arguments: ["image", "pull", "--platform", Self.hostPlatform, "--progress", "plain", imageRef]
        ).output
    }

    /// Streams `container image push` output line by line.
    nonisolated func pushImageStream(name: String) throws -> StreamingProcess.Output {
        let binary = ContainerCLI.resolve() ?? "container"
        return try StreamingProcess.start(
            binary,
            arguments: ["image", "push", "--progress", "plain", name]
        ).output
    }

    /// Streams `container build` output line by line from a prepared
    /// context directory.
    nonisolated func buildImageStream(
        contextDir: String,
        dockerfile: String?,
        tag: String?,
        buildArgs: [String],
        noCache: Bool
    ) throws -> StreamingProcess.Output {
        let binary = ContainerCLI.resolve() ?? "container"
        var args = ["build", "--progress", "plain"]
        if let dockerfile { args += ["-f", dockerfile] }
        if let tag { args += ["-t", tag] }
        for arg in buildArgs { args += ["--build-arg", arg] }
        if noCache { args.append("--no-cache") }
        args.append(contextDir)
        return try StreamingProcess.start(binary, arguments: args).output
    }

    // MARK: - Log follow

    /// Streams `container logs -f` as raw data chunks (logs may be binary;
    /// line splitting is not safe here).
    nonisolated func followLogs(id: String) throws -> LogFollowStream {
        let binary = ContainerCLI.resolve() ?? "container"
        let process = Process()
        process.executableURL = URL(filePath: binary)
        process.arguments = ["logs", "-f", id]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return LogFollowStream(process: process, handle: pipe.fileHandleForReading)
    }
}

/// Raw-chunk stream for `docker logs -f`.
struct LogFollowStream: AsyncSequence {
    typealias Element = Data
    let process: Process
    let handle: FileHandle

    struct AsyncIterator: AsyncIteratorProtocol {
        let handle: FileHandle

        mutating func next() async -> Data? {
            await withCheckedContinuation { continuation in
                handle.readabilityHandler = { h in
                    h.readabilityHandler = nil
                    let chunk = h.availableData
                    continuation.resume(returning: chunk.isEmpty ? nil : chunk)
                }
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(handle: handle)
    }
}

// MARK: - Exec pump

/// Wires one started exec process's stdio pipes to AsyncStreams and an
/// optional stdin sink. Output is delivered as tagged chunks: stdout/stderr
/// distinctions survive so non-TTY consumers can stdcopy-frame them, while
/// TTY consumers pass bytes through untouched.
final class ExecPump: @unchecked Sendable {
    struct TaggedChunk {
        let stream: DockerStreamType
        let data: Data
    }

    let execID: String
    let tty: Bool
    let interactive: Bool

    private(set) var process: (any ClientProcess)?
    private let stdinPipe: Pipe?
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe?

    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private let lock = NSLock()

    /// Created in init so no output is lost between XPC start and the
    /// consumer's subscription, and so subscription is race-free.
    private let outputStream: AsyncStream<TaggedChunk>
    private var outputContinuation: AsyncStream<TaggedChunk>.Continuation?

    init(execID: String, tty: Bool, interactive: Bool) {
        self.execID = execID
        self.tty = tty
        self.interactive = interactive
        self.stdinPipe = interactive ? Pipe() : nil
        self.stdoutPipe = Pipe()
        // On a TTY, stderr is merged into the PTY master; a separate pipe
        // would never see data.
        self.stderrPipe = tty ? nil : Pipe()
        let (stream, continuation) = AsyncStream<TaggedChunk>.makeStream()
        self.outputStream = stream
        self.outputContinuation = continuation
    }

    /// File handles to hand to the XPC `createProcess` call. The write ends
    /// belong to the runtime; we read the read ends.
    var stdioHandles: [FileHandle?] {
        [stdinPipe?.fileHandleForReading, stdoutPipe.fileHandleForWriting, stderrPipe?.fileHandleForWriting]
    }

    func setProcess(_ process: any ClientProcess) {
        self.process = process
    }

    /// The output stream for this exec (idempotent — the stream is created
    /// once in init and shared by whoever consumes it). A single
    /// continuation serves both pipes; chunks are tagged with their stream
    /// so non-TTY consumers can stdcopy-frame and TTY consumers can pass
    /// bytes through.
    func makeOutputStream() -> AsyncStream<TaggedChunk> {
        outputStream
    }

    /// Called after XPC start succeeded; drives the read ends and reaps the
    /// process. The exit code comes from `process.wait()` (the single
    /// authoritative waiter) — pipes can EOF slightly after the process is
    /// reaped, at which point a second wait would fail.
    func beginStreaming() {
        let continuation = outputContinuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation?.finish()
                self.handleEOF()
            } else {
                continuation?.yield(TaggedChunk(stream: .stdout, data: chunk))
            }
        }

        stderrPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation?.finish()
                self.handleEOF()
            } else {
                continuation?.yield(TaggedChunk(stream: .stderr, data: chunk))
            }
        }

        let process = self.process
        Task { [weak self] in
            let code = (try? await process?.wait()) ?? -1
            self?.publishExit(code: code)
        }
    }

    /// Forwards stdin bytes into the exec process. Called by hijacked
    /// connections on every client write.
    func writeStdin(_ data: Data) {
        guard let stdinPipe else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Signals stdin EOF (client closed its write side).
    func closeStdin() {
        try? stdinPipe?.fileHandleForWriting.close()
    }

    /// Exit code, resolved when all output streams have ended.
    func completion() async -> Int32 {
        if let code = cachedExitCode() {
            return code
        }
        return await withCheckedContinuation { continuation in
            if let code = registerWaiter(continuation) {
                continuation.resume(returning: code)
            }
        }
    }

    /// Returns the exit code if already published.
    private func cachedExitCode() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return exitCode
    }

    /// Registers a waiter; returns the exit code instead if it arrived first.
    private func registerWaiter(_ continuation: CheckedContinuation<Int32, Never>) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if let exitCode {
            return exitCode
        }
        exitWaiters.append(continuation)
        return nil
    }

    /// Closes our pipe ends and kills the process if it is still running.
    /// Used on error paths and consumer cancellation.
    func terminate() {
        closePipes()
        if process != nil {
            Task { try? await process?.kill(SIGKILL) }
        }
    }

    func closePipes() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
    }

    private func handleEOF() {
        // Both consumer-side streams ended; clean up pipe ends. The exit
        // code is published by the reap task started in beginStreaming.
        closePipes()
    }

    private func publishExit(code: Int32) {
        lock.lock()
        exitCode = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: code)
        }
    }
}
