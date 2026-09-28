import Foundation
import FoundationModels

/// Cooper's maintained internal knowledge base — curated, factual docs
/// about Apple's container framework, Keg itself, Docker compatibility,
/// Compose support, and the `keg` companion CLI.
///
/// Deliberately NOT part of the static instructions: the on-device context
/// window is small, so this corpus is served on demand through the
/// `keg_docs` tool (one topic per lookup). When Keg's behavior changes,
/// update the relevant entry here — this file is the source of truth for
/// what Cooper believes about the world.
enum CooperKnowledge {
    @Generable(description: "A Keg documentation topic")
    enum Topic: String, CaseIterable, Sendable {
        case appleContainerCLI
        case kegArchitecture
        case dockerCompatibility
        case composeSupport
        case appsStore
        case gateway
        case kegCLI
        case kegProjects
        case kubernetesCluster
        case runtimeStorage
        case troubleshooting
        case quickStarts
        case agentBackend
    }

    static func text(for topic: Topic) -> String {
        switch topic {
        case .appleContainerCLI: return appleContainerCLI
        case .kegArchitecture: return kegArchitecture
        case .dockerCompatibility: return dockerCompatibility
        case .composeSupport: return composeSupport
        case .appsStore: return appsStore
        case .gateway: return gateway
        case .kegCLI: return kegCLI
        case .kegProjects: return kegProjects
        case .kubernetesCluster: return kubernetesCluster
        case .runtimeStorage: return runtimeStorage
        case .troubleshooting: return troubleshooting
        case .quickStarts: return quickStarts
        case .agentBackend: return agentBackend
        }
    }

    static let index = """
    Available topics: \(Topic.allCases.map(\.rawValue).joined(separator: ", "))
    """

    // MARK: - Entries

    private static let appleContainerCLI = """
    APPLE CONTAINER CLI (what Keg drives underneath)
    - `container system start|stop` — boots/shuts the launchd-hosted
      container runtime (container-apiserver). Keg always passes
      `--app-root <path>` on start; a bare `container system start` in a
      terminal re-registers the runtime at ~/.container and silently
      splits the data root. Never advise running it without the flag.
    - `container run [-d] [--name n] [-p host:ctr] [-e K=V] <image>` —
      images are OCI; Apple Silicon runs linux/arm64 natively, amd64 via
      Rosetta (`--platform linux/amd64`).
    - `container exec <id> <cmd>` — run a command in a running container;
      Keg wraps commands in `/bin/sh -c` for pipes.
    - `container logs -n <tail> <id>`, `container ls` (list),
      `container images pull|push|build|tag|rm|prune`,
      `container network|volume` subcommands.
    - Containers are immutable: "restart" is stop then start; editing
      means recreate (Keg's Edit & Recreate).
    - Stopping a container must go through the CLI — the HTTP API's stop
      is broken against CLI >= 1.3 (Keg works around this).
    - Boot kernel: runtime 1.4+ requires an explicitly registered default
      kernel (`container system kernel set --recommended --force`);
      until then every run fails with "default kernel not configured for
      architecture arm64" — typical right after a Homebrew runtime
      upgrade. Keg detects this and auto-installs the recommended kernel
      once per session; the Run sheet banner, Health panel, and
      Settings → Apple Containers keep manual repair buttons for retries.
    """

    private static let kegArchitecture = """
    KEG ARCHITECTURE
    - Native SwiftUI app (macOS 26+, Apple Silicon), one instance ever.
    - Serves the Docker Engine API on a unix socket: /var/run/docker.sock
      (fallback ~/.keg/docker.sock). The socket path appears in Cooper's
      runtime line. Auto-starts with the runtime.
    - Talks to Apple's container runtime via its XPC API where possible
      and the `container` CLI (bounded timeouts, SIGTERM->SIGKILL) where
      the API is broken or missing.
    - Compose is orchestrated natively (parse -> plan -> topological
      up/down), not via docker-compose.
    - Sections: Dashboard, Apps, Containers, Images, Builds, Compose,
      Terminal, Ports, Networks, Volumes, Registries, Health, Dev Containers,
      Kubernetes, Logs, Settings. Deep links: keg://<section>.
    - Menu bar popover mirrors status; Settings holds experience level,
      data location (app-root), CLI install, and updates (Sparkle).
    """

