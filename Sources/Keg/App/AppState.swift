import Foundation
import ContainerAPIClient
import ContainerResource

enum SystemStatus: Sendable {
    case running(SystemHealth)
    case stopped
    case error(String)
}

@Observable
@MainActor
final class AppState {
    private static let agentPermissionModeDefaultsKey = "agents.permission-mode"

    // Docker API server
    private var dockerServerTask: Task<Void, Never>?
    var isDockerAPIRunning = false
    var dockerSocketPath: String { DockerAPIServer.socketPath() }
    var systemStatus: SystemStatus = .stopped

    // Area navigation
    var currentArea: AppArea = .keg
    var selectedKegSection: KegSection = .containers
    var selectedAgentSection: AgentSection = .dashboard
    var agentPermissionMode: AgentPermissionMode {
        didSet {
            UserDefaults.standard.set(agentPermissionMode.rawValue, forKey: Self.agentPermissionModeDefaultsKey)
        }
    }

    // Legacy selection (for compatibility during transition)
    var selectedSection: NavigationSection = .containers {
        didSet {
            // Sync legacy to new
            if let keg = KegSection(rawValue: selectedSection.rawValue) {
                currentArea = .keg
                selectedKegSection = keg
            }
        }
    }

    var selectedContainerID: String?
    var selectedImageReference: String?
    var selectedAgentID: String?
    var selectedSessionID: String?
    var agentServiceReachability: AgentServiceReachability = .unknown
    var isRefreshing = false
    var runningContainerCount = 0
    var unhealthyContainerCount = 0

    private let containerClient = ContainerClient()
    private var refreshTimer: Timer?

    init() {
        self.agentPermissionMode = Self.loadAgentPermissionMode()
    }

    var isSystemRunning: Bool {
        if case .running = systemStatus { return true }
        return false
    }

    var isAgentAuthenticated = AgentAuth.hasAPIKey()

    /// Lazy-initialized Agent API client
    var agentClient: ManagedAgentsClient? {
        get async {
            guard isAgentAuthenticated else { return nil }
            return try? await ManagedAgentsClient.fromKeychain()
        }
    }

    func refreshAgentAuthentication() {
        isAgentAuthenticated = AgentAuth.hasAPIKey()
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

    // Computed for current section (used by legacy views)
    var currentSection: NavigationSection {
        get {
            switch currentArea {
            case .keg: return NavigationSection(rawValue: selectedKegSection.rawValue) ?? .containers
            case .agents: return .agents
            }
        }
        set {
            selectedSection = newValue
        }
    }

    func checkSystemStatus() async {
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(5))
            systemStatus = .running(health)
        } catch {
            systemStatus = .stopped
        }
    }

    func startSystem() async {
        systemStatus = .stopped
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["container", "system", "start"]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                systemStatus = .error(errorMessage)
                return
            }

            for _ in 0..<30 {
                do {
                    let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
                    systemStatus = .running(health)
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            systemStatus = .error("API server did not start within timeout")
        } catch {
            systemStatus = .error(error.localizedDescription)
        }
    }

    func stopSystem() async {
        do {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["container", "system", "stop"]
            try process.run()
            process.waitUntilExit()
            systemStatus = .stopped
        } catch {
            systemStatus = .error(error.localizedDescription)
        }
    }

    func startDockerAPI() {
        guard dockerServerTask == nil else { return }
        dockerServerTask = Task.detached {
            let server = DockerAPIServer()
            do {
                try await server.start()
            } catch {
                // Server stopped
            }
        }
        isDockerAPIRunning = true
    }

    func stopDockerAPI() {
        dockerServerTask?.cancel()
        dockerServerTask = nil
        isDockerAPIRunning = false
    }

    func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
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
    }

    private func refreshDashboardCounts() async {
        do {
            let containers = try await containerClient.list(filters: .all)
            runningContainerCount = containers.filter { $0.status == .running }.count

            var warnings = 0
            for container in containers where container.status == .running {
                if let stats = try? await containerClient.stats(id: container.id),
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

    private static func loadAgentPermissionMode() -> AgentPermissionMode {
        guard let rawValue = UserDefaults.standard.string(forKey: agentPermissionModeDefaultsKey),
              let mode = AgentPermissionMode(rawValue: rawValue) else {
            return .ask
        }
        return mode
    }
}

// MARK: - Agent Permission Mode

enum AgentPermissionMode: String, CaseIterable, Identifiable {
    case explore = "Explore"
    case ask = "Ask"
    case execute = "Execute"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .explore: return "binoculars"
        case .ask: return "questionmark.circle"
        case .execute: return "bolt.fill"
        }
    }

    var summary: String {
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
    case agents = "Agents"
    case sessions = "Sessions"
    case sources = "Sources"
    case skills = "Skills"
    case account = "Account"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .agents: return "person.2.badge.gearshape"
        case .sessions: return "clock"
        case .sources: return "square.stack.3d.up"
        case .skills: return "book"
        case .account: return "gearshape"
        }
    }
}

// MARK: - Legacy Navigation Section (for compatibility)

@available(*, deprecated, message: "Use KegSection or AgentSection instead")
enum NavigationSection: String, CaseIterable, Identifiable, Hashable {
    case containers = "Containers"
    case images = "Images"
    case builds = "Builds"
    case compose = "Compose"
    case terminal = "Terminal"
    case ports = "Ports"
    case health = "Health"
    case devcontainers = "Dev Containers"
    case networks = "Networks"
    case volumes = "Volumes"
    case registries = "Registries"
    case kubernetes = "Kubernetes"
    case agents = "Agents"
    case settings = "Settings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .containers: return "cube.box"
        case .images: return "photo.stack"
        case .builds: return "hammer"
        case .compose: return "doc.text"
        case .terminal: return "terminal"
        case .ports: return "bolt.horizontal.fill"
        case .networks: return "network"
        case .volumes: return "externaldrive"
        case .registries: return "globe"
        case .health: return "heart.fill"
        case .devcontainers: return "chevron.left.forwardslash.chevron.right"
        case .kubernetes: return "helm"
        case .agents: return "person.2.badge.gearshape"
        case .settings: return "gearshape"
        }
    }
}
