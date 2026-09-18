import AppKit
import Foundation
import ContainerAPIClient
import ContainerResource

enum SystemStatus: Sendable {
    case running(SystemHealth)
    case stopped
    /// Services are alive but not answering within bounds — distinct from
    /// `.stopped` so the UI can offer diagnostics instead of just Start.
    case unresponsive
    case error(String)
}

@Observable
@MainActor
final class AppState {
    private static let agentPermissionModeDefaultsKey = "agents.permission-mode"
    private static let dockerAPIAutoStartDefaultsKey = "dockerAPI.autoStart"
    private static let experienceLevelDefaultsKey = "keg.experience-level"

    // Docker API server
    private var dockerServerTask: Task<Void, Never>?
    private var dockerServer: DockerAPIServer?
    var isDockerAPIRunning = false
    var dockerSocketPath: String {
        dockerServer?.resolvedSocketPath ?? DockerAPIServer.socketPath()
    }
    var dockerAPIAutoStart: Bool {
        didSet {
            UserDefaults.standard.set(dockerAPIAutoStart, forKey: Self.dockerAPIAutoStartDefaultsKey)
        }
    }
    var systemStatus: SystemStatus = .stopped {
        didSet {
            // Auto-start Docker API when system becomes running and auto-start is enabled
            if case .running = systemStatus, dockerAPIAutoStart, !isDockerAPIRunning {
                startDockerAPI()
            }
        }
    }

    /// Weak handle on the app's single main window, captured by the SwiftUI
    /// scene so the dock-click reopen path can re-order it front after the
    /// user closes it (a `Window` scene never recreates its window).
    weak var mainWindow: NSWindow?

    // Area navigation
    var currentArea: AppArea = .keg
    var selectedKegSection: KegSection = .containers
    var selectedAgentSection: AgentSection = .dashboard
    var agentPermissionMode: AgentPermissionMode {
        didSet {
            UserDefaults.standard.set(agentPermissionMode.rawValue, forKey: Self.agentPermissionModeDefaultsKey)
        }
    }

    /// How much of the UI to show. Defaults to Getting Started so first-run
    /// users land in the simplest possible surface; experts can opt into
    /// Full Control from the welcome sheet or Settings.
    var experienceLevel: ExperienceLevel {
        didSet {
            UserDefaults.standard.set(experienceLevel.rawValue, forKey: Self.experienceLevelDefaultsKey)
            // Never leave the user parked on a section the new level hides.
            if !experienceLevel.showsAdvancedSections,
               Self.advancedKegSections.contains(selectedKegSection) {
                selectedKegSection = .containers
            }
        }
    }

    var selectedContainerID: String?
    var selectedImageReference: String?
    /// Quick-start image waiting for the Containers screen to appear; consumed
    /// on appear so a fast section switch can't drop the welcome sheet's
    /// "Try a demo" action.
    var pendingRunImage: String?
    var selectedAgentID: String?
    var selectedSessionID: String?
    var agentServiceReachability: AgentServiceReachability = .unknown
    var agentAutomationState = AgentAutomationState()
    var agentApprovalItems: [AgentApprovalItem] = []
    var isRefreshing = false
    var isRefreshingAgentAutomation = false
    var runningContainerCount = 0
    var unhealthyContainerCount = 0
    var activeAgentCount = 0
    var activeSessionCount = 0

    private let containerClient = ContainerClient()
    private let agentAutomationService = AgentAutomationService()
    private var refreshTimer: Timer?

    init() {
        // Ship with Docker API auto-start on by default. First-run users should get
        // a working `docker` CLI without hunting through Settings. Existing users who
        // explicitly set the key keep their choice.
        UserDefaults.standard.register(defaults: [
            Self.dockerAPIAutoStartDefaultsKey: true
        ])

        self.agentPermissionMode = Self.loadAgentPermissionMode()
        self.dockerAPIAutoStart = UserDefaults.standard.bool(forKey: Self.dockerAPIAutoStartDefaultsKey)
        self.experienceLevel = Self.loadExperienceLevel()

        // A stale socket file from a previous Keg run makes `docker info` return EOF
        // because the kernel accepts the connect() and then immediately closes it.
        // Remove it eagerly so clients get ECONNREFUSED (which they retry cleanly)
        // until the real server binds. The removal is liveness-guarded: AppState
        // is also instantiated by unit tests, and unlinking a socket owned by a
        // *running* Keg app would silently kill its Docker API.
        let socketPath = DockerAPIServer.socketPath()
        if !DockerAPIServer.socketRespondsToPing(at: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        // DISABLED (launch-stall + repeated keychain prompts): the eager
        // keychain migration/read below runs on the main actor and its
        // synchronous SecItemCopyMatching blocks the main thread — including
        // window creation — until the user answers the keychain prompt.
        // Re-signing between builds changes the cdhash, so "Always Allow"
        // never sticks and the prompt returns every launch. Re-enable once
        // the agents feature needs launch-time auth state again.
    }

    /// Handles `keg://<section>` deep links from the companion CLI's
    /// `keg open` command: focuses the main area on the named section.
    /// Section names are case-insensitive; unknown names land on Containers.
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "keg" else { return }
        let section = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        currentArea = .keg
        let match = KegSection.allCases.first { $0.rawValue.lowercased() == section.lowercased() }
        selectedKegSection = match ?? .containers
    }

