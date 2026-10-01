import XCTest
@testable import Keg
import KegCLICore

/// Live-projection tests for the Tranche 1 deferred polish: the session
/// store's update stream, the service passthroughs, the detail view's
/// streaming consumer, and the New Session draft's validation.
@MainActor
final class AgentSessionUpdatesTests: XCTestCase {
    var baseDirectory: URL!
    var store: SessionStore!

    override func setUp() async throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-agent-updates-tests-\(UUID().uuidString)", isDirectory: true)
        store = try SessionStore(sessionsDirectory: baseDirectory.appendingPathComponent("sessions"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    // MARK: - Helpers

    private struct FakeBrain: AgentBrain {
        let events: [SessionEvent]
        func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private func makeService(brainEvents: [SessionEvent] = [
        SessionEvent(type: .assistantMessage, content: "done"),
    ]) -> AgentService {
        AgentService(
            store: store,
            workspace: AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces")),
            provisioner: AgentEnvironmentProvisioner(
                workspace: AgentWorkspace(baseDirectory: baseDirectory.appendingPathComponent("workspaces")),
                up: { _, _ in ["kegagent-x-app-1"] },
                down: { _, _ in }
            ),
            makeBrain: { _ in FakeBrain(events: brainEvents) }
        )
    }

    private func makeRecipe() -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: "/tmp/keg-test-repo", branch: "main", commit: "abc123"),
            kegYAML: "name: demo\nservices:\n  app:\n    image: nginx:alpine\n"
        )
    }

    private func makeSession(id: String = "updates-sess-1") -> Session {
        let now = Date()
        return Session(
            id: id, type: "agent", agentId: "agent-1", agentVersion: 1,
            environmentId: "env-1", status: .pending, createdAt: now, updatedAt: now
        )
    }

    private func waitFor(
        _ condition: @escaping @MainActor () -> Bool,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private final class UpdateBox: @unchecked Sendable {
        var updates: [SessionLogUpdate] = []
    }

    // MARK: - SessionStore updates

    func testStorePublishesAppendsAndSaves() async throws {
        let box = UpdateBox()
        let stream = await store.updates()
        // Registration is async on the store actor; give it a turn.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let consumer = Task {
            for await update in stream {
                box.updates.append(update)
            }
        }
        defer { consumer.cancel() }

        let session = makeSession()
        try await store.saveSession(session)
        try await store.appendEvent(.userMessage("hi"), toSession: session.id)

        let sawEnough = await waitFor { box.updates.count >= 2 }
        XCTAssertTrue(sawEnough)

        var sawSave = false
        var sawEvent = false
        for update in box.updates {
            switch update {
            case .sessionSaved(let saved) where saved.id == session.id:
                sawSave = true
            case .event(let sessionId, let event) where sessionId == session.id:
                sawEvent = true
                XCTAssertEqual(event.type, .userMessage)
                XCTAssertEqual(event.content, "hi")
            default:
                break
            }
        }
        XCTAssertTrue(sawSave)
        XCTAssertTrue(sawEvent)
    }

    func testStoreUpdateStreamFiltersBySessionOnConsumeSide() async throws {
        let box = UpdateBox()
        let stream = await store.updates()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let consumer = Task {
            for await update in stream {
                if case .event(let sessionId, _) = update, sessionId == "wanted" {
                    box.updates.append(update)
                }
            }
        }
        defer { consumer.cancel() }

        try await store.appendEvent(.userMessage("other"), toSession: "other")
        try await store.appendEvent(.userMessage("mine"), toSession: "wanted")

        let matched = await waitFor { box.updates.count == 1 }
        XCTAssertTrue(matched)
    }

    // MARK: - AgentService passthroughs

