import Foundation

/// A backend-neutral tool for the remote path: OpenAI function-calling
/// schema plus an invoker taking the raw arguments JSON the model emitted.
/// The invokers call the same `CooperGateway` methods as the FoundationModels
/// tools, so the permission gate, approval cards, refresh notifications,
/// and repeat-call protection behave identically regardless of brain.
struct CooperToolSpec: Sendable {
    var name: String
    var description: String
    /// JSON Schema for the `parameters` object.
    var parameters: CooperJSONValue
    var invoke: @Sendable (String) async throws -> String

    /// Decodes the model's arguments JSON into a typed value, tolerating
    /// the empty string some models emit for no-arg tools.
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = trimmed.isEmpty ? Data("{}".utf8) : Data(trimmed.utf8)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CooperToolArgumentError(
                message: "Could not parse the arguments as JSON matching this tool's parameter schema " +
                    "(\(error.localizedDescription)). Re-read the schema and call the tool again with valid JSON."
            )
        }
    }
}

/// The remote tool set. The on-device path routes to ≤5 tools per domain
/// because a ~3B model degrades beyond that; remote models handle the full
/// set, which also removes the misclassification risk, so no router pass
/// runs on this path at all.
enum CooperRemoteTools {
    static func allTools(gateway: CooperGateway, mode: AgentPermissionMode) -> [CooperToolSpec] {
        [
            Self.kegOverview(gateway: gateway),
            Self.kegDocs(),
            Self.openSection(gateway: gateway),
            Self.listContainers(gateway: gateway),
            Self.containerControl(gateway: gateway, mode: mode),
            Self.containerLogs(gateway: gateway),
            Self.containerInspect(gateway: gateway),
            Self.runContainer(gateway: gateway, mode: mode),
            Self.execInContainer(gateway: gateway, mode: mode),
            Self.imageControl(gateway: gateway, mode: mode),
            Self.composePS(gateway: gateway),
            Self.composeUp(gateway: gateway, mode: mode),
            Self.composeDown(gateway: gateway, mode: mode),
            Self.systemControl(gateway: gateway, mode: mode),
            Self.k8sControl(gateway: gateway, mode: mode),
            Self.openRunSheet(gateway: gateway),
        ]
    }

    /// System-level guidance that replaces the per-domain hints the
    /// on-device path injects per turn (remote sends one system message).
    static let systemGuidance = """
    TOOL USE: You have every Keg tool available. Always check real state \
    with tools instead of guessing names or IDs; quote IDs only as they \
    appear in tool results. Reach for keg_docs when a question needs \
    facts beyond the snapshot (CLI usage, Docker compatibility, storage, \
    troubleshooting). container_control/run_container/exec_in_container \
    act on specific containers; image_control pulls/deletes/inspects \
    images; compose_* manages the project configured in the Compose \
    section; system_control and k8s_control manage the runtime and the \
    kind cluster (cluster changes take minutes — say so first). \
    open_run_sheet only prefills the Run form for the user to submit. \
    One or two actions per turn; after an action, report what the tool \
    returned — never claim success if it returned an error. When an \
    approval card appears, tell the user briefly what it is.
    """

    // MARK: - Specs

    private static func kegOverview(gateway: CooperGateway) -> CooperToolSpec {
        CooperToolSpec(
            name: "keg_overview",
            description: "Get a fresh snapshot of the whole Keg system: runtime status, containers, images, volumes, networks, compose projects, and the local Kubernetes cluster.",
            parameters: .objectSchema([:])
        ) { _ in
            await gateway.overview()
        }
    }

