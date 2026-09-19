import Foundation
import FoundationModels

/// Cooper's brain: owns the conversation, routes each turn through the
/// router, streams replies into the panel, surfaces approval cards, turns
/// runtime events into nudges, and persists the transcript.
///
/// Turn pipeline: classify (tool-less, constrained decoding) → build a
/// specialist session over the trimmed transcript → stream a reply whose
/// prompt embeds a fresh state snapshot. Sessions are always constructed
/// through the `model:` parameter so an alternative backend can slot in
/// later without touching this file.
@Observable
@MainActor
final class CooperController {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        /// Non-model notes in the transcript (greeting, recoveries).
        case info
    }

    struct Message: Identifiable, Codable, Sendable, Equatable {
        var id = UUID()
        var role: Role
        var text: String
        var isStreaming = false
    }

    /// One proactive suggestion. Built from a state transition without a
    /// model call; tapping it starts a real turn with `followUpPrompt`.
    struct Nudge: Identifiable, Sendable, Equatable {
        enum Kind: Equatable, Sendable {
            case runtimeUnresponsive
            case runtimeStopped
        }

        var id = UUID()
        var kind: Kind
        var headline: String
        var detail: String
        var followUpPrompt: String
    }

    /// Fed by AppState's refresh loop.
    enum Event: Sendable {
        case runtimeUnresponsive
        case runtimeStopped
        case runtimeRecovered
    }

    private(set) var messages: [Message] = []
    private(set) var isStreaming = false
    private(set) var availability: CooperAvailability = .checking
    private(set) var pendingApprovals: [CooperApprovalRequest] = []
    private(set) var nudges: [Nudge] = []

    private weak var appState: AppState?
    private let gateway: CooperGateway
    private var streamTask: Task<Void, Never>?
    private var savedTranscript: Transcript?
    private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var hasLoadedHistory = false
    private var hasGreeted = false
    private var streamWatchdogFired = false

    static let watchdogMessage = """
    The on-device model didn't answer in time — Apple Intelligence may be \
    busy or still setting up. Ask again in a moment.
    """

    /// Stage tracing for the turn pipeline → `~/.keg/cooper/debug.log`.
    nonisolated static func debugLog(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let line = "[\(stamp)] \(message)\n"
        let url = URL.homeDirectory.appendingPathComponent(".keg/cooper/debug.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    init(appState: AppState? = nil) {
        self.appState = appState
        self.gateway = CooperGateway(appState: appState)
    }

    /// Late binding for the app-owned instance: AppState constructs bare in
    /// its own init and attaches itself once every stored property exists.
    /// Also wires the approval-card flow, which needs a fully-initialized
    /// `self` to capture.
    func attach(to appState: AppState) async {
        self.appState = appState
        await gateway.attach(appState: appState)
        await gateway.installApprovalHandler { [weak self] request in
            guard let self else { return false }
            return await self.requestApproval(request)
        }
    }

    var permissionMode: AgentPermissionMode {
        appState?.agentPermissionMode ?? .ask
    }

    // MARK: - Lifecycle

    /// Loads persisted history and checks model availability. Cheap enough
    /// to call on every panel open; real work happens once.
    func prepare() async {
        checkAvailability()
        guard !hasLoadedHistory else { return }
        hasLoadedHistory = true
        if let stored = Self.loadTranscript() {
            savedTranscript = stored
        }
        messages = Self.loadMessages()
        if messages.isEmpty {
            greet()
        }
    }

    func checkAvailability() {
        availability = CooperAvailability.from(systemModel: .default)
    }

    private func greet() {
        guard !hasGreeted else { return }
        hasGreeted = true
        messages.append(Message(
            role: .info,
            text: """
            Hi, I'm Cooper — I keep an eye on Keg and can run its containers, \
            images, compose projects, and runtime for you. Ask anything, or \
            tap a suggestion when I spot something.
            """
        ))
        persistMessages()
    }

    // MARK: - Turns

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, availability == .ready else { return }
        messages.append(Message(role: .user, text: trimmed))
        isStreaming = true
        streamTask = Task { [weak self] in
            await self?.runTurn(trimmed)
            self?.isStreaming = false
            self?.streamTask = nil
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let index = messages.lastIndex(where: \.isStreaming) {
            messages[index].isStreaming = false
            persistMessages()
        }
    }

    func clearConversation() {
        guard !isStreaming else { return }
        messages.removeAll()
        savedTranscript = nil
        Self.removePersistence()
        hasGreeted = false
        greet()
    }

    /// The full turn pipeline, on the main actor; every long step inside is
    /// async and yields, and the framework offloads generation internally.
    private func runTurn(_ text: String) async {
        Self.debugLog("turn start")
        messages.append(Message(role: .assistant, text: "", isStreaming: true))
        await gateway.beginTurn()
        Self.debugLog("turn: beginTurn done")

        do {
            Self.debugLog("turn: classifying")
            let domain = try await CooperRouter.classify(prompt: text)
            Self.debugLog("turn: classified \(domain.rawValue)")
            try await streamReply(text: text, domain: domain, mode: permissionMode)
        } catch let error as CooperGateError {
            finishAssistant(with: error.message)
        } catch is CancellationError {
            finishAssistant(with: " …stopped.")
        } catch {
            await handleModelFailure(error, text: text)
        }
        persistMessages()
    }

    /// Streams the specialist reply, retrying once on context pressure.
    private func streamReply(text: String, domain: CooperDomain, mode: AgentPermissionMode, keepLast: Int = 14) async throws {
        var effectiveTranscript = Self.trimmed(savedTranscript ?? Transcript(), keepLast: keepLast)
        let tools = CooperRouter.tools(for: domain, gateway: gateway, mode: mode)
        let hint = CooperRouter.domainHint(for: domain)

        // Watchdog: the framework has no internal timeout, and a wedged
        // model daemon (observed on this machine) must not leave a caret
        // forever. Cancelling the stream task unwinds the suspended loop.
        streamWatchdogFired = false
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(150))
            guard !Task.isCancelled else { return }
            Self.debugLog("reply: WATCHDOG fired")
            self?.streamWatchdogFired = true
            self?.streamTask?.cancel()
        }
        defer { watchdog.cancel() }

        for attempt in 0..<2 {
            let session = LanguageModelSession(model: .default, tools: tools, transcript: effectiveTranscript)
            let snapshot = await CooperContext.loadSnapshot(appState: appState)
            let prompt = """
            \(hint)
            Current Keg state:
            \(snapshot.render())
            User request: \(text)
            """
        do {
            Self.debugLog("reply: session start")
            var lastRendered = ""
            for try await partial in session.streamResponse(to: prompt) {
                if Task.isCancelled { break }
                if partial.content != lastRendered {
                    lastRendered = partial.content
                    replaceStreamingMessage(with: lastRendered)
                }
            }
            Self.debugLog("reply: stream finished, chars=\(lastRendered.count)")
                // The watchdog may have cancelled us mid-stream (a wedged
                // model daemon leaves a caret forever otherwise); only trust
                // and persist a completed reply.
                if streamWatchdogFired {
                    finalizeStreamingMessage(with: Self.watchdogMessage)
                } else {
                    finalizeStreamingMessage(with: lastRendered)
                    savedTranscript = session.transcript
                    Self.persist(transcript: session.transcript)
                }
                return
            } catch is CancellationError where streamWatchdogFired {
                finalizeStreamingMessage(with: Self.watchdogMessage)
                return
            } catch {
                if attempt == 0, Self.isContextOverflow(error) {
                    effectiveTranscript = Self.trimmed(savedTranscript ?? Transcript(), keepLast: 4)
                    continue
                }
                throw error
            }
        }
    }

    /// One bounded recovery pass: backoff for throttle, hard trim for
    /// overflow, plain language for refusals and everything else. Handles
    /// both error generations — `LanguageModelError` is macOS 27+,
    /// `GenerationError` is what a macOS 26 runtime throws.
    private func handleModelFailure(_ error: Error, text: String) async {
        if Self.isThrottled(error) {
            try? await Task.sleep(for: .seconds(2))
            do {
                try await streamReply(text: text, domain: .overview, mode: permissionMode)
            } catch {
                finishAssistant(with: "The on-device model is busy. Give it a moment and ask again.")
            }
            return
        }
        if Self.isRefusal(error) {
            finishAssistant(with: "I can't help with that particular request. Try rephrasing it.")
            return
        }
        if Self.isContextOverflow(error) {
            savedTranscript = Transcript()
            Self.persist(transcript: savedTranscript!)
            finishAssistant(with: """
            Our conversation outgrew the on-device model's memory, so I started fresh. \
            Ask again and I'll pick up from the current state.
            """)
            return
        }
        if error is CooperBounded.TimeoutError {
            finishAssistant(with: """
            The on-device model didn't answer in time — Apple Intelligence may \
            be busy or still setting up. Ask again in a moment.
            """)
            return
        }
        finishAssistant(with: "Something went sideways: \(error.localizedDescription)")
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        if #available(macOS 27.0, *), case .contextSizeExceeded = error as? LanguageModelError {
            return true
        }
        if case .exceededContextWindowSize = error as? LanguageModelSession.GenerationError {
            return true
        }
        return false
    }

    private static func isThrottled(_ error: Error) -> Bool {
        if #available(macOS 27.0, *), case .rateLimited = error as? LanguageModelError {
            return true
        }
        if case .rateLimited = error as? LanguageModelSession.GenerationError {
            return true
        }
        return false
    }

    private static func isRefusal(_ error: Error) -> Bool {
        if #available(macOS 27.0, *) {
            if case .refusal = error as? LanguageModelError { return true }
            if case .guardrailViolation = error as? LanguageModelError { return true }
        }
        if case .refusal = error as? LanguageModelSession.GenerationError { return true }
        if case .guardrailViolation = error as? LanguageModelSession.GenerationError { return true }
        return false
    }

    // MARK: - Message mutation

    private func replaceStreamingMessage(with text: String) {
        guard let index = messages.lastIndex(where: \.isStreaming) else { return }
        messages[index].text = text
    }

    private func finalizeStreamingMessage(with text: String) {
        guard let index = messages.lastIndex(where: \.isStreaming) else { return }
        messages[index].text = text
        messages[index].isStreaming = false
    }

    private func finishAssistant(with text: String) {
        replaceStreamingMessage(with: text)
        finalizeStreamingMessage(with: text)
    }

    // MARK: - Approvals

    private func requestApproval(_ request: CooperApprovalRequest) async -> Bool {
        pendingApprovals.append(request)
        defer { pendingApprovals.removeAll { $0.id == request.id } }
        return await withCheckedContinuation { continuation in
            approvalContinuations[request.id] = continuation
        }
    }

    func approve(_ id: UUID) {
        approvalContinuations[id]?.resume(returning: true)
        approvalContinuations[id] = nil
    }

    func deny(_ id: UUID) {
        approvalContinuations[id]?.resume(returning: false)
        approvalContinuations[id] = nil
    }

    // MARK: - Nudges

    func observe(event: Event) {
        switch event {
        case .runtimeUnresponsive:
            guard !nudges.contains(where: { $0.kind == .runtimeUnresponsive }) else { return }
            nudges.append(Nudge(
                kind: .runtimeUnresponsive,
                headline: "Runtime looks unresponsive",
                detail: "The container services are alive but not answering. I can take a closer look.",
                followUpPrompt: "The container runtime is unresponsive. Check what's wrong and walk me through recovering it."
            ))
        case .runtimeStopped:
            guard !nudges.contains(where: { $0.kind == .runtimeStopped }) else { return }
            nudges.append(Nudge(
                kind: .runtimeStopped,
                headline: "Runtime is stopped",
                detail: "The container runtime isn't running. I can start it against your app-root.",
                followUpPrompt: "Start the container runtime for me."
            ))
        case .runtimeRecovered:
            nudges.removeAll { $0.kind == .runtimeUnresponsive || $0.kind == .runtimeStopped }
        }
        while nudges.count > 3 {
            nudges.removeFirst()
        }
    }

    func dismissNudge(_ id: UUID) {
        nudges.removeAll { $0.id == id }
    }

    func act(on nudge: Nudge) {
        nudges.removeAll { $0.id == nudge.id }
        send(nudge.followUpPrompt)
    }

    // MARK: - Persistence

    /// The display log is Keg-owned (`Message` is Codable); the model-side
    /// transcript is persisted separately so the next launch rehydrates the
    /// session from it.
    private static var cooperDirectory: URL {
        URL.homeDirectory.appendingPathComponent(".keg/cooper", isDirectory: true)
    }

    private static var messagesURL: URL {
        cooperDirectory.appendingPathComponent("messages.json")
    }

    private static var transcriptURL: URL {
        cooperDirectory.appendingPathComponent("transcript.json")
    }

    private func persistMessages() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? FileManager.default.createDirectory(at: Self.cooperDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.messagesURL, options: .atomic)
    }

    private static func persist(transcript: Transcript) {
        guard let data = try? JSONEncoder().encode(transcript) else { return }
        try? FileManager.default.createDirectory(at: cooperDirectory, withIntermediateDirectories: true)
        try? data.write(to: transcriptURL, options: .atomic)
    }

    private static func loadMessages() -> [Message] {
        guard let data = try? Data(contentsOf: messagesURL),
              let messages = try? JSONDecoder().decode([Message].self, from: data) else { return [] }
        return messages.map { message in
            var message = message
            message.isStreaming = false
            return message
        }
    }

    private static func loadTranscript() -> Transcript? {
        guard let data = try? Data(contentsOf: transcriptURL),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { return nil }
        return transcript
    }

    private static func removePersistence() {
        try? FileManager.default.removeItem(at: messagesURL)
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    // MARK: - Context budget

    /// Keeps the instructions entry plus the most recent complete exchanges.
    /// Dangling tool outputs at the seam are dropped so the model never sees
    /// a tool result without its call.
    nonisolated static func trimmed(_ transcript: Transcript, keepLast: Int = 14) -> Transcript {
        let entries = Array(transcript)
        guard entries.count > keepLast + 1 else { return transcript }
        let head = entries.prefix(1)
        var tail = Array(entries.suffix(keepLast))
        while let first = tail.first, !isExchangeBoundary(first) {
            tail.removeFirst()
        }
        return Transcript(entries: Array(head) + tail)
    }

    nonisolated private static func isExchangeBoundary(_ entry: Transcript.Entry) -> Bool {
        switch entry {
        case .prompt, .instructions:
            return true
        case .toolCalls, .toolOutput, .response, .reasoning:
            return false
        @unknown default:
            return false
        }
    }
}
