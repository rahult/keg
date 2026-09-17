import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Incremental stdcopy splitter

/// Which channel a framed chunk belongs to. (Named distinctly from the app
/// target's internal DockerStreamType so both can coexist at link time.)
public enum StreamChannel: Sendable {
    case stdout
    case stderr
}

/// Splits a live stdcopy stream (the 8-byte-header framing Docker uses for
/// non-TTY exec/log streams) into complete (channel, payload) pairs,
/// keeping partial frames buffered between appends.
///
/// Backed by [UInt8] on purpose: Data slices keep shifted indices after
/// removal, and frame offsets are simplest against a zero-based buffer.
public final class DockerStreamSplitter: @unchecked Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds raw bytes and returns every frame that became complete.
    public func append(_ data: Data) -> [(channel: StreamChannel, payload: Data)] {
        buffer.append(contentsOf: data)
        var frames: [(StreamChannel, Data)] = []

        while buffer.count >= 8 {
            let channelByte = buffer[0]
            let length = (UInt32(buffer[4]) << 24) | (UInt32(buffer[5]) << 16)
                | (UInt32(buffer[6]) << 8) | UInt32(buffer[7])
            let frameEnd = 8 + Int(length)
            guard buffer.count >= frameEnd else { break }

            let payload = Data(buffer[8..<frameEnd])
            buffer.removeFirst(frameEnd)

            let channel: StreamChannel = channelByte == 2 ? .stderr : .stdout
            frames.append((channel, payload))
        }
        return frames
    }

    /// Bytes held back waiting for a complete frame.
    public var bufferedByteCount: Int { buffer.count }
}

// MARK: - Terminal helpers

/// termios/ioctl helpers for TTY exec sessions: raw mode so the remote
/// pty owns line editing, and window size for resize events.
public enum TerminalControl {
    public static var stdinIsTTY: Bool { isatty(STDIN_FILENO) == 1 }

    /// Puts stdin into raw mode; returns the original settings to restore.
    public static func enableRawMode() -> termios? {
        guard stdinIsTTY else { return nil }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        return original
    }

    public static func restore(_ original: termios?) {
        guard var original else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }

    /// Current terminal size for the initial resize handshake.
    public static var size: (rows: UInt16, columns: UInt16)? {
        var ws = winsize()
        guard ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 else {
            return nil
        }
        return (ws.ws_row, ws.ws_col)
    }
}

// SIGWINCH flag: signal handlers cannot capture context, so the flag lives
// at file scope and the IO pump consumes it after poll() is interrupted.
nonisolated(unsafe) private var kegCLISIGWINCHReceived = false

// MARK: - Exec session

/// Options for one `keg exec` invocation.
public struct KegExecOptions: Sendable {
    public var command: [String]
    public var interactive: Bool
    public var tty: Bool
    public var environment: [String]
    public var workingDirectory: String?
    public var user: String?

    public init(
        command: [String],
        interactive: Bool = false,
        tty: Bool = false,
        environment: [String] = [],
        workingDirectory: String? = nil,
        user: String? = nil
    ) {
        self.command = command
        self.interactive = interactive
        self.tty = tty
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
    }
}

public enum KegExecError: Error, CustomStringConvertible {
    case noCommand
    case createFailed(String)
    case unexpectedStatus(Int, String)
    case exitCodeUnavailable

    public var description: String {
        switch self {
        case .noCommand: return "no command given"
        case .createFailed(let message): return "exec create failed: \(message)"
        case .unexpectedStatus(let status, let body):
            return body.isEmpty ? "exec start returned HTTP \(status)" : "exec start returned HTTP \(status): \(body)"
        case .exitCodeUnavailable: return "exec finished but its exit code was not reported"
        }
    }
}

/// Runs `docker exec` semantics against Keg's socket: create the exec,
/// hijack a connection for start (`101 Switching Protocols` + `Upgrade:
/// tcp`), pump stdio both ways, and resolve the exit code from
/// `GET /exec/{id}/json`.
public final class KegExecSession: @unchecked Sendable {
    private let socketPath: String
    private let containerID: String
    private let http: UnixSocketHTTPClient

    public init(socketPath: String, containerID: String) {
        self.socketPath = socketPath
        self.containerID = containerID
        self.http = UnixSocketHTTPClient(socketPath: socketPath, timeoutSeconds: 30)
    }

    // MARK: - Public entry point