    /// Bring the container backend and Docker API up without user intervention.
    /// Called from the main window on launch.
    func ensureReady() async {
        await checkSystemStatus()
        if case .stopped = systemStatus {
            await startSystem()
        }
        // systemStatus.didSet starts the Docker API when autoStart is on.
        // Belt-and-braces: start it explicitly if the system is running but the
        // auto-start path somehow missed (e.g. status was already .running before
        // didSet wiring).
        if isSystemRunning, dockerAPIAutoStart, !isDockerAPIRunning {
            startDockerAPI()
        }
    }

    var isSystemRunning: Bool {
        if case .running = systemStatus { return true }
        return false
    }

    /// The runtime's services are alive but ignoring us — drives the
    /// diagnostics banner and the slowed refresh cadence.
    var isRuntimeUnresponsive: Bool {
        if case .unresponsive = systemStatus { return true }
        return false
    }

    /// The app-root the running apiserver reports, when one answered recently.
    var lastKnownRuntimeAppRoot: String?

    /// Effective data location for display: prefers the appRoot reported by
    /// the live runtime (ground truth), falling back to the configured
    /// override, then the default.
    var effectiveDataRootDescription: String {
        if let lastKnownRuntimeAppRoot {
            return lastKnownRuntimeAppRoot
        }
        return ContainerCLI.configuredAppRoot ?? "~/.container (default)"
    }


    // DISABLED: reading keychain state at launch triggers repeated prompts
    // (see note in init). Treat the agents feature as signed out until the
    // user connects explicitly from Settings.
    var isAgentAuthenticated = false

    /// Lazy-initialized Agent API client
    var agentClient: ManagedAgentsClient? {
        get async {
            guard isAgentAuthenticated else { return nil }
            return try? await ManagedAgentsClient.fromKeychain()
        }
    }

    func refreshAgentAuthentication() {
        // DISABLED alongside isAgentAuthentication (see init note): keychain
        // reads at launch cause blocking prompts. Keep call sites compiling.
        isAgentAuthenticated = false
    }

    var pendingAgentApprovals: [AgentApprovalItem] {
        agentApprovalItems.filter { $0.status == .pending }
    }

    func refreshAgentAutomation() async {
        guard !isRefreshingAgentAutomation else { return }
        isRefreshingAgentAutomation = true
        defer { isRefreshingAgentAutomation = false }
        agentAutomationState = await agentAutomationService.captureState()
    }

    func requestAgentNotificationAccess() async {
        agentAutomationState.notificationStatus = await agentAutomationService.requestNotificationAuthorization()
    }

    func queueApprovalPreview(for useCase: AgentUseCase) async {
        let item = AgentApprovalItem.preview(for: useCase, context: agentAutomationState.context)
        agentApprovalItems.insert(item, at: 0)
        await agentAutomationService.scheduleNotification(for: item)
    }

    func approveAgentApproval(_ id: UUID) {
        guard let index = agentApprovalItems.firstIndex(where: { $0.id == id }) else { return }
        agentApprovalItems[index].status = .approved
    }

    func rejectAgentApproval(_ id: UUID) {
        guard let index = agentApprovalItems.firstIndex(where: { $0.id == id }) else { return }
        agentApprovalItems[index].status = .rejected
    }

    func clearResolvedAgentApprovals() {
        agentApprovalItems.removeAll { $0.status != .pending }
    }

    /// Show the system dashboard in the detail area
    func showDashboard() {
        currentArea = .keg
        selectedKegSection = .dashboard
    }

    /// Refresh system metrics
    func refreshMetrics() async {
        await checkSystemStatus()
        await refreshDashboardCounts()
    }

