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
        case kegCLI
        case kubernetesCluster
        case runtimeStorage
        case troubleshooting
        case quickStarts
    }

    static func text(for topic: Topic) -> String {
        switch topic {
        case .appleContainerCLI: return appleContainerCLI
        case .kegArchitecture: return kegArchitecture
        case .dockerCompatibility: return dockerCompatibility
        case .composeSupport: return composeSupport
        case .kegCLI: return kegCLI
        case .kubernetesCluster: return kubernetesCluster
        case .runtimeStorage: return runtimeStorage
        case .troubleshooting: return troubleshooting
        case .quickStarts: return quickStarts
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
      upgrade. Keg detects this and offers a one-click install
      (Run sheet banner, Health panel, Settings → Apple Containers).
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
    - Sections: Dashboard, Containers, Images, Builds, Compose, Terminal,
      Ports, Networks, Volumes, Registries, Health, Dev Containers,
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
    - `keg env` prints DOCKER_HOST for full docker CLI workflows;
      `keg version`, `keg uninstall`.
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
}
