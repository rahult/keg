import Foundation

// MARK: - Store Updates (live projection)

/// A write to the session log, published after it lands on disk. The log
/// stays the source of truth — this is only a live projection for views
/// that want to reflect appends without re-reading the file (Tranche 1
/// streaming). Consumers filter by session id.
enum SessionLogUpdate: Sendable {
    case event(sessionId: String, event: SessionEvent)
    case sessionSaved(Session)
}

/// Handles persisting session data and events to disk
actor SessionStore {
    private let sessionsDirectory: URL
    private let encoder: JSONEncoder
    private let lineEncoder: JSONEncoder
    private let decoder: JSONDecoder
    private var updateContinuations: [UUID: AsyncStream<SessionLogUpdate>.Continuation] = [:]

    init(sessionsDirectory: URL? = nil) throws {
        let baseDir = sessionsDirectory ?? Self.defaultSessionsDirectory()
        self.sessionsDirectory = baseDir

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // JSONL must be one record per line — the pretty printer above is for
        // session.json only.
        self.lineEncoder = JSONEncoder()
        self.lineEncoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try Self.createDirectoryIfNeeded(at: baseDir)
    }

    private static func defaultSessionsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Keg/Sessions", isDirectory: true)
    }

    private static func createDirectoryIfNeeded(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Subscriptions

    /// Live projection of log writes. Events appended (by the runner or any
    /// other writer) arrive as `.event`; every `saveSession` lands as
    /// `.sessionSaved` (status transitions included). The stream is
    /// unbounded and never finishes on its own — cancel the consuming task.
    /// Registration is async, so append a baseline load after subscribing;
    /// appends that race the registration are already on disk and covered
    /// by that load.
    func updates() -> AsyncStream<SessionLogUpdate> {
        AsyncStream(SessionLogUpdate.self, bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeUpdateContinuation(id: id) }
            }
            Task { await self.addUpdateContinuation(id: id, continuation: continuation) }
        }
    }

    private func addUpdateContinuation(id: UUID, continuation: AsyncStream<SessionLogUpdate>.Continuation) {
        updateContinuations[id] = continuation
    }

    private func removeUpdateContinuation(id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    private func publish(_ update: SessionLogUpdate) {
        for continuation in updateContinuations.values {
            continuation.yield(update)
        }
    }

    // MARK: - Session Persistence

    func saveSession(_ session: Session) async throws {
        let sessionDir = sessionsDirectory.appendingPathComponent(session.id, isDirectory: true)
        try Self.createDirectoryIfNeeded(at: sessionDir)

        let metadataFile = sessionDir.appendingPathComponent("session.json")
        let data = try encoder.encode(session)
        try data.write(to: metadataFile, options: .atomic)
        publish(.sessionSaved(session))
    }

    func loadSession(id: String) async throws -> Session? {
        let metadataFile = sessionsDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("session.json")

        guard FileManager.default.fileExists(atPath: metadataFile.path) else {
            return nil
        }

        let data = try Data(contentsOf: metadataFile)
        return try decoder.decode(Session.self, from: data)
    }

    func loadAllSessions() async throws -> [Session] {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
            return []
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var sessions: [Session] = []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let metadataFile = entry.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: metadataFile.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: metadataFile)
                let session = try decoder.decode(Session.self, from: data)
                sessions.append(session)
            } catch {
                // Skip corrupted session files
                continue
            }
        }

        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    func deleteSession(id: String) async throws {
        let sessionDir = sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: sessionDir.path) {
            try FileManager.default.removeItem(at: sessionDir)
        }
    }

    // MARK: - Event Persistence

    func appendEvent(_ event: SessionEvent, toSession sessionId: String) async throws {
        let sessionDir = sessionsDirectory.appendingPathComponent(sessionId, isDirectory: true)
        try Self.createDirectoryIfNeeded(at: sessionDir)

        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        let eventData = try lineEncoder.encode(event)
        var eventLine = String(data: eventData, encoding: .utf8)! + "\n"

        // Append to file
        if FileManager.default.fileExists(atPath: eventsFile.path) {
            let fileHandle = try FileHandle(forWritingTo: eventsFile)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            if let lineData = eventLine.data(using: .utf8) {
                try fileHandle.write(contentsOf: lineData)
            }
        } else {
            try eventLine.write(to: eventsFile, atomically: true, encoding: .utf8)
        }
        publish(.event(sessionId: sessionId, event: event))
    }

    func appendEvents(_ events: [SessionEvent], toSession sessionId: String) async throws {
        for event in events {
            try await appendEvent(event, toSession: sessionId)
        }
    }

    func loadEvents(forSession sessionId: String) async throws -> [SessionEvent] {
        let eventsFile = sessionsDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("events.jsonl")

        guard FileManager.default.fileExists(atPath: eventsFile.path) else {
            return []
        }

        let content = try String(contentsOf: eventsFile, encoding: .utf8)
        var events: [SessionEvent] = []

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8) else { continue }
            do {
                let event = try decoder.decode(SessionEvent.self, from: lineData)
                events.append(event)
            } catch {
                // Skip malformed lines
                continue
            }
        }

        return events
    }

    func deleteEvents(forSession sessionId: String) async throws {
        let eventsFile = sessionsDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("events.jsonl")

        if FileManager.default.fileExists(atPath: eventsFile.path) {
            try FileManager.default.removeItem(at: eventsFile)
        }
    }

    // MARK: - Recipe Persistence (Tranche 2 handoff)

    /// The world recipe a session was run with, persisted alongside the
    /// log so handoff/cloud-push can reconstruct the session's world
    /// without re-reading the workspace. Additive: the log stays the
    /// source of truth; this is a convenience sidecar.
    func saveRecipe(_ recipe: WorldRecipe, forSession sessionId: String) async throws {
        let sessionDir = sessionsDirectory.appendingPathComponent(sessionId, isDirectory: true)
        try Self.createDirectoryIfNeeded(at: sessionDir)
        let data = try encoder.encode(recipe)
        try data.write(to: sessionDir.appendingPathComponent("recipe.json"), options: .atomic)
    }

    func loadRecipe(forSession sessionId: String) async throws -> WorldRecipe? {
        let recipeFile = sessionsDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("recipe.json")

        guard FileManager.default.fileExists(atPath: recipeFile.path) else {
            return nil
        }
        return try decoder.decode(WorldRecipe.self, from: Data(contentsOf: recipeFile))
    }
}