    private static let dockerCompatibility = """
    DOCKER COMPATIBILITY
    - The `docker` CLI works against Keg's socket out of the box for the
      common workflows: ps/run/exec/logs/images/build/compose-style
      operations all reach the same containers Cooper manages.
    - `keg env` prints the DOCKER_HOST line if a shell needs it; the
      Terminal section presets already set it.
    - Known gaps: streaming exec attach and live port-forwarding are not
      implemented; `docker wait` occasionally drops the connection under
      load (exit codes still propagate on fast runs).
    - Docker labels: compose projects carry
      com.docker.compose.project / .service labels, so docker-filtered
      views and Keg's Compose section agree.
    """

    private static let composeSupport = """
    COMPOSE SUPPORT (native, in-app)
    - Supports the common compose file: image, build, command, env,
    ports, volumes, depends_on, healthcheck, deploy resources; custom
    networks and volumes.
    - Containers are named <project>-<service>-1 unless container_name is
      set, and labeled with com.docker.compose.project / .service.
    - Lifecycle: Plan (dry-run preview with per-service warnings),
      Up (topological order, detached), Down (reverse order, best-effort
      network/volume cleanup), Restart one service, PS, Logs (tail 200).
    - The configured compose file and project name live in the Compose
      section; Cooper's compose tools operate on that same configuration.
    - Build failures on DNS hiccups trigger one automatic builder reset
      and retry.
    - The Apps section is built on the same orchestrator: each installed
      app is a managed compose project, so installs also appear in
      Containers and answer the Docker API.
    """

    private static let appsStore = """
    APPS SECTION (one-click installs of open-source apps)
    - A curated catalog (Memos, linkding, Uptime Kuma, Vaultwarden, Gitea,
      Umami, Syncthing, NocoDB, Jellyfin) synced from the maintainer's
      GitHub registry, with the bundled definitions as offline fallback.
      Users can add their own app definitions in ~/.keg/apps/catalog.
      All bundled apps are linux/arm64 images and deliberately
      single-service: apple container 1.3.1 has no inter-container name
      resolution, so multi-service templates (a web app plus its database)
      cannot work yet.
    - The Apps section has a Refresh Registry button; the registry also
      syncs itself about once a day. When a sync changes an installed
      app's template, its card shows "Template updated" and Update
      re-creates it with the user's settings kept. A "hidden" registry
      entry retires an app from the browse grid without breaking installs.
    - Installing renders the app's compose template with the wizard's
      answers into ~/.keg/apps/<id>/app.yaml, pre-pulls images pinned to
      linux/arm64, and brings the services up detached.
    - Naming: compose project apps-<id>; containers are named
      kegapp-<id>-<service> (templates set container_name explicitly).
    - Data lives in bind mounts under ~/.keg/apps/<id> (or a folder the
      user chose), so Start/Stop/Update keep data; Update re-pulls images
      and recreates containers. Removing keeps data unless the user opts
      to delete the folder in the app's detail view.
    - Statuses: Running / Partial / Stopped, refreshed from one container
      listing. "Start when Keg opens" recreates the app after the runtime
      is up; stopping by hand turns that off ("unless stopped").
    - Cooper tools: apps_list (installed apps + container names) and
      app_control (status/start/stop/update/remove; remove needs approval
      and never deletes data). To debug a broken app, list it, then read
      the failing service's container logs.
    """

