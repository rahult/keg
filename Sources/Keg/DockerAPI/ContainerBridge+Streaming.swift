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
    /// Starts `id` via XPC with retained stdio pipes (an `AttachBuffer`),
    /// keeping the process handle so `/wait` can report the real exit code
    /// and making `docker attach` / `keg attach` work at any time. Falls
    /// back to the `container start` CLI (no retained stdio) if XPC fails.
    func startContainerWithExitTracking(id: String) async throws {
        userStoppedIDs.remove(id)
        let tty = await containerIsTTY(id: id)
        let pump = ExecPump(execID: "stdio-\(id)", tty: tty, interactive: true)
        guard let process = try? await Self.xpc.bootstrap(id: id, stdio: pump.stdioHandles) else {
            pump.closePipes()
            let (code, output) = try await runCLI(["container", "start", id])
            if code != 0 {
                throw DockerAPIError.containerStartFailed(output)
            }
            return
        }
        do {
            pump.releaseWriteEndsToRuntime()
            try await process.start()
            pump.setProcess(process)
            pump.beginStreaming()
            startedProcesses[id] = Task { await pump.completion() }

            if let (connection, wantsStdin) = pendingAttaches.removeValue(forKey: id)?.first {
                // docker run: hand the retained pump straight to the
                // waiting attached connection (proven direct wiring).
                if wantsStdin {
                    connection.setReadHandler(
                        { data in pump.writeStdin(data) },
                        eof: { pump.closeStdin() }
                    )
                }
                Task.detached {
                    for try await chunk in pump.makeOutputStream() {
                        if pump.tty {
                            connection.write(chunk.data)
                        } else {
                            connection.write(DockerAPIServer.stdcopyFrame(chunk))
                        }
                    }
                    _ = await pump.completion()
                    connection.close()
                }
            } else {
                // No one is attached yet: retain stdio for late attach.
                let buffer = AttachBuffer(pump: pump, tty: tty)
                buffer.start()
                attachBuffers[id] = buffer
                pruneAttachBuffers()
            }
        } catch {
            pump.closePipes()
            throw DockerAPIError.containerStartFailed("\(error)")
        }
    }

    private func containerIsTTY(id: String) async -> Bool {
        let (_, output) = (try? await runCLI(["container", "inspect", id])) ?? (1, "")
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = entries.first else { return false }
        let initProc = (entry["configuration"] as? [String: Any])?["initProcess"] as? [String: Any]
        return (initProc?["terminal"] as? Bool) ?? false
    }

    // MARK: - Attach buffers (retained container stdio)

    /// Retained-stdio buffer for a container, if Keg started it.
    func attachBuffer(id: String) -> AttachBuffer? {
        attachBuffers[id]
    }

    func registerPendingAttach(id: String, connection: HijackedConnection, wantsStdin: Bool) {
        pendingAttaches[id, default: []].append((connection, wantsStdin))
    }

    private func drainPendingAttaches(id: String) {
        guard let buffer = attachBuffers[id] else { return }
        for (connection, wantsStdin) in pendingAttaches.removeValue(forKey: id) ?? [] {
            if wantsStdin {
                connection.setReadHandler(
                    { data in buffer.pump.writeStdin(data) },
                    eof: { buffer.pump.closeStdin() }
                )
            }
            buffer.attach(connection)
        }
    }

    /// Bounded memory: drop the oldest finished buffers past 64 entries.
    private func pruneAttachBuffers() {
        guard attachBuffers.count > 64 else { return }
        let finished = attachBuffers
            .filter { $0.value.isFinished }
            .sorted { $0.value.finishedAt ?? Date.distantPast < $1.value.finishedAt ?? .distantPast }
        for (id, _) in finished.prefix(attachBuffers.count - 64) {
            attachBuffers.removeValue(forKey: id)
        }
    }

    /// Called when a container is destroyed so its buffer dies with it.
    func discardAttachBuffer(id: String) {
        attachBuffers.removeValue(forKey: id)
        pendingAttaches.removeValue(forKey: id)
    }

    // MARK: - Restart policies

    /// The restart policy recorded on a container's labels, if any.
    func restartPolicy(container: DockerContainer) -> String? {
        container.labels?["keg.restart-policy"]
    }

    /// Called by the event bus when a container exits: restarts it if its
    /// policy says so. Caps consecutive restarts so a crash-looping
    /// container can't spin forever; a successful long run resets the cap
    /// (approximated by elapsed time since the last restart).
    func handleContainerExited(_ container: DockerContainer) async {
        guard let policy = restartPolicy(container: container),
              ["always", "unless-stopped", "on-failure"].contains(policy),
              !userStoppedIDs.contains(container.id) else {
            return
        }

        let attempts = restartAttempts[container.id] ?? 0
        guard attempts < 5 else { return }
        restartAttempts[container.id] = attempts + 1

        // Give a fast-failing process a beat before restarting, and the
        // runtime a moment to settle the stopped state.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // The container may have been removed meanwhile.
        let inspect = try? await runCLI(["container", "inspect", container.id])
        guard inspect?.0 == 0 else {
            restartAttempts.removeValue(forKey: container.id)
            return
        }
        userStoppedIDs.remove(container.id)
        _ = try? await startContainerWithExitTracking(id: container.id)
    }

    /// Marks a container as deliberately stopped (API stop/kill/rm).
    func markUserStopped(_ id: String) {
        userStoppedIDs.insert(id)
    }

    /// Starts every stopped container labeled restart=always — docker
    /// restarts those when the daemon comes up. `unless-stopped` and
    /// `on-failure` containers stay down across daemon restarts.
    func restartAlwaysContainersOnLaunch() async {
        guard let containers = try? await listContainers(all: true) else { return }
        for container in containers where container.state != "running" {
            if restartPolicy(container: container) == "always" {
                userStoppedIDs.remove(container.id)
                _ = try? await startContainerWithExitTracking(id: container.id)
            }
        }
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
            pump.releaseWriteEndsToRuntime()
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

    // MARK: - docker cp (archive endpoints)

    /// `PUT /containers/{id}/archive?path=…`: extracts the uploaded tar to
    /// a temp dir and XPC-copies each top-level entry into the container.
    func copyIntoContainer(id: String, tarData: Data, destination: String) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-cp-in-\(UUID().uuidString.prefix(8))")
        let tarPath = workDir.appendingPathComponent("in.tar").path
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        FileManager.default.createFile(atPath: tarPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(filePath: tarPath))
        try handle.write(contentsOf: tarData)
        try handle.close()

        let extract = Process()
        extract.executableURL = URL(filePath: "/usr/bin/tar")
        extract.arguments = ["-xf", tarPath, "-C", workDir.path]
        extract.standardOutput = FileHandle.nullDevice
        extract.standardError = FileHandle.nullDevice
        try extract.run()
        extract.waitUntilExit()
        guard extract.terminationStatus == 0 else {
            throw DockerAPIError.badRequest("uploaded archive is not a valid tar")
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        let topLevel = entries.filter { $0 != "in.tar" }
        guard !topLevel.isEmpty else {
            throw DockerAPIError.badRequest("uploaded archive is empty")
        }

        // docker cp semantics: when the destination is an existing
        // directory, entries land INSIDE it under their own names.
        let destinationIsDirectory = await self.pathIsDirectory(id: id, path: destination)
        for entry in topLevel {
            let target = destinationIsDirectory
                ? (destination as NSString).appendingPathComponent(entry)
                : destination
            try await Self.xpc.copyIn(
                id: id,
                source: workDir.appendingPathComponent(entry).path,
                destination: target
            )
        }
    }

    private func pathIsDirectory(id: String, path: String) async -> Bool {
        let (code, output) = (try? await runCLI(["container", "exec", id, "stat", "-c", "%F", path])) ?? (1, "")
        guard code == 0 else { return false }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).contains("directory")
    }

    /// `GET /containers/{id}/archive?path=…`: XPC-copies the path out and
    /// returns it as a tar stream (single top-level entry, like docker cp).
    func copyOutOfContainer(id: String, source: String) async throws -> Data {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-cp-out-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // XPC copyOut expects the exact destination path (file or dir),
        // unlike cp semantics — hand it <tmp>/<basename>.
        let baseName = (source as NSString).lastPathComponent
        let destination = workDir.appendingPathComponent(baseName.isEmpty ? "payload" : baseName).path
        try await Self.xpc.copyOut(id: id, source: source, destination: destination)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        guard let first = entries.first else {
            throw DockerAPIError.badRequest("no such path in container: \(source)")
        }

        let tar = Process()
        let pipe = Pipe()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", workDir.path, first]
        tar.standardOutput = pipe
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, !data.isEmpty else {
            throw DockerAPIError.badRequest("failed to archive path \(source)")
        }
        return data
    }

    // MARK: - Attach buffer

