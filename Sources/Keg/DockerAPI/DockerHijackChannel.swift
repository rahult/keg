import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1

// MARK: - Docker tcp-hijack channel
//
// The docker CLI refuses `POST /exec/{id}/start` unless the server performs
// Docker's connection hijack: reply `101 Switching Protocols` with
// `Upgrade: tcp`, then treat the connection as a raw bidirectional byte
// stream (stdcopy-multiplexed when the exec has no TTY). Plain Hummingbird
// has no upgrade support, so this file replaces the HTTP child channel with
// one that:
//
//   1. builds the same pipeline Hummingbird's HTTP1Channel would, but with
//      NIO's classic `HTTPServerUpgradeHandler` inserted after the decoder;
//   2. on a normal first request, finishes building the Hummingbird side
//      (HTTPTypes codec + async channel) and runs the standard request loop;
//   3. on an `Upgrade: tcp` request, strips the HTTP handlers and splices
//      the socket to the byte pump returned by `hijackHandler`.
//
// The upgrade handler only considers the FIRST request on a connection,
// which matches Docker clients: they open a fresh connection for hijacked
// calls (`Connection: Upgrade` forbids reuse anyway).

/// Raw byte interface handed to the hijack consumer after a successful
/// upgrade. Safe to call from any thread. Stdin bytes that arrive before a
/// read handler is installed are buffered (up to 1 MiB) and flushed on
/// subscription, so slow async exec setup never drops client input.
final class HijackedConnection: @unchecked Sendable {
    private let channel: Channel
    private let lock = NSLock()
    private var onRead: ((Data) -> Void)?
    private var onEOF: (() -> Void)?
    private var pendingStdin = Data()
    /// Set when the client half-closes before a read handler is installed;
    /// replayed on subscription so the EOF is never lost.
    private var sawEOF = false
    private static let maxBufferedStdin = 1 << 20

    /// Invoked once the splice handler is live in the pipeline (101 sent,
    /// connection fully raw). The consumer starts its async work here.
    var onEstablished: (@Sendable () -> Void)?

    /// Invoked when the client disconnects (half-close or full close).
    var onClosed: (@Sendable () -> Void)?
    private var closedReported = false
    private var isClosed = false

    init(channel: Channel) {
        self.channel = channel
    }


    /// Bytes arriving from the client (stdin for exec) plus EOF.
    func setReadHandler(_ handler: @escaping (Data) -> Void, eof: @escaping () -> Void) {
        lock.lock()
        onRead = handler
        onEOF = eof
        let buffered = pendingStdin
        let eofAlready = sawEOF
        pendingStdin = Data()
        lock.unlock()
        if !buffered.isEmpty {
            handler(buffered)
        }
        if eofAlready {
            eof()
        }
    }

    func deliver(_ data: Data) {
        lock.lock()
        if let onRead {
            lock.unlock()
            onRead(data)
            return
        }
        if pendingStdin.count + data.count <= Self.maxBufferedStdin {
            pendingStdin.append(data)
        }
        lock.unlock()
    }

    func deliverEOF() {
        lock.lock()
        let handler = onEOF
        let closedHandler = onClosed
        let alreadyReported = closedReported
        closedReported = true
        sawEOF = true
        lock.unlock()
        handler?()
        if !alreadyReported {
            closedHandler?()
        }
        _ = alreadyReported
    }

    /// Bytes to send to the client (stdout/stderr for exec). The actual
    /// write runs ON the channel's event loop: it serializes with close
    /// handling, and a write that loses the race simply sees an inactive
    /// channel — otherwise the write syscall can hit EBADF after fd
    /// teardown, which is a fatal NIO precondition.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { return }
        let channel = self.channel
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            channel.writeAndFlush(buffer, promise: nil)
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        channel.close(promise: nil)
    }
}

