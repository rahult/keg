import Foundation
import FoundationModels

/// The specialist domain a user request is routed to. On-device models
/// select reliably among very few options, so the first (tool-less) pass of
/// every turn is a forced-choice classification into this enum.
@Generable(description: "Which part of Keg the request is about")
enum CooperDomain: String, CaseIterable, Sendable {
    /// General questions, status, navigation, volumes, networks, registries.
    case overview
    /// Container lifecycle, logs, and details.
    case containers
    /// Pulling, deleting, or inspecting images.
    case images
    /// Docker Compose projects.
    case compose
    /// The container runtime itself and the Kubernetes cluster.
    case system
}

enum CooperRouter {
    private static let instructions = """
    Classify the user's request into exactly one domain.
    - overview: general questions about Keg or Docker compatibility, overall \
    status, volumes, networks, registries, being navigated somewhere, or \
    having a Run form prefilled.
    - containers: acting on specific containers (start, stop, restart, \
    delete), running new containers, executing commands inside them, \
    reading logs or details.
    - images: pulling, deleting, or inspecting images.
    - compose: anything about docker compose projects or services.
    - system: the container runtime itself (start/stop/recover), disk \
    usage, or the Kubernetes cluster (status/start/stop/create/delete).
    When several domains seem plausible, choose the one the request would \
    actually operate on. Answer with the domain only.
    """

    /// Classifies the request with a bare session (no tools) and a
    /// constrained-decoding enum response — invalid outputs are impossible.
    /// Bounded: a wedged model daemon must not stall the turn forever.
    static func classify(prompt: String) async throws -> CooperDomain {
        let session = LanguageModelSession(
            model: .default,
            tools: [],
            instructions: instructions
        )
        CooperController.debugLog("classify: start")
        let response = try await CooperBounded.withTimeout(.seconds(45)) {
            try await session.respond(to: prompt, generating: CooperDomain.self)
        }
        CooperController.debugLog("classify: done")
        return response.content
    }

    /// The specialist session for a domain: its own small tool set plus the
    /// shared navigation tool. Static instructions per domain keep the
    /// transcript's leading instructions entry consistent across turns.
    static func tools(for domain: CooperDomain, gateway: CooperGateway, mode: AgentPermissionMode) -> [any Tool] {
        switch domain {
        case .overview:
            return [
                CooperOverviewTool(gateway: gateway),
                CooperDocsTool(),
                CooperOpenSectionTool(gateway: gateway),
                CooperListContainersTool(gateway: gateway),
                CooperOpenRunSheetTool(gateway: gateway),
            ]
        case .containers:
            return [
                CooperContainerControlTool(gateway: gateway, mode: mode),
                CooperContainerLogsTool(gateway: gateway),
                CooperContainerInspectTool(gateway: gateway),
                CooperRunContainerTool(gateway: gateway, mode: mode),
                CooperExecTool(gateway: gateway, mode: mode),
            ]
        case .images:
            return [
                CooperImageControlTool(gateway: gateway, mode: mode),
                CooperOpenSectionTool(gateway: gateway),
            ]
        case .compose:
            return [
                CooperComposePSTool(gateway: gateway),
                CooperComposeUpTool(gateway: gateway, mode: mode),
                CooperComposeDownTool(gateway: gateway, mode: mode),
            ]
        case .system:
            return [
                CooperSystemControlTool(gateway: gateway, mode: mode),
                CooperKubernetesTool(gateway: gateway, mode: mode),
            ]
        }
    }

    /// Per-domain pointers appended to the user prompt so the specialist
    /// knows its scope without bloating the static instructions.
    static func domainHint(for domain: CooperDomain) -> String {
        switch domain {
        case .overview:
            return """
            You are handling a general/overview request. Tools: full snapshot, \
            internal docs (keg_docs), navigation, container list, and \
            prefilled Run form. Reach for keg_docs when facts beat \
            impressions.
            """
        case .containers:
            return """
            You are handling a container operation. Use container IDs from \
            tool results only. run_container starts a new detached container; \
            exec_in_container runs one shell command inside a running one.
            """
        case .images:
            return "You are handling an image operation. Quote references exactly as the user or tools gave them."
        case .compose:
            return "You are handling a compose operation on the project configured in the Compose section."
        case .system:
            return """
            You are handling a runtime or Kubernetes question. Confirm real \
            state with the tool before advising; cluster changes are slow \
            (minutes) — say so before starting them.
            """
        }
    }
}
