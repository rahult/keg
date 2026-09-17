import Foundation

/// How much of Keg's surface a user wants to see.
///
/// Keg serves two audiences: people who have never touched containers and
/// just want their app to run, and experienced operators who want every
/// knob. The level controls sidebar density, help copy tone, and how much
/// hand-holding the UI offers. It is a preference, not a gate — every
/// capability stays reachable from Settings.
enum ExperienceLevel: String, CaseIterable, Identifiable, Sendable {
    case gettingStarted = "Getting Started"
    case comfortable = "Comfortable"
    case fullControl = "Full Control"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .comfortable: return "hand.raised"
        case .fullControl: return "slider.horizontal.3"
        }
    }

    /// One-line pitch shown on the welcome cards and in Settings.
    var summary: String {
        switch self {
        case .gettingStarted:
            return "Just the essentials, with plain-language help everywhere."
        case .comfortable:
            return "All standard sections, with tips as you need them."
        case .fullControl:
            return "Every section and detail, no hand-holding."
        }
    }

    /// Longer explanation for the welcome sheet.
    var detail: String {
        switch self {
        case .gettingStarted:
            return """
                Keg shows only the screens you need to run apps: your containers, \
                images, and simple shortcuts. Everything is explained in plain \
                language, and nothing can break your Mac — containers are isolated.
                """
        case .comfortable:
            return """
                All everyday sections are visible — containers, images, builds, \
                logs, networks, and volumes — with a help button on each screen \
                when you want background.
                """
        case .fullControl:
            return """
                The complete Docker-compatible surface: every section, every \
                field, raw IDs and CLI-level detail. Keg behaves like a full \
                desktop for Apple's container tool.
                """
        }
    }

    /// Whether the sidebar shows advanced sections (Kubernetes, ports,
    /// registries, health, dev containers).
    var showsAdvancedSections: Bool {
        switch self {
        case .gettingStarted: return false
        case .comfortable, .fullControl: return true
        }
    }
}

// MARK: - Section Help Content

/// Plain-language + technical explanation for one sidebar section, shown in
/// the help popover attached to each screen's toolbar.
struct SectionHelpContent {
    let title: String
    /// Plain-language explanation for newcomers.
    let beginner: String
    /// Precise technical description for experienced users.
    let technical: String
    /// Concrete first actions someone can take in this section.
    let firstSteps: [String]
    /// One practical tip.
    let tip: String?
}

