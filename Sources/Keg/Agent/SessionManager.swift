import Foundation

// MARK: - Session Store (Persistence)

/// Handles persisting session data and events to disk
actor SessionStore {
    private let sessionsDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(sessionsDirectory: URL? = nil) throws {
        let baseDir = sessionsDirectory ?? Self.defaultSessionsDirectory()
        self.sessionsDirectory = baseDir

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

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

    // MARK: - Session Persistence

    func saveSession(_ session: Session) async throws {
        let sessionDir = sessionsDirectory.appendingPathComponent(session.id, isDirectory: true)
        try Self.createDirectoryIfNeeded(at: sessionDir)

        let metadataFile = sessionDir.appendingPathComponent("session.json")
        let data = try encoder.encode(session)
        try data.write(to: metadataFile, options: .atomic)
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
        let eventData = try encoder.encode(event)
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
}

// MARK: - Session Manager

/// Manages session lifecycle, status transitions, and cleanup
actor SessionManager {
    private var activeSessions: [String: Session] = [:]
    private var statusListeners: [String: [(SessionStatus) -> Void]] = [:]
    private let store: SessionStore
    private let cleanupInterval: TimeInterval
    private var cleanupTask: Task<Void, Never>?

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
            self.store = try await SessionStore()
        }
        self.cleanupInterval = cleanupInterval
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
}