    func testServiceUpdatesStreamCoversATurn() async throws {
        let service = makeService()
        let box = UpdateBox()
        let stream = await service.updates()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let consumer = Task {
            for await update in stream {
                box.updates.append(update)
            }
        }
        defer { consumer.cancel() }

        try await service.createSession(id: "svc-turn", agentId: "a", environmentId: "e")
        try await service.runTurn(sessionId: "svc-turn", recipe: makeRecipe(), prompt: "go", brain: .pi)

        // One create + two transitions (running, completed) and two runner events.
        let drained = await waitFor { box.updates.count >= 5 }
        XCTAssertTrue(drained)

        let eventTypes = box.updates.compactMap { update -> SessionEventType? in
            if case .event(_, let event) = update { return event.type }
            return nil
        }
        XCTAssertEqual(eventTypes, [.userMessage, .assistantMessage])

        let statuses = box.updates.compactMap { update -> SessionStatus? in
            if case .sessionSaved(let saved) = update { return saved.status }
            return nil
        }
        XCTAssertEqual(statuses, [.pending, .running, .completed])
    }

    func testServiceLoadEventsReadsThroughSameStore() async throws {
        let service = makeService()
        try await service.createSession(id: "svc-load", agentId: "a", environmentId: "e")

        let empty = try await service.loadEvents(forSession: "svc-load")
        XCTAssertTrue(empty.isEmpty)

        try await store.appendEvent(.userMessage("pre-existing"), toSession: "svc-load")
        let events = try await service.loadEvents(forSession: "svc-load")
        XCTAssertEqual(events.map(\.type), [.userMessage])
    }

    // MARK: - SessionDetailVM streaming

    func testDetailVMStreamsEventsAndEndsOnTerminalStatus() async throws {
        let service = makeService()
        let session = try await service.createSession(id: "vm-stream", agentId: "a", environmentId: "e")

        let vm = SessionDetailVM(session: session)
        await vm.loadLocalEvents(store: store)
        await vm.startLiveUpdates(service: service)

        Task { [service] in
            try? await service.runTurn(sessionId: "vm-stream", recipe: self.makeRecipe(), prompt: "go", brain: .pi)
        }

        let eventsArrived = await waitFor { vm.events.count == 2 }
        XCTAssertTrue(eventsArrived, "streamed events should arrive")
        XCTAssertEqual(vm.events.map(\.type), [.userMessage, .assistantMessage])

        let streamEnded = await waitFor { !vm.isStreaming }
        XCTAssertTrue(streamEnded, "stream should end on terminal status")
        XCTAssertEqual(vm.sessionStatus, .completed)
        XCTAssertEqual(vm.events.count, 2, "no duplicates after the turn settles")
    }

    func testDetailVMSkipsEventsAlreadyPresentFromBaselineLoad() async throws {
        let service = makeService()
        let session = try await service.createSession(id: "vm-baseline", agentId: "a", environmentId: "e")
        try await store.appendEvent(.userMessage("early"), toSession: session.id)

        let vm = SessionDetailVM(session: session)
        await vm.loadLocalEvents(store: store)
        XCTAssertEqual(vm.events.count, 1)

        await vm.startLiveUpdates(service: service)
        Task { [service] in
            try? await service.runTurn(sessionId: "vm-baseline", recipe: self.makeRecipe(), prompt: "go", brain: .pi)
        }

        // The pre-existing event must not be duplicated by the stream.
        let streamEnded = await waitFor { !vm.isStreaming }
        XCTAssertTrue(streamEnded)
        XCTAssertEqual(vm.events.map(\.content), ["early", "go", "done"])
    }

    func testDetailVMDoesNotStreamTerminalSessions() async throws {
        let service = makeService()
        let done = Session(
            id: "vm-done", type: "agent", agentId: "a", agentVersion: 1,
            environmentId: "e", status: .completed, createdAt: Date(), updatedAt: Date()
        )
        let vm = SessionDetailVM(session: done)
        await vm.startLiveUpdates(service: service)
        XCTAssertFalse(vm.isStreaming)
    }

    // MARK: - New session draft

    func testDraftEnvKeyValidation() {
        XCTAssertNil(AgentSessionDraft.envKeyProblem("NODE_ENV"))
        XCTAssertNil(AgentSessionDraft.envKeyProblem("")) // empty rows ignored
        XCTAssertNotNil(AgentSessionDraft.envKeyProblem("1BAD"))
        XCTAssertNotNil(AgentSessionDraft.envKeyProblem("API_TOKEN"))
        XCTAssertNotNil(AgentSessionDraft.envKeyProblem("DB_PASSWORD"))
    }

