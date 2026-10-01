import Foundation

/// Metadata about how a bundle was produced — recorded so an importer (or
/// a human reading the bundle) can tell a fresh workspace from one the
/// handoff flow initialized just to have a commit baseline.
struct SessionBundleMetadata: Codable, Sendable, Equatable {
    var sessionId: String
    var exportedAt: Date
    /// True when the exporter ran `git init` in the workspace because it
    /// wasn't already a git repo.
    var workspaceInitialized: Bool
    /// The branch the handoff committed and pushed.
    var branch: String
}

/// A self-contained export of an agent session: the world recipe plus the
/// append-only event log, optionally with the workspace diff and export
/// metadata. This is the `.kegsession` payload that gets shared, archived,
/// attached to review PRs, and (Tranche 3) pushed to a cloud landing zone.
struct SessionBundle: Codable, Sendable {
    var recipe: WorldRecipe
    var events: [SessionEvent]
    /// `git diff` output captured at export time; nil for bundles exported
    /// before diff support. Absent keys decode as nil, so pre-Tranche 2
    /// bundles still import.
    var diff: String?
    var metadata: SessionBundleMetadata?

    enum BundleError: Error, Equatable {
        case sessionNotFound(String)
    }

    init(
        recipe: WorldRecipe,
        events: [SessionEvent],
        diff: String? = nil,
        metadata: SessionBundleMetadata? = nil
    ) {
        self.recipe = recipe
        self.events = events
        self.diff = diff
        self.metadata = metadata
    }

    /// Write as the same self-contained JSON shape `export` produces.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
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
        try SessionBundle(recipe: recipe, events: events).write(to: url)
    }

    /// Import a previously exported bundle.
    static func `import`(from url: URL) async throws -> SessionBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionBundle.self, from: Data(contentsOf: url))
    }
}
