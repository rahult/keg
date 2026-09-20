# Keg — Agent Instructions

## Project Overview

Keg is a native macOS SwiftUI app that wraps Apple's `container` framework (github.com/apple/container v1.3.1) to provide a Docker Desktop–class experience. Target: macOS 26+ (Tahoe), Apple Silicon only.

## Tech Stack

- **Language**: Swift 6.2 (strict concurrency, `.swiftLanguageMode(.v6)`)
- **UI**: SwiftUI (macOS 26+), NavigationSplitView, @Observable
- **Container runtime**: Apple Containerization (ContainerAPIClient + ContainerResource)
- **HTTP server**: Hummingbird 2.x (Docker API compat on Unix socket)
- **YAML parsing**: Yams 5.x (docker-compose.yml)
- **Build**: Swift Package Manager, Makefile for .app bundle

## Architecture

- **One VM per container** via Virtualization.framework — not a shared Linux VM like Docker Desktop
- `ContainerAPIClient` talks to `container-apiserver` (launchd XPC service)
- Most container operations go through `Process()` calling the `container` CLI
- Docker API server runs on `~/.keg/docker.sock` (Hummingbird)
- K8s uses kindest/node image with kubeadm inside a single Apple Container

## Code Conventions

- `@Observable @MainActor final class` for ViewModels
- `async throws` for all container operations via `Process()` + `container` CLI
- SwiftUI `Table` for list views, `.inset(alternatesRowBackgrounds: true)`
- Docker API types in `DockerTypes.swift` use `CodingKeys` matching Docker's PascalCase JSON
- `ContainerBridge` actor translates between Docker API and `container` CLI
- `ComposeOrchestrator` actor handles compose file parsing and execution

## Key Files

| File | Purpose |
|------|---------|
| `Package.swift` | Dependencies + targets: `Keg` app, `kegcli` companion CLI, `KegCLICore` shared library |
| `Sources/Keg/App/AppState.swift` | Global state, system lifecycle, Docker API control, NavigationSection enum |
| `Sources/Keg/App/KegApp.swift` | App entry, single `Window` scene + instance guard, MenuBarExtra, DetailView routing, `keg://` deep links |
| `Sources/Keg/DockerAPI/DockerAPIServer.swift` | Hummingbird HTTP server with Docker Engine API routes |
| `Sources/Keg/DockerAPI/ContainerBridge.swift` | CLI bridge: Docker API → `container` CLI translation |
| `Sources/Keg/DockerAPI/DockerHijackChannel.swift` | NIO 101-upgrade hijack channel for `docker run`/`exec` attach |
| `Sources/KegCLICore/` | Shared logic for the `keg` CLI: unix-socket HTTP client, models, PATH install rules |
| `Sources/KegCLI/` | The `keg` companion CLI (built as `kegcli`, bundled + installed as `keg`) |
| `Sources/Keg/App/KegCLIInstaller.swift` | App-side one-click CLI install (same location rules as `keg install`) |
| `Sources/Keg/Compose/ComposeOrchestrator.swift` | YAML parsing, topological sort, compose lifecycle |
| `Sources/Keg/Apps/` | **Apps store** (one-click self-host installs): `AppCatalog` (schema + loader), `BundledAppCatalog` (12 embedded YAML app definitions), `AppComposeRenderer` (`{{.Placeholder}}` rendering, YAML-safe secret quoting, `PortProbe`), `AppStoreManager` (@MainActor lifecycle: install/update/uninstall/status/auto-start, registry at `~/.keg/apps/registry.json`) |
| `Sources/Keg/Views/Apps/` | Apps section UI: catalog grid + install wizard + per-app detail (`AppsView`, `AppInstallSheet`, `AppDetailView`) |
| `Sources/Keg/Views/Kubernetes/KubernetesView.swift` | K8s cluster bootstrap (kindest/node + kubeadm) |
| `Sources/Keg/Cooper/` | **Cooper**, the built-in on-device agent (Apple FoundationModels): `CooperController` (turns, transcript, approvals, nudges), `CooperGateway` (all agent-driven operations + permission gate), `CooperContext` (persona + compact state snapshot), `CooperRouter` (intent → specialist tool set), `CooperTools` (Tool conformances) |
| `Sources/Keg/Views/Cooper/CooperPanelView.swift` | Cooper inspector panel: chat, approval cards, nudges, Explore/Ask/Execute picker |

## Cooper (built-in agent)

Cooper is a local agent on Apple's FoundationModels framework (`SystemLanguageModel.default`) — no cloud calls, no bundled models. Architecture is shaped by the on-device model's limits (~3B, 4K/8K context):