// MARK: - Session Manager

/// Manages session lifecycle, status transitions, and cleanup
actor SessionManager {
    private var activeSessions: [String: Session] = [:]
    private var statusListeners: [String: [(SessionStatus) -> Void]] = [:]
    private let store: SessionStore
    private let cleanupInterval: TimeInterval
    private var cleanupTask: Task<Void, Never>?
    private let agentRunner: HybridAgentRunner
    private let containerManager: LightweightContainerManager
    private var isPrewarmed = false

    enum SessionError: Error, LocalizedError {
        case sessionNotFound(String)
        case invalidStatusTransition(from: SessionStatus, to: SessionStatus)
        case sessionAlreadyExists(String)
        case storeError(String)

        var errorDescription: String? {
            switch self {
            case .sessionNotFound(let id):
                return "Session not found: \(id)"
            case .invalidStatusTransition(let from, let to):
                return "Invalid status transition from \(from.rawValue) to \(to.rawValue)"
            case .sessionAlreadyExists(let id):
                return "Session already exists: \(id)"
            case .storeError(let message):
                return "Store error: \(message)"
            }
        }
    }

    init(store: SessionStore? = nil, cleanupInterval: TimeInterval = 300) async throws {
        if let store = store {
            self.store = store
        } else {
            self.store = try SessionStore()
        }
        self.cleanupInterval = cleanupInterval
        self.agentRunner = HybridAgentRunner()
        self.containerManager = LightweightContainerManager()
        await restoreSessions()
        self.cleanupTask = Task { [weak self] in
            await self?.runCleanupLoop()
        }
    }

    deinit {
        cleanupTask?.cancel()
    }

    // MARK: - Session Lifecycle

    func createSession(
        id: String,
        agentId: String,
        agentVersion: Int,
        environmentId: String,
        type: String = "agent"
    ) async throws -> Session {
        if activeSessions[id] != nil {
            throw SessionError.sessionAlreadyExists(id)
        }

        let now = Date()
        let session = Session(
            id: id,
            type: type,
            agentId: agentId,
            agentVersion: agentVersion,
            environmentId: environmentId,
            status: .pending,
            createdAt: now,
            updatedAt: now
        )

        activeSessions[id] = session
        try await store.saveSession(session)
        return session
    }

    func getSession(id: String) async -> Session? {
        return activeSessions[id]
    }

    func listSessions() async -> [Session] {
        return Array(activeSessions.values).sorted { $0.createdAt > $1.createdAt }
    }

    func listActiveSessions() async -> [Session] {
        return activeSessions.values.filter { $0.status == .running || $0.status == .pending }
    }

    // MARK: - Status Transitions

    func transitionStatus(sessionId: String, to newStatus: SessionStatus) async throws {
        guard var session = activeSessions[sessionId] else {
            throw SessionError.sessionNotFound(sessionId)
        }

        guard isValidTransition(from: session.status, to: newStatus) else {
            throw SessionError.invalidStatusTransition(from: session.status, to: newStatus)
        }

        session.status = newStatus
        session = Session(
            id: session.id,
            type: session.type,
            agentId: session.agentId,
            agentVersion: session.agentVersion,
            environmentId: session.environmentId,
            status: newStatus,
            createdAt: session.createdAt,
            updatedAt: Date()
        )

        activeSessions[sessionId] = session
        try await store.saveSession(session)

        await notifyStatusChange(sessionId: sessionId, status: newStatus)
    }

    private func isValidTransition(from: SessionStatus, to: SessionStatus) -> Bool {
        switch (from, to) {
        case (.pending, .running),
             (.pending, .cancelled),
             (.running, .completed),
             (.running, .failed),
             (.running, .cancelled):
            return true
        default:
            return false
        }
    }

    // MARK: - Event Handling

    func recordEvent(_ event: SessionEvent, inSession sessionId: String) async throws {
        guard activeSessions[sessionId] != nil else {
            throw SessionError.sessionNotFound(sessionId)
        }

        try await store.appendEvent(event, toSession: sessionId)
    }

    func recordEvents(_ events: [SessionEvent], inSession sessionId: String) async throws {
        guard activeSessions[sessionId] != nil else {
            throw SessionError.sessionNotFound(sessionId)
        }

        try await store.appendEvents(events, toSession: sessionId)
    }

    func getEvents(forSession sessionId: String) async throws -> [SessionEvent] {
        guard activeSessions[sessionId] != nil else {
            throw SessionError.sessionNotFound(sessionId)
        }

        return try await store.loadEvents(forSession: sessionId)
    }

    // MARK: - Status Listeners

    func addStatusListener(for sessionId: String, handler: @escaping (SessionStatus) -> Void) {
        if statusListeners[sessionId] == nil {
            statusListeners[sessionId] = []
        }
        statusListeners[sessionId]?.append(handler)
    }

    func removeStatusListeners(for sessionId: String) {
        statusListeners[sessionId] = nil
    }

    private func notifyStatusChange(sessionId: String, status: SessionStatus) async {
        let listeners = statusListeners[sessionId] ?? []
        for listener in listeners {
            listener(status)
        }
    }

    // MARK: - Session Cleanup

    func cleanupSession(id: String) async throws {
        guard activeSessions[id] != nil else {
            throw SessionError.sessionNotFound(id)
        }

        // Check if session is in a terminal state
        guard let session = activeSessions[id],
              session.status == .completed || session.status == .failed || session.status == .cancelled else {
            return
        }

        // Optionally delete persisted data (comment out to keep history)
        // try await store.deleteSession(id: id)
        // try await store.deleteEvents(forSession: id)

        activeSessions.removeValue(forKey: id)
        statusListeners[id] = nil
    }

    func cleanupOldSessions(olderThan days: Int = 30) async throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var removedCount = 0

        let allSessions = try await store.loadAllSessions()
        for session in allSessions {
            if session.status == .completed || session.status == .failed || session.status == .cancelled {
                if session.updatedAt < cutoff {
                    try await store.deleteSession(id: session.id)
                    if activeSessions[session.id] != nil {
                        activeSessions.removeValue(forKey: session.id)
                    }
                    removedCount += 1
                }
            }
        }

        return removedCount
    }

    private func runCleanupLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(cleanupInterval))

                // Cleanup completed sessions older than 1 hour
                let cutoff = Date().addingTimeInterval(-3600)
                for (id, session) in activeSessions {
                    if session.status == .completed || session.status == .failed || session.status == .cancelled {
                        if session.updatedAt < cutoff {
                            try? await cleanupSession(id: id)
                        }
                    }
                }
            } catch {
                // Task cancelled or sleep failed
                break
            }
        }
    }

    // MARK: - Persistence Restoration

    private func restoreSessions() async {
        do {
            let sessions = try await store.loadAllSessions()
            for session in sessions {
                // Only restore non-terminal sessions as active
                if session.status == .running || session.status == .pending {
                    activeSessions[session.id] = session
                }
            }
        } catch {
            // Start fresh if restoration fails
        }
    }

    // MARK: - Session Data Access

    func getActiveSessionCount() async -> Int {
        return activeSessions.values.filter { $0.status == .running || $0.status == .pending }.count
    }

    func getSessionByAgent(agentId: String) async -> [Session] {
        return activeSessions.values.filter { $0.agentId == agentId }
    }

    func getSessionByEnvironment(environmentId: String) async -> [Session] {
        return activeSessions.values.filter { $0.environmentId == environmentId }
    }
}