    /// Bounds any async call — most importantly the XPC API-client calls,
    /// whose timeout argument does not bound connection establishment against
    /// a wedged apiserver (observed: `ClientHealthCheck.ping(timeout: 5s)`
    /// hanging for minutes). When the deadline wins, the abandoned task is
    /// left in the background — XPC work can't be truly cancelled, but the
    /// caller stops caring and the UI recovers.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation: continuation)
            Task.detached(priority: .userInitiated) {
                do {
                    let value = try await operation()
                    once.resume(returning: value)
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: timeout)
                once.resume(throwing: ContainerCLIError.unresponsive(command: "runtime API call"))
            }
        }
    }

    /// Ensures the wrapped continuation resumes exactly once.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let continuation: CheckedContinuation<T, Error>

        init(continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            lock.unlock()
            continuation.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    func checkSystemStatus() async {
        do {
            let health = try await Self.withTimeout(.seconds(8)) {
                try await ClientHealthCheck.ping(timeout: .seconds(5))
            }
            lastKnownRuntimeAppRoot = health.appRoot.path
            systemStatus = .running(health)
        } catch {
            // The launchd service having a live process means the runtime
            // started; if it still won't answer, it's wedged, not stopped.
            if ContainerCLI.isAPIServerProcessRunning() {
                systemStatus = .unresponsive
            } else {
                systemStatus = .stopped
            }
        }
    }

    func startSystem() async {
        systemStatus = .stopped
        if let problem = ContainerCLI.appRootProblem() {
            systemStatus = .error(problem)
            return
        }
        do {
            let arguments = ["container", "system", "start"] + ContainerCLI.appRootArguments
            // Bounded: a wedged runtime used to hang this call forever. On
            // timeout the child is killed and .unresponsive (or the error)
            // is surfaced instead of the app silently stalling.
            let (code, output) = try await ContainerCLI.run(arguments, timeout: .seconds(120))
            if code != 0 {
                systemStatus = .error(output.isEmpty ? "container system start failed" : output)
                return
            }
            for _ in 0..<30 {
                do {
                    let health = try await Self.withTimeout(.seconds(3)) {
                        try await ClientHealthCheck.ping(timeout: .seconds(2))
                    }
                    lastKnownRuntimeAppRoot = health.appRoot.path
                    systemStatus = .running(health)
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            if ContainerCLI.isAPIServerProcessRunning() {
                systemStatus = .unresponsive
            } else {
                systemStatus = .error("API server did not start within timeout")
            }
        } catch let error as ContainerCLIError {
            if case .unresponsive = error {
                systemStatus = .unresponsive
            } else {
                systemStatus = .error(error.localizedDescription)
            }
        } catch {
            systemStatus = .error(error.localizedDescription)
        }
    }

    func stopSystem() async {
        do {
            let (code, output) = try await ContainerCLI.run(["container", "system", "stop"], timeout: .seconds(30))
            if code != 0 {
                systemStatus = .error(output.isEmpty ? "container system stop failed" : output)
                return
            }
            systemStatus = .stopped
        } catch is ContainerCLIError {
            systemStatus = .unresponsive
        } catch {
            systemStatus = .error(error.localizedDescription)
        }
    }

    func startDockerAPI() {
        guard dockerServerTask == nil else { return }
        let server = DockerAPIServer()
        self.dockerServer = server
        dockerServerTask = Task.detached {
            do {
                try await server.start()
            } catch {
                // Server stopped or failed to bind
            }
        }
        // Give the server a moment to bind, then confirm it started
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if server.resolvedSocketPath != nil {
                self.isDockerAPIRunning = true
            } else {
                // Server hasn't bound yet; wait a bit more
                try? await Task.sleep(for: .seconds(1))
                if server.resolvedSocketPath != nil || self.dockerServerTask != nil {
                    self.isDockerAPIRunning = true
                }
            }
        }
    }

    func stopDockerAPI() {
        // Capture the bound path before tearing down: once the server task
        // is cancelled the socket file may linger, and a stale socket makes
        // clients hang instead of failing fast.
        let socketPath = dockerServer?.resolvedSocketPath ?? DockerAPIServer.socketPath()
        dockerServerTask?.cancel()
        dockerServerTask = nil
        dockerServer = nil
        isDockerAPIRunning = false
        if !DockerAPIServer.socketRespondsToPing(at: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    func startRefreshing() {
        guard refreshTimer == nil else { return }
        scheduleRefreshTimer()
    }

    /// Schedule the next refresh timer tick with an adaptive interval:
    /// 2 seconds when containers are running, 10 seconds when idle, and a
    /// minute when the runtime is unresponsive — hammering a wedged runtime
    /// every 2s just piles up dead calls (each status check alone costs its
    /// 5s ping timeout).
    private func scheduleRefreshTimer() {
        let interval: TimeInterval
        if isRuntimeUnresponsive {
            interval = 60.0
        } else {
            interval = runningContainerCount > 0 ? 2.0 : 10.0
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refresh()
                // Reschedule with potentially updated interval
                self.refreshTimer = nil
                self.scheduleRefreshTimer()
            }
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await checkSystemStatus()
        await refreshDashboardCounts()
        await refreshAgentCounts()
    }

    private func refreshDashboardCounts() async {
        do {
            let containers = try await Self.withTimeout(.seconds(20)) {
                try await self.containerClient.list(filters: .all)
            }
            runningContainerCount = containers.filter { $0.status == .running }.count

            var warnings = 0
            for container in containers where container.status == .running {
                if let stats = try? await Self.withTimeout(.seconds(10), operation: {
                    try await self.containerClient.stats(id: container.id)
                }),
                   let used = stats.memoryUsageBytes,
                   let limit = stats.memoryLimitBytes,
                   limit > 0 {
                    let memPercent = Double(used) / Double(limit) * 100
                    if memPercent >= 80 {
                        warnings += 1
                    }
                }
            }
            unhealthyContainerCount = warnings + containers.filter { $0.status != .running }.count
        } catch {
            runningContainerCount = 0
            unhealthyContainerCount = 0
        }
    }

    func refreshAgentCounts() async {
        guard isAgentAuthenticated else {
            activeAgentCount = 0
            activeSessionCount = 0
            return
        }
        do {
            let client = try await ManagedAgentsClient.fromKeychain()
            let response = try await client.listAgents()
            let agents = response.data.filter { $0.archivedAt == nil }
            activeAgentCount = agents.count

            var sessionTotal = 0
            for agent in agents.prefix(10) {
                let sessions = try await client.listSessions(agentId: agent.id)
                sessionTotal += sessions.data.filter { $0.status != .completed }.count
            }
            activeSessionCount = sessionTotal
        } catch {
            // Keep existing counts on failure
        }
    }

    /// Agents feature is shelved: all agent UI (menu bar status, Settings
    /// API section, dashboard discovery card) is hidden unless explicitly
    /// re-enabled, e.g. `defaults write <bundle-id> keg.showAgents true`.
    /// Capability stays in the codebase; this only hides the surface.
    static var isAgentsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "keg.showAgents")
    }

    /// Sections hidden in Getting Started mode. Everything stays reachable
    /// by switching levels — this is density control, not a gate.
    static let advancedKegSections: Set<KegSection> = [
        .kubernetes, .builds, .networks, .ports,
        .volumes, .registries, .health, .devcontainers,
    ]

    private static func loadExperienceLevel() -> ExperienceLevel {
        guard let rawValue = UserDefaults.standard.string(forKey: experienceLevelDefaultsKey),
              let level = ExperienceLevel(rawValue: rawValue) else {
            return .gettingStarted
        }
        return level
    }

    private static func loadAgentPermissionMode() -> AgentPermissionMode {
        guard let rawValue = UserDefaults.standard.string(forKey: agentPermissionModeDefaultsKey),
              let mode = AgentPermissionMode(rawValue: rawValue) else {
            return .ask
        }
        return mode
    }
}

// MARK: - Agent Permission Mode

public enum AgentPermissionMode: String, CaseIterable, Identifiable, Sendable {
    case explore = "Explore"
    case ask = "Ask"
    case execute = "Execute"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .explore: return "binoculars"
        case .ask: return "questionmark.circle"
        case .execute: return "bolt.fill"
        }
    }

    public var summary: String {
        switch self {
        case .explore: return "Research-first mode"
        case .ask: return "Confirm before changes"
        case .execute: return "Trusted autonomous execution"
        }
    }
}

