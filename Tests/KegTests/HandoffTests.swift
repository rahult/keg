import XCTest
@testable import Keg

/// Tranche 2 handoff tests: pure builders (remote parsing, summaries,
/// messages, URL extraction, readiness) plus the full push flow driven by
/// a scripted shell — git/gh never run for real here.
@MainActor
final class HandoffTests: XCTestCase {
    var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Scripted shell

    private struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var directory: String?
    }

    private struct ShellResult {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        static func ok(_ stdout: String = "") -> ShellResult {
            ShellResult(stdout: stdout, stderr: "", exitCode: 0)
        }
        static func fail(_ stderr: String, _ code: Int32) -> ShellResult {
            ShellResult(stdout: "", stderr: stderr, exitCode: code)
        }
    }

    /// Mutable fake-git state, escaped via @unchecked Sendable like the
    /// Recorder pattern in AgentServiceTests.
    private final class FakeGitState: @unchecked Sendable {
        var isRepo = false
        var origin: String? = nil
    }

    private final class ScriptedRunner: @unchecked Sendable {
        var calls: [Call] = []
        var handler: (Call) -> ShellResult
        init(handler: @escaping (Call) -> ShellResult) {
            self.handler = handler
        }
        func run(executable: String, arguments: [String], directory: URL?, timeout: Duration) async throws -> Handoff.ProcessResult {
            let call = Call(executable: executable, arguments: arguments, directory: directory?.path)
            calls.append(call)
            let result = handler(call)
            return Handoff.ProcessResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }
    }

    private func makeRecipe(url: String = "https://github.com/owner/repo.git") -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: url, branch: "main", commit: ""),
            kegYAML: "name: demo\nservices:\n  app:\n    image: nginx:alpine\n"
        )
    }

    private func makeEvents() -> [SessionEvent] {
        [
            .userMessage("fix the build"),
            SessionEvent(type: .assistantMessage, content: "on it"),
            SessionEvent(type: .toolUse, toolUse: ToolUseEvent(tool: "run", toolInput: [:], toolUseId: "t1")),
        ]
    }

    // MARK: - GitHubRemote parsing

    func testGitHubRemoteParsesCommonShapes() {
        XCTAssertEqual(GitHubRemote.parse("https://github.com/owner/repo.git"), GitHubRemote(owner: "owner", repo: "repo"))
        XCTAssertEqual(GitHubRemote.parse("https://github.com/owner/repo"), GitHubRemote(owner: "owner", repo: "repo"))
        XCTAssertEqual(GitHubRemote.parse("http://github.com/owner/repo"), GitHubRemote(owner: "owner", repo: "repo"))
        XCTAssertEqual(GitHubRemote.parse("git@github.com:owner/repo.git"), GitHubRemote(owner: "owner", repo: "repo"))
        XCTAssertEqual(GitHubRemote.parse("git@github.com:owner/repo"), GitHubRemote(owner: "owner", repo: "repo"))
        XCTAssertEqual(GitHubRemote.parse("ssh://git@github.com/owner/repo.git"), GitHubRemote(owner: "owner", repo: "repo"))
        XCTAssertEqual(GitHubRemote.parse("  https://github.com/owner/repo.git \n"), GitHubRemote(owner: "owner", repo: "repo"))
    }

    func testGitHubRemoteRejectsNonGitHubAndMalformed() {
        XCTAssertNil(GitHubRemote.parse("https://gitlab.com/owner/repo.git"))
        XCTAssertNil(GitHubRemote.parse("https://github.com/onlyowner"))
        XCTAssertNil(GitHubRemote.parse("https://github.com/owner/repo/extra"))
        XCTAssertNil(GitHubRemote.parse("https://github.com/"))
        XCTAssertNil(GitHubRemote.parse("github.com"))
        XCTAssertNil(GitHubRemote.parse(""))
        XCTAssertNil(GitHubRemote.parse("https://notgithub.com/owner/repo"))
    }

    // MARK: - Summary + message builders

    func testHandoffSummaryCountsAndFirstInstruction() {
        let summary = HandoffSummary(events: makeEvents())
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.counts[.userMessage], 1)
        XCTAssertEqual(summary.counts[.assistantMessage], 1)
        XCTAssertEqual(summary.counts[.toolUse], 1)
        XCTAssertEqual(summary.firstUserInstruction, "fix the build")
        XCTAssertEqual(summary.countsLine, "1 user, 1 assistant, 1 tool call")
    }

    func testHandoffSummaryEmptyLog() {
        let summary = HandoffSummary(events: [])
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.countsLine, "no events")
        XCTAssertNil(summary.firstUserInstruction)
    }

    func testCommitMessageReferencesSessionAndLog() {
        let message = Handoff.commitMessage(sessionId: "sess-1", summary: HandoffSummary(events: makeEvents()))
        XCTAssertTrue(message.contains("keg: agent session sess-1"))
        XCTAssertTrue(message.contains("Session: sess-1"))
        XCTAssertTrue(message.contains("Events: 3 (1 user, 1 assistant, 1 tool call)"))
        XCTAssertTrue(message.contains("First instruction: fix the build"))
    }

    func testPRTitlePrefersInstructionAndTruncates() {
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(Handoff.prTitle(sessionId: "s", summary: HandoffSummary(events: [.userMessage(long)])), "keg: \(String(repeating: "a", count: 60))…")
        XCTAssertEqual(Handoff.prTitle(sessionId: "s", summary: HandoffSummary(events: [])), "keg: agent session s")
    }

    func testPRBodyEmbedsReplayInstructions() {
        let body = Handoff.prBody(sessionId: "sess-9", summary: HandoffSummary(events: makeEvents()), branch: "keg/sess-9")
        XCTAssertTrue(body.contains("`sess-9`"))
        XCTAssertTrue(body.contains(".keg/session.kegsession"))
        XCTAssertTrue(body.contains("import the bundle"))
        XCTAssertTrue(body.contains("fix the build"))
    }

    func testExtractPullRequestURL() {
        XCTAssertEqual(
            Handoff.extractPullRequestURL("Creating pull request\nhttps://github.com/owner/repo/pull/42\n"),
            "https://github.com/owner/repo/pull/42"
        )
        XCTAssertEqual(
            Handoff.extractPullRequestURL("a pull request for branch already exists:\nhttps://github.com/owner/repo/pull/7\n"),
            "https://github.com/owner/repo/pull/7"
        )
        XCTAssertNil(Handoff.extractPullRequestURL("no url here"))
    }

    func testBranchNameUsesSessionSlug() {
        XCTAssertEqual(Handoff.branchName(sessionId: "Sess 42!"), "keg/sess-42")
        XCTAssertEqual(Handoff.branchName(sessionId: "session-abc123"), "keg/session-abc123")
    }

    func testReadinessCombinations() {
        func verdict(_ gh: Bool, _ recipe: Bool, _ repo: Bool) -> Bool {
            Handoff.readiness(hasRecipe: true, workspaceExists: true, recipeIsGitHub: recipe, workspaceIsRepo: repo, ghAvailable: gh).ready
        }
        XCTAssertFalse(verdict(false, true, false))
        XCTAssertFalse(verdict(true, false, false))
        XCTAssertTrue(verdict(true, true, false))
        XCTAssertTrue(verdict(true, false, true))
        let missing = Handoff.readiness(hasRecipe: true, workspaceExists: false, recipeIsGitHub: true, workspaceIsRepo: false, ghAvailable: true)
        XCTAssertFalse(missing.ready)
        XCTAssertNotNil(missing.reason)
        let noRecipe = Handoff.readiness(hasRecipe: false, workspaceExists: true, recipeIsGitHub: true, workspaceIsRepo: true, ghAvailable: true)
        XCTAssertEqual(noRecipe.reason, "This session has no saved world recipe to hand off.")
    }

    // MARK: - Full flow with scripted shell

    func testPushForReviewInitializesRepoAndPushesBundle() async throws {
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "code".write(to: workspace.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let state = FakeGitState()
        let runner = ScriptedRunner { call in
            switch (call.executable, call.arguments.first) {
            case ("git", "rev-parse"):
                return state.isRepo ? .ok("true\n") : .fail("fatal: not a git repository", 128)
            case ("git", "init"):
                state.isRepo = true
                return .ok("Initialized empty Git repository")
            case ("git", "remote"):
                if call.arguments.count >= 3, call.arguments[1] == "get-url" {
                    if let origin = state.origin { return .ok(origin + "\n") }
                    return .fail("error: No such remote 'origin'", 2)
                }
                state.origin = call.arguments.last  // remote add origin <url>
                return .ok("")
            case ("git", "diff"):
                return .ok("diff --git a/main.swift b/main.swift\n+code\n")
            case ("git", "config"):
                return .fail("", 1) // no git identity configured
            case ("gh", .some):
                return .ok("https://github.com/owner/repo/pull/42\n")
            default:
                return .ok("")
            }
        }

        let handoff = Handoff(run: runner.run)
        let result = try await handoff.pushForReview(
            workspace: workspace,
            sessionId: "Sess 1",
            recipe: makeRecipe(),
            events: makeEvents()
        )

        XCTAssertEqual(result.prURL, "https://github.com/owner/repo/pull/42")
        XCTAssertEqual(result.branch, "keg/sess-1")

        // The bundle rode the branch: it exists in the workspace and
        // carries the diff + metadata.
        let bundleURL = workspace.appendingPathComponent(".keg/session.kegsession")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        let bundle = try await SessionBundle.import(from: bundleURL)
        XCTAssertEqual(bundle.diff, "diff --git a/main.swift b/main.swift\n+code\n")
        XCTAssertEqual(bundle.metadata?.workspaceInitialized, true)
        XCTAssertEqual(bundle.metadata?.branch, "keg/sess-1")
        XCTAssertEqual(bundle.metadata?.sessionId, "Sess 1")
        XCTAssertEqual(bundle.recipe, makeRecipe())
        XCTAssertEqual(bundle.events.map(\.type), [.userMessage, .assistantMessage, .toolUse])

        // Command sequence: init → remote add → identity-fallback commit →
        // branch → push → draft PR against the parsed repo.
        let flat = runner.calls.map { "\($0.executable) \($0.arguments.joined(separator: " "))" }
        XCTAssertTrue(flat.contains("git init -b main"), "workspace should be initialized: \(flat)")
        XCTAssertTrue(flat.contains("git remote add origin https://github.com/owner/repo.git"))
        XCTAssertTrue(flat.contains { $0.hasPrefix("git -c user.name=Keg Agent -c user.email=keg-agent@users.noreply.github.com commit") },
                      "missing identity fallback: \(flat)")
        XCTAssertTrue(flat.contains("git checkout -B keg/sess-1"))
        XCTAssertTrue(flat.contains("git push -u origin keg/sess-1"))
        guard let prCall = flat.first(where: { $0.hasPrefix("gh pr create") }) else {
            return XCTFail("gh pr create not called: \(flat)")
        }
        XCTAssertTrue(prCall.contains("--draft"))
        XCTAssertTrue(prCall.contains("--repo owner/repo"))
        XCTAssertTrue(prCall.contains("--head keg/sess-1"))
    }

    func testPushForReviewExistingRepoUsesOrigin() async throws {
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let state = FakeGitState()
        state.isRepo = true
        state.origin = "git@github.com:me/project.git"
        let runner = ScriptedRunner { call in
            switch (call.executable, call.arguments.first) {
            case ("git", "rev-parse"):
                return .ok("true\n")
            case ("git", "remote"):
                if call.arguments.count >= 3, call.arguments[1] == "get-url" {
                    return .ok((state.origin ?? "") + "\n")
                }
                return .fail("unexpected remote mutation", 1)
            case ("git", "diff"):
                return .ok("")
            case ("git", "config"):
                return .ok("dev@example.com\n") // identity configured
            case ("gh", .some):
                return .ok("https://github.com/me/project/pull/3\n")
            default:
                return .ok("")
            }
        }

        // Recipe points at a local folder; the workspace origin wins.
        let handoff = Handoff(run: runner.run)
        let result = try await handoff.pushForReview(
            workspace: workspace,
            sessionId: "sess-2",
            recipe: makeRecipe(url: "/Users/me/Code/local-project"),
            events: [.userMessage("hi")]
        )

        XCTAssertEqual(result.prURL, "https://github.com/me/project/pull/3")
        let bundle = try await SessionBundle.import(from: workspace.appendingPathComponent(".keg/session.kegsession"))
        XCTAssertEqual(bundle.metadata?.workspaceInitialized, false)

        let flat = runner.calls.map { "\($0.executable) \($0.arguments.joined(separator: " "))" }
        XCTAssertFalse(flat.contains("git init -b main"))
        XCTAssertFalse(flat.contains { $0.hasPrefix("git remote add") }, "existing origin must not be overwritten")
        XCTAssertTrue(flat.contains { $0.hasPrefix("git commit") && !$0.hasPrefix("git -c") },
                      "configured identity should be used as-is: \(flat)")
    }

    func testPushForReviewRejectsNonGitHubRemote() async throws {
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let state = FakeGitState()
        state.isRepo = true
        state.origin = "https://gitlab.com/owner/repo.git"
        let runner = ScriptedRunner { call in
            switch (call.executable, call.arguments.first) {
            case ("git", "rev-parse"): return .ok("true\n")
            case ("git", "remote"): return .ok((state.origin ?? "") + "\n")
            default: return .ok("")
            }
        }

        let handoff = Handoff(run: runner.run)
        do {
            _ = try await handoff.pushForReview(
                workspace: workspace, sessionId: "s", recipe: makeRecipe(), events: []
            )
            XCTFail("expected notGitHubRemote")
        } catch Handoff.HandoffError.notGitHubRemote(let url) {
            XCTAssertEqual(url, "https://gitlab.com/owner/repo.git")
        }
    }

    func testPushForReviewTreatsExistingPRAsSuccess() async throws {
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let runner = ScriptedRunner { call in
            switch (call.executable, call.arguments.first) {
            case ("gh", "pr"):
                return ShellResult(
                    stdout: "",
                    stderr: "a pull request for branch \"keg/sess-3\" already exists:\nhttps://github.com/owner/repo/pull/9\n",
                    exitCode: 1
                )
            default:
                return .ok("")
            }
        }

        let handoff = Handoff(run: runner.run)
        let result = try await handoff.pushForReview(
            workspace: workspace, sessionId: "sess-3", recipe: makeRecipe(), events: []
        )
        XCTAssertEqual(result.prURL, "https://github.com/owner/repo/pull/9")
    }

    // MARK: - Recipe sidecar + bundle shape

    func testStoreRecipeRoundTrip() async throws {
        let store = try SessionStore(sessionsDirectory: directory.appendingPathComponent("sessions"))
        let session = Session(
            id: "recipe-sess", type: "agent", agentId: "a", agentVersion: 1,
            environmentId: "e", status: .running, createdAt: Date(), updatedAt: Date()
        )
        try await store.saveSession(session)
        let missing = try await store.loadRecipe(forSession: "recipe-sess")
        XCTAssertNil(missing)

        let recipe = makeRecipe(url: "git@github.com:me/proj.git")
        try await store.saveRecipe(recipe, forSession: "recipe-sess")
        let loaded = try await store.loadRecipe(forSession: "recipe-sess")
        XCTAssertEqual(loaded, recipe)
    }

    func testBundleWithDiffAndMetadataRoundTrips() async throws {
        let bundle = SessionBundle(
            recipe: makeRecipe(),
            events: makeEvents(),
            diff: "diff --git a/x b/x\n",
            metadata: SessionBundleMetadata(
                sessionId: "s1",
                exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                workspaceInitialized: true,
                branch: "keg/s1"
            )
        )
        let url = directory.appendingPathComponent("bundle.kegsession")
        try bundle.write(to: url)

        let imported = try await SessionBundle.import(from: url)
        XCTAssertEqual(imported.recipe, bundle.recipe)
        XCTAssertEqual(imported.events.map(\.type), bundle.events.map(\.type))
        XCTAssertEqual(imported.events.map(\.content), bundle.events.map(\.content))
        XCTAssertEqual(imported.diff, bundle.diff)
        XCTAssertEqual(imported.metadata, bundle.metadata)
    }

    func testBundleDecodesPreTranche2Payloads() async throws {
        // Bundles written before diff/metadata existed must still import.
        let json = """
        {
          "recipe": {
            "repo": {"url": "https://github.com/owner/repo.git", "branch": "main", "commit": ""},
            "kegYAML": "name: demo\\nservices:\\n  app:\\n    image: nginx:alpine\\n",
            "env": {},
            "databases": []
          },
          "events": [
            {"type": "user", "content": "hi", "toolUse": null, "toolResult": null, "status": null, "id": null, "timestamp": null}
          ]
        }
        """
        let url = directory.appendingPathComponent("legacy.kegsession")
        try json.write(to: url, atomically: true, encoding: .utf8)

        let bundle = try await SessionBundle.import(from: url)
        XCTAssertEqual(bundle.events.map(\.content), ["hi"])
        XCTAssertNil(bundle.diff)
        XCTAssertNil(bundle.metadata)
    }
}