    /// Executes the command and returns its exit code. Stdout/stderr stream
    /// to the real descriptors as they arrive; stdin forwards when
    /// `options.interactive`.
    public func run(_ options: KegExecOptions) throws -> Int32 {
        guard !options.command.isEmpty else { throw KegExecError.noCommand }
        let execID = try createExec(options)

        let fd = try connectSocket()
        defer { close(fd) }

        // Set up the terminal before starting so the initial resize lands.
        let originalTermios = options.tty ? TerminalControl.enableRawMode() : nil
        defer { TerminalControl.restore(originalTermios) }

        try sendStartRequest(fd: fd, execID: execID, tty: options.tty)
        try verifyUpgrade(fd: fd)

        // SIGWINCH-driven resize, only meaningful for TTY sessions. The
        // handler can't capture context, so it flips a file-scope flag the
        // pump drains whenever poll() comes back interrupted.
        var previousWinchHandler: (@convention(c) (Int32) -> Void)?
        if options.tty, TerminalControl.stdinIsTTY {
            previousWinchHandler = signal(SIGWINCH, SIG_IGN)
            signal(SIGWINCH) { _ in
                kegCLISIGWINCHReceived = true
            }
            sendResize(execID: execID)
        }
        defer {
            if let previousWinchHandler {
                signal(SIGWINCH, previousWinchHandler)
            }
        }

        try pumpIO(fd: fd, interactive: options.interactive, tty: options.tty) {
            if kegCLISIGWINCHReceived {
                kegCLISIGWINCHReceived = false
                sendResize(execID: execID)
            }
        }

        return try exitCode(execID: execID)
    }

    // MARK: - Protocol steps

    private struct ExecCreateResponse: Decodable {
        let id: String
        enum CodingKeys: String, CodingKey { case id = "Id" }
    }

    private struct ExecInspect: Decodable {
        let running: Bool
        let exitCode: Int?
        enum CodingKeys: String, CodingKey {
            case running = "Running"
            case exitCode = "ExitCode"
        }
    }

