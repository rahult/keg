import Foundation
import FoundationModels

/// Cooper's tools, grouped into the specialist domains the router picks.
/// Deliberately few per domain (Apple guidance: 3–5 per request) and
/// deliberately neutral in phrasing — guardrails inspect tool definitions,
/// so these read as "manage application containers", not shell commands.
///
/// Every tool has `typealias Output = String`: results are compact text the
/// model can quote, already truncated at the source by the gateway.

// MARK: - Overview domain

struct CooperOverviewTool: Tool {
    let gateway: CooperGateway
    var name = "keg_overview"
    var description: String {
        "Get a fresh snapshot of the whole Keg system: runtime status, containers, images, volumes, networks, compose projects, and the local Kubernetes cluster."
    }

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await gateway.overview()
    }
}

struct CooperOpenSectionTool: Tool {
    let gateway: CooperGateway
    var name = "open_section"
    var description: String {
        "Navigate the Keg window to one of its sections (Dashboard, Containers, Images, Compose, Kubernetes, …). Use when guiding the user somewhere."
    }

    @Generable struct Arguments {
        @Guide(description: "The section name, e.g. \"Containers\" or \"Kubernetes\"")
        var section: String
    }

    func call(arguments: Arguments) async throws -> String {
        await gateway.openSection(arguments.section)
    }
}

struct CooperListContainersTool: Tool {
    let gateway: CooperGateway
    var name = "list_containers"
    var description: String {
        "List application containers with their state and image. Set all=false to see only running containers."
    }

    @Generable struct Arguments {
        @Guide(description: "true lists every container including stopped ones; false lists only running containers")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await gateway.listContainers(all: arguments.all)
    }
}

struct CooperDocsTool: Tool {
    var name = "keg_docs"
    var description: String {
        "Look up Keg's internal reference docs: Apple container CLI usage, Keg architecture, Docker compatibility, Compose support, the keg CLI, the Kubernetes cluster, storage, troubleshooting, or quick starts. Use when a question needs facts beyond the current snapshot."
    }

    @Generable struct Arguments {
        @Guide(description: "Which documentation topic to read")
        var topic: CooperKnowledge.Topic
    }

    func call(arguments: Arguments) async throws -> String {
        CooperKnowledge.text(for: arguments.topic)
    }
}

// MARK: - Containers domain

struct CooperContainerControlTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "container_control"
    var description: String {
        "Apply one action (start, stop, restart, or remove) to a container by ID. Removal requires user approval."
    }

    @Generable struct Arguments {
        @Guide(description: "The container ID, exactly as it appeared in a tool result")
        var id: String
        @Guide(description: "The action to apply")
        var action: CooperContainerAction
    }

    func call(arguments: Arguments) async throws -> String {
        try await gateway.recordCall(toolName: name, argumentsSummary: "\(arguments.action.rawValue) \(arguments.id)")
        return try await gateway.containerControl(id: arguments.id, action: arguments.action, mode: mode)
    }
}

struct CooperContainerLogsTool: Tool {
    let gateway: CooperGateway
    var name = "container_logs"
    var description: String {
        "Read the most recent log lines of one container."
    }

    @Generable struct Arguments {
        @Guide(description: "The container ID, exactly as it appeared in a tool result")
        var id: String
        @Guide(description: "How many trailing lines to read, between 10 and 500")
        var tail: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await gateway.containerLogs(id: arguments.id, tail: arguments.tail)
    }
}

struct CooperContainerInspectTool: Tool {
    let gateway: CooperGateway
    var name = "container_inspect"
    var description: String {
        "Get the details of one container: image, state, exit code, IP address, port mappings, labels, and memory usage when running."
    }

    @Generable struct Arguments {
        @Guide(description: "The container ID, exactly as it appeared in a tool result")
        var id: String
    }

    func call(arguments: Arguments) async throws -> String {
        await gateway.containerInspect(id: arguments.id)
    }
}