enum SectionHelpGuide {
    static func content(for section: KegSection) -> SectionHelpContent {
        switch section {
        case .dashboard:
            return SectionHelpContent(
                title: "Dashboard",
                beginner: "A live overview of how your containers are doing — how many are running, how much memory they use, and whether anything needs attention.",
                technical: "System-wide health view fed by the container API server: running/stopped counts, per-container memory pressure, and CPU history for the lightweight VM fleet.",
                firstSteps: [
                    "Glance at Running Containers to see what's active",
                    "Watch Memory Pressure for anything above 80%",
                ],
                tip: "The menu bar icon shows the same status without opening the window."
            )
        case .containers:
            return SectionHelpContent(
                title: "Containers",
                beginner: "Your apps. Each container is one isolated app — its own tiny virtual machine, so it can't interfere with your Mac or other apps. Run one to see it here.",
                technical: "One Virtualization.framework VM per container. Lists snapshots from ContainerAPIClient with live CPU/memory stats, published ports, and IP addresses.",
                firstSteps: [
                    "Click Run… and try the nginx quick start — it serves a web page at http://localhost:8080",
                    "Select a container to see logs, files, and stats in the side panel",
                    "Right-click a container for Stop, Restart, or a terminal inside it",
                ],
                tip: "Press Space-friendly workflow: select a container, then use the inspector for logs without leaving the list."
            )
        case .images:
            return SectionHelpContent(
                title: "Images",
                beginner: "Templates containers are built from — think of them as install packages. Pull one once, then run as many containers from it as you like.",
                technical: "OCI images in the container image store, listed by reference and digest with on-disk size. Pull is pinned to the host platform (arm64).",
                firstSteps: [
                    "Click Pull… to download an image (nginx is a good first one)",
                    "Select an image and click Run to start a container from it",
                ],
                tip: "Images are shared: ten containers from one image cost one download."
            )
        case .builds:
            return SectionHelpContent(
                title: "Builds",
                beginner: "Turn a folder with a Dockerfile into your own image — useful once you have an app you want to package.",
                technical: "BuildKit-backed image builds via the container CLI, with live log streaming from the build session.",
                firstSteps: [
                    "Pick the folder containing your Dockerfile",
                    "Give the result a name like my-app:latest",
                ],
                tip: nil
            )
        case .compose:
            return SectionHelpContent(
                title: "Compose",
                beginner: "Run a whole group of containers from one file — for example a website plus its database. If a project has a docker-compose.yml, this is where it comes alive.",
                technical: "docker-compose.yml parsed with Yams; services are dependency-sorted and run as linked containers with a shared network.",
                firstSteps: [
                    "Open the folder that contains docker-compose.yml",
                    "Click Up to start everything, Down to stop",
                ],
                tip: "Most open-source projects you download include a compose file — look for it in the project root."
            )
        case .kubernetes:
            return SectionHelpContent(
                title: "Kubernetes",
                beginner: "A local Kubernetes cluster for trying out cloud-style deployments. Advanced — you can ignore this unless a project asks for Kubernetes.",
                technical: "Single-node cluster bootstrapped with kubeadm inside a kindest/node-based Apple Container; kubeconfig is written to ~/.kube/config.",
                firstSteps: [
                    "Click Create Cluster and wait for the bootstrap to finish",
                    "Use kubectl as usual against the new context",
                ],
                tip: nil
            )
        case .logs:
            return SectionHelpContent(
                title: "Logs",
                beginner: "Everything your containers have printed, in one scrolling window — like a combined console for all your apps.",
                technical: "Multi-container log aggregation with per-container filtering, pause/resume streaming, and search.",
                firstSteps: [
                    "Pick a container from the list to focus its output",
                    "Use the search field to find errors",
                ],
                tip: nil
            )
        case .networks:
            return SectionHelpContent(
                title: "Networks",
                beginner: "How containers talk to each other. Containers on the same network can reach each other by name — you usually don't need to create networks by hand.",
                technical: "Container network interfaces with assigned IPv4 addresses; each container gets its own isolated network namespace.",
                firstSteps: [
                    "Select a network to see which containers are attached",
                ],
                tip: "Compose creates a dedicated network per project automatically."
            )
        case .volumes:
            return SectionHelpContent(
                title: "Volumes",
                beginner: "Folders that keep their data even after a container is deleted — where databases store their information, for example.",
                technical: "Persistent storage mounts. Volume data lives in the container image store and survives container removal.",
                firstSteps: [
                    "Select a volume to inspect or delete it",
                    "When running a container, map a volume like my-data:/data to keep files",
                ],
                tip: nil
            )
        case .registries:
            return SectionHelpContent(
                title: "Registries",
                beginner: "Sign in to places that host images (like Docker Hub) so you can pull private images or push your own.",
                technical: "Registry credential management stored in the container CLI's auth file; supports Docker Hub, GHCR, ECR, and others.",
                firstSteps: [
                    "Add your Docker Hub account to raise pull limits",
                ],
                tip: nil
            )
        case .terminal:
            return SectionHelpContent(
                title: "Terminal",
                beginner: "A command line with the container tools ready to go — handy if you prefer typing commands or are following a tutorial.",
                technical: "Terminal window with PATH configured for the container CLI and DOCKER_HOST pointed at Keg's socket.",
                firstSteps: [
                    "Try container system status to check the backend",
                    "Try docker ps — Keg answers the Docker CLI too",
                ],
                tip: "DOCKER_HOST is already set, so the docker CLI works out of the box."
            )
        case .ports:
            return SectionHelpContent(
                title: "Ports",
                beginner: "Which of your apps are listening on which web addresses on your Mac — e.g. http://localhost:8080.",
                technical: "Published port mappings across all containers: host port, container port, and the owning container.",
                firstSteps: [
                    "Click a published port to open it in your browser",
                ],
                tip: nil
            )
        case .health:
            return SectionHelpContent(
                title: "Health",
                beginner: "A check-up for your setup: is the container engine healthy, are containers under memory pressure, is anything stuck?",
                technical: "Aggregated health scoring across the API server, per-container memory pressure, and stuck/stopped workloads.",
                firstSteps: [
                    "Aim for a green score; investigate anything flagged",
                ],
                tip: nil
            )
        case .devcontainers:
            return SectionHelpContent(
                title: "Dev Containers",
                beginner: "Open a project inside a container with all its tools preinstalled — the same setup every time, matching a project's own configuration.",
                technical: "Dev Container spec support: builds or pulls the project's devcontainer image and attaches your editor tooling.",
                firstSteps: [
                    "Open a folder that contains a .devcontainer directory",
                ],
                tip: nil
            )
        case .settings:
            return SectionHelpContent(
                title: "Settings",
                beginner: "Keg's preferences: start/stop the container engine, choose your comfort level, and connect integrations.",
                technical: "App-level configuration: container system control, terminal preferences, Docker API socket, and agent integrations.",
                firstSteps: [],
                tip: nil
            )
        }
    }

    static func content(for section: AgentSection) -> SectionHelpContent {
        switch section {
        case .dashboard:
            return SectionHelpContent(
                title: "Dashboard",
                beginner: "An overview of your AI agents: what's running, what needs your approval, and what's finished.",
                technical: "Aggregated agent state: active sessions, pending approval items, and automation status.",
                firstSteps: [],
                tip: nil
            )
        case .useCases:
            return SectionHelpContent(
                title: "Use Cases",
                beginner: "Ready-made agent recipes for common jobs — preview what an agent would do before letting it run.",
                technical: "Library of AgentUseCase definitions with previewable approval flows.",
                firstSteps: [],
                tip: nil
            )
        case .agents:
            return SectionHelpContent(
                title: "Agents",
                beginner: "Create and manage AI agents that can use tools — each with its own model, skills, and permissions.",
                technical: "Agent definitions: model routing, MCP servers, skills, and session management.",
                firstSteps: [],
                tip: nil
            )
        case .sessions:
            return SectionHelpContent(
                title: "Sessions",
                beginner: "Conversations and jobs your agents have run — open one to see the full transcript.",
                technical: "Agent session history with status, transcript, and live context.",
                firstSteps: [],
                tip: nil
            )
        case .sources:
            return SectionHelpContent(
                title: "Sources",
                beginner: "Documents and data your agents can read — connect a source so agents answer from your material.",
                technical: "Knowledge sources and integrations for agent context.",
                firstSteps: [],
                tip: nil
            )
        case .skills:
            return SectionHelpContent(
                title: "Skills",
                beginner: "Reusable abilities you can give an agent, like 'search the web' or 'review this code'.",
                technical: "Skill template registry with installation and assignment to agents.",
                firstSteps: [],
                tip: nil
            )
        }
    }
}
