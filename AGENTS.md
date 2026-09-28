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
| `Sources/KegCLICore/` | Shared logic for the `keg` CLI: unix-socket HTTP client, models, PATH install rules, **keg.yaml project config + engine**, **agent skill** (`KegSkill` + `Resources/KegSkill/SKILL.md`) |
| `Sources/KegCLI/` | The `keg` companion CLI (built as `kegcli`, bundled + installed as `keg`) |
| `Sources/Keg/App/KegCLIInstaller.swift` | App-side one-click CLI install (same location rules as `keg install`) |
| `Sources/Keg/Compose/ComposeOrchestrator.swift` | YAML parsing, topological sort, compose lifecycle |
| `Sources/Keg/Apps/` | **Apps store** (one-click self-host installs): `AppCatalog` (schema + loader), `BundledAppCatalog` (12 embedded YAML app definitions), `AppComposeRenderer` (`{{.Placeholder}}` rendering, YAML-safe secret quoting, `PortProbe`), `AppStoreManager` (@MainActor lifecycle: install/update/uninstall/status/auto-start, registry at `~/.keg/apps/registry.json`) |
| `Sources/Keg/Views/Apps/` | Apps section UI: catalog grid + install wizard + per-app detail (`AppsView`, `AppInstallSheet`, `AppDetailView`) |
| `Sources/Keg/Gateway/` | **Gateway** (loopback hostnames): `GatewayDNS` (raw-socket UDP responder), `GatewayProxy` (NIO byte-splice Host-routing proxy, WebSockets pass through), `GatewayController` (@MainActor lifecycle + status), `GatewayRoutes` (table + user routes in Application Support/keg/gateway/routes.json); Settings tab in `Views/Settings/GatewaySettingsSection.swift` |
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
- **Remote backend** (`Sources/Keg/Cooper/Remote/`): when the on-device model is unavailable (Apple Intelligence off / ineligible / not ready) — or the user forces it in Settings → Cooper — turns run against **any OpenAI-compatible chat-completions server** (OpenAI, OpenRouter, Groq, DeepSeek, Ollama, LM Studio, vLLM, …). Config (`CooperRemoteConfig`) lives in `UserDefaults` key `cooper.remote` + `cooper.remote.backend`; the API key in the Keychain (`CooperKeychain`, service `com.keg.cooper`). Backend choice is resolved purely in `CooperBackendResolver.resolve` (auto = on-device first, remote fallback). The remote path: no router pass (a capable model gets all 16 tools as `CooperToolSpec`s with JSON schemas, calling the same `CooperGateway` — the permission gate/approvals/repeat-guard are brain-independent), OpenAI function calling with streamed `tool_calls` fragments (`CooperToolCallAccumulator`), SSE parsing in `CooperOpenAIBackend.turn`, its own persisted history (`~/.keg/cooper/remote-transcript.json`, trimmed by `CooperChatHistory.trimmed` which never leaves tool results without their calls). **Thinking mode**: request-side sends `reasoning_effort` only for explicit low/medium/high (never for off/default — providers 400 on unsupported values); response-side strips reasoning out of the visible reply whether the server streams `reasoning_content`/`reasoning` fields or the model inlines `<think>` tags (`CooperThinkStream` is delta-safe: tags split across chunks are held back and reassembled); thinking renders as a collapsed disclosure in the panel. Provider-specific switches (Qwen `enable_thinking`, temperature, `max_tokens`) go through the Extra Request JSON setting, merged last into every request body. A live E2E of the loop exists (`CooperRemoteLiveTests`, opt-in via `KEG_RUN_COOPER_REMOTE_E2E=1`).
- On-device sessions are always built via `LanguageModelSession(model: .default, ...)`; the remote path is the second brain, not a replacement, and switching backends never mixes the two persisted histories.
- The dormant cloud-agent stacks (`Sources/Keg/Agent/`, `Sources/Keg/Agents/`) are unrelated and still gated off by `keg.showAgents`; Cooper reuses only `AgentPermissionMode` from AppState.

## Apps Store (one-click self-host installs)

