import ContainerAPIClient
import ContainerResource
import Foundation
import FoundationModels

/// What an operation is allowed to touch — drives the permission gate.
enum CooperActionLevel: Equatable, Sendable {
    case read
    /// Changes runtime state that is routine to undo (start/stop/pull/up).
    case mutating
    /// Hard-to-undo or user-data-affecting (remove container/image, compose
    /// down, stop the runtime). Requires explicit approval in every mode.
    case destructive
}

/// Raised by the gate or by an operation; surfaces verbatim as the tool
/// result so the model can explain it to the user in its next reply.
struct CooperGateError: LocalizedError, Sendable {
    enum Kind: Sendable {
        case readOnlyMode
        case approvalDenied
        case repeatedCall
    }

    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}

/// A pending destructive/mutating action shown as a card in the panel.
struct CooperApprovalRequest: Identifiable, Sendable {
    let id = UUID()
    let toolName: String
    let summary: String
    let details: String
}

/// The single seam between Cooper's tools and the running system. All Keg
/// state changes funnel through here so the permission gate, the refresh
/// notification, repeat-call protection, and logging live in one place.
///
/// Mirrors the semantics of `ContainersVM`/`ImagesVM`: XPC API first, bounded
/// CLI fallback (the API's stop is broken against CLI ≥1.3), and a
/// `.kegRefresh` notification after every mutation.
actor CooperGateway {
    /// Suspends until the user answers the approval card. Installed by the
    /// controller once it is fully initialized; nil (tests) means every
    /// approval-gated call is denied.
    private var approvalHandler: (@Sendable (CooperApprovalRequest) async -> Bool)?

    /// Weak: AppState owns the controller that owns this gateway.
    private weak var appState: AppState?

    /// Identical-call guard for the current turn: a small model can loop on
    /// the same failing action. The fourth identical call in one turn is
    /// refused with a message telling the model to change approach.
    private var turnCallCounts: [String: Int] = [:]

    init(appState: AppState?, approvalHandler: (@Sendable (CooperApprovalRequest) async -> Bool)? = nil) {
        self.appState = appState
        self.approvalHandler = approvalHandler
    }

    /// Late binding, called by the controller's `attach(to:)`.
    func attach(appState: AppState?) {
        self.appState = appState
    }

    func installApprovalHandler(_ handler: (@Sendable (CooperApprovalRequest) async -> Bool)?) {
        self.approvalHandler = handler
    }

    // MARK: - Turn bookkeeping

    func beginTurn() {
        turnCallCounts = [:]
    }

    /// Throws `.repeatedCall` when the same tool+argument combination has
    /// already run three times this turn.
    func recordCall(toolName: String, argumentsSummary: String) throws {
        let key = "\(toolName)|\(argumentsSummary)"
        let count = (turnCallCounts[key] ?? 0) + 1
        turnCallCounts[key] = count
        if count > 3 {
            throw CooperGateError(
                kind: .repeatedCall,
                message: """
                "\(toolName) \(argumentsSummary)" has already been attempted 3 times this turn. \
                Stop retrying it; summarize what you know and suggest a different approach.
                """
            )
        }
    }

    // MARK: - Permission gate

    /// - `read`: always allowed.
    /// - `mutating`: refused outright in Explore; approved automatically in
    ///   Execute; requires an approval card in Ask.
    /// - `destructive`: requires an approval card in every mode.
    func authorize(
        _ level: CooperActionLevel,
        mode: AgentPermissionMode,
        toolName: String,
        summary: String,
        details: String = ""
    ) async throws {
        switch level {
        case .read:
            return
        case .mutating:
            switch mode {
            case .explore:
                throw CooperGateError(
                    kind: .readOnlyMode,
                    message: """
                    Permission mode is Explore (read-only). This change was not made. \
                    The user can switch to Ask or Execute mode in the Cooper panel header.
                    """
                )
            case .execute:
                return
            case .ask:
                break
            }
        case .destructive:
            break
        }

        guard let approvalHandler else {
            throw CooperGateError(kind: .approvalDenied, message: "Action not approved.")
        }
        let granted = await approvalHandler(CooperApprovalRequest(
            toolName: toolName,
            summary: summary,
            details: details
        ))
        guard granted else {
            throw CooperGateError(
                kind: .approvalDenied,
                message: "The user declined this action. Do not retry it; ask how they'd like to proceed."
            )
        }
    }

    // MARK: - Overview & navigation

    func overview() async -> String {
        await CooperContext.loadSnapshot(appState: appState).render()
    }

    /// Navigates the main window to a Keg section. Accepts the section's
    /// display name case-insensitively ("containers", "Kubernetes", ...).
    func openSection(_ name: String) async -> String {
        let request = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let section = KegSection.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(request) == .orderedSame
                || $0.rawValue.replacingOccurrences(of: " ", with: "").caseInsensitiveCompare(request) == .orderedSame
        }) else {
            return """
            No section named "\(request)". Sections: \
            \(KegSection.allCases.map(\.rawValue).joined(separator: ", ")).
            """
        }
        let state = appState
        await MainActor.run {
            state?.currentArea = .keg
            state?.selectedKegSection = section
            state?.mainWindow?.makeKeyAndOrderFront(nil)
        }
        return "Opened the \(section.rawValue) section."
    }

    // MARK: - Containers

    /// Builds `container run` arguments. Static + pure so tests can pin the
    /// CLI contract. Always detached: non-detached runs from chat are a
    /// footgun (they block until the container exits).
    static func runArguments(
        image: String,
        name: String?,
        ports: [String],
        env: [String]
    ) -> [String] {
        var arguments = ["container", "run", "-d"]
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["--name", name]
        }
        for port in ports where !port.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["-p", port.trimmingCharacters(in: .whitespaces)]
        }
        for entry in env where !entry.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["-e", entry.trimmingCharacters(in: .whitespaces)]
        }
        arguments.append(image)
        return arguments
    }

    /// Runs a new container from chat. Mirrors `RunContainerView`'s native
    /// path: image, optional name, `host:container` port pairs, `KEY=value`
    /// env entries — always detached.
    func runContainer(
        image: String,
        name: String?,
        ports: [String],
        env: [String],
        mode: AgentPermissionMode
    ) async throws -> String {
        let summary = name.flatMap { $0.isEmpty ? nil : $0 } ?? image
        try await authorize(
            .mutating, mode: mode,
            toolName: "run_container",
            summary: "Run a container from “\(summary)”",
            details: """
            Detached run. \(ports.isEmpty ? "No published ports." : "Ports: \(ports.joined(separator: ", "))") \
            \(env.isEmpty ? "No environment variables." : "Env: \(env.count) variable(s).")
            """
        )
        let arguments = Self.runArguments(image: image, name: name, ports: ports, env: env)
        do {
            let (code, output) = try await ContainerCLI.run(arguments, timeout: .seconds(300))
            if code != 0 {
                return output.isEmpty ? "`\(arguments.joined(separator: " "))` failed (exit \(code))." : Self.clipped(output, label: "run output")
            }
            await postRefresh()
            let identifier = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return identifier.isEmpty
                ? "Container from \(image) started."
                : "Container started with ID \(identifier)."
        } catch let error as ContainerCLIError {
            return "CLI error: \(error.localizedDescription)"
        }
    }

    /// Runs a command inside a running container via `/bin/sh -c`, so pipes
    /// and redirections work. Output is captured and clipped.
    func execInContainer(id: String, command: String, mode: AgentPermissionMode) async throws -> String {
        try await authorize(
            .mutating, mode: mode,
            toolName: "exec_in_container",
            summary: "Run a command inside “\(id)”",
            details: "Command runs via /bin/sh -c: \(command)"
        )
        do {
            let (code, output) = try await ContainerCLI.run(
                ["container", "exec", id, "/bin/sh", "-c", command],
                timeout: .seconds(120)
            )
            let body = Self.clipped(output, label: "output of \(command)")
            return code == 0
                ? body.isEmpty ? "Command completed with no output." : body
                : "Command exited \(code). \(body)"
        } catch let error as ContainerCLIError {
            return "CLI error: \(error.localizedDescription)"
        }
    }

    func listContainers(all: Bool) async -> String {
        guard let containers = try? await CooperBounded.withTimeout(.seconds(15), operation: {
            try await ContainerClient().list(filters: .all)
        }) else {
            return "Could not list containers (runtime did not answer within 15s)."
        }
        let visible = all ? containers : containers.filter { $0.status == .running }
        guard !visible.isEmpty else {
            return all ? "No containers exist." : "No containers are currently running."
        }
        return visible.map { item in
            var row = "- \(item.id) [\(item.status.rawValue)] \(item.configuration.image.reference)"
            let ports = item.configuration.publishedPorts
                .map { "\($0.hostPort):\($0.containerPort)" }
                .joined(separator: ",")
            if !ports.isEmpty { row += " ports \(ports)" }
            return row
        }
        .joined(separator: "\n")
    }

    /// start/stop/restart go through the CLI (the XPC API's stop fails
    /// against CLI ≥1.3 — same workaround `ContainersVM` applies); remove
    /// uses the XPC API with force, mirroring `ContainersVM.delete`.
    func containerControl(id: String, action: CooperContainerAction, mode: AgentPermissionMode) async throws -> String {
        switch action {
        case .start:
            try await authorize(.mutating, mode: mode, toolName: "container_control",
                                summary: "Start container “\(id)”")
            return try await runContainerCLI(["container", "start", id], success: "Container \(id) started.")
        case .stop:
            try await authorize(.mutating, mode: mode, toolName: "container_control",
                                summary: "Stop container “\(id)”")
            return try await runContainerCLI(["container", "stop", id], success: "Container \(id) stopped.")
        case .restart:
            try await authorize(.mutating, mode: mode, toolName: "container_control",
                                summary: "Restart container “\(id)”",
                                details: "Apple containers are immutable; this stops then starts the container.")
            _ = try await runContainerCLI(["container", "stop", id], success: "")
            return try await runContainerCLI(["container", "start", id], success: "Container \(id) restarted.")
        case .remove:
            try await authorize(
                .destructive, mode: mode,
                toolName: "container_control",
                summary: "Delete container “\(id)”",
                details: "The container and its writable state will be removed permanently. Volumes and images are untouched."
            )
            let client = ContainerClient()
            do {
                try await CooperBounded.withTimeout(.seconds(60)) {
                    try await client.delete(id: id, force: true)
                }
            } catch {
                await postRefresh()
                return "Could not delete container \(id): \(error.localizedDescription)"
            }
            await postRefresh()
            return "Container \(id) deleted."
        }
    }

    func containerLogs(id: String, tail: Int) async -> String {
        let capped = max(10, min(tail, 500))
        do {
            let (code, output) = try await ContainerCLI.run(
                ["container", "logs", "-n", "\(capped)", id],
                timeout: .seconds(30)
            )
            guard code == 0, !output.isEmpty else {
                return "No logs returned for \(id) (exit \(code)). It may have no output yet, or the ID may be wrong."
            }
            return Self.clipped(output, label: "last \(capped) log lines of \(id)")
        } catch {
            return "Could not read logs for \(id): \(error.localizedDescription)"
        }
    }

    func containerInspect(id: String) async -> String {
        do {
            let bridge = ContainerBridge()
            let inspect = try await CooperBounded.withTimeout(.seconds(20)) {
                try await bridge.inspectContainer(id: id)
            }
            var lines: [String] = [
                "name: \(inspect.name)",
                "image: \(inspect.config?.image ?? inspect.image)",
                "state: \(inspect.state.status)",
            ]
            if let exit = inspect.state.exitCode { lines.append("exit code: \(exit)") }
            if let started = inspect.state.startedAt { lines.append("started: \(started)") }
            if let ip = inspect.networkSettings?.ipAddress { lines.append("ip: \(ip)") }
            if let ports = inspect.networkSettings?.ports, !ports.isEmpty {
                let bindings = ports.map { key, values in
                    let targets = values.map { "\($0.hostIP ?? ""):\($0.hostPort)" }.joined(separator: ",")
                    return "\(key) -> \(targets)"
                }
                lines.append("ports: \(bindings.joined(separator: "; "))")
            }
            if let labels = inspect.config?.labels, !labels.isEmpty {
                let pairs = labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                lines.append("labels: \(Self.clipped(pairs.joined(separator: " "), label: "labels"))")
            }
            // Live resource usage for a running container (two XPC samples).
            if inspect.state.running {
                let stats = try? await CooperBounded.withTimeout(.seconds(15), operation: {
                    try await bridge.containerStats(id: id)
                })
                if let stats {
                    let memoryUsed = stats.memoryStats.usage.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                    } ?? "?"
                    let memoryLimit = stats.memoryStats.limit.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                    } ?? "?"
                    lines.append("memory: \(memoryUsed) of \(memoryLimit)")
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Could not inspect \(id): \(error.localizedDescription)"
        }
    }

    // MARK: - Images

    func imageControl(reference: String, action: CooperImageAction, mode: AgentPermissionMode) async throws -> String {
        switch action {
        case .pull:
            try await authorize(.mutating, mode: mode, toolName: "image_control",
                                summary: "Pull image “\(reference)”",
                                details: "Downloads the image for the native arm64 platform.")
            do {
                let config = await SystemConfigProvider.current()
                let normalized = try ClientImage.normalizeReference(reference, containerSystemConfig: config)
                try await CooperBounded.withTimeout(.seconds(1200)) {
                    _ = try await ClientImage.pull(
                        reference: normalized,
                        platform: .current,
                        containerSystemConfig: config
                    )
                }
                await postRefresh()
                return "Pulled \(normalized)."
            } catch {
                return "Could not pull \(reference): \(error.localizedDescription)"
            }
        case .remove:
            try await authorize(
                .destructive, mode: mode,
                toolName: "image_control",
                summary: "Delete image “\(reference)”",
                details: "The image is removed from local storage and must be pulled again to use it."
            )
            do {
                try await ClientImage.delete(reference: reference)
                await postRefresh()
                return "Image \(reference) deleted."
            } catch {
                return "Could not delete \(reference): \(error.localizedDescription)"
            }
        case .inspect:
            let bridge = ContainerBridge()
            do {
                let inspect = try await CooperBounded.withTimeout(.seconds(20)) {
                    try await bridge.inspectImage(name: reference)
                }
                return Self.clipped(String(describing: inspect), label: "image \(reference)")
            } catch {
                return "Could not inspect \(reference): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Compose

    /// Cooper shares the Compose section's stored file path: reads the same
    /// defaults keys `ComposeVM` writes, so both surfaces stay in agreement.
    private var composeFilePath: String {
        UserDefaults.standard.string(forKey: "compose.filePath") ?? ""
    }

    private var composeProjectName: String? {
        let name = UserDefaults.standard.string(forKey: "compose.projectName") ?? ""
        return name.isEmpty ? nil : name
    }

    func composePS() async -> String {
        let filePath = composeFilePath
        let project = composeProjectName
        let orchestrator = ComposeOrchestrator()
        do {
            let services = try await CooperBounded.withTimeout(.seconds(60)) {
                try await orchestrator.ps(filePath: filePath, projectName: project)
            }
            guard !services.isEmpty else { return "No services reported for the configured compose file." }
            return services
                .map { "- \($0.name) [\($0.service)] \($0.state)" }
                .joined(separator: "\n")
        } catch {
            return "Compose ps failed: \(error.localizedDescription)"
        }
    }

    func composeUp(mode: AgentPermissionMode) async throws -> String {
        guard !composeFilePath.isEmpty else {
            return "No compose file is configured. The user can pick one in the Compose section."
        }
        try await authorize(
            .mutating, mode: mode,
            toolName: "compose_up",
            summary: "Bring up the compose project from \(composeFilePath)",
            details: "Creates and starts every service in dependency order."
        )
        let orchestrator = ComposeOrchestrator()
        do {
            try await orchestrator.up(
                filePath: composeFilePath,
                projectName: composeProjectName,
                detached: true,
                progress: nil
            )
            await postRefresh()
            return "Compose project is up (\(composeFilePath))."
        } catch {
            return "Compose up failed: \(error.localizedDescription)"
        }
    }

    func composeDown(mode: AgentPermissionMode) async throws -> String {
        guard !composeFilePath.isEmpty else {
            return "No compose file is configured. The user can pick one in the Compose section."
        }
        try await authorize(
            .destructive, mode: mode,
            toolName: "compose_down",
            summary: "Tear down the compose project from \(composeFilePath)",
            details: "Stops and deletes the project's containers, then removes its networks and best-effort volumes."
        )
        let orchestrator = ComposeOrchestrator()
        do {
            try await orchestrator.down(
                filePath: composeFilePath,
                projectName: composeProjectName,
                progress: nil
            )
            await postRefresh()
            return "Compose project is down."
        } catch {
            return "Compose down failed: \(error.localizedDescription)"
        }
    }

    // MARK: - System

    func systemControl(action: CooperSystemAction, mode: AgentPermissionMode) async throws -> String {
        let state = appState
        switch action {
        case .status:
            let status = await MainActor.run {
                state?.systemStatus.description ?? "unknown"
            }
            return "Runtime status: \(status)."
        case .start:
            try await authorize(.mutating, mode: mode, toolName: "system_control",
                                summary: "Start the container runtime",
                                details: "Runs `container system start` against the configured app-root.")
            guard let state else { return "Runtime control is unavailable in this context." }
            await state.startSystem()
            let status = await MainActor.run { state.systemStatus.description }
            return "Start attempt finished. Runtime status: \(status)."
        case .stop:
            try await authorize(
                .destructive, mode: mode,
                toolName: "system_control",
                summary: "Stop the container runtime",
                details: "All running containers will be shut down and the Docker API socket will stop serving."
            )
            guard let state else { return "Runtime control is unavailable in this context." }
            await state.stopSystem()
            return "Runtime stopped."
        }
    }

    // MARK: - Resources (volumes & networks)

    func listResources(kind: CooperResourceKind) async -> String {
        switch kind {
        case .volumes:
            guard let volumes = try? await CooperBounded.withTimeout(.seconds(15), operation: {
                try await ClientVolume.list()
            }) else {
                return "Could not list volumes (runtime did not answer within 15s)."
            }
            guard !volumes.isEmpty else { return "No volumes exist." }
            return volumes.map { "- \($0.name) [\($0.driver)]" }.joined(separator: "\n")
        case .networks:
            guard let networks = try? await CooperBounded.withTimeout(.seconds(15), operation: {
                try await NetworkClient().list()
            }) else {
                return "Could not list networks (runtime did not answer within 15s)."
            }
            guard !networks.isEmpty else { return "No networks exist." }
            return networks.map { network -> String in
                let subnet = network.status.ipv4Subnet.description
                return "- \(network.id)\(network.isBuiltin ? " (built-in)" : "") subnet \(subnet)"
            }.joined(separator: "\n")
        }
    }

    // MARK: - Guided UI actions from chat

    /// Opens the Containers section with the Run sheet prefilled for the
    /// given image — the same path the welcome sheet's quick starts use.
    /// The user reviews and submits; nothing runs until they do.
    func openRunSheet(image: String) async -> String {
        await MainActor.run { [weak appState] in
            appState?.pendingRunImage = image
            appState?.currentArea = .keg
            appState?.selectedKegSection = .containers
            appState?.mainWindow?.makeKeyAndOrderFront(nil)
        }
        // Belt-and-braces, mirroring MainView.quickRun: cover the case
        // where the Containers list is already alive and visible.
        let reference = image
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .kegRunImage, object: reference)
        }
        return "Opened the Run sheet prefilled with \(image). The user reviews and submits it."
    }

    // MARK: - Kubernetes

    func kubernetesControl(action: CooperK8sAction, mode: AgentPermissionMode) async throws -> String {
        let summary: String
        let level: CooperActionLevel
        switch action {
        case .status:
            summary = "Check the Kubernetes cluster status"
            level = .read
        case .start:
            summary = "Start the Kubernetes cluster"
            level = .mutating
        case .create:
            summary = "Create the Kubernetes cluster"
            level = .mutating
        case .stop:
            summary = "Stop the Kubernetes cluster"
            level = .mutating
        case .delete:
            summary = "Delete the Kubernetes cluster"
            level = .destructive
        }
        try await authorize(
            level, mode: mode,
            toolName: "k8s_control",
            summary: summary,
            details: action == .delete
                ? "Deletes the keg-k8s container and ~/.keg/kubeconfig. All cluster state is lost."
                : ""
        )

        let vm = await MainActor.run { KubernetesVM() }
        switch action {
        case .status:
            await vm.checkClusterStatus()
        case .start:
            await vm.startCluster()
        case .stop:
            await vm.stopCluster()
        case .create:
            await vm.createCluster()
        case .delete:
            await vm.deleteCluster()
        }
        if action != .status {
            await vm.checkClusterStatus()
        }
        let description = await MainActor.run { Self.describe(vm.clusterStatus) }
        await postRefresh()
        return action == .status
            ? "Kubernetes cluster status: \(description)."
            : "\(summary) finished. Cluster status: \(description)."
    }

    private static func describe(_ status: ClusterStatus) -> String {
        switch status {
        case .notCreated: return "not created"
        case .creating: return "creating"
        case .running: return "running"
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .stopping: return "stopping"
        case .error(let message): return "error: \(message)"
        }
    }

    // MARK: - Helpers

    private func runContainerCLI(_ arguments: [String], success: String) async throws -> String {
        do {
            let (code, output) = try await ContainerCLI.run(arguments, timeout: .seconds(60))
            if code != 0 {
                return output.isEmpty ? "`\(arguments.joined(separator: " "))` failed (exit \(code))." : output
            }
            await postRefresh()
            return success
        } catch let error as ContainerCLIError {
            return "CLI error: \(error.localizedDescription)"
        }
    }

    /// Tells the UI (and the next snapshot) that state changed.
    private func postRefresh() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .kegRefresh, object: nil)
        }
    }

    /// Long tool output gets a one-line head so the small context window
    /// survives multi-step turns.
    static func clipped(_ text: String, label: String, limit: Int = 1600) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let head = String(trimmed.prefix(limit))
        return "\(head)\n[… \(label) truncated; \(trimmed.count - limit) more characters]"
    }
}

/// `@Generable` enums for the consolidated control tools.
@Generable(description: "An action to apply to one container")
enum CooperContainerAction: String, Sendable {
    case start
    case stop
    case restart
    case remove
}

@Generable(description: "An action to apply to one image")
enum CooperImageAction: String, Sendable {
    case pull
    case remove
    case inspect
}

@Generable(description: "An action on the container runtime itself")
enum CooperSystemAction: String, Sendable {
    case status
    case start
    case stop
}

@Generable(description: "Which Keg resource kind to list")
enum CooperResourceKind: String, Sendable {
    case volumes
    case networks
}

@Generable(description: "An action on the local Kubernetes cluster")
enum CooperK8sAction: String, Sendable {
    case status
    case start
    case stop
    case create
    case delete
}