    private func createExec(_ options: KegExecOptions) throws -> String {
        var payload: [String: Any] = [
            "Cmd": options.command,
            "AttachStdout": true,
            "AttachStderr": true,
            "Tty": options.tty,
        ]
        if options.interactive {
            payload["AttachStdin"] = true
        }
        if !options.environment.isEmpty {
            payload["Env"] = options.environment
        }
        if let workingDirectory = options.workingDirectory {
            payload["WorkingDir"] = workingDirectory
        }
        if let user = options.user, !user.isEmpty {
            payload["User"] = user
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try http.post("/containers/\(containerID)/exec", body: body)
        guard response.status == 201 else {
            throw KegExecError.createFailed(
                "HTTP \(response.status): \(String(data: response.body, encoding: .utf8) ?? "")"
            )
        }
        let created = try JSONDecoder().decode(ExecCreateResponse.self, from: response.body)
        return created.id
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(String(cString: strerror(errno)))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < sunPathSize else {
            close(fd)
            throw UnixSocketHTTPClient.ClientError.connectFailed(socketPath)
        }
        socketPath.withCString { cPath in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                let base = UnsafeMutableRawPointer(addrPtr).assumingMemoryBound(to: CChar.self)
                let pathPtr = base.advanced(by: MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!)
                strncpy(pathPtr, cPath, sunPathSize - 1)
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw UnixSocketHTTPClient.ClientError.connectFailed(socketPath)
        }
        return fd
    }

    private func sendStartRequest(fd: Int32, execID: String, tty: Bool) throws {
        let body = Array("{\"Detach\":false,\"Tty\":\(tty)}".utf8)
        var request = "POST /exec/\(execID)/start HTTP/1.1\r\n"
        request += "Host: keg\r\n"
        request += "Content-Type: application/json\r\n"
        request += "Content-Length: \(body.count)\r\n"
        // The hijack handshake: docker-style clients demand the upgrade,
        // and Keg's server only hijacks when it sees one.
        request += "Connection: Upgrade\r\n"
        request += "Upgrade: tcp\r\n\r\n"
        let requestBytes = Array(request.utf8)
        let sent = requestBytes.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return send(fd, base, requestBytes.count, 0)
        }
        guard sent >= 0 else {
            throw UnixSocketHTTPClient.ClientError.sendFailed(String(cString: strerror(errno)))
        }
        let bodySent = body.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return send(fd, base, body.count, 0)
        }
        guard bodySent >= 0 else {
            throw UnixSocketHTTPClient.ClientError.sendFailed(String(cString: strerror(errno)))
        }
    }

    /// Reads the response head; anything after it belongs to the exec
    /// stream. Only 101 continues.
    private func verifyUpgrade(fd: Int32) throws {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while collected.range(of: Data("\r\n\r\n".utf8)) == nil {
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { break }
            collected.append(contentsOf: buffer[0..<received])
        }
        guard let headEnd = collected.range(of: Data("\r\n\r\n".utf8)) else {
            throw UnixSocketHTTPClient.ClientError.badResponse
        }
        let head = String(data: collected[collected.startIndex..<headEnd.lowerBound], encoding: .utf8) ?? ""
        guard head.hasPrefix("HTTP/1.1 101") || head.hasPrefix("HTTP/1.0 101") else {
            let status = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            // Drain whatever body arrived for the error message.
            var body = collected[headEnd.upperBound...]
            if body.isEmpty {
                let received = recv(fd, &buffer, buffer.count, 0)
                if received > 0 { body.append(contentsOf: buffer[0..<received]) }
            }
            throw KegExecError.unexpectedStatus(status, String(data: body, encoding: .utf8) ?? "")
        }
        // Any bytes already read past the head are stream payload.
        pendingStreamData = collected[headEnd.upperBound...]
    }

    // MARK: - IO pumping

    /// Bytes read past the response head during the upgrade handshake.
    private var pendingStreamData: Data?

    private func pumpIO(fd: Int32, interactive: Bool, tty: Bool, onInterrupt: () -> Void) throws {
        let splitter = DockerStreamSplitter()
        var stdinOpen = interactive

        func writeFrames(_ data: Data) {
            guard !tty else {
                FileHandle.standardOutput.write(data)
                return
            }
            for (channel, payload) in splitter.append(data) {
                switch channel {
                case .stderr: FileHandle.standardError.write(payload)
                case .stdout: FileHandle.standardOutput.write(payload)
                }
            }
        }

        if let pending = pendingStreamData, !pending.isEmpty {
            writeFrames(pending)
            pendingStreamData = nil
        }

        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            if stdinOpen {
                fds.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0))
            }
            let ready = poll(&fds, UInt32(fds.count), -1)
            if ready < 0 {
                if errno == EINTR {
                    onInterrupt()
                    continue
                }
                throw UnixSocketHTTPClient.ClientError.sendFailed(String(cString: strerror(errno)))
            }

            // Socket → local output.
            if fds[0].revents & Int16(POLLIN) != 0 || fds[0].revents & Int16(POLLHUP) != 0 {
                var buffer = [UInt8](repeating: 0, count: 65536)
                let received = recv(fd, &buffer, buffer.count, 0)
                if received <= 0 {
                    break // stream over
                }
                writeFrames(Data(buffer[0..<received]))
                continue
            }

            // Stdin → socket.
            if stdinOpen, fds.count == 2, fds[1].revents & Int16(POLLIN) != 0 {
                var buffer = [UInt8](repeating: 0, count: 65536)
                let readCount = read(STDIN_FILENO, &buffer, buffer.count)
                if readCount <= 0 {
                    // EOF: half-close our side; the server turns this into
                    // stdin EOF for the exec'd process and keeps streaming.
                    shutdown(fd, Int32(SHUT_WR))
                    stdinOpen = false
                    continue
                }
                let sent = send(fd, buffer, readCount, 0)
                guard sent >= 0 else {
                    throw UnixSocketHTTPClient.ClientError.sendFailed(String(cString: strerror(errno)))
                }
            }
        }
    }

    // MARK: - Exit code + resize

    private func exitCode(execID: String) throws -> Int32 {
        // The server records the code when the exec pump completes — a hair
        // after the stream EOFs. Retry briefly rather than racing.
        for attempt in 0..<15 {
            if let response = try? http.get("/exec/\(execID)/json"), response.status == 200,
               let inspect = try? JSONDecoder().decode(ExecInspect.self, from: response.body),
               !inspect.running, let code = inspect.exitCode {
                return Int32(code)
            }
            if attempt < 14 {
                usleep(200_000)
            }
        }
        throw KegExecError.exitCodeUnavailable
    }

    private func sendResize(execID: String) {
        guard let size = TerminalControl.size else { return }
        _ = try? http.post("/exec/\(execID)/resize?h=\(size.rows)&w=\(size.columns)")
    }
}