The Apps section (feature branch: curated catalog of open-source apps — Memos, linkding, Uptime Kuma, Vaultwarden, Gitea, Umami, Syncthing, NocoDB, Jellyfin) is a friendly layer over `ComposeOrchestrator`, not a separate engine:

- Each app is a catalog YAML doc (metadata + fields + raw compose template with `{{.Placeholder}}` slots). Catalogs merge by id in tiers — bundled (`BundledAppCatalog.swift`, offline fallback) → synced remote registry → user-local `~/.keg/apps/catalog/*.yaml` — later tiers override earlier ones; any tier can retire an app with `hidden: true` (stays resolvable for installed apps, gone from the browse grid). All bundled images are linux/arm64.
- **Bundled apps are deliberately single-service**: apple container 1.3.1 has NO inter-container name resolution (runtime `/etc/hosts` is self-only, no embedded DNS, no `--add-host` — verified live and in vendored `RuntimeService.swift`). Multi-service templates (Miniflux/WordPress/Paperless) are therefore excluded until the runtime resolves peers; do not re-add them referencing a database by name or service alias.
- **Template rules**: whole-value placeholders are written bare (the renderer quotes/escapes them — hostile secret values must round-trip); placeholders *embedded* in template-quoted strings must be plain text (`"`, `\`, newlines are rejected by `validateEmbeddable` — passwords land only in whole-value slots). Reserved values: `KegWebPort`, `KegDataDir`, `KegTimeZone`.
- **Naming contract**: compose project `apps-<id>`; every service declares `container_name: kegapp-<id>-<service>` (prefix enforced by test). Status matching in `AppStoreManager` keys off the same names.
- Data is bind-mounted under `~/.keg/apps/<id>` (or a user-chosen folder), so stop/update/remove keep data; only the detail view's "Remove and Delete Data" erases the data root, and never folders picked from elsewhere.
- Install = render → write `~/.keg/apps/<id>/app.yaml` → pre-pull images pinned `linux/arm64` (1200s bound) → orchestrator `up` detached; a failed install downs its half-started services. Update = re-pull + down + up. "Start when Keg opens" (`autoStart` per installation) recreates apps after the runtime is up; stopping by hand clears it ("unless stopped" semantics).
- Port choice is validated in the wizard and again at install: >1024 and actually free (`PortProbe` binds loopback; note `INADDR_LOOPBACK.bigEndian` — s_addr is network byte order).
- **Runtime fidelity rules (verified live 2026-09-25 against 1.4.1)**: the runtime applies image ENV, but does **not** apply the image's `WorkingDir` to relative entrypoint/cmd paths, and bind mounts **refuse `chown`**. Templates must therefore use absolute-path `entrypoint:`/`command:` overrides where an image needs them (linkding, Uptime Kuma, Umami carry these; audited all nine — the rest are absolute). `ComposeOrchestrator` now supports `entrypoint:` (was ignored), wraps `command:` in a **non-login** `sh -c` (login shell wiped image ENV PATH), drops the `sh` token when `entrypoint` ends in `sh` (argv = [entrypoint] + args), and **recreates** same-name containers during `up` (a crashed container otherwise wedged start/auto-start forever). Uptime Kuma skips its image entrypoint because its `chown` of the bind-mounted data dir is fatal.
- Cooper: `apps_list` (installed apps + container names) and `app_control` (status/start/stop/update/remove; remove is approval-gated and never deletes data), routed into the compose domain; see `CooperKnowledge.appsStore`.
- **Remote registry** (`RemoteCatalog.swift` + `registry/` in the repo): the catalog of record is this repo's `registry/` folder on GitHub — `index.yaml` (version, `updated` stamp, per-app file + sha256) plus `apps/<id>.yaml`; `file:` paths are relative to the index, and pushing to `main` publishes to clients without a release. Base URL defaults to `raw.githubusercontent.com/rahult/keg/main/registry`, overridable via `defaults write dev.rahult.keg apps.catalogURL <url>` (branch URLs for staging; file:// URLs work for offline testing). Sync mirrors the registry into `~/.keg/apps/remote-catalog/` with the cached `index.yaml` as the commit point (a failed sync never leaves a partial catalog); checksums skip unchanged downloads and reject mismatches; entry paths are sanitized against traversal. Refresh is manual (Apps section button), throttled to daily on launch/section-appear. Install records carry `definitionSHA`; when the synced definition's checksum differs, the card shows "Template updated" and **Update re-renders from the new template** with the stored wizard answers (new required fields without defaults are refused with a reinstall hint). See `registry/README.md` for the catalog-maintainer workflow.
- Tests: `Tests/KegTests/AppsStoreTests.swift` (catalog integrity, adversarial rendering, port probe — needs real socket bind, so run `swift test` unsandboxed) and `Tests/KegTests/RemoteCatalogTests.swift` (index parse, sync via URLProtocol stubs + real file:// E2E against `registry/`, checksum/traversal rejection, merge precedence, definition-change detection).

## Keg Projects (`keg.yaml` — container infra for any local repo)

The `keg project` command family turns a `keg.yaml` in any repo into running containers — the CLI-native sibling of the Apps store, aimed at agents (via the skill below) and developers:

- **Config**: `Sources/KegCLICore/KegProject.swift` (schema, Yams parse, `${VAR}`/`${VAR:-default}` interpolation from shell env + repo `.env`, `.env` loader, topological `depends_on` ordering with cycle detection, port/volume validation). `KegProjectScaffold.swift` powers `keg project init` with stack detection (node/python/go/rust/swift/Dockerfile/generic); every scaffold template must parse (test-enforced).
- **Engine**: `KegProjectEngine.swift` — up (build via tarred context → `POST /build` with `.dockerignore` approximation + always-exclude `.git`; create via `POST /containers/create` with long-timeout calls because the server pulls images inline; **recreates same-name containers on every up** — same wedge-avoidance as the compose orchestrator; polls until running and fails with the container's log tail attached), down (reverse order, data always survives), status (also `--json` for agents).
- **Naming contract**: containers `<project>-<service>-1`, labels `com.docker.compose.project`/`com.docker.compose.service`, built image tags `<project>-<service>:local` — identical to ComposeOrchestrator so project containers group in the app's Compose screen. Changing these means breaking that screen.
- **Wire contract**: `KegContainerCreateRequest.make` (tested against the Docker PascalCase JSON keys). The bridge (`ContainerBridge.containerArgs`) gained `--entrypoint` passthrough: apple's `--entrypoint` takes a **single token** (verified in vendored `Parser.swift` — no space-splitting), so extra entrypoint elements are re-attached in front of the command so argv = entrypoint + cmd holds.
- **No inter-container path applies here at all (verified live 2026-09-27)**: no DNS between containers AND published ports listen on the Mac's loopback only — a container cannot reach a peer's published port, not even via `192.168.64.1` (the default vmnet subnet is `192.168.64.1/24` per vendored `AllocationOnlyVmnetNetwork.swift`, but nothing listens for publishes there). `depends_on` is ordering only; the skill tells agents to keep multi-service files to independent services.
- **Socket client hardening**: `UnixSocketHTTPClient.request` takes a per-call `timeoutSeconds` (interactive default 10s is far too short for inline image pulls and streamed builds; up/create use 1250s, build 1800s), sends large bodies in chunks (a single `send()` drops partial multi-MB writes), and now reports `EAGAIN` as `.timeout` instead of a misleading bad-response.
- **Agent skill**: `keg skill install` writes the bundled `SKILL.md` (frontmatter `name: keg` + the keg.yaml handbook / agent workflow) into `~/.zcode/skills/keg/` + `~/.agents/skills/keg/` (the two conventions this machine's tools scan); `--project` installs repo-locally, `--dir` to one path, `keg skill show` prints it, `keg doctor` reports install state. The skill file is the version-controlled source of truth at `Sources/KegCLICore/Resources/KegSkill/SKILL.md` — edit there, then `keg skill install` refreshes copies. Lookup avoids `Bundle.module` on purpose (its accessor `fatalError`s when the resource bundle wasn't copied — a missing skill must degrade to an error, never crash the CLI). The Makefile copies `Keg_KegCLICore.bundle` next to the bundled CLI so app installs carry it.
- Tests: `Tests/KegTests/KegProjectTests.swift` — pure logic (parse errors, interpolation, dotenv, ordering/cycles, naming contract, create-request wire shape, volume resolution, scaffold detection + template round-trip, skill install round-trip). No sockets needed.


## Gateway (loopback hostnames for apps)

The Gateway gives installed apps memorable addresses (`http://memos.keg:8080`, opt-in `https://memos.keg:8443`) instead of raw ports. Lives in `Sources/Keg/Gateway/` + Settings → Gateway (`GatewaySettingsSection.swift`). Design rules (spike-proven 2026-09-24, `spike/gateway/README.md`):

- **Resolution**: a one-time `/etc/resolver/keg` file (`nameserver 127.0.0.1` + `port 15353`) routes `*.keg` to the in-app DNS responder (`GatewayDNS`). **Keg never runs sudo** — Settings surfaces the exact command with Copy / Open-in-Terminal (house rule: show the command, don't elevate).
- **Ports are load-bearing**: DNS = 15353 (container-apiserver 1.4.1 owns 127.0.0.1:1053 and 2053 — never bind those), HTTP proxy = 8080, TLS = 8443. All loopback-only.
- **Routing**: `GatewayRouteTable` (locked snapshot read from NIO event loops) merges `AppInstallation.webPort` routes (hostname = sanitized `<id>.keg`) with user custom routes from `~/Library/Application Support/keg/gateway/routes.json` (the `~/.keg/gateway` fallback applies only if the Application Support lookup fails); apps win collisions. The proxy relays bytes verbatim after the first request head — WebSockets/SSE need no special handling; route is fixed per connection.
- **TLS is per-hostname, never wildcard**: macOS Security.framework and curl reject `DNS:*.keg` wildcards (`errSSLHostNameMismatch` -9843) even with the CA fully trusted; explicit SANs pass everywhere. `GatewayPKI` keeps a local CA key (P-256) in the login keychain via SecItem, issues one leaf covering all current hostnames (exported to `~/Library/Application Support/keg/gateway/keg-ca.pem` when the user installs trust), and reissues on route changes (context swap in `GatewayTLSContextBox` — live connections keep the old cert). Trust = user-domain `security add-trusted-cert -p ssl` which pops the mandatory GUI dialog; verify = URLSession probe (CFNetwork = Safari's path). Firefox needs manual import.
- Port-free 443/80 needs a privileged helper — deliberately out; if ever built it must be a dumb splice daemon with all TLS/logic unprivileged in-app (the TLS listener here already speaks plain HTTP internally, so a 443/80 forwarder is all Phase C would add).
- Cooper: `keg_docs` topic `gateway` (`CooperKnowledge.gateway`).
- Tests: `Tests/KegTests/GatewayTests.swift` — DNS wire protocol, live UDP, routes, proxy relay (GET/404/502/WebSocket), PKI, verified TLS handshake E2E; needs real sockets → `swift test` unsandboxed. Note: editing test files can leave a stale `.xctest` bundle where new tests silently don't run — `rm -rf .build/debug/KegTests.xctest` if a new test "doesn't exist".

## Container Runtime Data Location

The runtime's data location (app-root) is **per-machine and configurable**: Settings → Container System → Data Location (`UserDefaults` key `container.app-root`; empty = stock `~/.container`). `AppState.startSystem()` passes `--app-root <path>` when set, preflights that the path exists (a missing volume must surface an error, never spin up an empty runtime), and the Health dashboard shows the location the running apiserver actually reports (from the XPC health check's `appRoot`). This dev machine is configured to **`/Volumes/Atlas/Containers`** — a separate volume holding the user's real containers/images/volumes. Don't "fix" a missing-containers symptom by re-initializing `~/.container`; the data lives at the configured root.

**Never invoke the bare `container` CLI un-anchored on this machine.** The CLI resolves its root from the plist the last `container system start` wrote: an un-anchored `container system start` rewrites the launchd registration to the stock root (`~/Library/Application Support/com.apple.container`) and from then on every CLI-side write (image unpacks, container scaffolding) lands there while XPC operations keep landing on the real apiserver — a silent split-brain that looks exactly like data loss. Always pass `--app-root /Volumes/Atlas/Containers`. **For `container system start` the argument is required and the env var is NOT enough** (verified 2026-09-23: `CONTAINER_APP_ROOT` env does not reach the launchd registration — the service silently came up at the stock root; only the `--app-root` argument gets baked in). The env var is fine for non-start ops (`ContainerCLI.makeProcess` pins it for all Keg-originated calls, and `startSystem` passes `appRootArguments`).

## Build & Run

```bash
make app          # Build Keg.app
make open         # Build and launch
make test         # Run tests
swift build -c release  # Build binary only
make hooks        # Activate versioned git hooks (core.hooksPath githooks)
```

## Git Hooks

`githooks/post-commit` (active via `make hooks` → `core.hooksPath githooks`, local config per clone) starts a **background** `make app` after every commit — macOS notification on pass/fail, full log at `.git/keg-build.log`, lock-guarded so commit bursts start one build. Skips during rebase/amend chains. Expect the notification a couple of minutes after committing; a failed build means the commit you just made doesn't compile.

## Current Capabilities

- Container CRUD, logs, stats, exec (via container CLI)
- Image pull/push/build/delete/list
- Network and volume management
- Registry login/logout
- Build (Dockerfile via container build, BuildKit)
- Docker API compatibility (socket proxy)
- Docker Compose orchestration
- **Keg projects**: `keg.yaml` in any repo → `keg project up` (CLI-driven container infra; also the agent skill `keg skill install`)
- **Apps store**: curated one-click installs of open-source apps over the compose engine
- **Gateway**: loopback DNS + Host-routing proxy — installed apps answer at `http://<id>.keg:8080` (opt-in, Settings → Gateway)
- Kubernetes cluster lifecycle
- Menu bar popover, settings
- Cooper: agent in an inspector panel — on-device via FoundationModels, with an OpenAI-compatible fallback (any provider) for Macs where Apple Intelligence is off; observe, guide (section navigation), and gated container/image/compose/app/runtime actions
- Boot-kernel setup: detects an unregistered default kernel (container runtime 1.4+ refuses to start containers without one — typical after a Homebrew upgrade) and **auto-repairs it once per session** (`container system kernel set --recommended --force`, triggered from `checkBootKernel` and after `startSystem`); Run sheet, Health panel, and Settings → Apple Containers keep manual repair buttons for retries (`BootKernel.swift`, `BootKernelStatusViews.swift`)

## Known Limitations

- Apple Container is pre-1.0 — API may change between minor versions
- Memory pages not returned to macOS (partial ballooning support)
- No Docker socket streaming for exec/port-forward yet (stubs)
- K8s is single-node only
- No Intel Mac support (Apple Silicon required)
- No CRI shim yet (K8s uses containerd inside kindest/node)
- The runtime never GCs `snapshots/`: per-image seed blocks (~180 MB–1.4 GB each) of deleted containers/images stay behind forever. After bulk container or image deletion, remove `snapshots/<64-hex>` dirs that no remaining container references (check `containers/*/*.json` for references first)
- **`DockerHijackHTTPChannel` request swallow (fixed 2026-09-28, watch for recurrence)**: some accepted connections never dispatched their first request — the client hung until it gave up as EOF. Root cause: `LateHTTPPipelineBuilder` gated its pipeline build on `channelReadComplete`; when that event was lost the connection sat buffered forever. The builder now engages on the first buffered part, and a 2s `channelActive` fallback forces the build (with a warning log) if parts arrived without any completion event. If occasional `docker run`/`/wait` EOFs resurface, the fallback's warning in the logs is the tell

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| apple/container | 1.3.1 | ContainerAPIClient, ContainerResource |
| hummingbird | 2.22+ | HTTP server for Docker API |
| Yams | 6.2+ | YAML parsing for Compose |
| Sparkle | 2.10+ | Auto-update feed |
| SwiftTerm | 1.11.2 | Embedded terminal emulator (PTY + VT100) |
