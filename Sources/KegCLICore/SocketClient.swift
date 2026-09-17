import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A minimal synchronous HTTP/1.1 client over a Unix domain socket —
/// exactly what the Docker API speaks. Foundation-only on purpose: the
/// `keg` CLI should start instantly and work even when nothing else does.
public struct UnixSocketHTTPClient: Sendable {
    public struct Response: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    public enum ClientError: Error, CustomStringConvertible {
        case socketFailed(String)
        case connectFailed(String)
        case sendFailed(String)
        case timeout
        case badResponse

        public var description: String {
            switch self {
            case .socketFailed(let why): return "cannot create socket: \(why)"
            case .connectFailed(let path): return "cannot connect to \(path) — is Keg running?"
            case .sendFailed(let why): return "request failed: \(why)"
            case .timeout: return "timed out waiting for a response"
            case .badResponse: return "server sent a malformed response"
            }
        }
    }

    public let socketPath: String
    public let timeoutSeconds: Int32

    public init(socketPath: String, timeoutSeconds: Int32 = 10) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Requests

    public func get(_ path: String) throws -> Response {
        try request("GET", path, body: nil)
    }

    public func post(_ path: String, body: Data? = nil) throws -> Response {
        try request("POST", path, body: body)
    }

    public func delete(_ path: String) throws -> Response {
        try request("DELETE", path, body: nil)
    }

    public func request(_ method: String, _ path: String, body: Data? = nil) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.socketFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < sunPathSize else {
            throw ClientError.connectFailed(socketPath)
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
            throw ClientError.connectFailed(socketPath)
        }

        // Bounded reads/writes so a stuck server can't hang the CLI forever.
        var timeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var payload = "\(method) \(path) HTTP/1.1\r\n"
        payload += "Host: keg\r\n"
        if let body {
            payload += "Content-Type: application/json\r\n"
            payload += "Content-Length: \(body.count)\r\n"
        } else if method == "POST" {
            payload += "Content-Length: 0\r\n"
        }
        payload += "Connection: close\r\n\r\n"

        let sent = payload.withCString { cString -> Int in
            send(fd, cString, strlen(cString), 0)
        }
        guard sent >= 0 else { throw ClientError.sendFailed(String(cString: strerror(errno))) }
        if let body {
            body.withUnsafeBytes { raw in
                _ = send(fd, raw.baseAddress, raw.count, 0)
            }
        }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let received = recv(fd, &buffer, buffer.count, 0)
            if received <= 0 { break }
            collected.append(contentsOf: buffer[0..<received])
            if let parsed = Self.parse(collected), parsed.hasCompleteBody { break }
        }

        guard let parsed = Self.parse(collected), parsed.hasCompleteBody else {
            // Connection: close responses without length hints are complete
            // once recv drains — accept a parsed-but-unbounded body then.
            guard let closed = Self.parse(collected) else {
                throw ClientError.badResponse
            }
            return Response(status: closed.status, headers: closed.headers, body: closed.bodyData)
        }
        return Response(status: parsed.status, headers: parsed.headers, body: parsed.bodyData)
    }

    // MARK: - Response parsing

    /// HTTP/1.1 response parser handling Content-Length and
    /// Transfer-Encoding: chunked (Keg streams logs that way when it must).
    struct ParsedResponse {
        let status: Int
        let headers: [String: String]
        let bodyStart: Data.Index
        let bodyData: Data
        let hasCompleteBody: Bool
    }

    static func parse(_ data: Data) -> ParsedResponse? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }

        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let body = Data(data[headerEnd.upperBound...])

        if let lengthHeader = headers["content-length"], let length = Int(lengthHeader) {
            return ParsedResponse(
                status: status,
                headers: headers,
                bodyStart: headerEnd.upperBound,
                bodyData: body,
                hasCompleteBody: body.count >= length
            )
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var decoded = Data()
            var complete = false
            var index = body.startIndex
            while index < body.endIndex {
                // Read the chunk-size line.
                guard let lineEnd = body.range(of: Data("\r\n".utf8), in: index..<body.endIndex) else {
                    break // size line incomplete
                }
                let sizeText = String(data: body[index..<lineEnd.lowerBound], encoding: .utf8) ?? ""
                let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
                guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                let chunkStart = body.index(lineEnd.upperBound, offsetBy: 0)
                guard body.distance(from: chunkStart, to: body.endIndex) >= size + 2 else {
                    break // chunk incomplete
                }
                let chunkEnd = body.index(chunkStart, offsetBy: size)
                decoded.append(contentsOf: body[chunkStart..<chunkEnd])
                index = body.index(chunkEnd, offsetBy: 2) // skip trailing CRLF
                if size == 0 {
                    complete = true
                    break
                }
            }
            return ParsedResponse(
                status: status,
                headers: headers,
                bodyStart: headerEnd.upperBound,
                bodyData: decoded,
                hasCompleteBody: complete
            )
        }

        // No length information: complete when the server closed (we only
        // get here after recv returned 0) — optimistic while streaming.
        return ParsedResponse(
            status: status,
            headers: headers,
            bodyStart: headerEnd.upperBound,
            bodyData: body,
            hasCompleteBody: false
        )
    }
}
