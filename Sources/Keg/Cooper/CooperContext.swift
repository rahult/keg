import ContainerAPIClient
import ContainerResource
import Foundation
import FoundationModels

/// Cooper's readiness, mapped from `SystemLanguageModel.default.availability`.
/// The panel renders a distinct explanation (and recovery path) per case.
enum CooperAvailability: Equatable, Sendable {
    case checking
    case ready
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    case unavailable(String)

    static func from(systemModel: SystemLanguageModel) -> CooperAvailability {
        switch systemModel.availability {
        case .available:
            return .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unavailable("Apple Intelligence is not available right now.")
        @unknown default:
            return .unavailable("This system reports an unknown model availability state.")
        }
    }
}

/// One container in the compact state snapshot Cooper sees every turn.
/// Plain values, no Apple types, so tests can construct it directly.
struct CooperSnapshotContainer: Equatable, Sendable {
    var displayName: String
    var id: String
    var state: String
    var image: String
    var ports: String
}

/// The per-turn view of everything Cooper is "aware of". Rendered as a few
/// hundred tokens of text and prepended to the user's prompt — never baked
/// into the static instructions, which must stay byte-stable across a
/// session for transcript compatibility.
struct CooperSnapshot: Equatable, Sendable {
    var appLine = "unknown"
    var systemLine = "unknown"
    var dockerAPILine = "unknown"
    var uiLine = "unknown"
    var containers: [CooperSnapshotContainer] = []
    var imageReferences: [String] = []
    var volumeNames: [String] = []
    var networkIDs: [String] = []
    var composeProjects: [String] = []
    var kubernetesLine = "not checked"

    var containerSummary: String {
        let running = containers.filter { $0.state == "running" }.count
        return "\(containers.count) total, \(running) running"
    }

    func render() -> String {
        var lines: [String] = []
        lines.append("APP: \(appLine)")
        lines.append("RUNTIME: \(systemLine)")
        lines.append("DOCKER API: \(dockerAPILine)")
        lines.append("UI: \(uiLine)")

        if containers.isEmpty {
            lines.append("CONTAINERS: none")
        } else {
            lines.append("CONTAINERS (\(containerSummary)):")
            for container in containers {
                var row = "- \(container.displayName) [\(container.state)] \(container.image)"
                if !container.ports.isEmpty {
                    row += " ports \(container.ports)"
                }
                lines.append(row)
            }
        }

        if imageReferences.isEmpty {
            lines.append("IMAGES: none")
        } else {
            let preview = imageReferences.prefix(8).joined(separator: ", ")
            let more = imageReferences.count > 8 ? " (+\(imageReferences.count - 8) more)" : ""
            lines.append("IMAGES: \(imageReferences.count) (\(preview)\(more))")
        }

        if volumeNames.isEmpty {
            lines.append("VOLUMES: none")
        } else {
            lines.append("VOLUMES: \(volumeNames.joined(separator: ", "))")
        }

        if networkIDs.isEmpty {
            lines.append("NETWORKS: none")
        } else {
            lines.append("NETWORKS: \(networkIDs.joined(separator: ", "))")
        }

        if composeProjects.isEmpty {
            lines.append("COMPOSE: no active projects")
        } else {
            lines.append("COMPOSE projects: \(composeProjects.joined(separator: ", "))")
        }

        lines.append("KUBERNETES: \(kubernetesLine)")
        return lines.joined(separator: "\n")
    }
}

/// Static persona/facts and the per-turn snapshot loader. Everything here is
/// model-free so the snapshot formatting is unit-testable.
enum CooperContext {
    /// Static instructions, identical for the life of the session. Kept
    /// dense but bounded: instructions are re-sent every request and the
    /// on-device window is small. Live state goes in the per-turn prompt.
    static let personaInstructions = """
    You are Cooper, the built-in assistant of Keg — a native macOS app \
    (Apple Silicon, macOS 26+) that wraps Apple's container framework. You \
    know the entire app:

    SECTIONS: Dashboard (runtime health, disk usage, metrics), Containers \
    (lifecycle, logs, stats, exec, files, recreate), Images (pull, push, \
    tag, delete, prune), Builds (Dockerfile builds), Compose \
    (docker-compose.yml up/down/plan/ps/logs/restart), Terminal (a shell \
    with DOCKER_HOST already pointed at Keg's Docker socket), Ports \
    (published port map), Networks, Volumes, Registries (docker \
    login/logout), Health (diagnostics), Dev Containers, Kubernetes (a \
    single-node kind cluster: kindest/node inside a container named \
    keg-k8s, kubeconfig at ~/.keg/kubeconfig), Logs (multi-container), \
    Settings (experience level, data location, CLI install, updates).

    DOCKER COMPATIBILITY: Keg serves the Docker Engine API on a unix \
    socket (path in the runtime line). The `docker` CLI works against it \
    out of the box; `docker run/exec/logs/ps/build/compose` all operate on \
    the same containers you manage. The `keg` companion CLI (installable \
    from Settings) provides `keg open keg://<section>` deep links.

    QUICK STARTS: the Containers screen offers demo presets (5-second \
    demo, web server, custom).

    RUNTIME QUIRKS: container data lives at the configured app-root \
    (shown in the runtime line). Stopping containers goes through the \
    CLI, not the API. "Unresponsive" means services are alive but not \
    answering — suggest Retry or Restart Services on the banner, or \
    Copy Diagnostics.

    LIMITS: no multi-node Kubernetes, no swarm, no live port-forward \
    streaming, no building images from chat (point at the Builds \
    section), no internet access. Executed commands run inside the \
    container's /bin/sh.

    STYLE: Concise and warm. A light brewing metaphor is welcome ("on \
    tap", "poured", "tapped"), never more than one per reply. Under 120 \
    words unless asked for detail.

    TOOLS: Always check real state with tools instead of guessing names \
    or IDs; quote IDs only as they appear in tool results. One or two \
    actions per turn. After an action, report what the tool returned — \
    never claim success if the tool returned an error. When the app \
    shows an approval card for an action you asked for, tell the user \
    briefly what it is and why. open_run_sheet only prefills the Run \
    form for the user to review and submit.

    SAFETY: If you don't know, say so. Never invent container IDs, image \
    references, or file paths.
    """

