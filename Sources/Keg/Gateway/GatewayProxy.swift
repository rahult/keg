// Gateway reverse proxy: a raw NIO TCP listener that routes by Host header
// to loopback upstreams and then relays bytes verbatim in both directions.
//
// Byte-splice by design: once the first request head is routed, the client
// and upstream channels are glued together, so WebSocket upgrades, SSE and
// streaming bodies pass through without the proxy understanding them (same
// thinking as DockerHijackChannel's RawSpliceHandler). Route is fixed per
// client connection — every new browser connection re-routes.

import NIOCore
import NIOPosix
import NIOSSL
import Foundation

/// Holds the current server TLS context so it can be swapped (leaf reissue)
/// without touching live channels — new connections pick up the new cert.
final class GatewayTLSContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: NIOSSLContext?

    init(context: NIOSSLContext? = nil) {
        self.context = context
    }

    func get() -> NIOSSLContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    func set(_ newContext: NIOSSLContext?) {
        lock.lock()
        defer { lock.unlock() }
        context = newContext
    }
}

final class GatewayProxy: @unchecked Sendable {
    private let port: Int
    private let table: GatewayRouteTable
    private let tlsContextBox: GatewayTLSContextBox?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var serverChannel: Channel?

    /// Port actually bound (differs from `port` when bound to an ephemeral
    /// port in tests); read after `start()` returns.
    private(set) var boundPort: Int = 0

    init(
        port: Int = GatewayConfig.proxyPort,
        table: GatewayRouteTable,
        tlsContextBox: GatewayTLSContextBox? = nil
    ) {
        self.port = port
        self.table = table
        self.tlsContextBox = tlsContextBox
    }

    func start() async throws {
        let table = table
        let tlsContextBox = tlsContextBox
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                // With TLS the box's current context terminates TLS before
                // the routing handler sees plaintext; the routing handler
                // itself is unchanged.
                let routing = GatewayProxyHandler(table: table)
                if let context = tlsContextBox?.get() {
                    return channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), routing])
                }
                return channel.pipeline.addHandler(routing)
            }

        do {
            let channel = try await awaitFuture(bootstrap.bind(host: "127.0.0.1", port: port))
            serverChannel = channel
            boundPort = channel.localAddress?.port ?? port
        } catch {
            try? await stop()
            throw GatewayError.bindFailed("proxy 127.0.0.1:\(port): \(error.localizedDescription)")
        }
    }

    func stop() async {
        let channel = serverChannel
        serverChannel = nil
        boundPort = 0
        if let channel {
            // Closing the listener stops accepts; live relay connections die
            // with their peers, and the group shutdown below reaps the rest.
            _ = try? await awaitFuture(channel.close())
        }
        try? await group.shutdownGracefully()
    }

    /// Bridges NIO's callback future into async/await.
    private func awaitFuture<T: Sendable>(_ future: EventLoopFuture<T>) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            future.whenComplete { continuation.resume(with: $0) }
        }
    }
}