// MARK: - Top-Level Area

enum AppArea: String, CaseIterable, Identifiable {
    case keg = "Keg"
    case agents = "Agents"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .keg: return "shippingbox"
        case .agents: return "person.2.badge.gearshape"
        }
    }
}

// MARK: - Keg Sections

enum KegSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case containers = "Containers"
    case compose = "Compose"
    case kubernetes = "Kubernetes"
    case logs = "Logs"
    case images = "Images"
    case builds = "Builds"
    case networks = "Networks"
    case volumes = "Volumes"
    case registries = "Registries"
    case terminal = "Terminal"
    case ports = "Ports"
    case health = "Health"
    case devcontainers = "Dev Containers"
    case settings = "Settings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .containers: return "cube.box"
        case .compose: return "doc.text"
        case .kubernetes: return "helm"
        case .logs: return "text.alignleft"
        case .images: return "photo.stack"
        case .builds: return "hammer"
        case .networks: return "network"
        case .volumes: return "externaldrive"
        case .registries: return "globe"
        case .terminal: return "terminal"
        case .ports: return "bolt.horizontal.fill"
        case .health: return "heart.fill"
        case .devcontainers: return "chevron.left.forwardslash.chevron.right"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Agent Sections

enum AgentSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case useCases = "Use Cases"
    case agents = "Agents"
    case sessions = "Sessions"
    case sources = "Sources"
    case skills = "Skills"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .useCases: return "wand.and.stars"
        case .agents: return "person.2.badge.gearshape"
        case .sessions: return "clock"
        case .sources: return "square.stack.3d.up"
        case .skills: return "book"
        }
    }
}