    func testDraftMakeRecipeRejectsSecretEnv() throws {
        let folder = baseDirectory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var draft = AgentSessionDraft()
        draft.localPath = folder.path
        draft.env = [AgentSessionEnvEntry(key: "API_TOKEN", value: "x")]

        var caught: Error?
        do {
            _ = try draft.makeRecipe()
        } catch {
            caught = error
        }
        guard case AgentSessionDraft.DraftError.envKey(let key, _)? = caught else {
            return XCTFail("expected envKey error, got \(String(describing: caught))")
        }
        XCTAssertEqual(key, "API_TOKEN")
    }

    func testDraftMakeRecipeRejectsMissingLocalFolder() {
        var draft = AgentSessionDraft()
        draft.localPath = baseDirectory.appendingPathComponent("nope").path

        var caught: Error?
        do {
            _ = try draft.makeRecipe()
        } catch {
            caught = error
        }
        guard case AgentSessionDraft.DraftError.folderMissing? = caught else {
            return XCTFail("expected folderMissing error, got \(String(describing: caught))")
        }
    }

    func testDraftMakeRecipeBuildsValidatedWorldRecipe() throws {
        let folder = baseDirectory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var draft = AgentSessionDraft()
        draft.localPath = folder.path
        draft.env = [AgentSessionEnvEntry(key: "NODE_ENV", value: "production")]
        draft.kegYAML = "name: demo\nservices:\n  app:\n    image: nginx:alpine\n"

        let recipe = try draft.makeRecipe()
        XCTAssertEqual(recipe.repo.url, folder.path)
        XCTAssertEqual(recipe.env, ["NODE_ENV": "production"])
        do {
            try recipe.validate()
        } catch {
            XCTFail("recipe should re-validate: \(error)")
        }
    }

    func testDraftMakePromptDefaultsWhenInstructionEmpty() {
        var draft = AgentSessionDraft()
        draft.instruction = "  "
        XCTAssertEqual(draft.makePrompt(), AgentSessionDraft.defaultPrompt)
        draft.instruction = " fix the build "
        XCTAssertEqual(draft.makePrompt(), "fix the build")
    }

    func testDraftProjectNameFromRepoURL() {
        XCTAssertEqual(AgentSessionDraft.projectName(for: "/Users/me/Code/projects/keg"), "keg")
        XCTAssertEqual(AgentSessionDraft.projectName(for: "https://github.com/owner/demo.git"), "demo")
        XCTAssertEqual(AgentSessionDraft.projectName(for: ""), "keg-project")
    }

    func testStrippingPortsRemovesBlockAndInlineMappings() {
        let block = """
        services:
          app:
            image: alpine:3.20
            ports:
              - "8080:8080"               # host:container
            restart: unless-stopped
        """
        let strippedBlock = AgentSessionDraft.strippingPorts(from: block)
        XCTAssertFalse(strippedBlock.contains("ports"))
        XCTAssertFalse(strippedBlock.contains("8080"))
        XCTAssertTrue(strippedBlock.contains("restart: unless-stopped"))

        let inline = """
        services:
          app:
            image: nginx:alpine
            ports: ["80:80"]
            command: ["nginx", "-g", "daemon off;"]
        """
        let strippedInline = AgentSessionDraft.strippingPorts(from: inline)
        XCTAssertFalse(strippedInline.contains("ports"))
        XCTAssertTrue(strippedInline.contains("command:"))
    }

    func testScaffoldedYAMLOmitsPortsForEveryStack() {
        for stack in KegProjectScaffold.Stack.allCases {
            let yaml = AgentSessionDraft().scaffoldedYAML(stack)
            let activePortLines = yaml.split(separator: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("ports:")
            }
            XCTAssertTrue(activePortLines.isEmpty, "\(stack) scaffold should not publish ports")
        }
    }
}
