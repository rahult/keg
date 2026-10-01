import Foundation

// MARK: - Pure helpers (unit-tested)

/// A GitHub remote, parsed from the various URL spellings git accepts.
struct GitHubRemote: Equatable, Sendable {
    var owner: String
    var repo: String

    /// Parse `https://github.com/owner/repo(.git)`, `http://…`,
    /// `git@github.com:owner/repo(.git)`, and `ssh://git@github.com/…`.
    /// Anything else (other hosts, missing/extra path components) is nil —
    /// push-for-review only speaks GitHub in v1.
    static func parse(_ raw: String) -> GitHubRemote? {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        // Strip scheme (ssh://git@github.com/owner/repo).
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
        }
        // Strip userinfo (git@…, ssh user prefix).
        if let at = rest.range(of: "@") {
            rest = String(rest[at.upperBound...])
        }

        // Host and path: either host/path or host:path (scp-like syntax).
        let host: String
        let path: String
        if let colon = rest.range(of: ":"), rest.distance(from: rest.startIndex, to: colon.lowerBound) < rest.distance(from: rest.startIndex, to: rest.firstIndex(of: "/") ?? rest.endIndex) {
            host = String(rest[rest.startIndex..<colon.lowerBound])
            path = String(rest[colon.upperBound...])
        } else {
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[rest.startIndex..<slash])
            path = String(rest[rest.index(after: slash)...])
        }
        guard host == "github.com" else { return nil }

        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        var repo = String(parts[1])
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return GitHubRemote(owner: owner, repo: repo)
    }
}

/// A compact, deterministic summary of a session's event log for commit
/// messages and PR bodies.
struct HandoffSummary: Equatable, Sendable {
    var total: Int
    var counts: [SessionEventType: Int]
    var firstUserInstruction: String?

    init(events: [SessionEvent]) {
        total = events.count
        counts = [:]
        for event in events {
            counts[event.type, default: 0] += 1
        }
        firstUserInstruction = events.first { $0.type == .userMessage }?.content
    }

    /// "3 user, 2 assistant, 1 tool call" — fixed display order, only
    /// kinds that occurred.
    var countsLine: String {
        let labels: [(SessionEventType, String)] = [
            (.userMessage, "user"),
            (.assistantMessage, "assistant"),
            (.toolUse, "tool call"),
            (.toolResult, "tool result"),
            (.error, "error"),
            (.statusUpdate, "status"),
        ]
        let parts = labels.compactMap { kind, label -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(count) \(label)\(count == 1 ? "" : "s")"
        }
        return parts.isEmpty ? "no events" : parts.joined(separator: ", ")
    }
}

// MARK: - Handoff