- **Hierarchical routing**: each turn first classifies intent (constrained-decode enum, no tools), then runs one specialist session with ≤5 tools from `CooperRouter.tools(for:)`.
- **Domains & tools**: overview (snapshot, `keg_docs` internal reference, navigate, list containers, prefill Run sheet), containers (control, logs, inspect+stats, `run_container`, `exec_in_container` via `/bin/sh -c`), images (pull/remove/inspect), compose (ps/up/down + `apps_list`/`app_control` for Apps-section installs), system (runtime start/stop/status, `k8s_control` for the kind cluster).
- **Knowledge base**: `CooperKnowledge.swift` is the maintained source of truth for what Cooper believes about the world (Apple container CLI, Keg architecture, Docker compatibility, Compose support, Apps store, keg CLI, k8s, storage, troubleshooting, quick starts) — served on demand via the `keg_docs` tool instead of inflating the tiny context window. Update it when Keg's behavior changes.
- **Live tool activity**: stream snapshots' transcript entries (macOS 27+) are recomputed into ⚙/✓ chips per tool call (`CooperController.chipLabels` → `Message.toolActivity` → `FlowChipsView`).
- **Prewarm & backoff**: model weights load at attach (`prewarmIfNeeded`), avoiding the observed first-call stall; throttled turns retry with exponential backoff (2s, 6s).
- **Deep links**: right-click a container or image → "Ask Cooper About This…" opens the panel with an object-specific question (`AppState.askCooper`); panel icon is pure SwiftUI vectors (`CooperBadgeIcon`).
- **Self-knowledge**: static instructions cover every section, the Docker Engine API socket (the `docker` CLI works against it), the `keg` companion CLI + `keg://` deep links, quick starts, runtime quirks (app-root, CLI-stop workaround, `.unresponsive` semantics), and Keg's limits; the per-turn snapshot adds app version, current section/selection, and experience level.
- **Permission gate** (`CooperGateway.authorize`): reads always allowed; mutations refused in Explore, approval-carded in Ask, auto in Execute; **destructive ops (remove container/image, compose down, app remove, runtime stop, k8s delete) require approval in every mode**. The gate suspends inside `Tool.call` (the session blocks while awaiting tools) and resumes when the user answers the card.
- **Context budget**: static persona instructions never change (transcript compatibility); live state goes in the per-turn prompt as a compact `CooperSnapshot`; transcripts are trimmed (`CooperController.trimmed`) on overflow and retried once; `GenerationError`/`LanguageModelError` (26/27 respectively) drive backoff on rate-limit and friendly copy on refusals.
- **Repeat-call guard**: the 4th identical tool call in a turn is refused with change-your-approach guidance.
- **Persistence**: `~/.keg/cooper/{transcript.json,messages.json}`; the session rehydrates from the Codable `Transcript` on next launch. Stage tracing in `~/.keg/cooper/debug.log` (`CooperController.debugLog`).
- Sessions are always built via `LanguageModelSession(model: .default, ...)` so an alternative backend (e.g. MLX via the 27-era `LanguageModel` protocol) can be added without re-architecture.
- The dormant cloud-agent stacks (`Sources/Keg/Agent/`, `Sources/Keg/Agents/`) are unrelated and still gated off by `keg.showAgents`; Cooper reuses only `AgentPermissionMode` from AppState.

## Apps Store (one-click self-host installs)

The Apps section (feature branch: curated catalog of open-source apps — Memos, linkding, Uptime Kuma, Vaultwarden, Gitea, Umami, Syncthing, NocoDB, Jellyfin) is a friendly layer over `ComposeOrchestrator`, not a separate engine:

