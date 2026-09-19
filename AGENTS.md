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
| `Sources/Keg/Views/Kubernetes/KubernetesView.swift` | K8s cluster bootstrap (kindest/node + kubeadm) |
| `Sources/Keg/Cooper/` | **Cooper**, the built-in on-device agent (Apple FoundationModels): `CooperController` (turns, transcript, approvals, nudges), `CooperGateway` (all agent-driven operations + permission gate), `CooperContext` (persona + compact state snapshot), `CooperRouter` (intent → specialist tool set), `CooperTools` (Tool conformances) |
| `Sources/Keg/Views/Cooper/CooperPanelView.swift` | Cooper inspector panel: chat, approval cards, nudges, Explore/Ask/Execute picker |

## Cooper (built-in agent)

Cooper is a local agent on Apple's FoundationModels framework (`SystemLanguageModel.default`) — no cloud calls, no bundled models. Architecture is shaped by the on-device model's limits (~3B, 4K/8K context):

- **Hierarchical routing**: each turn first classifies intent (constrained-decode enum, no tools), then runs one specialist session with ≤5 tools from `CooperRouter.tools(for:)`.
- **Domains & tools**: overview (snapshot, navigate, list containers/volumes/networks, prefill Run sheet), containers (control, logs, inspect+stats, `run_container`, `exec_in_container` via `/bin/sh -c`), images (pull/remove/inspect), compose (ps/up/down), system (runtime start/stop/status, `k8s_control` for the kind cluster).
- **Self-knowledge**: static instructions cover every section, the Docker Engine API socket (the `docker` CLI works against it), the `keg` companion CLI + `keg://` deep links, quick starts, runtime quirks (app-root, CLI-stop workaround, `.unresponsive` semantics), and Keg's limits; the per-turn snapshot adds app version, current section/selection, and experience level.
- **Permission gate** (`CooperGateway.authorize`): reads always allowed; mutations refused in Explore, approval-carded in Ask, auto in Execute; **destructive ops (remove container/image, compose down, runtime stop, k8s delete) require approval in every mode**. The gate suspends inside `Tool.call` (the session blocks while awaiting tools) and resumes when the user answers the card.
- **Context budget**: static persona instructions never change (transcript compatibility); live state goes in the per-turn prompt as a compact `CooperSnapshot`; transcripts are trimmed (`CooperController.trimmed`) on overflow and retried once; `GenerationError`/`LanguageModelError` (26/27 respectively) drive backoff on rate-limit and friendly copy on refusals.
- **Repeat-call guard**: the 4th identical tool call in a turn is refused with change-your-approach guidance.
- **Persistence**: `~/.keg/cooper/{transcript.json,messages.json}`; the session rehydrates from the Codable `Transcript` on next launch. Stage tracing in `~/.keg/cooper/debug.log` (`CooperController.debugLog`).
- Sessions are always built via `LanguageModelSession(model: .default, ...)` so an alternative backend (e.g. MLX via the 27-era `LanguageModel` protocol) can be added without re-architecture.
- The dormant cloud-agent stacks (`Sources/Keg/Agent/`, `Sources/Keg/Agents/`) are unrelated and still gated off by `keg.showAgents`; Cooper reuses only `AgentPermissionMode` from AppState.

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
- Kubernetes cluster lifecycle
- Menu bar popover, settings
- Cooper: on-device agent (FoundationModels) in an inspector panel — observe, guide (section navigation), and gated container/image/compose/runtime actions

## Known Limitations

- Apple Container is pre-1.0 — API may change between minor versions
- Memory pages not returned to macOS (partial ballooning support)
- No Docker socket streaming for exec/port-forward yet (stubs)
- K8s is single-node only
- No Intel Mac support (Apple Silicon required)
- No CRI shim yet (K8s uses containerd inside kindest/node)
- The runtime never GCs `snapshots/`: per-image seed blocks (~180 MB–1.4 GB each) of deleted containers/images stay behind forever. After bulk container or image deletion, remove `snapshots/<64-hex>` dirs that no remaining container references (check `containers/*/*.json` for references first)
- `POST /wait` occasionally drops the connection (EOF) instead of returning the exit code when the runtime is contended; `docker run` then warns instead of printing the code. Exit codes propagate reliably on fast runs

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| apple/container | 1.3.1 | ContainerAPIClient, ContainerResource |
| hummingbird | 2.22+ | HTTP server for Docker API |
| Yams | 6.2+ | YAML parsing for Compose |
| Sparkle | 2.10+ | Auto-update feed |
| SwiftTerm | 1.11.2 | Embedded terminal emulator (PTY + VT100) |