    private static func kegDocs() -> CooperToolSpec {
        struct Arguments: Codable { var topic: String }
        return CooperToolSpec(
            name: "keg_docs",
            description: "Look up Keg's internal reference docs: Apple container CLI usage, Keg architecture, Docker compatibility, Compose support, the keg CLI, the Kubernetes cluster, storage, troubleshooting, or quick starts.",
            parameters: .objectSchema([
                "topic": .schema("Which documentation topic to read", type: "string",
                                 enumValues: CooperKnowledge.Topic.allCases.map(\.rawValue)),
            ], required: ["topic"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            guard let topic = CooperKnowledge.Topic(rawValue: arguments.topic) else {
                return "Unknown topic \"\(arguments.topic)\". \(CooperKnowledge.index)"
            }
            return CooperKnowledge.text(for: topic)
        }
    }

    private static func openSection(gateway: CooperGateway) -> CooperToolSpec {
        struct Arguments: Codable { var section: String }
        return CooperToolSpec(
            name: "open_section",
            description: "Navigate the Keg window to one of its sections (Dashboard, Containers, Images, Compose, Kubernetes, …).",
            parameters: .objectSchema([
                "section": .schema("The section name, e.g. \"Containers\" or \"Kubernetes\"", type: "string"),
            ], required: ["section"])
        ) { raw in
            await gateway.openSection(try CooperToolSpec.decode(Arguments.self, from: raw).section)
        }
    }

    private static func listContainers(gateway: CooperGateway) -> CooperToolSpec {
        struct Arguments: Codable { var all: Bool }
        return CooperToolSpec(
            name: "list_containers",
            description: "List application containers with their state and image. Set all=false to see only running containers.",
            parameters: .objectSchema([
                "all": .schema("true lists every container including stopped ones; false lists only running containers", type: "boolean"),
            ], required: ["all"])
        ) { raw in
            await gateway.listContainers(all: try CooperToolSpec.decode(Arguments.self, from: raw).all)
        }
    }

    private static func containerControl(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        struct Arguments: Codable { var id: String; var action: String }
        return CooperToolSpec(
            name: "container_control",
            description: "Apply one action (start, stop, restart, or remove) to a container by ID. Removal requires user approval.",
            parameters: .objectSchema([
                "id": .schema("The container ID, exactly as it appeared in a tool result", type: "string"),
                "action": .schema("The action to apply", type: "string",
                                  enumValues: ["start", "stop", "restart", "remove"]),
            ], required: ["id", "action"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            guard let action = CooperContainerAction(rawValue: arguments.action) else {
                return "Unknown action \"\(arguments.action)\"; use start, stop, restart, or remove."
            }
            try await gateway.recordCall(toolName: "container_control", argumentsSummary: "\(action.rawValue) \(arguments.id)")
            return try await gateway.containerControl(id: arguments.id, action: action, mode: mode)
        }
    }

    private static func containerLogs(gateway: CooperGateway) -> CooperToolSpec {
        struct Arguments: Codable { var id: String; var tail: Int }
        return CooperToolSpec(
            name: "container_logs",
            description: "Read the most recent log lines of one container.",
            parameters: .objectSchema([
                "id": .schema("The container ID, exactly as it appeared in a tool result", type: "string"),
                "tail": .schema("How many trailing lines to read, between 10 and 500", type: "integer"),
            ], required: ["id", "tail"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            return await gateway.containerLogs(id: arguments.id, tail: arguments.tail)
        }
    }

    private static func containerInspect(gateway: CooperGateway) -> CooperToolSpec {
        struct Arguments: Codable { var id: String }
        return CooperToolSpec(
            name: "container_inspect",
            description: "Get the details of one container: image, state, exit code, IP address, port mappings, labels, and memory usage when running.",
            parameters: .objectSchema([
                "id": .schema("The container ID, exactly as it appeared in a tool result", type: "string"),
            ], required: ["id"])
        ) { raw in
            await gateway.containerInspect(id: try CooperToolSpec.decode(Arguments.self, from: raw).id)
        }
    }

    private static func runContainer(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        struct Arguments: Codable { var image: String; var name: String?; var ports: [String]?; var env: [String]? }
        return CooperToolSpec(
            name: "run_container",
            description: "Run a new container from an image, detached. Use for actually starting something; the user approves first.",
            parameters: .objectSchema([
                "image": .schema("The image reference, e.g. \"docker.io/library/nginx:latest\"", type: "string"),
                "name": .schema("Optional container name; omit to let the runtime pick one", type: "string"),
                "ports": .schema("Port mappings as host:container pairs, e.g. [\"8080:80\"]", type: "array",
                                 arrayItems: .schema("", type: "string")),
                "env": .schema("Environment variables as KEY=value entries", type: "array",
                               arrayItems: .schema("", type: "string")),
            ], required: ["image"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            try await gateway.recordCall(toolName: "run_container", argumentsSummary: arguments.image)
            return try await gateway.runContainer(
                image: arguments.image,
                name: arguments.name.flatMap { $0.isEmpty ? nil : $0 },
                ports: arguments.ports ?? [],
                env: arguments.env ?? [],
                mode: mode
            )
        }
    }

    private static func execInContainer(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        struct Arguments: Codable { var id: String; var command: String }
        return CooperToolSpec(
            name: "exec_in_container",
            description: "Run one shell command inside a running container (via /bin/sh -c) and return its output.",
            parameters: .objectSchema([
                "id": .schema("The container ID, exactly as it appeared in a tool result", type: "string"),
                "command": .schema("The shell command to run, e.g. \"ps aux | head -20\"", type: "string"),
            ], required: ["id", "command"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            try await gateway.recordCall(toolName: "exec_in_container", argumentsSummary: arguments.command)
            return try await gateway.execInContainer(id: arguments.id, command: arguments.command, mode: mode)
        }
    }

    private static func imageControl(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        struct Arguments: Codable { var reference: String; var action: String }
        return CooperToolSpec(
            name: "image_control",
            description: "Work with one image by reference: pull downloads it for the native platform, remove deletes it (approval required), inspect shows its details.",
            parameters: .objectSchema([
                "reference": .schema("The image reference, e.g. \"docker.io/library/redis:7\"", type: "string"),
                "action": .schema("The action to apply", type: "string",
                                  enumValues: ["pull", "remove", "inspect"]),
            ], required: ["reference", "action"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            guard let action = CooperImageAction(rawValue: arguments.action) else {
                return "Unknown action \"\(arguments.action)\"; use pull, remove, or inspect."
            }
            try await gateway.recordCall(toolName: "image_control", argumentsSummary: "\(action.rawValue) \(arguments.reference)")
            return try await gateway.imageControl(reference: arguments.reference, action: action, mode: mode)
        }
    }

    private static func composePS(gateway: CooperGateway) -> CooperToolSpec {
        CooperToolSpec(
            name: "compose_ps",
            description: "List the services of the configured compose project with their state.",
            parameters: .objectSchema([:])
        ) { _ in
            await gateway.composePS()
        }
    }

    private static func composeUp(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        CooperToolSpec(
            name: "compose_up",
            description: "Create and start every service of the configured compose project, in dependency order.",
            parameters: .objectSchema([:])
        ) { _ in
            try await gateway.composeUp(mode: mode)
        }
    }

    private static func composeDown(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        CooperToolSpec(
            name: "compose_down",
            description: "Stop and delete the configured compose project's containers and resources. Requires user approval.",
            parameters: .objectSchema([:])
        ) { _ in
            try await gateway.composeDown(mode: mode)
        }
    }

    private static func systemControl(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        struct Arguments: Codable { var action: String }
        return CooperToolSpec(
            name: "system_control",
            description: "Check or change the container runtime itself: status reports it, start boots it, stop shuts it down (approval required).",
            parameters: .objectSchema([
                "action": .schema("The action on the runtime", type: "string",
                                  enumValues: ["status", "start", "stop"]),
            ], required: ["action"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            guard let action = CooperSystemAction(rawValue: arguments.action) else {
                return "Unknown action \"\(arguments.action)\"; use status, start, or stop."
            }
            try await gateway.recordCall(toolName: "system_control", argumentsSummary: action.rawValue)
            return try await gateway.systemControl(action: action, mode: mode)
        }
    }

    private static func k8sControl(gateway: CooperGateway, mode: AgentPermissionMode) -> CooperToolSpec {
        struct Arguments: Codable { var action: String }
        return CooperToolSpec(
            name: "k8s_control",
            description: "Check or change the local single-node Kubernetes cluster: status, start, stop, create, or delete it (delete requires approval).",
            parameters: .objectSchema([
                "action": .schema("The action on the cluster", type: "string",
                                  enumValues: ["status", "start", "stop", "create", "delete"]),
            ], required: ["action"])
        ) { raw in
            let arguments = try CooperToolSpec.decode(Arguments.self, from: raw)
            guard let action = CooperK8sAction(rawValue: arguments.action) else {
                return "Unknown action \"\(arguments.action)\"; use status, start, stop, create, or delete."
            }
            try await gateway.recordCall(toolName: "k8s_control", argumentsSummary: action.rawValue)
            return try await gateway.kubernetesControl(action: action, mode: mode)
        }
    }

    private static func openRunSheet(gateway: CooperGateway) -> CooperToolSpec {
        struct Arguments: Codable { var image: String }
        return CooperToolSpec(
            name: "open_run_sheet",
            description: "Open Keg's Run Container form prefilled with an image so the user can review and submit it themselves. Nothing runs until the user submits.",
            parameters: .objectSchema([
                "image": .schema("The image reference to prefill, e.g. \"docker.io/library/redis:7\"", type: "string"),
            ], required: ["image"])
        ) { raw in
            await gateway.openRunSheet(image: try CooperToolSpec.decode(Arguments.self, from: raw).image)
        }
    }
}
