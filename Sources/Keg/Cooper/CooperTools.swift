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
        "Get the details of one container: image, state, exit code, IP address, port mappings, labels."
    }

    @Generable struct Arguments {
        @Guide(description: "The container ID, exactly as it appeared in a tool result")
        var id: String
    }

    func call(arguments: Arguments) async throws -> String {
        await gateway.containerInspect(id: arguments.id)
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
