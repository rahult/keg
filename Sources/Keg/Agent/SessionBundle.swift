import Foundation

/// A self-contained export of an agent session: the world recipe plus the
/// append-only event log. This is the `.kegsession` payload that gets shared,
/// archived, and (Tranche 3) pushed to a cloud landing zone.
struct SessionBundle: Codable, Sendable {
    var recipe: WorldRecipe
    var events: [SessionEvent]

    enum BundleError: Error, Equatable {
        case sessionNotFound(String)
    }

    init(recipe: WorldRecipe, events: [SessionEvent]) {
        self.recipe = recipe
        self.events = events
    }

    /// Export a session's persisted events plus the given recipe to `url` (JSON).
    static func export(
        sessionId: String,
        recipe: WorldRecipe,
        store: SessionStore,
        to url: URL
    ) async throws {
        guard try await store.loadSession(id: sessionId) != nil else {
            throw BundleError.sessionNotFound(sessionId)
        }
        let events = try await store.loadEvents(forSession: sessionId)
        let bundle = SessionBundle(recipe: recipe, events: events)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(bundle).write(to: url, options: .atomic)
    }

    /// Import a previously exported bundle.
    static func `import`(from url: URL) async throws -> SessionBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionBundle.self, from: Data(contentsOf: url))
    }
}
