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

    /// The `<slug>` in `kegagent-<slug>`: lowercase, `[a-z0-9-]`, ≤63 chars
    /// including the prefix, Docker-name-safe.
    static func sessionSlug(_ sessionId: String) -> String {
        let slug = sessionId
            .lowercased()
            .map { c in ("a"..."z").contains(c) || ("0"..."9").contains(c) ? c : "-" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "-")
            .joined(separator: "-")
        let budget = 63 - "kegagent-".count
        return slug.count > budget ? String(slug.prefix(budget)) : slug
    }

    /// `kegagent-<slug>`: lowercase, `[a-z0-9-]`, Docker-name-safe (≤63 chars).
    static func containerName(sessionId: String) -> String {
        "kegagent-" + sessionSlug(sessionId)
    }

    /// Per-session workspace directory under the base directory.
    func workspacePath(sessionId: String) -> URL {
        baseDirectory.appendingPathComponent(Self.containerName(sessionId: sessionId), isDirectory: true)
    }

    // MARK: - Materialization

    /// Materialize the session workspace from a world recipe: writes
    /// keg.yaml so the project engine (or a cloud landing zone, later) can
    /// bring the services up. Idempotent; overwrites a changed recipe.
    ///
    /// A remote repo (https/ssh/git URL) starts as a **clone**, not a fresh
    /// directory: handoff (Tranche 2) then shares history with the remote's
    /// default branch, so the draft PR has a common base. A fresh `git init`
    /// produces an unrelated history that GitHub refuses to open a PR for.
    /// Local folders and already-cloned workspaces are left untouched.
    @discardableResult
    func materialize(sessionId: String, recipe: WorldRecipe) async throws -> URL {
        try recipe.validate()

        let workspace = workspacePath(sessionId: sessionId)
        let gitDir = workspace.appendingPathComponent(".git")
        // A missing workspace counts as empty — `git clone` creates it.
        let workspaceEmpty: Bool = {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: workspace.path)
            else { return true }
            return contents.isEmpty
        }()
        if Self.isRemoteGitURL(recipe.repo.url),
           !FileManager.default.fileExists(atPath: gitDir.path),
           workspaceEmpty {
            try await Self.git(["clone", "--", recipe.repo.url, workspace.path])
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try recipe.kegYAML.write(to: workspace.appendingPathComponent("keg.yaml"), atomically: true, encoding: .utf8)
        return workspace
    }

    /// `repo.url` points at a remote git transport (not a local folder path).
    static func isRemoteGitURL(_ url: String) -> Bool {
        url.hasPrefix("https://") || url.hasPrefix("http://")
            || url.hasPrefix("git@") || url.hasPrefix("ssh://")
    }

    /// One git invocation; throws with the command's stderr on failure.
    private static func git(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            let stderr = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "git exited \(process.terminationStatus)"
                    continuation.resume(throwing: NSError(domain: "Keg.AgentWorkspace", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "git \(arguments.first ?? "") failed: \(message)"
                    ]))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
