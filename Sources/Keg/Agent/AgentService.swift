import Foundation

/// Production assembly for the local agent runtime: owns session lifecycle,
/// environment provisioning, and turn execution against the append-only
/// log. Brains are created per turn through `makeBrain` so the service
/// stays testable and the brain choice can vary per session.
actor AgentService {
    enum BrainKind: String, Sendable, CaseIterable {
        case cooper   // default: remote backend + permission-gated tool set
        case pi       // pi via RPC mode
    }

    enum ServiceError: Error, Equatable {
        case sessionNotFound(String)
        case invalidStatusTransition(from: SessionStatus, to: SessionStatus)
    }

    private let store: SessionStore
    private let workspace: AgentWorkspace
    private let provisioner: AgentEnvironmentProvisioner
    private let makeBrain: @Sendable (BrainKind) -> any AgentBrain
    private var activeSessions: [String: Session] = [:]

    init(
        store: SessionStore? = nil,
        workspace: AgentWorkspace? = nil,
        provisioner: AgentEnvironmentProvisioner? = nil,
        makeBrain: @escaping @Sendable (BrainKind) -> any AgentBrain
    ) {
        self.store = store ?? (try? SessionStore()) ?? SessionStore.fallbackInMemory
        self.workspace = workspace ?? AgentWorkspace()
        self.provisioner = provisioner ?? AgentEnvironmentProvisioner()
        self.makeBrain = makeBrain
    }

    // MARK: - Sessions

    func createSession(id: String, agentId: String, environmentId: String, type: String = "agent") async throws -> Session {
        let now = Date()
        let session = Session(
            id: id, type: type, agentId: agentId, agentVersion: 1,
            environmentId: environmentId, status: .pending,
            createdAt: now, updatedAt: now
        )
        activeSessions[id] = session
        try await store.saveSession(session)
        return session
    }

    func getSession(id: String) async -> Session? {
        activeSessions[id]
    }

    // MARK: - Turns

    /// Provision the session's world and run one turn, recording every
    /// event to the log. Status: pending → running → completed/failed.
    func runTurn(
        sessionId: String,
        recipe: WorldRecipe,
        prompt: String,
        brain: BrainKind
    ) async throws {
        guard activeSessions[sessionId] != nil else {
            throw ServiceError.sessionNotFound(sessionId)
        }

        try await transition(sessionId: sessionId, to: .running)
        do {
            _ = try await provisioner.provision(sessionId: sessionId, recipe: recipe)
            let runner = AgentRunner(store: store, workspace: workspace)
            try await runner.run(sessionId: sessionId, recipe: recipe, prompt: prompt, brain: makeBrain(brain))
            try await transition(sessionId: sessionId, to: .completed)
        } catch {
            try? await transition(sessionId: sessionId, to: .failed)
            throw error
        }
    }

    // MARK: - Status transitions (same rules as SessionManager)

    private func transition(sessionId: String, to newStatus: SessionStatus) async throws {
        guard var session = activeSessions[sessionId] else {
            throw ServiceError.sessionNotFound(sessionId)
        }
        guard isValidTransition(from: session.status, to: newStatus) else {
            throw ServiceError.invalidStatusTransition(from: session.status, to: newStatus)
        }
        session.status = newStatus
        session = Session(
            id: session.id, type: session.type, agentId: session.agentId,
            agentVersion: session.agentVersion, environmentId: session.environmentId,
            status: newStatus, createdAt: session.createdAt, updatedAt: Date(),
            isFlagged: session.isFlagged
        )
        activeSessions[sessionId] = session
        try await store.saveSession(session)
    }

    private func isValidTransition(from: SessionStatus, to: SessionStatus) -> Bool {
        switch (from, to) {
        case (.pending, .running), (.pending, .cancelled),
             (.running, .completed), (.running, .failed), (.running, .cancelled):
            return true
        default:
            return false
        }
    }
}

extension SessionStore {
    /// `AgentService` init must not fail when the Application Support
    /// directory is unavailable; a temp store beats a crash.
    static let fallbackInMemory: SessionStore = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keg-agent-service-fallback-\(UUID().uuidString)")
        return try! SessionStore(sessionsDirectory: dir)
    }()
}

extension AgentService {
    /// Composition root: the gateway-bound Cooper brain (remote backend +
    /// permission-gated tools, approval-carded mutations) and pi as the
    /// harness alternative. `appState` nil gives a gateway without UI
    /// approvals — everything approval-worthy is refused, so headless use
    /// stays read-only. Pass `approvalHandler` to surface approval cards
    /// (the controller installs the same shape for its own gateway).
    static func production(
        appState: AppState?,
        gateway sharedGateway: CooperGateway? = nil,
        approvalHandler: (@Sendable (CooperApprovalRequest) async -> Bool)? = nil
    ) -> AgentService {
        let gateway = sharedGateway ?? CooperGateway(appState: appState, approvalHandler: approvalHandler)
        return AgentService { kind in
            switch kind {
            case .pi:
                return PiBrain()
            case .cooper:
                return CooperBrain(
                    config: CooperRemoteConfigStore.loadConfig(),
                    apiKey: CooperKeychain.loadAPIKey(),
                    tools: CooperRemoteTools.allTools(gateway: gateway, mode: .ask)
                )
            }
        }
    }
}