/// Per-client-connection state machine: collect the request head, route it,
/// glue the channels, then relay.
final class GatewayProxyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private enum State {
        /// Accumulating bytes until the head terminator arrives.
        case collecting
        /// Head routed; waiting for the upstream connection.
        case connecting(head: [UInt8], pending: ByteBuffer)
        /// Bidirectional relay is live.
        case relaying
    }

    private static let headScanLimit = 64 * 1024
    private static let pendingLimit = 4 * 1024 * 1024

    private let table: GatewayRouteTable
    private var state: State = .collecting
    private var upstream: Channel?
    private var collected = ByteBuffer()

    init(table: GatewayRouteTable) {
        self.table = table
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = Self.unwrapInboundIn(data)

        switch state {
        case .relaying:
            upstream?.writeAndFlush(NIOAny(chunk), promise: nil)

        case .collecting:
            collected.writeBuffer(&chunk)
            guard let headEnd = Self.headEnd(of: collected) else {
                if collected.readableBytes > Self.headScanLimit {
                    writeResponse(context, Self.errorResponse(code: 431, reason: "headers too large"), thenClose: true)
                }
                return
            }
            handleCompleteHead(context, headEnd: headEnd)

        case .connecting(let head, var pending):
            // More client bytes while the upstream connection is dialing.
            pending.writeBuffer(&chunk)
            if pending.readableBytes > Self.pendingLimit {
                writeResponse(context, Self.errorResponse(code: 413, reason: "request too large"), thenClose: true)
            } else {
                state = .connecting(head: head, pending: pending)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        upstream = nil
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            // Client finished writing; the upstream sees the same fate.
            upstream?.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upstream?.close(promise: nil)
        context.close(promise: nil)
    }

    // MARK: - Head handling

    private func handleCompleteHead(_ context: ChannelHandlerContext, headEnd: Int) {
        let headBytes = collected.readBytes(length: headEnd) ?? []
        let bodyPrefix = collected  // remainder after the head

        guard let parsed = Self.parseRequestHead(headBytes), let host = parsed.host else {
            writeResponse(context, Self.errorResponse(code: 400, reason: "no Host header"), thenClose: true)
            return
        }

        guard let upstreamPort = table.upstream(for: host) else {
            writeResponse(context, Self.errorResponse(code: 404, reason: "no keg route for \(host)"), thenClose: true)
            return
        }

        let forwardedHead = Self.injectForwardedHeaders(into: headBytes, host: host)
        state = .connecting(head: forwardedHead, pending: bodyPrefix)
        dialUpstream(context, port: upstreamPort)
    }

    private func dialUpstream(_ context: ChannelHandlerContext, port: Int) {
        let front = context.channel
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ProxyRelayHandler(peer: front))
            }

        bootstrap.connect(host: "127.0.0.1", port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // Upstream app is down — a clean, explanatory close beats a hang.
                self.writeResponse(context, Self.errorResponse(code: 502, reason: "upstream not reachable on 127.0.0.1:\(port)"), thenClose: true)
            case .success(let upstreamChannel):
                guard case .connecting(let head, let pending) = self.state else {
                    upstreamChannel.close(promise: nil)
                    return
                }
                self.upstream = upstreamChannel
                upstreamChannel.closeFuture.whenComplete { _ in
                    front.close(promise: nil)
                }
                var payload = ByteBuffer(bytes: head)
                var pendingCopy = pending
                payload.writeBuffer(&pendingCopy)
                upstreamChannel.writeAndFlush(NIOAny(payload), promise: nil)
                self.state = .relaying
            }
        }
    }

    private func writeResponse(_ context: ChannelHandlerContext, _ response: String, thenClose: Bool) {
        let buffer = context.channel.allocator.buffer(string: response)
        context.channel.writeAndFlush(NIOAny(buffer), promise: nil)
        if thenClose {
            context.close(promise: nil)
        }
    }

    // MARK: - Pure parsing (unit-tested)

    /// Index of the first `\r\n\r\n` terminator in `buffer`, if present.
    static func headEnd(of buffer: ByteBuffer) -> Int? {
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        guard bytes.count >= 4 else { return nil }
        for offset in 0...(bytes.count - 4) {
            if bytes[offset] == 0x0D, bytes[offset + 1] == 0x0A,
               bytes[offset + 2] == 0x0D, bytes[offset + 3] == 0x0A {
                return offset + 4
            }
        }
        return nil
    }

    struct ParsedHead {
        var method: String
        var path: String
        var host: String?
        var isUpgrade: Bool
    }

    static func parseRequestHead(_ head: [UInt8]) -> ParsedHead? {
        let text = String(decoding: head[0..<(head.count - 4)], as: UTF8.self)
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }

        var host: String?
        var isUpgrade = false
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "host" { host = value }
            if name == "upgrade", !value.isEmpty { isUpgrade = true }
        }
        return ParsedHead(method: String(parts[0]), path: String(parts[1]), host: host.map(GatewayRouteTable.normalizeHostname), isUpgrade: isUpgrade)
    }

    /// Adds X-Forwarded-* headers just before the head's final CRLF.
    static func injectForwardedHeaders(into head: [UInt8], host: String) -> [UInt8] {
        guard head.count >= 4 else { return head }
        let insertion = head.count - 2  // keep the final CRLF
        let additions = Array("X-Forwarded-Proto: http\r\nX-Forwarded-Host: \(host)\r\n".utf8)
        return Array(head[0..<insertion]) + additions + Array(head[insertion...])
    }

    static func errorResponse(code: Int, reason: String) -> String {
        let body = "keg gateway: \(reason)\n"
        return "HTTP/1.1 \(code) \(shortStatus(code))\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
    }

    private static func shortStatus(_ code: Int) -> String {
        switch code {
        case 400: "Bad Request"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Bad Gateway"
        }
    }
}

/// Upstream-side relay: ships everything the app sends back to the client
/// channel and tears the pair down when either side goes away.
final class ProxyRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(NIOAny(Self.unwrapInboundIn(data)), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            peer.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }
}
