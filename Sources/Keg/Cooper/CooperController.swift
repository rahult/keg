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
///
/// Two backends share this pipeline. The on-device one is the FoundationModels
/// path above. When the on-device model is unavailable — or the user forces
/// it — turns run against any OpenAI-compatible server (`streamRemoteReply`):
/// no router pass (a capable model takes the full tool set), OpenAI function
/// calling against the same gateway, reasoning output split out of the
/// visible reply, and its own persisted history. Approval cards, the
/// permission gate, and repeat-call protection are backend-independent.
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
        /// Live tool-activity chips ("⚙ container_logs", "✓ container_logs"),
        /// recomputed from stream snapshots. Optional so transcripts saved
        /// before this field decode cleanly.
        var toolActivity: [String]?
        /// Reasoning text (remote thinking models). Optional so transcripts
        /// saved before this field decode cleanly.
        var reasoning: String?
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
    /// Which brain the current turns run on. `.remote` when the on-device
    /// model is unavailable (or forced off) and an OpenAI-compatible
    /// server is configured; the panel shows `remoteLabel` then.
    private(set) var brain: CooperBrainKind = .onDevice
    private(set) var remoteLabel: String?
    private(set) var pendingApprovals: [CooperApprovalRequest] = []
    private(set) var nudges: [Nudge] = []

    private weak var appState: AppState?
    private let gateway: CooperGateway
    private var streamTask: Task<Void, Never>?
    private var savedTranscript: Transcript?
    /// The remote path's own conversation (OpenAI message shapes), kept
    /// alongside the FoundationModels transcript so switching backends
    /// never mixes dialects.
    private var remoteHistory: [CooperChatMessage] = []
    private var hasLoadedRemoteHistory = false
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
    /// `self` to capture, and starts the model warm-up.
    func attach(to appState: AppState) async {
        self.appState = appState
        await gateway.attach(appState: appState)
        await gateway.installApprovalHandler { [weak self] request in
            guard let self else { return false }
            return await self.requestApproval(request)
        }
        prewarmIfNeeded()
    }

    var permissionMode: AgentPermissionMode {
        appState?.agentPermissionMode ?? .ask
    }

    // MARK: - Lifecycle

    /// Loads persisted history and checks model availability. Cheap enough
    /// to call on every panel open; real work happens once.
    func prepare() async {
        checkAvailability()
        prewarmIfNeeded()
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

    /// Resolves which brain turns run on: the on-device model when it is
    /// ready (unless the remote path is forced), otherwise the configured
    /// OpenAI-compatible server. Cheap enough to call on every panel open;
    /// also invoked by Settings when the remote configuration changes.
    func checkAvailability() {
        let resolution = CooperBackendResolver.resolve(
            systemAvailability: CooperAvailability.from(systemModel: .default),
            preference: CooperRemoteConfigStore.loadPreference(),
            remote: CooperRemoteConfigStore.loadConfig()
        )
        availability = resolution.availability
        brain = resolution.brain
        remoteLabel = resolution.remoteConfig.map { "\($0.model) · \($0.hostDisplay)" }
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
        remoteHistory = []
        hasLoadedRemoteHistory = true
        Self.removePersistence()
        CooperChatHistory.removePersistence()
        hasGreeted = false
        greet()
    }

    /// The full turn pipeline, on the main actor; every long step inside is
    /// async and yields, and the framework offloads generation internally.
    private func runTurn(_ text: String) async {
        Self.debugLog("turn start (brain: \(brain == .remote ? "remote" : "on-device"))")
        messages.append(Message(role: .assistant, text: "", isStreaming: true))
        await gateway.beginTurn()
        Self.debugLog("turn: beginTurn done")

        switch brain {
        case .onDevice:
            await runOnDeviceTurn(text)
        case .remote:
            await runRemoteTurn(text)
        }
        persistMessages()
    }

    private func runOnDeviceTurn(_ text: String) async {
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
    }

    // MARK: - Remote turns (OpenAI-compatible backend)

    private func runRemoteTurn(_ text: String) async {
        do {
            try await streamRemoteReply(text: text)
        } catch let error as CooperGateError {
            finishAssistant(with: error.message)
        } catch is CancellationError {
            finishAssistant(with: " …stopped.")
        } catch {
            await handleRemoteFailure(error, text: text)
        }
    }

    /// Streams the remote model's reply with live tool round-trips, then
    /// persists the updated history. Retries once on context overflow with
    /// a hard-trimmed history.
    private func streamRemoteReply(text: String) async throws {
        let config = CooperRemoteConfigStore.loadConfig()
        guard config.isConfigured, let _ = config.effectiveBaseURL else {
            throw CooperRemoteError.configuration("No remote model is configured — set one up in Settings → Cooper.")
        }
        let apiKey = CooperKeychain.loadAPIKey()
        loadRemoteHistoryIfNeeded()
        var history = remoteHistory
        if history.first?.role != .system {
            history.insert(CooperChatMessage.system(Self.remoteSystemPrompt), at: 0)
        }
        let tools = CooperRemoteTools.allTools(gateway: gateway, mode: permissionMode)
        let snapshot = await CooperContext.loadSnapshot(appState: appState)
        let userPrompt = """
        Current Keg state:
        \(snapshot.render())
        User request: \(text)
        """

        // Remote watchdog: generous, because reasoning models can be silent
        // for minutes before the first token; URLSession's request timeout
        // is the lower backstop and the user's Stop button the real one.
        streamWatchdogFired = false
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            Self.debugLog("remote reply: WATCHDOG fired")
            self?.streamWatchdogFired = true
            self?.streamTask?.cancel()
        }
        defer { watchdog.cancel() }

        for attempt in 0..<2 {
            replaceStreamingMessage(with: "")
            do {
                Self.debugLog("remote reply: start (attempt \(attempt))")
                var lastRendered = ""
                var lastChips: [String] = []
                var finalHistory: [CooperChatMessage]?
                let stream = CooperOpenAIBackend.turn(
                    config: config,
                    apiKey: apiKey,
                    history: history,
                    userPrompt: userPrompt,
                    tools: tools
                )
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .update(let update):
                        if let delta = update.visibleDelta, !delta.isEmpty {
                            lastRendered += delta
                            replaceStreamingMessage(with: lastRendered)
                        }
                        if let delta = update.thinkingDelta, !delta.isEmpty,
                           config.thinking != .off {
                            appendStreamingReasoning(delta)
                        }
                        if let name = update.toolStarted {
                            lastChips.append("⚙ \(name)")
                            updateStreamingActivity(lastChips)
                        }
                        if let name = update.toolFinished,
                           let index = lastChips.firstIndex(of: "⚙ \(name)") {
                            lastChips[index] = "✓ \(name)"
                            updateStreamingActivity(lastChips)
                        }
                    case .done(let newHistory):
                        finalHistory = newHistory
                    }
                }
                Self.debugLog("remote reply: stream finished, chars=\(lastRendered.count)")
                if streamWatchdogFired {
                    finalizeStreamingMessage(with: Self.remoteWatchdogMessage(host: config.hostDisplay))
                } else {
                    finalizeStreamingMessage(with: lastRendered.isEmpty
                        ? "The model returned an empty reply. Try again, or pick a different model in Settings → Cooper."
                        : lastRendered)
                    if let finalHistory {
                        remoteHistory = finalHistory
                        CooperChatHistory.persist(finalHistory)
                    }
                }
                return
            } catch is CancellationError where streamWatchdogFired {
                finalizeStreamingMessage(with: Self.remoteWatchdogMessage(host: config.hostDisplay))
                return
            } catch {
                if attempt == 0, CooperRemoteError.isContextOverflow(error) {
                    history = CooperChatHistory.trimmed(history, keepLast: 6)
                    continue
                }
                throw error
            }
        }
    }

    /// Persona plus the all-tools guidance — the remote path sends one
    /// system message instead of the on-device path's per-turn domain hints.
    private static var remoteSystemPrompt: String {
        CooperContext.personaInstructions + "\n\n" + CooperRemoteTools.systemGuidance
    }

    private static func remoteWatchdogMessage(host: String) -> String {
        "The model at \(host) didn't answer in time — the server may be busy or unreachable. Ask again in a moment."
    }

    /// One bounded recovery pass for the remote path: exponential backoff
    /// for throttle, hard trim for overflow (handled in the stream loop),
    /// and provider-specific copy for everything else.
    private func handleRemoteFailure(_ error: Error, text: String) async {
        if Self.isThrottledRemote(error) {
            for delay in [2.0, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                Self.debugLog("remote retry after \(delay)s backoff")
                do {
                    try await streamRemoteReply(text: text)
                    return
                } catch {
                    if !Self.isThrottledRemote(error) {
                        finishAssistant(with: Self.remoteRecoveryCopy(error))
                        return
                    }
                }
            }
            finishAssistant(with: "The model server keeps rate-limiting us. Give it a moment and ask again.")
            return
        }
        if CooperRemoteError.isContextOverflow(error) {
            remoteHistory = CooperChatHistory.trimmed(remoteHistory, keepLast: 4)
            CooperChatHistory.persist(remoteHistory)
            finishAssistant(with: "Our conversation outgrew the model's context window, so I trimmed it back. Ask again and I'll pick up from the current state.")
            return
        }
        finishAssistant(with: Self.remoteRecoveryCopy(error))
    }

    private static func isThrottledRemote(_ error: Error) -> Bool {
        if case CooperRemoteError.http(let status, _) = error { return status == 429 }
        return false
    }

    private static func remoteRecoveryCopy(_ error: Error) -> String {
        switch error {
        case CooperRemoteError.configuration(let message):
            return message
        case CooperRemoteError.http(let status, let message):
            switch status {
            case 401, 403:
                return "The API key was rejected by the model server (\(message)). Check it in Settings → Cooper."
            case 404:
                return "The model or endpoint wasn't found (\(message)). Check the model name and server URL in Settings → Cooper."
            case 429:
                return "The model server is rate-limiting us (\(message)). Give it a moment and ask again."
            default:
                return "The model server reported an error: \(message)"
            }
        case CooperRemoteError.interrupted(let message):
            return message
        case CooperRemoteError.network(let message):
            return "Couldn't reach the model server: \(message)"
        default:
            return "Something went sideways: \(error.localizedDescription)"
        }
    }

    private func loadRemoteHistoryIfNeeded() {
        guard !hasLoadedRemoteHistory else { return }
        hasLoadedRemoteHistory = true
        remoteHistory = CooperChatHistory.load()
    }

    private func appendStreamingReasoning(_ delta: String) {
        guard let index = messages.lastIndex(where: \.isStreaming) else { return }
        messages[index].reasoning = (messages[index].reasoning ?? "") + delta
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
                var lastChips: [String] = []
                for try await partial in session.streamResponse(to: prompt) {
                    if Task.isCancelled { break }
                    if partial.content != lastRendered {
                        lastRendered = partial.content
                        replaceStreamingMessage(with: lastRendered)
                    }
                    // Live tool visibility: snapshots carry the transcript
                    // entries generated so far (macOS 27+). Recomputing from
                    // scratch each snapshot is cheap and self-healing.
                    if #available(macOS 27.0, *) {
                        let chips = Self.chipLabels(from: Array(partial.transcriptEntries))
                        if chips != lastChips {
                            lastChips = chips
                            updateStreamingActivity(chips)
                        }
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

    /// One bounded recovery pass: exponential backoff for throttle, hard
    /// trim for overflow, plain language for refusals and everything else.
    /// Handles both error generations — `LanguageModelError` is macOS 27+,
    /// `GenerationError` is what a macOS 26 runtime throws.
    private func handleModelFailure(_ error: Error, text: String) async {
        if Self.isThrottled(error) {
            // Exponential backoff: the framework throttles rapid requests,
            // and one fixed short retry isn't always enough.
            for delay in [2.0, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                Self.debugLog("retry after \(delay)s backoff")
                do {
                    try await streamReply(text: text, domain: .overview, mode: permissionMode)
                    return
                } catch {
                    if !Self.isThrottled(error) {
                        finishAssistant(with: Self.recoveryCopy(for: error))
                        return
                    }
                }
            }
            finishAssistant(with: "The on-device model is busy. Give it a moment and ask again.")
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
        finishAssistant(with: Self.recoveryCopy(for: error))
    }

    private static func recoveryCopy(for error: Error) -> String {
        if Self.isRefusal(error) {
            return "I can't help with that particular request. Try rephrasing it."
        }
        return "Something went sideways: \(error.localizedDescription)"
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

    private func updateStreamingActivity(_ chips: [String]) {
        guard let index = messages.lastIndex(where: \.isStreaming) else { return }
        messages[index].toolActivity = chips
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

    /// Chip labels for the panel: one per tool call, flipped from ⚙ (running)
    /// to ✓ (result received) when its output lands. Deterministic from the
    /// entry list so recomputing per snapshot is stable.
    nonisolated static func chipLabels(from entries: [Transcript.Entry]) -> [String] {
        var chips: [String] = []
        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls {
                    chips.append("⚙ \(call.toolName)")
                }
            case .toolOutput(let output):
                if let index = chips.firstIndex(of: "⚙ \(output.toolName)") {
                    chips[index] = "✓ \(output.toolName)"
                } else {
                    chips.append("✓ \(output.toolName)")
                }
            case .prompt, .instructions, .response, .reasoning:
                break
            @unknown default:
                break
            }
        }
        return chips
    }

    // MARK: - Prewarm

    /// Loads the model weights before the first question. The first-ever
    /// generation on a machine can otherwise stall for a long time (observed
    /// here); a prewarmed session answers in seconds. Called at attach (app
    /// launch) and again from the panel if assets weren't ready yet. Only
    /// applies to the on-device brain — and re-runs if that brain becomes
    /// active later (e.g. after switching back from remote).
    func prewarmIfNeeded() {
        guard !hasPrewarmedOnDevice, brain == .onDevice, availability == .ready else { return }
        hasPrewarmedOnDevice = true
        Self.debugLog("prewarm: start")
        Task.detached(priority: .utility) {
            let session = LanguageModelSession(
                model: .default,
                tools: [],
                instructions: CooperContext.personaInstructions
            )
            session.prewarm()
            CooperController.debugLog("prewarm: done")
        }
    }

    private var hasPrewarmedOnDevice = false

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