// MARK: - Convenience Extensions

extension SessionManager {
    /// Start a new session for an agent/environment
    func startSession(
        agentId: String,
        agentVersion: Int = 1,
        environmentId: String
    ) async throws -> Session {
        // Pre-warm container on session start
        if !isPrewarmed {
            try? await prewarmContainer()
            isPrewarmed = true
        }

        let sessionId = "session-\(UUID().uuidString.prefix(12).lowercased())"
        _ = try await createSession(
            id: sessionId,
            agentId: agentId,
            agentVersion: agentVersion,
            environmentId: environmentId
        )

        try await transitionStatus(sessionId: sessionId, to: .running)
        return activeSessions[sessionId]!
    }

    // MARK: - Command Execution

    /// Execute a command using HybridAgentRunner (auto-selects process vs container)
    func executeCommand(_ command: String) async throws -> HybridAgentRunner.ExecutionResult {
        return try await agentRunner.execute(command: command)
    }

    /// Execute a command with forced execution mode
    func executeCommand(_ command: String, mode: HybridAgentRunner.Mode) async throws -> HybridAgentRunner.ExecutionResult {
        return try await agentRunner.execute(command: command, mode: mode)
    }

    // MARK: - Container Pre-warming

    /// Pre-warm the lightweight container for faster dangerous command execution
    func prewarmContainer(
        name: String = "lightweight-agent",
        image: String = "alpine:latest"
    ) async throws {
        try await containerManager.prewarm(name: name, image: image)
    }