    private static let gateway = """
    GATEWAY (memorable app hostnames, http://<name>.keg)
    - A loopback DNS responder plus a Host-routing proxy inside Keg:
      installed apps answer at http://<id>.keg:8080 (e.g. memos.keg), so
      nobody has to remember ports. Entirely local — only this Mac can
      reach those names.
    - One-time root step, surfaced by Keg but never run by it: a
      /etc/resolver/keg file routes *.keg DNS queries to Keg's responder
      (port 15353; container-apiserver owns 1053/2053). Settings →
      Gateway shows the exact command with Copy / Open in Terminal.
    - The proxy (127.0.0.1:8080) routes by Host header to each app's
      published port; WebSockets and streaming pass through. The app
      cards show memos.keg:8080 style addresses when the gateway is on;
      direct 127.0.0.1:<port> keeps working as a fallback.
    - Setup checks: gateway enabled (Settings → Gateway), the resolver
      file present, and the proxy running. When names don't resolve,
      the resolver file is the usual missing piece; when they resolve
      but hang, the app or the proxy is down — check the app first.
    - Custom <name>.keg → localhost:port routes for development live in
      the same Settings tab; an app with the same name wins.
    - HTTPS opt-in (Settings → Gateway): Keg issues per-app certificates
      from a local CA (key stays in the login keychain) and serves
      https://<id>.keg:8443. Trusting the CA needs one system dialog.
      Wildcards are impossible by design — macOS rejects *.keg
      wildcard certs even when trusted.
    - Port-free 443/80 (no :8443/:8080 suffix) is future work; it needs
      a privileged helper for the privileged ports.
    """

    private static let kegCLI = """
    KEG COMPANION CLI (`keg`)
    - Install from Keg's Settings (or `keg install`); puts `keg` on PATH.
    - Container ops (speak Keg's socket directly, no docker CLI needed):
      ps, images, logs <ctr>, exec <ctr> <cmd>, attach <ctr>,
      start|stop|restart|rm <ctr>.
    - App control: open [section] — sections: containers, images,
      compose, kubernetes, networks, volumes, logs, terminal, dashboard,
      settings; keg://<section> deep links do the same from anywhere.
    - Repo infra: keg project up|down|status|logs|validate|init — driven
      by a keg.yaml in the repo (topic: kegProjects). `keg up` and
      `keg down` are short aliases.
    - Agent skill: `keg skill install` teaches coding agents the whole
      workflow; `keg skill show` prints the same handbook.
    - `keg env` prints DOCKER_HOST for full docker CLI workflows;
      `keg version`, `keg uninstall`.
    """

    private static let kegProjects = """
    KEG PROJECTS (keg.yaml — container infra for any repo)
    - A keg.yaml in a repo root declares services; `keg project up`
      (alias `keg up`) builds or pulls each one and starts them in
      depends_on order. `keg project down` stops and removes them
      (data in bind mounts and named volumes always survives).
    - Service fields: image OR build (context dir, optional dockerfile
      and args), ports "host:container" (host port must be >1024),
      environment (KEY=value with ${VAR} / ${VAR:-default} from your
      shell or the repo's .env), env_file, volumes ("./dir:/path" binds,
      "name:/path" named volumes), command, entrypoint, workdir,
      platform (linux/arm64 default), restart, depends_on, labels.
    - Containers are named <project>-<service>-1 with
      com.docker.compose.project labels, so they show grouped under the
      project name in the Compose screen.
    - No inter-container DNS (same as everywhere in Keg), and published
      ports listen on the Mac's loopback only — containers cannot reach
      other containers' published ports (verified 2026-09-27). depends_on
      is start ordering only; published ports are for tools on the Mac at
      127.0.0.1:<hostPort>. Keep multi-service projects to independent
      services, not server+database stacks.
    - `keg project validate` checks the file cold; `keg project status
      --json` is machine-readable; `keg project logs <service> [-f]`
      tails a service. If a container dies at startup, `up` fails with
      its log tail attached — read it before re-running.
    - `keg project init` scaffolds a keg.yaml pre-detected for
      node/python/go/rust/swift/Dockerfile repos.
    """

