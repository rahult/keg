import Foundation

/// Owns the on-disk workspace for an agent session and the naming contract
/// that ties a session to its containers.
///
/// Naming contract (Tranche 1): everything belonging to session X is prefixed
/// `kegagent-<slug>` where slug is the sanitized session id — containers,
/// workspace directories, and (later) the pushed cloud sandbox.
///
/// Named `AgentWorkspace` rather than `AgentEnvironment` because
/// `EnvironmentTypes.swift` already uses `AgentEnvironment` for the
/// Anthropic Managed Agents environment DTO.
actor AgentWorkspace {
    private let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            self.baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Keg/AgentWorkspaces", isDirectory: true)
        }
    }

    // MARK: - Naming contract

    /// `kegagent-<slug>`: lowercase, `[a-z0-9-]`, Docker-name-safe (≤63 chars).
    static func containerName(sessionId: String) -> String {
        let slug = sessionId
            .lowercased()
            .map { c in ("a"..."z").contains(c) || ("0"..."9").contains(c) ? c : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-")
            .joined(separator: "-")
        let prefix = "kegagent-"
        let budget = 63 - prefix.count
        let clipped = slug.count > budget ? String(slug.prefix(budget)) : slug
        return prefix + clipped
    }

    /// Per-session workspace directory under the base directory.
    func workspacePath(sessionId: String) -> URL {
        baseDirectory.appendingPathComponent(Self.containerName(sessionId: sessionId), isDirectory: true)
    }

    // MARK: - Materialization

    /// Materialize the session workspace from a world recipe: writes
    /// keg.yaml so the project engine (or a cloud landing zone, later) can
    /// bring the services up. Idempotent; overwrites a changed recipe.
    @discardableResult
    func materialize(sessionId: String, recipe: WorldRecipe) async throws -> URL {
        try recipe.validate()

        let workspace = workspacePath(sessionId: sessionId)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try recipe.kegYAML.write(to: workspace.appendingPathComponent("keg.yaml"), atomically: true, encoding: .utf8)
        return workspace
    }
}