    static let sectionNames = [
        "dashboard", "containers", "images", "builds", "compose", "terminal",
        "ports", "networks", "volumes", "registries", "health", "devcontainers",
        "kubernetes", "logs", "settings",
    ]

    /// Gathers a fresh snapshot. Every runtime call is time-bounded and
    /// non-throwing: a wedged runtime degrades that section to "unknown"
    /// instead of stalling the turn.
    static func loadSnapshot(appState: AppState?) async -> CooperSnapshot {
        var snapshot = CooperSnapshot()

        let header = await MainActor.run { () -> (app: String, system: String, dockerAPI: String, ui: String)? in
            guard let appState else { return nil }
            let selection = appState.selectedContainerID.map { " | selected: \($0.prefix(12))" } ?? ""
            return (
                "Keg \(AppVersion.displayString)",
                appState.systemStatus.description,
                appState.isDockerAPIRunning ? "serving at \(appState.dockerSocketPath)" : "not running",
                "section: \(appState.selectedKegSection.rawValue)\(selection) | level: \(appState.experienceLevel.rawValue)"
            )
        }
        if let header {
            snapshot.appLine = header.app
            snapshot.systemLine = header.system
            snapshot.dockerAPILine = header.dockerAPI
            snapshot.uiLine = header.ui
        }

        async let containersTask = bounded { try await ContainerClient().list(filters: .all) }
        async let imagesTask = bounded { try await ClientImage.list() }
        async let volumesTask = bounded { try await ClientVolume.list() }
        async let networksTask = bounded { try await NetworkClient().list() }

        if let containers = await containersTask {
            snapshot.containers = containers.map { item in
                let name = item.configuration.labels["name"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(item.id.prefix(12))
                let ports = item.configuration.publishedPorts
                    .map { "\($0.hostPort):\($0.containerPort)" }
                    .joined(separator: ",")
                return CooperSnapshotContainer(
                    displayName: name,
                    id: item.id,
                    state: item.status.rawValue,
                    image: item.configuration.image.reference,
                    ports: ports
                )
            }
            snapshot.composeProjects = Array(Set(containers.compactMap {
                $0.configuration.labels["com.docker.compose.project"]
            })).sorted()
            snapshot.kubernetesLine = Self.kubernetesLine(in: containers)
        }

        if let images = await imagesTask {
            snapshot.imageReferences = images.map(\.reference)
        }
        if let volumes = await volumesTask {
            snapshot.volumeNames = volumes.map(\.name)
        }
        if let networks = await networksTask {
            snapshot.networkIDs = networks.map(\.id)
        }
        return snapshot
    }

    private static func kubernetesLine(in containers: [ContainerSnapshot]) -> String {
        guard let cluster = containers.first(where: { $0.id == "keg-k8s" }) else {
            return "no cluster (keg-k8s container absent)"
        }
        let state = cluster.status.rawValue
        return state == "running" ? "cluster keg-k8s running" : "cluster keg-k8s \(state)"
    }

    private static func bounded<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        do {
            return try await CooperBounded.withTimeout(.seconds(10), operation: operation)
        } catch {
            return nil
        }
    }
}

/// Bounds async calls. Deliberately mirrors `AppState.withTimeout`'s
/// detached-task + resume-once shape rather than a task group: a task group
/// implicitly awaits its outstanding operation when the deadline throws, and
/// against a wedged runtime the operation ignores cancellation, so the
/// "timeout" would hang forever. Here the deadline wins and the abandoned
/// task is left in the background.
enum CooperBounded {
    struct TimeoutError: LocalizedError {
        var errorDescription: String? { "call exceeded its time budget" }
    }

    static func withTimeout<T: Sendable>(
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
                once.resume(throwing: TimeoutError())
            }
        }
    }

    /// Guarantees the wrapped continuation resumes exactly once.
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
}

extension SystemStatus {
    /// One-line human form used in the snapshot's RUNTIME row.
    var description: String {
        switch self {
        case .running(let health):
            return "running (app-root \(health.appRoot.path))"
        case .stopped:
            return "stopped"
        case .unresponsive:
            return "unresponsive (services alive but not answering)"
        case .error(let message):
            return "error: \(message)"
        }
    }
}
