// In-process DNS responder for the `*.keg` zone — the spike's dnsspike.swift
// moved into the app (proven 2026-09-24: A answers, empty NOERROR for
// AAAA/HTTPS-record so resolvers fall back to A, NXDOMAIN off-zone).
//
// Raw Darwin sockets on a dedicated thread on purpose: the whole protocol is
// a hundred lines and NIO adds nothing for a UDP echo-shape service. Port
// 15353 because container-apiserver 1.4.1 already binds 127.0.0.1:1053/2053.
//
// Resolution of `*.keg` to 127.0.0.1 needs /etc/resolver/keg pointing here —
// GatewayController surfaces that one-time command; this class only answers.

import Darwin
import Foundation

final class GatewayDNS: @unchecked Sendable {
    private let port: UInt16
    private let zone: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var thread: Thread?

    /// Port actually bound (differs from `port` when binding an ephemeral
    /// port for tests); read after `start()` returns.
    private(set) var boundPort: UInt16 = 0

    init(port: UInt16 = GatewayConfig.dnsPort, zone: String = GatewayConfig.zone) {
        self.port = port
        self.zone = zone
    }

    /// Binds and starts the responder thread. Throws on bind failure
    /// (port in use, permission, …).
    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd == -1 else { return }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw GatewayError.bindFailed("socket(): \(errnoDescription)") }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)  // s_addr is network byte order
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(sock)
            throw GatewayError.bindFailed("bind 127.0.0.1:\(port): \(errnoDescription)")
        }

        if port == 0 {
            var actual = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(sock, $0, &len)
                }
            }
            guard got == 0 else {
                close(sock)
                throw GatewayError.bindFailed("getsockname: \(errnoDescription)")
            }
            boundPort = UInt16(bigEndian: actual.sin_port)
        } else {
            boundPort = port
        }

        fd = sock
        let worker = Thread { [weak self] in
            self?.receiveLoop()
        }
        worker.name = "dev.rahult.keg.gateway-dns"
        worker.stackSize = 1 << 18
        thread = worker
        worker.start()
    }

    /// Closes the socket; the receive loop unwinds and the thread exits.
    func stop() {
        lock.lock()
        let handle = fd
        fd = -1
        boundPort = 0
        lock.unlock()
        guard handle != -1 else { return }
        close(handle)  // unblocks a blocking recvfrom with an error
        thread = nil
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock()
            let handle = fd
            lock.unlock()
            guard handle != -1 else { return }

            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(handle, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }
            guard received > 0 else {
                // Socket closed (stop) or transient error — check whether to
                // keep going so a spurious EINTR doesn't kill the loop.
                if errno == EINTR { continue }
                lock.lock()
                let stillOpen = fd == handle
                lock.unlock()
                if stillOpen { continue }  // transient; keep serving
                return
            }

            guard let response = Self.respond(to: Array(buffer[0..<received]), zone: zone) else { continue }
            _ = response.withUnsafeBufferPointer { body in
                withUnsafePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(handle, body.baseAddress, response.count, 0, $0, fromLen)
                    }
                }
            }
        }
    }

    // MARK: - DNS wire protocol (pure, unit-tested)

    /// Builds the response for one DNS query. Returns nil for malformed or
    /// multi-question packets (silently dropped, matching resolver behavior
    /// for probes it can't serve).
    static func respond(to query: [UInt8], zone: String) -> [UInt8]? {
        guard query.count > 12 else { return nil }
        let questionCount = Int(query[4]) << 8 | Int(query[5])
        guard questionCount == 1 else { return nil }
        guard let (name, questionEnd) = parseName(query, at: 12), questionEnd + 4 <= query.count else { return nil }
        let type = Int(query[questionEnd]) << 8 | Int(query[questionEnd + 1])
        let headEnd = questionEnd + 4  // name + root label + QTYPE + QCLASS

        let inZone = name == zone || name.hasSuffix("." + zone)
        let answerable = inZone && type == 1  // A record

        var flags: UInt16 = 0x8400  // QR=1, AA=1, opcode 0, RCODE=0 (NOERROR)
        if !inZone { flags |= 0x0003 }  // NXDOMAIN

        var message: [UInt8] = []
        message += query[0..<2]  // echo transaction ID
        message += u16(flags)
        message += u16(1)  // QDCOUNT
        message += u16(answerable ? 1 : 0)  // ANCOUNT
        message += [0, 0, 0, 0]  // NSCOUNT, ARCOUNT
        message += query[12..<headEnd]  // echo the question
        if answerable {
            message += [0xC0, 0x0C]  // NAME: pointer to the question at offset 12
            message += u16(1)  // TYPE A
            message += u16(1)  // CLASS IN
            message += [0, 0, 0, 5]  // TTL 5s — keeps stale answers out of tests and disables
            message += u16(4)  // RDLENGTH
            message += [127, 0, 0, 1]
        }
        return message
    }

    private static func parseName(_ query: [UInt8], at start: Int) -> (name: String, end: Int)? {
        var labels: [String] = []
        var index = start
        while index < query.count {
            let length = Int(query[index])
            if length == 0 { return (labels.joined(separator: ".").lowercased(), index + 1) }
            if length & 0xC0 != 0 { return nil }  // compression never appears in questions
            index += 1
            guard index + length <= query.count else { return nil }
            labels.append(String(decoding: query[index..<index + length], as: UTF8.self))
            index += length
        }
        return nil
    }

    private static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
}

enum GatewayError: LocalizedError {
    case bindFailed(String)
    case notRunning
    case routeInvalid(String)
    case keychainFailure(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .bindFailed(let detail): "Could not bind: \(detail)"
        case .notRunning: "The gateway service is not running."
        case .routeInvalid(let detail): "Invalid route: \(detail)"
        case .keychainFailure(let operation, let status): "Keychain \(operation) failed (OSStatus \(status))"
        }
    }
}

private var errnoDescription: String { String(cString: strerror(errno)) }