- Each app is a catalog YAML doc (metadata + fields + raw compose template with `{{.Placeholder}}` slots). Bundled definitions live in `BundledAppCatalog.swift`; user catalogs in `~/.keg/apps/catalog/*.yaml` override bundled entries by id. All bundled images are linux/arm64.
- **Bundled apps are deliberately single-service**: apple container 1.3.1 has NO inter-container name resolution (runtime `/etc/hosts` is self-only, no embedded DNS, no `--add-host` — verified live and in vendored `RuntimeService.swift`). Multi-service templates (Miniflux/WordPress/Paperless) are therefore excluded until the runtime resolves peers; do not re-add them referencing a database by name or service alias.
- **Template rules**: whole-value placeholders are written bare (the renderer quotes/escapes them — hostile secret values must round-trip); placeholders *embedded* in template-quoted strings must be plain text (`"`, `\`, newlines are rejected by `validateEmbeddable` — passwords land only in whole-value slots). Reserved values: `KegWebPort`, `KegDataDir`, `KegTimeZone`.
- **Naming contract**: compose project `apps-<id>`; every service declares `container_name: kegapp-<id>-<service>` (prefix enforced by test). Status matching in `AppStoreManager` keys off the same names.
- Data is bind-mounted under `~/.keg/apps/<id>` (or a user-chosen folder), so stop/update/remove keep data; only the detail view's "Remove and Delete Data" erases the data root, and never folders picked from elsewhere.
- Install = render → write `~/.keg/apps/<id>/app.yaml` → pre-pull images pinned `linux/arm64` (1200s bound) → orchestrator `up` detached; a failed install downs its half-started services. Update = re-pull + down + up. "Start when Keg opens" (`autoStart` per installation) recreates apps after the runtime is up; stopping by hand clears it ("unless stopped" semantics).
- Port choice is validated in the wizard and again at install: >1024 and actually free (`PortProbe` binds loopback; note `INADDR_LOOPBACK.bigEndian` — s_addr is network byte order).
- Cooper: `apps_list` (installed apps + container names) and `app_control` (status/start/stop/update/remove; remove is approval-gated and never deletes data), routed into the compose domain; see `CooperKnowledge.appsStore`.
- Tests: `Tests/KegTests/AppsStoreTests.swift` (catalog integrity, adversarial rendering, port probe — needs real socket bind, so run `swift test` unsandboxed).

## Container Runtime Data Location

The runtime's data location (app-root) is **per-machine and configurable**: Settings → Container System → Data Location (`UserDefaults` key `container.app-root`; empty = stock `~/.container`). `AppState.startSystem()` passes `--app-root <path>` when set, preflights that the path exists (a missing volume must surface an error, never spin up an empty runtime), and the Health dashboard shows the location the running apiserver actually reports (from the XPC health check's `appRoot`). This dev machine is configured to **`/Volumes/Atlas/Containers`** — a separate volume holding the user's real containers/images/volumes. Don't "fix" a missing-containers symptom by re-initializing `~/.container`; the data lives at the configured root.

**Never invoke the bare `container` CLI un-anchored on this machine.** The CLI resolves its root from the plist the last `container system start` wrote: an un-anchored `container system start` rewrites the launchd registration to the stock root (`~/Library/Application Support/com.apple.container`) and from then on every CLI-side write (image unpacks, container scaffolding) lands there while XPC operations keep landing on the real apiserver — a silent split-brain that looks exactly like data loss. Always pass `--app-root /Volumes/Atlas/Containers` (or export `CONTAINER_APP_ROOT`); `ContainerCLI.makeProcess` pins this env for all Keg-originated calls.

## Build & Run

```bash
make app          # Build Keg.app
make open         # Build and launch
make test         # Run tests
swift build -c release  # Build binary only
```

## Current Capabilities

- Container CRUD, logs, stats, exec (via container CLI)
- Image pull/push/build/delete/list
- Network and volume management
- Registry login/logout
- Build (Dockerfile via container build, BuildKit)
- Docker API compatibility (socket proxy)
- Docker Compose orchestration
- **Apps store**: curated one-click installs of open-source apps over the compose engine
- Kubernetes cluster lifecycle
- Menu bar popover, settings
- Cooper: on-device agent (FoundationModels) in an inspector panel — observe, guide (section navigation), and gated container/image/compose/app/runtime actions

## Known Limitations

- Apple Container is pre-1.0 — API may change between minor versions
- Memory pages not returned to macOS (partial ballooning support)
- No Docker socket streaming for exec/port-forward yet (stubs)
- K8s is single-node only
- No Intel Mac support (Apple Silicon required)
- No CRI shim yet (K8s uses containerd inside kindest/node)
- The runtime never GCs `snapshots/`: per-image seed blocks (~180 MB–1.4 GB each) of deleted containers/images stay behind forever. After bulk container or image deletion, remove `snapshots/<64-hex>` dirs that no remaining container references (check `containers/*/*.json` for references first)
- **Intermittent request swallow in `DockerHijackHTTPChannel`**: some accepted connections never dispatch their first request to the router (no response, no error — the client hangs until it gives up as EOF), while identical fresh connections succeed. Isolated 2026-09-20: it is NOT the bridge or the runtime (same requests succeed via fresh connections and via the raw CLI); suspicion is `LateHTTPPipelineBuilder`'s buffered pipeline hand-off racing request delivery. `/wait` itself is now bounded (stalled exit delivery falls back instead of hanging), but the channel-level swallow still surfaces as occasional `docker run`/`/wait` EOFs — needs a dedicated pass over the custom channel pipeline

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| apple/container | 1.3.1 | ContainerAPIClient, ContainerResource |
| hummingbird | 2.22+ | HTTP server for Docker API |
| Yams | 6.2+ | YAML parsing for Compose |
| Sparkle | 2.10+ | Auto-update feed |
| SwiftTerm | 1.11.2 | Embedded terminal emulator (PTY + VT100) |