/// Tranche 2 artifact handoff: turn a finished agent session into a
/// reviewable draft PR on GitHub.
///
/// Mechanics: snapshot the workspace diff, write the `.kegsession` bundle
/// (log + recipe + diff + metadata) into the workspace, commit everything
/// on `keg/<session-id>`, push, and open a draft PR with `gh` (which owns
/// auth — Keg never touches tokens). The bundle rides the branch as
/// `.keg/session.kegsession`: `gh pr create` can't attach arbitrary files,
/// and a committed bundle travels with the branch, needs no upload API,
/// and is exactly what `Continue in Cloud` will consume in Tranche 3.
actor Handoff {
    struct HandoffResult: Sendable, Equatable {
        var prURL: String
        var branch: String
        /// The bundle committed with the branch, inside the workspace.
        var bundlePath: String
    }

    enum HandoffError: Error, Equatable, LocalizedError {
        case workspaceMissing(String)
        case recipeMissing(String)
        case notGitHubRemote(String)
        case toolUnavailable(String)
        case commandFailed(command: String, output: String)
        case timedOut(command: String)
        case prURLNotReturned(output: String)

        var errorDescription: String? {
            switch self {
            case .workspaceMissing(let path):
                return "The session's workspace is missing at \(path)."
            case .recipeMissing(let sessionId):
                return "This session (\(sessionId)) has no saved world recipe to hand off."
            case .notGitHubRemote(let url):
                return "“\(url)” isn't a GitHub repo. Push for review needs a github.com remote."
            case .toolUnavailable(let tool):
                return tool == "gh"
                    ? "The GitHub CLI (gh) isn't installed or not on your PATH. Install it and run gh auth login."
                    : "git isn't available on your PATH."
            case .commandFailed(let command, let output):
                let tail = String(output.suffix(300))
                return "“\(command)” failed. \(tail)"
            case .timedOut(let command):
                return "“\(command)” timed out after 120 seconds."
            case .prURLNotReturned(let output):
                return "The pull request was created but its URL couldn't be read from gh's output: \(output)"
            }
        }
    }

    struct ProcessResult: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    /// Shell seam: tests inject a scripted runner; production shells out.
    typealias Run = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ directory: URL?,
        _ timeout: Duration
    ) async throws -> ProcessResult

    static let bundleRelativePath = ".keg/session.kegsession"

    private let run: Run
    private let timeout: Duration

    init(run: @escaping Run = Handoff.defaultRun, timeout: Duration = .seconds(120)) {
        self.run = run
        self.timeout = timeout
    }

    // MARK: - Push for review

    /// Full flow: resolve the session's recipe + workspace, then push.
    func pushForReview(sessionId: String, store: SessionStore) async throws -> HandoffResult {
        guard let recipe = try await store.loadRecipe(forSession: sessionId) else {
            throw HandoffError.recipeMissing(sessionId)
        }
        let workspace = await AgentWorkspace().workspacePath(sessionId: sessionId)
        let events = (try? await store.loadEvents(forSession: sessionId)) ?? []
        return try await pushForReview(
            workspace: workspace,
            sessionId: sessionId,
            recipe: recipe,
            events: events
        )
    }

    /// The git/gh mechanics against an explicit workspace — the testable core.
    func pushForReview(
        workspace: URL,
        sessionId: String,
        recipe: WorldRecipe,
        events: [SessionEvent]
    ) async throws -> HandoffResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HandoffError.workspaceMissing(workspace.path)
        }
        try await requireTools()

        // Baseline: the workspace must be a git repo for the diff/commit
        // flow. If it isn't (agent worked in a bare materialized folder),
        // initialize one — recorded in the bundle metadata.
        let wasRepo = (try? await git(
            ["rev-parse", "--is-inside-work-tree"], cwd: workspace
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == "true"
        if !wasRepo {
            try await git(["init", "-b", "main"], cwd: workspace)
        }

        // Remote: an existing origin wins (the agent may have cloned its own
        // repo into the workspace); otherwise the recipe's repo must be a
        // GitHub URL — that's what we push the branch to.
        let origin = (try? await git(
            ["remote", "get-url", "origin"], cwd: workspace
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let remoteString = origin ?? recipe.repo.url
        guard let remote = GitHubRemote.parse(remoteString) else {
            throw HandoffError.notGitHubRemote(remoteString)
        }
        if origin == nil {
            try await git(["remote", "add", "origin", recipe.repo.url], cwd: workspace)
        }

        let branch = Self.branchName(sessionId: sessionId)
        let summary = HandoffSummary(events: events)

        // Stage everything and snapshot the patch BEFORE writing the
        // bundle — the bundle embeds the patch, so the patch must not
        // contain the bundle.
        try await git(["add", "-A"], cwd: workspace)
        let patch = (try? await git(["diff", "--cached"], cwd: workspace).stdout) ?? ""

        let metadata = SessionBundleMetadata(
            sessionId: sessionId,
            exportedAt: Date(),
            workspaceInitialized: !wasRepo,
            branch: branch
        )
        let bundle = SessionBundle(recipe: recipe, events: events, diff: patch, metadata: metadata)
        let bundleURL = workspace.appendingPathComponent(Self.bundleRelativePath)
        try FileManager.default.createDirectory(
            at: bundleURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bundle.write(to: bundleURL)

        // Commit all workspace changes (including the bundle, so the PR
        // carries it). Nothing-to-commit is fine on a re-push.
        try await git(["add", "-A"], cwd: workspace)
        let hasIdentity = ((try? await git(
            ["config", "user.email"], cwd: workspace
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "").isEmpty == false
        var commitArgs = ["commit", "-m", Self.commitMessage(sessionId: sessionId, summary: summary)]
        if !hasIdentity {
            // Fresh machines may have no git identity; attribute to Keg
            // rather than failing the handoff.
            commitArgs = [
                "-c", "user.name=Keg Agent",
                "-c", "user.email=keg-agent@users.noreply.github.com",
            ] + commitArgs
        }
        let commit = try await run("git", commitArgs, workspace, timeout)
        let commitOutput = commit.stdout + commit.stderr
        if commit.exitCode != 0, !commitOutput.contains("nothing to commit") {
            throw HandoffError.commandFailed(
                command: "git commit", output: commitOutput
            )
        }

        try await git(["checkout", "-B", branch], cwd: workspace)
        try await git(["push", "-u", "origin", branch], cwd: workspace)

        // Draft PR. gh owns auth (no tokens in Keg). Re-running against an
        // existing PR exits non-zero but prints the existing URL — treat
        // that as success so the flow is idempotent.
        let prArgs = [
            "pr", "create", "--draft",
            "--repo", "\(remote.owner)/\(remote.repo)",
            "--head", branch,
            "--title", Self.prTitle(sessionId: sessionId, summary: summary),
            "--body", Self.prBody(sessionId: sessionId, summary: summary, branch: branch),
        ]
        let pr = try await run("gh", prArgs, workspace, timeout)
        let prOutput = pr.stdout + "\n" + pr.stderr
        guard let url = Self.extractPullRequestURL(prOutput) else {
            if pr.exitCode != 0 {
                throw HandoffError.commandFailed(command: "gh pr create", output: prOutput)
            }
            throw HandoffError.prURLNotReturned(output: prOutput)
        }
        return HandoffResult(prURL: url, branch: branch, bundlePath: bundleURL.path)
    }

    /// One cheap process spawn, used by the UI for availability checks.
    func toolAvailable(_ name: String) async -> Bool {
        guard let result = try? await run(name, ["--version"], nil, timeout) else { return false }
        return result.exitCode == 0
    }

    // MARK: - Pure builders

    /// `keg/<slug>` — the branch every handoff push lands on.
    static func branchName(sessionId: String) -> String {
        "keg/" + AgentWorkspace.sessionSlug(sessionId)
    }

    static func commitMessage(sessionId: String, summary: HandoffSummary) -> String {
        var lines = [
            "keg: agent session \(sessionId)",
            "",
            "Session: \(sessionId)",
            "Events: \(summary.total) (\(summary.countsLine))",
        ]
        if let first = summary.firstUserInstruction {
            lines.append("First instruction: \(first)")
        }
        lines.append("")
        lines.append("Pushed for review by Keg.")
        return lines.joined(separator: "\n")
    }

    static func prTitle(sessionId: String, summary: HandoffSummary) -> String {
        if let first = summary.firstUserInstruction {
            let trimmed = first.replacingOccurrences(of: "\n", with: " ")
            let prefix = String(trimmed.prefix(60))
            return trimmed.count > 60 ? "keg: \(prefix)…" : "keg: \(prefix)"
        }
        return "keg: agent session \(sessionId)"
    }

    static func prBody(sessionId: String, summary: HandoffSummary, branch: String) -> String {
        var lines = [
            "## Agent session",
            "",
            "- Session: `\(sessionId)`",
            "- Events: \(summary.total) (\(summary.countsLine))",
        ]
        if let first = summary.firstUserInstruction {
            lines.append("- First instruction: \(first)")
        }
        lines.append("")
        lines.append("## Replay this session")
        lines.append("")
        lines.append("1. The `.kegsession` bundle (full event log + world recipe + workspace diff) is committed on this branch at `\(Self.bundleRelativePath)`.")
        lines.append("2. In Keg → Agents, import the bundle to replay the session against this branch.")
        lines.append("")
        lines.append("---")
        lines.append("Pushed for review by Keg.")
        return lines.joined(separator: "\n")
    }

    /// First `https://github.com/…/pull/<n>` URL in gh output, if any.
    static func extractPullRequestURL(_ output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https://github\.com/[^\s\"']+/pull/\d+"#) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range) else { return nil }
        return String(output[Range(match.range, in: output)!])
    }

    /// Side-effect-free prerequisite verdict for the UI's disabled state.
    static func readiness(
        hasRecipe: Bool,
        workspaceExists: Bool,
        recipeIsGitHub: Bool,
        workspaceIsRepo: Bool,
        ghAvailable: Bool
    ) -> (ready: Bool, reason: String?) {
        guard workspaceExists else {
            return (false, "The session's workspace no longer exists.")
        }
        guard hasRecipe else {
            return (false, "This session has no saved world recipe to hand off.")
        }
        guard recipeIsGitHub || workspaceIsRepo else {
            return (false, "The session isn't linked to a GitHub repo.")
        }
        guard ghAvailable else {
            return (false, "Install the GitHub CLI (gh) to push for review.")
        }
        return (true, nil)
    }

    // MARK: - Shell helpers

    private func requireTools() async throws {
        for tool in ["git", "gh"] {
            let result = try await run(tool, ["--version"], nil, timeout)
            guard result.exitCode == 0 else {
                throw HandoffError.toolUnavailable(tool)
            }
        }
    }

    /// Run git and treat a non-zero exit as a thrown failure.
    private func git(_ arguments: [String], cwd: URL) async throws -> ProcessResult {
        let result = try await run("git", arguments, cwd, timeout)
        guard result.exitCode == 0 else {
            throw HandoffError.commandFailed(
                command: "git \(arguments.joined(separator: " "))",
                output: result.stdout + result.stderr
            )
        }
        return result
    }

    private static let defaultRun: Run = { executable, arguments, directory, timeout in
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            if let directory {
                process.currentDirectoryURL = directory
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout.components.seconds) * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }
            process.terminationHandler = { process in
                timeoutTask.cancel()
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if process.terminationReason == .uncaughtSignal, process.terminationStatus != 0 {
                    // Distinguish our timeout kill from a real crash.
                    continuation.resume(throwing: HandoffError.timedOut(
                        command: "\(executable) \(arguments.joined(separator: " "))"
                    ))
                } else {
                    continuation.resume(returning: ProcessResult(
                        stdout: stdout, stderr: stderr, exitCode: process.terminationStatus
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                continuation.resume(throwing: HandoffError.toolUnavailable(executable))
            }
        }
    }
}