    /// Check if container is pre-warmed and ready
    func isContainerReady() async -> Bool {
        do {
            _ = try await containerManager.exec(command: "echo ready")
            return true
        } catch {
            return false
        }
    }

    /// End a session with success
    func completeSession(_ sessionId: String) async throws {
        try await transitionStatus(sessionId: sessionId, to: .completed)
    }

    /// End a session with failure
    func failSession(_ sessionId: String) async throws {
        try await transitionStatus(sessionId: sessionId, to: .failed)
    }

    /// Cancel an active session
    func cancelSession(_ sessionId: String) async throws {
        try await transitionStatus(sessionId: sessionId, to: .cancelled)
    }

    // MARK: - Tool Mention Parsing

    /// Parse `@toolname` mentions from session input text.
    /// Returns an ordered list of unique tool names found.
    /// Handles quoted and unquoted tool references: `@read_file`, `@"custom tool"`, `@'another tool'`
    static func parseToolMentions(_ input: String) -> [String] {
        var tools: [String] = []
        var seen: Set<String> = []

        // Pattern: @ followed by optional quoted name ("..." or '...') or bare word
        let pattern = #"@(?:"([^"]+)"|'([^']+)'|([\w\-]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(input.startIndex..., in: input)
        for match in regex.matches(in: input, options: [], range: range) {
            // Group 0 = double-quoted, group 1 = single-quoted, group 2 = bare
            let name: String?
            if match.range(at: 1).location != NSNotFound {
                name = (input as NSString).substring(with: match.range(at: 1))
            } else if match.range(at: 2).location != NSNotFound {
                name = (input as NSString).substring(with: match.range(at: 2))
            } else {
                name = (input as NSString).substring(with: match.range(at: 3))
            }

            if let name, !seen.contains(name) {
                tools.append(name)
                seen.insert(name)
            }
        }

        return tools
    }
}
