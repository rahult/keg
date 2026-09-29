import Foundation

/// The brain behind an agent session: something that takes a prompt and a
/// workspace and emits session events. Cooper is the default brain;
/// harness adapters (pi via RPC mode, Claude Code, …) conform to the same
/// protocol, so the runner and the log don't care which is attached.
protocol AgentBrain: Sendable {
    /// Run one turn. Events arrive on the stream in order; the stream
    /// finishes when the brain has nothing more to say for this prompt.
    func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error>
}

/// Drives one agent session turn: materializes the workspace from the world
/// recipe, hands the prompt to a brain, and writes every emitted event to
/// the append-only session log (Tranche 0 invariant: the log is the source
/// of truth; transcripts are projections of it).
actor AgentRunner {
    enum RunnerError: Error, Equatable {
        case sessionNotFound(String)
    }

    private let store: SessionStore
    private let workspace: AgentWorkspace

    init(store: SessionStore, workspace: AgentWorkspace? = nil) {
        self.store = store
        self.workspace = workspace ?? AgentWorkspace()
    }

    /// Run one turn of `sessionId`. The session must already exist in the
    /// store; the recipe must validate. Events are appended as they arrive,
    /// so a crash mid-turn leaves a replayable prefix in the log.
    func run(
        sessionId: String,
        recipe: WorldRecipe,
        prompt: String,
        brain: any AgentBrain
    ) async throws {
        guard try await store.loadSession(id: sessionId) != nil else {
            throw RunnerError.sessionNotFound(sessionId)
        }

        // Validate + materialize before anything is written: a bad recipe
        // must not leave partial events behind.
        try recipe.validate()
        try await workspace.materialize(sessionId: sessionId, recipe: recipe)

        try await store.appendEvent(.userMessage(prompt), toSession: sessionId)

        let stream = brain.run(prompt: prompt, workspace: await workspace.workspacePath(sessionId: sessionId))
        for try await event in stream {
            try await store.appendEvent(event, toSession: sessionId)
        }
    }
}