struct CooperRunContainerTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "run_container"
    var description: String {
        "Run a new container from an image, detached. Use for actually starting something; the user approves first."
    }

    @Generable struct Arguments {
        @Guide(description: "The image reference, e.g. \"docker.io/library/nginx:latest\"")
        var image: String
        @Guide(description: "Optional container name; empty string to let the runtime pick one")
        var name: String
        @Guide(description: "Port mappings as host:container pairs, e.g. \"8080:80\"; empty list for none")
        var ports: [String]
        @Guide(description: "Environment variables as KEY=value entries; empty list for none")
        var env: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        try await gateway.recordCall(toolName: name, argumentsSummary: arguments.image)
        return try await gateway.runContainer(
            image: arguments.image,
            name: arguments.name.isEmpty ? nil : arguments.name,
            ports: arguments.ports,
            env: arguments.env,
            mode: mode
        )
    }
}

struct CooperExecTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "exec_in_container"
    var description: String {
        "Run one shell command inside a running container (via /bin/sh -c) and return its output. Use for quick checks, not long-running processes."
    }

    @Generable struct Arguments {
        @Guide(description: "The container ID, exactly as it appeared in a tool result")
        var id: String
        @Guide(description: "The shell command to run, e.g. \"ps aux | head -20\"")
        var command: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await gateway.recordCall(toolName: name, argumentsSummary: arguments.command)
        return try await gateway.execInContainer(id: arguments.id, command: arguments.command, mode: mode)
    }
}

// MARK: - Images domain

struct CooperImageControlTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "image_control"
    var description: String {
        "Work with one image by reference: pull downloads it for the native platform, remove deletes it (approval required), inspect shows its details."
    }

    @Generable struct Arguments {
        @Guide(description: "The image reference, e.g. \"docker.io/library/redis:7\"")
        var reference: String
        @Guide(description: "The action to apply")
        var action: CooperImageAction
    }

    func call(arguments: Arguments) async throws -> String {
        try await gateway.recordCall(toolName: name, argumentsSummary: "\(arguments.action.rawValue) \(arguments.reference)")
        return try await gateway.imageControl(reference: arguments.reference, action: arguments.action, mode: mode)
    }
}

// MARK: - Compose domain

struct CooperComposePSTool: Tool {
    let gateway: CooperGateway
    var name = "compose_ps"
    var description: String {
        "List the services of the configured compose project with their state."
    }

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await gateway.composePS()
    }
}

struct CooperComposeUpTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "compose_up"
    var description: String {
        "Create and start every service of the configured compose project, in dependency order."
    }

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        return try await gateway.composeUp(mode: mode)
    }
}

struct CooperComposeDownTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "compose_down"
    var description: String {
        "Stop and delete the configured compose project's containers and resources. Requires user approval."
    }

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        return try await gateway.composeDown(mode: mode)
    }
}

// MARK: - System domain

struct CooperSystemControlTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "system_control"
    var description: String {
        "Check or change the container runtime itself: status reports it, start boots it, stop shuts it down (approval required)."
    }

    @Generable struct Arguments {
        @Guide(description: "The action on the runtime")
        var action: CooperSystemAction
    }

    func call(arguments: Arguments) async throws -> String {
        try await gateway.recordCall(toolName: name, argumentsSummary: arguments.action.rawValue)
        return try await gateway.systemControl(action: arguments.action, mode: mode)
    }
}

struct CooperKubernetesTool: Tool {
    let gateway: CooperGateway
    let mode: AgentPermissionMode
    var name = "k8s_control"
    var description: String {
        "Check or change the local single-node Kubernetes cluster: status, start, stop, create, or delete it (delete requires approval)."
    }

    @Generable struct Arguments {
        @Guide(description: "The action on the cluster")
        var action: CooperK8sAction
    }

    func call(arguments: Arguments) async throws -> String {
        try await gateway.recordCall(toolName: name, argumentsSummary: arguments.action.rawValue)
        return try await gateway.kubernetesControl(action: arguments.action, mode: mode)
    }
}

struct CooperOpenRunSheetTool: Tool {
    let gateway: CooperGateway
    var name = "open_run_sheet"
    var description: String {
        "Open Keg's Run Container form prefilled with an image so the user can review and submit it themselves. Nothing runs until the user submits."
    }

    @Generable struct Arguments {
        @Guide(description: "The image reference to prefill, e.g. \"docker.io/library/redis:7\"")
        var image: String
    }

    func call(arguments: Arguments) async throws -> String {
        await gateway.openRunSheet(image: arguments.image)
    }
}