/// Bridges raw socket bytes (post-upgrade) to a `HijackedConnection`.
/// Inbound: ByteBuffer → connection.deliver. Outbound writes flow through
/// `HijackedConnection.write`, which writes plain ByteBuffers to the
/// (now HTTP-free) channel.
final class RawSpliceHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let connection: HijackedConnection

    init(connection: HijackedConnection) {
        self.connection = connection
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Auto-read may have been managed by handlers we removed; keep data
        // flowing to us, then let the consumer start its async work.
        context.channel.read()
        connection.onEstablished?()
        connection.onEstablished = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        connection.deliver(Data(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.channel.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.deliverEOF()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            connection.deliverEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// NIO classic upgrader for Docker's `Upgrade: tcp`. One instance per
/// connection (created in `DockerHijackHTTPChannel.setup`), so the stored
/// pending connection never races. Declines the upgrade — the classic
/// handler then falls back to plain HTTP handling — unless `hijackHandler`
/// accepts the request URI.
final class DockerTCPHijackUpgrader: HTTPServerProtocolUpgrader, @unchecked Sendable {
    let supportedProtocol = "tcp"
    let requiredUpgradeHeaders: [String] = []

    /// Decides whether `path` (e.g. `/v1.51/exec/abc/start`) may hijack the
    /// connection. Called on the channel's event loop before the 101 is
    /// sent; return false to refuse the upgrade (plain HTTP 500 follows).
    private let hijackHandler: @Sendable (String, HijackedConnection) -> Bool
    private let onHijackStarted: @Sendable () -> Void
    private var pendingConnection: HijackedConnection?

    init(
        hijackHandler: @escaping @Sendable (String, HijackedConnection) -> Bool,
        onHijackStarted: @escaping @Sendable () -> Void
    ) {
        self.hijackHandler = hijackHandler
        self.onHijackStarted = onHijackStarted
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        let connection = HijackedConnection(channel: channel)
        guard hijackHandler(upgradeRequest.uri, connection) else {
            return channel.eventLoop.makeFailedFuture(
                DockerAPIError.badRequest("connection hijack not supported for \(upgradeRequest.uri)")
            )
        }
        pendingConnection = connection
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Type", value: "application/vnd.docker.raw-stream")
        return channel.eventLoop.makeSucceededFuture(headers)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        guard let connection = pendingConnection else {
            return context.eventLoop.makeFailedFuture(DockerAPIError.badRequest("no pending hijack connection"))
        }
        pendingConnection = nil

        let pipeline = context.pipeline
        let splice = RawSpliceHandler(connection: connection)
        onHijackStarted()
        // Remove the never-engaged late builder, then add the raw splice.
        // The classic upgrade handler re-fires any stdin bytes it buffered
        // once this future succeeds and it removes itself.
        return pipeline.handler(type: LateHTTPPipelineBuilder.self)
            .flatMap { builder in
                pipeline.removeHandler(builder)
            }
            .flatMap { _ in
                pipeline.addHandler(splice)
            }
    }
}

/// Inbound handler sitting directly after the classic upgrade handler.
/// For a normal request (no upgrade in progress) it finishes building the
/// Hummingbird HTTP pipeline on first read-complete, re-fires everything it
/// buffered, removes itself, and hands the async channel to `handle(value:)`
/// via the stored continuation. For an upgrading connection it never fires —
/// the upgrader removes it while attaching the splice handler.
final class LateHTTPPipelineBuilder: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart

    private let logger: Logger
    private let responderReady: @Sendable (NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>) -> Void
    private var buffered: [NIOAny] = []
    private var engaged = false

    init(
        logger: Logger,
        responderReady: @escaping @Sendable (NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>) -> Void
    ) {
        self.logger = logger
        self.responderReady = responderReady
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if engaged {
            context.fireChannelRead(data)
            return
        }
        buffered.append(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        guard !engaged, !buffered.isEmpty else {
            context.fireChannelReadComplete()
            return
        }
        engaged = true

        do {
            let pipeline = context.pipeline
            try pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))
            try pipeline.syncOperations.addHandler(HTTPUserEventHandler(logger: logger))
            let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                wrappingChannelSynchronously: context.channel,
                configuration: .init(isOutboundHalfClosureEnabled: true)
            )
            let buffered = self.buffered
            self.buffered = []
            // Deliver buffered parts through the freshly added codec into
            // the async channel's inbound stream, then step aside.
            for part in buffered {
                context.fireChannelRead(part)
            }
            responderReady(asyncChannel)
            pipeline.syncOperations.removeHandler(context: context, promise: nil)
            context.fireChannelReadComplete()
        } catch {
            context.fireErrorCaught(error)
        }
    }
}

/// One-shot communication between the pipeline builder (event loop) and
/// `handle(value:)` (async task).
final class DockerHijackChannelState: @unchecked Sendable {
    enum Outcome {
        case http(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>)
        case hijacked
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func deliver(_ outcome: Outcome) {
        lock.lock()
        self.outcome = outcome
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    func awaitOutcome() async -> Outcome {
        if let resolved = cachedOutcome() {
            return resolved
        }
        return await withCheckedContinuation { continuation in
            if let resolved = registerWaiter(continuation) {
                continuation.resume(returning: resolved)
            }
        }
    }

    private func cachedOutcome() -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    private func registerWaiter(_ continuation: CheckedContinuation<Outcome, Never>) -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        if let outcome {
            return outcome
        }
        waiters.append(continuation)
        return nil
    }
}

/// The `ServerChildChannel` handed to Hummingbird's `HTTPServerBuilder`:
/// HTTP/1.1 with Docker tcp-hijack support. Mirrors `HTTP1Channel.setup`
/// but inserts NIO's upgrade handler and defers the Hummingbird-side
/// pipeline to `LateHTTPPipelineBuilder`.
struct DockerHijackHTTPChannel: ServerChildChannel, HTTPChannelHandler {
    typealias Value = DockerHijackChannelValue

    let responder: HTTPChannelHandler.Responder
    /// Shared across connections; decides which paths may hijack.
    let hijackHandler: @Sendable (String, HijackedConnection) -> Bool

    func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<Value> {
        let state = DockerHijackChannelState()
        let upgrader = DockerTCPHijackUpgrader(
            hijackHandler: hijackHandler,
            onHijackStarted: { state.deliver(.hijacked) }
        )
        let builder = LateHTTPPipelineBuilder(logger: logger) { asyncChannel in
            state.deliver(.http(asyncChannel))
        }
        let upgradeConfig = NIOHTTPServerUpgradeConfiguration(
            upgraders: [upgrader],
            completionHandler: { _ in }
        )
        do {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withPipeliningAssistance: false,
                withServerUpgrade: upgradeConfig,
                withErrorHandling: false,
                withOutboundHeaderValidation: false
            )
            try channel.pipeline.syncOperations.addHandler(builder)
            return channel.eventLoop.makeSucceededFuture(
                DockerHijackChannelValue(state: state, channel: channel)
            )
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    func handle(value: Value, logger: Logging.Logger) async {
        switch await value.state.awaitOutcome() {
        case .http(let asyncChannel):
            await handleHTTP(asyncChannel: asyncChannel, logger: logger)
        case .hijacked:
            // Raw bytes are pumped by the splice handler; keep this task
            // alive until the channel goes away.
            _ = try? await value.channel.closeFuture.get()
        }
    }
}

/// Marker value passed from `setup` to `handle`.
struct DockerHijackChannelValue: Sendable {
    let state: DockerHijackChannelState
    let channel: Channel
}

extension DockerHijackChannelValue: ServerChildChannelValue {}
