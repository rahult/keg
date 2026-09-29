import Foundation
import KegCLICore

/// Brings a session's world recipe up as running containers (one microVM
/// per service) and tears it down — reusing `KegProjectEngine` over Keg's
/// Docker API socket, so recipe services appear in the app's Compose
/// screen exactly like `keg project up` results.
///
/// Naming contract: the project name is overridden to the session's
/// `kegagent-<slug>`, so every container is `kegagent-<slug>-<service>-1`.
///
/// `up`/`down` are injected seams: production wires `KegProjectEngine`,
/// tests inject recorders. A failed provision runs `down` on what it
/// started (same rule as the Apps store's failed installs).
actor AgentEnvironmentProvisioner {
    /// Build/pull + start every service; returns the created container names.
    typealias UpFn = @Sendable (_ config: KegProjectConfig, _ workspace: URL) throws -> [String]
    /// Stop + remove the session's services.
    typealias DownFn = @Sendable (_ config: KegProjectConfig, _ workspace: URL) throws -> Void

    struct ProvisionResult: Sendable {
        var workspace: URL
        var containers: [String]
    }

    private let workspace: AgentWorkspace
    private let up: UpFn
    private let down: DownFn

    init(
        workspace: AgentWorkspace? = nil,
        up: @escaping UpFn = AgentEnvironmentProvisioner.defaultUp,
        down: @escaping DownFn = AgentEnvironmentProvisioner.defaultDown
    ) {
        self.workspace = workspace ?? AgentWorkspace()
        self.up = up
        self.down = down
    }

    /// Materialize the workspace and bring the recipe's services up.
    func provision(sessionId: String, recipe: WorldRecipe) async throws -> ProvisionResult {
        try recipe.validate()
        let workspaceURL = try await workspace.materialize(sessionId: sessionId, recipe: recipe)
        var config = try KegProjectLoader.load(directory: workspaceURL.path)
        config.name = AgentWorkspace.containerName(sessionId: sessionId)

        do {
            let containers = try up(config, workspaceURL)
            return ProvisionResult(workspace: workspaceURL, containers: containers)
        } catch {
            // Leave no half-started world behind.
            try? down(config, workspaceURL)
            throw error
        }
    }

    /// Tear the session's services down (data survives, per the engine).
    func teardown(sessionId: String, recipe: WorldRecipe) async throws {
        let workspaceURL = try await workspace.materialize(sessionId: sessionId, recipe: recipe)
        var config = try KegProjectLoader.load(directory: workspaceURL.path)
        config.name = AgentWorkspace.containerName(sessionId: sessionId)
        try down(config, workspaceURL)
    }

    // MARK: - Production seams

    private static func makeEngine() -> KegProjectEngine {
        KegProjectEngine(client: KegAPIClient(socketPath: NSHomeDirectory() + "/.keg/docker.sock"))
    }

    private static let defaultUp: UpFn = { config, _ in
        let engine = makeEngine()
        let result = try engine.up(config)
        return result.outcomes.map(\.container)
    }

    private static let defaultDown: DownFn = { config, _ in
        let engine = makeEngine()
        _ = try engine.down(config)
    }
}