    private static let kubernetesCluster = """
    KUBERNETES IN KEG (single-node kind)
    - The cluster is one container named keg-k8s running kindest/node
      (kubeadm inside), 8 GB RAM / 4 CPUs, API server published on
      127.0.0.1:6443, kubeconfig written to ~/.keg/kubeconfig.
    - Lifecycle: create (several minutes: image pull + kubeadm init +
      CNI), start, stop, delete (destructive: container and kubeconfig
      are removed). Statuses surface in the Kubernetes section and via
      Cooper's k8s_control tool.
    - Workloads run with containerd inside keg-k8s (no CRI shim into the
      host runtime); use kubectl with the kubeconfig above.
    - Single-node only; multi-node and ingress are not supported.
    """

    private static let runtimeStorage = """
    RUNTIME DATA & STORAGE
    - The data root (app-root) is configurable in Settings; it holds
      containers, images, volumes, and build state. The effective path is
      shown in the runtime line of Cooper's snapshot.
    - A missing data volume must surface as an error, never silently
      re-initialized at ~/.container.
    - The runtime never garbage-collects build snapshots: after bulk
      container or image deletion, orphaned snapshot blocks (hundreds of
      MB to GBs each) can remain under <app-root>/snapshots/<64-hex>.
      Removing those requires checking container references first.
    - Disk usage per image (blobs + unpacked snapshot) is what the Images
      section and `container system df` report.
    """

    private static let troubleshooting = """
    TROUBLESHOOTING THE RUNTIME
    - "unresponsive" = services alive but not answering within bounds;
      "stopped" = not running. Different remedies.
    - Unresponsive: use Retry on the banner; then Restart Services; then
      Copy Diagnostics (CLI call history + health). A reboot is the
      proven last resort when the apiserver wedges in kernel calls.
    - Containers stuck "Loading": the same wedge; lists stay empty until
      it recovers.
    - Image pull failures: check registry auth (Registries section,
      docker login) and network; builder DNS failures self-heal with one
      retry after a builder reset.
    - Exit codes: reliable on fast runs; `docker wait` can EOF under
      contention.
    - Cooper's tools time out well before the UI would freeze; if a tool
      reports a timeout, the runtime itself is the suspect.
    """

    private static let quickStarts = """
    QUICK STARTS (Containers screen)
    - "Try a 5-second demo": tiny alpine run that prints and exits —
      safe first run, needs a pull.
    - "Run a web server": nginx with a published port; open the printed
      URL after start.
    - "Run something else…": custom image field. Cooper can prefill this
      form via open_run_sheet; nothing runs until the user submits.
    - All quick starts pin the native arm64 platform.
    """

    private static let agentBackend = """
    COOPER'S MODEL BACKEND
    - Two brains, one agent. Preferred: Apple's on-device FoundationModels
      model. Fallback (or user-forced): any OpenAI-compatible
      chat-completions server — OpenAI, OpenRouter, Groq, DeepSeek,
      Mistral, Together, Fireworks, or local Ollama / LM Studio / vLLM.
    - Selection is in Settings → Cooper → Model backend: On-device,
      Automatic (on-device first, remote fallback), or Remote server.
      When the panel header shows a model name, the remote path is live.
    - Setup: pick a provider preset, fill the server URL and model
      (the "List" button reads the server's model catalog), paste an API
      key if the provider needs one. The key is stored in the macOS
      Keychain, never in plain preferences. Local servers need no key.
    - Remote-path thinking: Settings → Cooper → Thinking picks low/
      medium/high reasoning effort, or Off to not request and not show
      thinking. Thinking renders as a collapsible section and never
      leaks into the reply. Provider-specific switches (e.g. Qwen
      enable_thinking, temperature, max_tokens) go in Advanced →
      Extra Request JSON, merged last into every request.
    - Privacy: on-device requests never leave the Mac; remote requests
      go only to the configured server (a local Ollama keeps everything
      on this machine). Approvals and permission modes apply on both
      paths identically.
    """
}
