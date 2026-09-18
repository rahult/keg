import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Attaches to a container's retained stdio over the same hijack protocol
/// `keg exec` uses: `101 Switching Protocols` + `Upgrade: tcp`, then framed
/// (or raw, for TTY containers) bytes with recent history replayed first.
public final class KegAttachSession: @unchecked Sendable {
    private let socketPath: String
    private let containerID: String

    public init(socketPath: String, containerID: String) {
        self.socketPath = socketPath
        self.containerID = containerID
    }

    /// Streams the container's output until it exits (or the client
    /// detaches). Returns the container's exit code when available.
    public func run(interactive: Bool) throws -> Int32 {
        let http = UnixSocketHTTPClient(socketPath: socketPath, timeoutSeconds: 30)
        let fd = try openSocket(socketPath)
        defer { close(fd) }

        var request = "POST /containers/\(containerID)/attach?stream=1&stdout=1&stderr=1"
        if interactive {
            request += "&stdin=1"
        }
        request += " HTTP/1.1\r\nHost: keg\r\nContent-Length: 0\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
        let bytes = Array(request.utf8)
        let sent = bytes.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return send(fd, base, bytes.count, 0)
        }
        guard sent >= 0 else {
            throw UnixSocketHTTPClient.ClientError.sendFailed(String(cString: strerror(errno)))
        }

        // Read the head; the rest is stream payload.
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while collected.range(of: Data("\r\n\r\n".utf8)) == nil {
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { break }
            collected.append(contentsOf: buffer[0..<received])
        }
        guard let headEnd = collected.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: collected[collected.startIndex..<headEnd.lowerBound], encoding: .utf8),
              head.hasPrefix("HTTP/1.1 101") || head.hasPrefix("HTTP/1.0 101") else {
            let headText = String(data: collected.prefix(256), encoding: .utf8) ?? ""
            throw KegExecError.unexpectedStatus(0, headText)
        }

        let originalTermios = interactive ? TerminalControl.enableRawMode() : nil
        defer { TerminalControl.restore(originalTermios) }

        let splitter = DockerStreamSplitter()
        var stdinOpen = interactive
        var stream = collected[headEnd.upperBound...]

        func writeChunk(_ data: Data) {
            for (channel, payload) in splitter.append(data) {
                switch channel {
                case .stderr: FileHandle.standardError.write(payload)
                case .stdout: FileHandle.standardOutput.write(payload)
                }
            }
        }
        if !stream.isEmpty {
            writeChunk(Data(stream))
            stream = Data()[...]
        }

        // Same poll loop shape as exec: socket → output, stdin → socket.
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            if stdinOpen {
                fds.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0))
            }
            let ready = poll(&fds, UInt32(fds.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if fds[0].revents & Int16(POLLIN) != 0 || fds[0].revents & Int16(POLLHUP) != 0 {
                let received = recv(fd, &buffer, buffer.count, 0)
                if received <= 0 { break }
                writeChunk(Data(buffer[0..<received]))
                continue
            }
            if stdinOpen, fds.count == 2, fds[1].revents & Int16(POLLIN) != 0 {
                let readCount = read(STDIN_FILENO, &buffer, buffer.count)
                if readCount <= 0 {
                    shutdown(fd, Int32(SHUT_WR))
                    stdinOpen = false
                    continue
                }
                _ = send(fd, buffer, readCount, 0)
            }
        }

        // Container exit code, when the server has it.
        if let response = try? http.get("/containers/\(containerID)/json"),
           let text = String(data: response.body, encoding: .utf8),
           let range = text.range(of: "\"ExitCode\":(-?\\d+)", options: .regularExpression),
           let code = Int32(text[range].replacingOccurrences(of: "\"ExitCode\":", with: "")) {
            return code
        }
        return 0
    }

    private func openSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketHTTPClient.ClientError.socketFailed(String(cString: strerror(errno)))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < sunPathSize else {
            close(fd)
            throw UnixSocketHTTPClient.ClientError.connectFailed(path)
        }
        path.withCString { cPath in
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
            throw UnixSocketHTTPClient.ClientError.connectFailed(path)
        }
        return fd
    }
}
