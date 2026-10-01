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
- The `Sources/Keg/Agent(s)/` stacks are the local agent runtime (Tranche 0–1 of the managed-agents plan, `outputs/managed-agents-roadmap.md`): sessions run on the Mac under Keg's control plane, with cloud continuation planned. The Agents UI section is visible by default since 2026-09-29 (`keg.showAgents false` explicitly hides it); Cooper reuses only `AgentPermissionMode` from AppState.

## Managed Agents (local runtime, Tranche 0–1)

The on-Mac agent runtime behind the Agents section — the local half of the "managed agent service for macOS, continue in cloud" plan (research: `outputs/managed-agents-research-synthesis.md`):

- **Session = append-only event log** (`SessionStore`, `events.jsonl`) + a **world recipe** (`WorldRecipe`: repo ref, raw keg.yaml, non-secret env, database needs). The log is the source of truth; transcripts are projections. This is the invariant that makes export, resume, and (later) cloud push transforms over the log — do not let session state creep back into the brain or the sandbox. JSONL lines must be compact-encoded (the pretty-printed `session.json` encoder silently broke event reload until 2026-09-29).
- **World recipes never carry secrets**: `WorldRecipe.validate()` rejects secret-looking env keys (TOKEN/SECRET/PASSWORD/…); credentials travel via the egress-proxy pattern planned for Tranche 3, never in the recipe.
- **Brains are swappable** (`AgentBrain` protocol → `AsyncThrowingStream<SessionEvent>`): `CooperBrain` (default; wraps `CooperOpenAIBackend.turn` + `CooperRemoteTools.allTools` so the permission gate/approvals apply) and `PiBrain` (pi via `pi --mode rpc`, JSONL per earendil-works/pi docs: LF-only framing, events mapped by `PiRPC`; live E2E `PiBrainLiveTests`, opt-in `KEG_RUN_PI_E2E=1`).
- **AgentRunner** drives a turn: validate recipe → `AgentWorkspace.materialize` (writes keg.yaml to `~/Library/Application Support/Keg/AgentWorkspaces/kegagent-<slug>/`) → append user event → stream brain events into the log. `.kegsession` bundles (log + recipe) export/import via `SessionBundle` — the payload cloud continuation will push.
- **Naming contract**: sessions own `kegagent-<slug>` names (workspace dirs now; containers/sandboxes later). `ContainerPool` executes dangerous commands in warm pooled microVMs through the injected runner — which defaults to `ContainerCLI.run`, so `CONTAINER_APP_ROOT` is pinned per the house rule (the pool's old raw-`Process` path was un-anchored).
- Wired 2026-10-01 (Tranche 1 deferred polish): a "New Session…" flow in the session inbox (Agents → Sessions routes to `SessionInboxView`, which covers the cloud-client path when authenticated and the local log when not) — the sheet (`NewAgentSessionSheet` + pure-logic `AgentSessionDraft`) takes a repo folder (NSOpenPanel) or Git URL, non-secret env vars (rejected by the same `WorldRecipe.isSecretLike` heuristic the validator uses), an editable keg.yaml seeded from `KegProjectScaffold` detection, a brain choice (Auto/Cooper/pi; Auto = Cooper), and an optional first instruction (empty → a neutral orientation prompt), then creates + launches the session through `AgentService` (`createSession` → `runTurn` launched-not-awaited, so approval cards and the detail view stay reachable while the turn runs). Live event streaming during a turn: `SessionStore.updates()` is a continuation-based `AsyncStream<SessionLogUpdate>` (`.event` published after every successful append, `.sessionSaved` after every save), surfaced through `AgentService.updates()`/`loadEvents(forSession:)`; `SessionDetailVM.startLiveUpdates(service:)` subscribes, baseline-loads through the same store, appends each arriving event (skipping ones the baseline already covered), refreshes `sessionStatus`, and ends on terminal status. Tests: `Tests/KegTests/AgentSessionUpdatesTests.swift`. Still next: cloud push transforms (Tranche 3), menu-bar/streaming polish (Tranche 4).
- **Tranche 2 handoff (2026-10-01, live E2E passed)**: `Handoff.swift` — "Push for Review…" commits the session workspace on `keg/<slug>`, pushes, and opens a draft PR via `gh` (gh owns auth; Keg never touches tokens). The `.kegsession` bundle (log + recipe + staged workspace diff + metadata) rides the branch at `.keg/session.kegsession` — not a PR attachment, because `gh pr create` can't attach arbitrary files and the committed bundle is the payload Tranche 3 consumes. The recipe is persisted per session (`recipe.json` sidecar in the session dir, written by `AgentService.runTurn`; nothing else remembered it). Remote resolution: existing workspace origin wins, else the recipe's URL must parse as GitHub owner/repo (`GitHubRemote.parse`). Non-repo workspaces get `git init -b main` (recorded in bundle metadata). Detail-view button disables with an explanation until workspace/recipe/GitHub-remote/gh prerequisites pass; success shows the PR URL with a copy line; failures use the banner overlay with Retry. Tests: `Tests/KegTests/HandoffTests.swift` (scripted-shell flow + pure builders). Live E2E 2026-10-01 (real repo `rahult/keg-agent-e2e`, real gh, Cooper remote over local Ollama): full loop New Session → microVM world → tool-calling turn → completed log → draft PR opened by the app with the bundle on the branch.
- **E2E hardening (2026-10-01, each fix found by the live pass)**: (1) *The Agents area is reachable* — `AreaPicker` was dead code and neither `SidebarView` nor `DetailView` switched on `currentArea`; the picker now tops the sidebar and both columns switch. (2) *Session detail lives in a sheet, not `.inspector`* — a root-level inspector on the split view triggers the macOS 27 "Update Constraints in Window pass" abort (the AppKit bug MainView's comment documents; crash confirmed live in `~/.keg/exceptions.log`). (3) *Session scaffolds publish no ports* — the shared templates' fixed 8080/3000 collided with the Gateway proxy / other session worlds and the runtime fails the whole provision on the bind error; `AgentSessionDraft.strippingPorts` removes `ports:` from session scaffolds (unit-tested; users can re-add by hand). (4) *Remote-repo sessions start as a clone* — `AgentWorkspace.materialize` runs `git clone` when the recipe URL is a remote transport and the workspace is empty, so handoff shares history with the remote default branch (a fresh `git init` produces unrelated histories GitHub refuses to PR).

## Traces (agent-execution trace store, 2026-10-01)

Langfuse/Braintrust-style tracing for the managed-agent runtime, backed by the ClickHouse shared engine:

- **Store**: `Sources/Keg/Traces/TraceStore.swift` — an actor mirroring every session event into `kegtraces.trace_events` (`MergeTree ORDER BY (trace_id, event_index)`; row 0 is a synthetic trace summary, events are 1-based insert-only). Ingest subscribes to `SessionStore.updates()`; backfill imports pre-existing session logs once (skips traces already present). All writes are best-effort — a ClickHouse outage degrades traces, never sessions (failures log to `~/.keg/cooper/debug.log` with a `trace:` prefix). Wired in `AppState.wireTraceStore()`.
- **Wire quirks (verified live)**: ClickHouse HTTP INSERT statements must be **trimmed of trailing whitespace** (ValuesBlockInputFormat rejects a trailing newline after the final `)`) and must actually **close the VALUES paren** — CH reports an unterminated row as a misleading DateTime64 parse error at the last column. String literals need both `'`→`''` and `\`→`\\` (backslash escapes are parsed by default). UInt64 columns come back quoted in `FORMAT JSONEachRow` unless the SELECT carries `SETTINGS output_format_json_quote_64bit_integers = 0`.
- **Viewer**: Agents → Traces (`Sources/Keg/Agents/Views/TracesView.swift`) — searchable table (name/status/events/duration/started, ClickHouse online dot) + sheet-based waterfall detail (user/assistant/tool/tool_result rows with collapsible JSON input/output, per-step timestamps and deltas). Detail is a **sheet, never `.inspector`** (the macOS 27 abort applies to every split view in the app).

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
- **Shared database servers (`keg db`, 2026-09-28)** — postgres + redis verified live E2E (mysql statement-tested; run `keg db ensure mysql` once before relying on it; clickhouse verified live E2E 2026-10-01): the answer to "backend + frontend + db" is one container per *engine*, not per project: `kegdb-postgres`/`kegdb-mysql`/`kegdb-redis`/`kegdb-clickhouse` host many logical databases (`keg db ensure postgres --database <app> --user <role>` is idempotent and prints a loopback `DATABASE_URL` that host-run app code uses). `KegDatabase.swift` (KegCLICore) holds the engines, name/SQL builders, registry (`~/.keg/db/registry.json`), and port planner; `KegCLIDatabase.swift` (KegCLI) wires the subcommands via captured exec (`KegExecCapture` — plain POST `/exec/{id}/start` streams stdcopy over chunked HTTP, no hijack needed). **Data MUST live in a runtime named volume (`kegdb-<engine>-data`): bind mounts refuse chown, which kills the database images' entrypoints** (verified live: postgres `chmod/chown: Operation not permitted` on a bind mount — the same wall as Uptime Kuma). More live-verified postgres quirks baked into the builders: mount the volume at the PARENT dir with `PGDATA` pointing at a subdir (initdb refuses a mount root because of `lost+found`); `psql -c "a; b"` runs both in ONE implicit transaction so `DROP DATABASE` must get its own `-c`; PG 15+ `GRANT ... ON DATABASE` no longer covers the `public` schema — make the per-app role the database OWNER instead. ClickHouse specifics (verified live 2026-10-01): app clients use the **HTTP interface** — 8123 is published, native TCP 9000 is not, and the `DATABASE_URL` is `http://127.0.0.1:<port>/?database=<name>`; admin execs go through `clickhouse-client --query` (`EXISTS DATABASE` prints `1`/`0`, which the shared exists-check already matches); the default user is passwordless so no bootstrap env (`CLICKHOUSE_SKIP_USER_SETUP=1` is REQUIRED in createRequest — without it the image entrypoint rewrites the stock user to localhost-only-in-VM and every Mac-side client gets AUTHENTICATION_FAILED, verified live 2026-10-01); `DROP DATABASE … SYNC` avoids re-create races on the Atomic engine. Port picking must probe-bind first (this Mac runs a native postgres on 5432 — a successful probe bind means FREE, a failed bind means busy; polarity was inverted once). `keg db remove` is the explicit opt-out; a dedicated db in keg.yaml is still available for projects that truly need isolation.
- **Socket client hardening**: `UnixSocketHTTPClient.request` takes a per-call `timeoutSeconds` (interactive default 10s is far too short for inline image pulls and streamed builds; up/create use 1250s, build 1800s), sends large bodies in chunks (a single `send()` drops partial multi-MB writes), and now reports `EAGAIN` as `.timeout` instead of a misleading bad-response.
- **Agent skill**: `keg skill install` writes the bundled `SKILL.md` (frontmatter `name: keg` + the keg.yaml handbook / agent workflow) into `~/.zcode/skills/keg/` + `~/.agents/skills/keg/` (the two conventions this machine's tools scan); `--project` installs repo-locally, `--dir` to one path, `keg skill show` prints it, `keg doctor` reports install state. The skill file is the version-controlled source of truth at `Sources/KegCLICore/Resources/KegSkill/SKILL.md` — edit there, then `keg skill install` refreshes copies. Lookup avoids `Bundle.module` on purpose (its accessor `fatalError`s when the resource bundle wasn't copied — a missing skill must degrade to an error, never crash the CLI). The Makefile copies `Keg_KegCLICore.bundle` next to the bundled CLI so app installs carry it.
- Tests: `Tests/KegTests/KegProjectTests.swift` — pure logic (parse errors, interpolation, dotenv, ordering/cycles, naming contract, create-request wire shape, volume resolution, scaffold detection + template round-trip, skill install round-trip). No sockets needed.


## Gateway (loopback hostnames for apps)

The Gateway gives installed apps memorable addresses (`http://memos.keg:8080`, opt-in `https://memos.keg:8443`) instead of raw ports. Lives in `Sources/Keg/Gateway/` + Settings → Gateway (`GatewaySettingsSection.swift`). Design rules (spike-proven 2026-09-24, `spike/gateway/README.md`):

- **Resolution**: a one-time `/etc/resolver/keg` file (`nameserver 127.0.0.1` + `port 15353`) routes `*.keg` to the in-app DNS responder (`GatewayDNS`). **Keg never runs sudo** — Settings surfaces the exact command with Copy / Open-in-Terminal (house rule: show the command, don't elevate).
- **Ports are load-bearing**: DNS = 15353 (container-apiserver 1.4.1 owns 127.0.0.1:1053 and 2053 — never bind those), HTTP proxy = 8080, TLS = 8443. All loopback-only.
- **Routing**: `GatewayRouteTable` (locked snapshot read from NIO event loops) merges `AppInstallation.webPort` routes (hostname = sanitized `<id>.keg`) with user custom routes from `~/Library/Application Support/keg/gateway/routes.json` (the `~/.keg/gateway` fallback applies only if the Application Support lookup fails); apps win collisions. The proxy relays bytes verbatim after the first request head — WebSockets/SSE need no special handling; route is fixed per connection.
- **TLS is per-hostname, never wildcard**: macOS Security.framework and curl reject `DNS:*.keg` wildcards (`errSSLHostNameMismatch` -9843) even with the CA fully trusted; explicit SANs pass everywhere. `GatewayPKI` keeps a local CA key (P-256) in the login keychain via SecItem, issues one leaf covering all current hostnames (exported to `~/Library/Application Support/keg/gateway/keg-ca.pem` when the user installs trust), and reissues on route changes (context swap in `GatewayTLSContextBox` — live connections keep the old cert). Trust = user-domain `security import … -k login.keychain-db` then `add-trusted-cert -k login.keychain-db -r trustRoot -p ssl`, which pops the mandatory GUI dialog; **macOS 26 regression (verified live 2026-09-29)**: `add-trusted-cert` WITHOUT `-k` exits 0 but silently imports nothing — the cert must be imported into the keychain explicitly, and success is only reported after `find-certificate` confirms it (the Settings UI additionally requires the URLSession probe to pass before showing green). Two CLI traps: `find-certificate` takes the keychain as a POSITIONAL arg (no `-k`; a `-k` there exits 2 and reads as "absent"), and its duplicate/usage errors are localized — so re-installs are gated by a `find-certificate` presence pre-check (exit-code based), never by string-matching stderr. Verify = URLSession probe (CFNetwork = Safari's path). Firefox needs manual import.
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
- **`DockerHijackHTTPChannel` request swallow (improved 2026-09-28, NOT fully solved)**: some accepted connections never dispatch their first request — the client hangs until it gives up as EOF. The original read-complete gate is gone (builder engages on the first buffered part, plus a 2s `channelActive` fallback that logs a warning), but the swallow RECURRED during `keg db` E2E (~3 in ~60 requests, all on `/exec/{id}/start`) — in those cases the request bytes were never read into the pipeline at all, so neither the engage-on-part nor the fallback timer can fire. The reliable mitigation is client-side: `keg db` retries idempotent admin execs and verifies state after lost responses, and the project engine does the same for create/start. A proper fix needs a reproduction against the raw channel (suspect: reads not being issued on some accepts — autoRead/NIOAsyncChannel hand-off); until then, treat unexplained single-request hangs as this bug — the client's retry path should absorb it

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| apple/container | 1.3.1 | ContainerAPIClient, ContainerResource |
| hummingbird | 2.22+ | HTTP server for Docker API |
| Yams | 6.2+ | YAML parsing for Compose |
| Sparkle | 2.10+ | Auto-update feed |
| SwiftTerm | 1.11.2 | Embedded terminal emulator (PTY + VT100) |