/// Retained stdio for one API-started container. Output is framed (non-TTY)
/// or raw (TTY) into a bounded ring so a client attaching later still sees
/// recent history, while a live attached connection receives bytes as they
/// arrive. Lives in ContainerBridge's `attachBuffers`.
final class AttachBuffer: @unchecked Sendable {
    let pump: ExecPump
    let tty: Bool
    private let lock = NSLock()
    private var ring = Data()
    private static let ringCap = 256 * 1024
    private var liveConnection: HijackedConnection?
    private(set) var isFinished = false
    private(set) var finishedAt: Date?
    private var consumer: Task<Void, Never>?

    init(pump: ExecPump, tty: Bool) {
        self.pump = pump
        self.tty = tty
    }

    /// Starts consuming the pump's output into the ring (and any live
    /// connection). Called once, right after the container starts.
    func start() {
        consumer = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.pump.makeOutputStream() {
                    self.ingest(chunk)
                }
            } catch {
                // Stream cancelled — keep whatever the ring captured.
            }
            self.finish()
        }
    }

    private func ingest(_ chunk: ExecPump.TaggedChunk) {
        let bytes = tty ? chunk.data : DockerAPIServer.stdcopyFrame(chunk)
        lock.lock()
        ring.append(bytes)
        if ring.count > Self.ringCap {
            ring.removeFirst(ring.count - Self.ringCap)
        }
        let connection = liveConnection
        lock.unlock()
        connection?.write(bytes)
    }

    /// Attaches a hijacked connection: replays recent history, then streams
    /// live until the container exits (or the client goes away).
    func attach(_ connection: HijackedConnection) {
        lock.lock()
        let replay = ring
        let finished = isFinished
        liveConnection = connection
        lock.unlock()

        connection.onClosed = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.liveConnection = nil
            self.lock.unlock()
        }

        if !replay.isEmpty {
            connection.write(replay)
        }
        if finished {
            // Container already exited; the client sees history, then EOF.
            connection.close()
        }
    }

    private func finish() {
        lock.lock()
        isFinished = true
        finishedAt = Date()
        let connection = liveConnection
        liveConnection = nil
        lock.unlock()
        connection?.close()
    }
}

    /// The base64 `X-Docker-Container-Path-Stat` payload docker cp requires
    /// on both HEAD and GET /archive: {name, size, mode, mTime}. Computed
    /// with a stat(1) inside the container (busybox-compatible).
    func containerPathStat(id: String, path: String) async throws -> String {
        let (code, output) = try await runCLI([
            "container", "exec", id,
            "stat", "-c", "%F|%s|%Y", path,
        ])
        guard code == 0 else {
            throw DockerAPIError.containerNotFound("no such path: \(path)")
        }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|").map(String.init)
        let kind = parts.count > 0 ? parts[0] : ""
        let size = parts.count > 1 ? Int64(parts[1]) ?? 0 : 0
        let mtime = parts.count > 2 ? Int64(parts[2]) ?? 0 : 0

        // Go FileMode: os.ModeDir is bit 31; permission bits ride along.
        let mode: Int64 = kind.contains("directory") ? ((1 << 31) | 0o755) : 0o644
        let name = (path as NSString).lastPathComponent
        // docker's PathStat decodes mTime as a Go time.Time — RFC 3339.
        let mtimeDate = Date(timeIntervalSince1970: TimeInterval(mtime))
        let payload: [String: Any] = [
            "name": name.isEmpty ? "/" : name,
            "size": size,
            "mode": mode,
            "mTime": ISO8601DateFormatter().string(from: mtimeDate),
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        return json.base64EncodedString()
    }

    // MARK: - Streaming image operations

    /// Streams `container image pull` output line by line (Docker progress
    /// JSON mapping happens in the server route). `platform` overrides the
    /// host default so amd64 images pull for Rosetta when clients ask.
    nonisolated func pullImageStream(from imageRef: String, platform: String? = nil) throws -> StreamingProcess.Output {
        let binary = ContainerCLI.resolve() ?? "container"
        return try StreamingProcess.start(
            binary,
            arguments: ["image", "pull", "--platform", platform ?? Self.hostPlatform, "--progress", "plain", imageRef]
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
    /// Guards closePipes against closing write ends twice (double EOF).
    private var pipesClosed = false

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

    /// File handles to hand to the XPC `createProcess`/`bootstrap` calls.
    /// CRITICAL: XPC's `set(key:value: FileHandle)` closes the fd locally
    /// after transferring it — handing it our Pipe's own handles would
    /// leave them owning dead fd numbers whose later close() (by us or by
    /// FileHandle deinit) lands on whatever recycled the number (CLI pipe
    /// reads, NIO sockets) and crashes the app. We pass dup'ed fds wrapped
    /// in non-owning FileHandles so XPC's close hits only the dup.
    var stdioHandles: [FileHandle?] {
        func transferredCopy(_ handle: FileHandle?) -> FileHandle? {
            guard let handle else { return nil }
            let duplicate = dup(handle.fileDescriptor)
            guard duplicate >= 0 else { return nil }
            // FileHandle(fileDescriptor:) does not close on deinit.
            return FileHandle(fileDescriptor: duplicate)
        }
        return [
            transferredCopy(stdinPipe?.fileHandleForReading),
            transferredCopy(stdoutPipe.fileHandleForWriting),
            transferredCopy(stderrPipe?.fileHandleForWriting),
        ]
    }

    /// Close OUR stdout/stderr write-end originals after XPC has taken
    /// dups — otherwise our copies keep the pipe open and EOF never
    /// reaches the readers when the process exits.
    func releaseWriteEndsToRuntime() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
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
    /// process. Read ends are closed ONLY inside their own EOF handler —
    /// Foundation's `availableData` raises an NSException when invoked on a
    /// closed handle, and a readability handler can't throw, so closing a
    /// read end from elsewhere races the dispatch queue and kills the app.
    /// The exit code comes from `process.wait()` (the single authoritative
    /// waiter) — pipes can EOF slightly after the process is reaped, at
    /// which point a second wait would fail.
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
        // WRITE ends only: closing them delivers EOF to our readers, whose
        // handlers then close their own read ends safely. Never close a
        // read end here — an in-flight availableData on a closed handle
        // throws an uncatchable NSException.
        lock.lock()
        let alreadyClosed = pipesClosed
        pipesClosed = true
        lock.unlock()
        guard !alreadyClosed else { return }
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
