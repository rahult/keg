# Changelog

## [0.8.0] — 2026-09-22

### Added
- **Cooper runs without Apple Intelligence** — a second brain: any OpenAI-compatible chat-completions server (OpenAI, OpenRouter, Groq, DeepSeek, Mistral, Together, Fireworks, or local Ollama / LM Studio / vLLM). When the on-device model is unavailable — Apple Intelligence turned off, this Mac not eligible, or its model assets still downloading — Cooper automatically switches to the configured remote server; Settings → Cooper → Model backend can also force either path, and the panel header shows which model is answering. Tool calling, permission modes, approval cards, and the repeat-call guard are identical on both paths (the remote model gets every tool at once — no small-model tool subsets).
- **Remote model setup** — provider presets with a one-click server URL, a "List" button that reads the server's model catalog, and the API key stored in the macOS Keychain (never in plain preferences). A "Set Up a Remote Model…" recovery path appears in the Cooper panel when Apple Intelligence is off and nothing is configured yet.
- **Thinking-model support** on the remote path — request-side `reasoning_effort` (low/medium/high, sent only when explicitly chosen since providers reject unsupported values); response-side reasoning is separated from the answer whether the server streams `reasoning_content`/`reasoning` fields or the model inlines `<think>` tags, including tags split across stream chunks. Thinking renders as a collapsible section; "Off" neither requests nor shows it. Provider-specific switches (Qwen `enable_thinking`, temperature, `max_tokens`) go through an Advanced *Extra Request JSON* field merged last into every request.
- Cooper's knowledge base covers its own backends (new `agent_backend` topic), and the guide documents the fallback.

### Fixed
- Remote-path robustness: context-overflow replies retry with a hard-trimmed history that never leaves tool results orphaned from their calls (the message shape providers reject); 429s back off exponentially; 401/404/5xx surface the server's own error message with actionable copy.

## [0.7.1] — 2026-09-21

### Added
- **Boot-kernel setup & repair** — container runtime 1.4+ requires an explicitly registered default boot kernel and refuses to start any new container with "default kernel not configured for architecture arm64" until one exists — exactly where a Homebrew runtime upgrade (`brew upgrade container`) leaves an otherwise healthy install, with nothing but the raw CLI error as a hint. Keg now detects the missing registration and offers a one-click **Install Recommended Kernel** (runs `container system kernel set --recommended --force`, pinned to your data location) in the three places users meet the problem: the Run sheet — before the image pull is wasted, with Run disabled until fixed — the Health panel, and Settings → Apple Containers. **Reinstall** re-fetches the recommended kernel after future runtime upgrades, a raw CLI kernel failure in a run is translated into an actionable message (for the race past the precheck), and Cooper's knowledge base covers the condition.

## [0.7.0] — 2026-09-21

### Added
- **Cooper, the built-in agent** — an on-device agent on Apple's FoundationModels (`SystemLanguageModel.default`): no cloud calls, no account, nothing leaves the machine. Ask "what's running?" or "why did my container fail?", have it pull an image, bring up a Compose stack, or navigate the app ("open the logs view"). The architecture is sized to the on-device model: each turn classifies intent, then runs one specialist session with at most five tools (overview, containers, images, compose, system/k8s); the maintained knowledge base is served on demand via a `keg_docs` tool instead of inflating the context; live state arrives as a compact per-turn snapshot; transcripts trim on overflow with one retry; throttled turns back off exponentially.
- **Cooper permission gate** — Settings → Cooper picks the mode: Explore (look, never touch), Ask (an approval card for every change), Execute (routine actions applied autonomously). Destructive operations — removing containers/images, compose down, stopping the runtime, deleting the cluster — require approval in every mode. The gate suspends inside the tool call and resumes when you answer the card; the 4th identical tool call in a turn is refused with change-your-approach guidance.
- **Cooper conversations persist** on-device at `~/.keg/cooper` and rehydrate on the next launch (stage tracing in `debug.log`). Right-click any container or image → "Ask Cooper About This…" opens the panel with the object preloaded; the toolbar button uses a pure-SwiftUI barrel mark.
- **One instance, one window** — a POSIX pid guard makes a second launch focus the existing app instead of racing it (lowest pid survives); `keg://` deep links always land in the live window, and a stale `/Applications` copy hijacking the scheme is detected.
- **Settings rebuilt into six domain tabs** — Keg, Apple Containers, Docker, Kubernetes, Cooper, About — with host-bounded sliders that save on a debounce, the runtime's per-machine **data location** (app-root) settable through a volume browser with a refuse-to-start preflight, and the container config surface exposed: home mount (ro/rw/none) and builder image as grouped rows.
- **Docker API completions** — `--rm` is honored (AutoRemove), the prune routes work (containers, images, networks, volumes), and `POST /wait` is bounded so a stalled exit delivery falls back instead of hanging `docker run`.
- **Honest lists** — container/image lists carry truth-in-listing subtitles, an All|Running segmented filter with visible counts, and chips that say what they do; volumes can be created from the UI; Compose guards against a stale or missing compose-file path.
- **User guide** — a twelve-page plain-Markdown docs set (`docs/guide/`) covering every app area, linked from the website and in-app help.

### Fixed
- A wedged container runtime is survivable and diagnosable: CLI operations run bounded, the runtime reports `.unresponsive` with backoff instead of hanging the UI, and the Health panel surfaces diagnostics with one-click recovery.
- The Cooper panel's "Open Apple Intelligence Settings" now opens the Siri & Apple Intelligence pane (the old anchor landed on General on macOS 27).

### Known limitations
- Some accepted Docker-API connections never dispatch their first request (the client waits until EOF while an identical fresh connection succeeds) — a `DockerHijackHTTPChannel` pipeline race under investigation; `/wait` itself is bounded, but occasional `docker run` EOFs can still surface.

## [0.6.0] — 2026-09-18

### Added
- **`docker cp`** works end to end — file and directory, in and out, including into-directory semantics — via the `/archive` endpoints (HEAD stat with the base64 `X-Docker-Container-Path-Stat` header, XPC `copyIn`/`copyOut`, tar handling).
- **Restart policies**: `--restart always / unless-stopped / on-failure` persists as a container label; the event bus (now always polling, no `/events` subscriber needed) revives crashed containers with a crash-loop cap; API stop/kill suppresses auto-restart; a startup sweep revives `always` containers daemon-style.
- **Late attach**: API-started containers keep their stdio in a ring-buffered buffer, so `docker attach` on a *running* container replays recent history then streams live. Attach-before-start (`docker run`) uses direct pump wiring. `keg attach [-i]` joins from the companion CLI.
- **Certification suite** (`Scripts/certify-ecosystem.sh`): runs compose stacks and Testcontainers against the socket with tool discovery, and writes the pass matrix to `docs/certification.md`.
- **CI on a real Mac** (`.github/workflows/contract.yml`): the 21-check Docker CLI contract suite on a self-hosted `macos-container-runtime` runner on every push/PR.
- **Homebrew cask** (`Casks/keg.rb`) ready for submission; installs the app and puts `keg` on PATH.

### Fixed
- **The crash class behind months of flakiness — XPC fd double-close**: Apple's `XPCMessage.set(FileHandle)` *closes the descriptor after transfer*. Every stdio fd Keg handed to `createProcess`/`bootstrap` died in-process, and our later closes (or FileHandle deinit) landed on recycled fd numbers — killing CLI pipe reads (NSException) and NIO sockets (EBADF write preconditions) at random. Stdio now transfers dup'ed fds in non-owning FileHandles; our originals close once, at the right time. Verified: 20/20 rapid `docker run` with exact exit codes, 10× exec loop, full contract suite green repeatedly.
- Hijacked-connection writes are serialized on the channel's event loop; error responses to HEAD carry no body (Go client connection poisoning); directory stat mode carries Go's `ModeDir` bit so `docker cp` resolves destinations correctly.

### Known issues
- After heavy kill -9 churn, Apple's runtime vmnet service can wedge machine-wide (`container network create/list` hangs). Fixed by a reboot — a runtime-level issue, tracked for an upstream report if it reproduces.

## [0.5.0] — 2026-09-18

### Added
- **Docker CLI daily-driver parity**: the Docker API socket now backs the full `docker` workflow, verified end-to-end against the real docker CLI (29.x) by `Scripts/docker-cli-contract-test.sh` — all 15 checks green:
  - `docker run` streams stdout/stderr and propagates real exit codes (verified `exit 7` round-trips)
  - `docker exec` works (including `-i` stdin and exit codes) via a from-scratch HTTP connection hijack: Hummingbird has no upgrade support, so Keg runs a custom NIO child channel that answers `101 Switching Protocols` + `Upgrade: tcp` and splices the socket to the container's stdio over XPC
  - `POST /wait` follows the daemon's ≥1.30 contract — headers flush immediately, the JSON body arrives at exit — which the CLI's synchronous ContainerWait handshake requires before it will issue `/start`
  - `docker stats` (XPC-backed CPU/memory/network/pids with pre/post samples for CPU%), `docker events` (poll-differed lifecycle stream that also finally dispatches the webhook manager), `docker volume create/ls/rm`, `docker system df`, `containers prune`, and the classic `POST /build` (tar context, streamed NDJSON output) used by API clients like Testcontainers
  - `docker pull`/`push` stream Docker-format JSON progress mapped from the Apple CLI's plain progress
  - API version negotiation is honest: `HEAD /_ping` (auto-generated) carries `Api-Version`, `OSType`, `Builder-Version`
- **Native advantages made visible**:
  - **Isolation banner** in the container inspector: every container runs in its own microVM with a dedicated kernel — the security property Docker Desktop and OrbStack (shared kernel) can't offer, now stated where operators look.
  - **Memory honesty**: the inspector shows used-vs-limit while running and explains that freed pages stay inside the VM until stop/restart (Apple's runtime doesn't return pages to macOS mid-run) — turning the known limitation into actionable guidance.
  - **x86 images via Rosetta**: the pull sheet picks arm64 (native) or amd64 (Rosetta); `POST /images/create` honors `?platform=`, and create requests carrying `Platform` (e.g. `"linux/amd64"`) pull and run the amd64 variant — verified `uname -m` → `x86_64`.
  - **Real networks**: Docker API network create/delete now provisions actual runtime networks (`container network create` gets its own subnet — verified `keg-net-test → 192.168.65.0/24`), and create requests with a named `HostConfig.NetworkMode` (what compose sends) attach the container to that network via `--network`. In-memory bookkeeping remains only as an error fallback.
- **`keg` companion CLI, installed from the app**: a Foundation-only terminal client for Keg — no docker CLI required. Ships inside Keg.app (`Contents/SharedSupport/bin/keg`) and installs onto PATH with one click from Settings → Keg CLI (or `keg install` itself): first writable of `/usr/local/bin`, `/opt/homebrew/bin`, `~/.keg/bin`, the last with a copyable PATH line. Commands: `status`, `doctor` (pass/fail stack checks with hints), `version`, `env` (DOCKER_HOST exports), `ps [-a]`, `images`, `logs [-f] [-n N]` (stdcopy demuxed, follow until exit), `exec`, `start/stop/restart/rm`, `open [section]` — a `keg://` deep link that focuses the named section in the app (scheme registered in the bundle Info.plist) — and `install`/`uninstall`. Verified round-trip live: install → `keg status` from PATH → uninstall. Built as target `kegcli` (the build dir is case-insensitive; a `keg` artifact would clobber the `Keg` app binary) and symlinked as `keg` on PATH.
- **`keg exec`**: full docker-exec semantics in the companion CLI — the client side of the connection hijack. `keg exec [-i] [-t] [-e K=V]… [-w dir] [-u user] <id> cmd…` streams stdout/stderr live (stdcopy demuxed to the right descriptors), forwards stdin (`-i`, with half-close on EOF), puts the terminal into raw mode for `-t` and sends PTY resizes on window changes, and propagates the command's real exit code. Verified against the running app: multi-frame streams, stderr routing, env/workdir, exit codes, TTY sessions, and clean 404s for unknown containers.
- **Launch at login** (Settings → Docker API) via SMAppService, with socket cleanup on quit — a stale bound socket makes every Docker client hang instead of failing fast.
- New dependencies: NIOHTTPTypesHTTP1 (swift-nio-extras) and ContainerizationOS (containerization 0.42.0, matching apple/container 1.3.1) for the hijack channel and exec resize.

### Fixed
- **Docker API errors now carry proper statuses**: typed Keg errors map to Docker's HTTP semantics (404 for missing containers/images/webhooks, 400 for bad requests) instead of blanket 500s — `keg exec` and the docker CLI both surface real messages now; exec create validates container existence up front.
- **Stale-socket guard hardened**: the launch-time liveness probe before unlinking `~/.keg/docker.sock` now waits 2s instead of 300ms — a slow moment on the owner's side (test hosts, heavy load) can no longer cause a live app's Docker API socket to be unlinked.

### Known limitations
- `docker build` from the docker CLI requires the BuildKit protocol (docker 29 dropped the classic builder client-side); the classic `POST /build` works for API clients. BuildKit session support is future work.
- Attaching to an already-running container (`docker attach`) is unsupported — init-process stdio is fixed at start (same limitation as Apple's own CLI).

## [0.4.0] — 2026-09-17

### Added
- **Compose Topology**: the Compose screen renders an interactive dependency graph of the file's services — nodes show service, image and live state; arrows point at dependencies, reading left to right like request flow. Click a node to trace its edges; right-click for logs, restart, or copy. Derived from the same parsed plan as "What Will Run".
- **Real embedded terminal**: the Terminal section is now a genuine pseudo-terminal (SwiftTerm) running your login shell with full VT100/xterm support — colors, line editing, full-screen apps like vim. `DOCKER_HOST`, `KUBECONFIG` and Homebrew `PATH` are pre-wired; presets type into the live session instead of restarting it.
- **Welcome screen with live sidebar preview**: picking an experience level shows exactly what the sidebar will look like before you commit.
- **Sidebar reoriented per experience level**: Getting Started groups tasks in plain language (My Apps, Essentials); the full operator surface appears at Comfortable/Full Control. New sidebar footer switches levels in place — no Settings trip.
- New dependency: SwiftTerm 1.11.2 (MIT) for the terminal emulator.

### Fixed (0.3.1)
- **Window-resize crash with the container inspector open**: resizing the window with a container selected aborted with `NSGenericException` ("more Update Constraints in Window passes than there are views in the window"). The inspector's Overview tab used an adaptive-column `LazyVGrid` for its stat cards; the column count changed with the proposed width, so the inspector's reported minimum size oscillated during live resizes until AppKit's update-constraints loop guard fired. Replaced with a fixed two-column grid.
- **Stale sidebar system summary**: the "Containers N/N · Images · API latency" row above the sidebar sections fetched metrics once per appearance and never refreshed, so it showed launch-time counts all session. It now polls every 5s (task-cancelled when hidden, sharing the metrics actor's cache with the dashboard).

### Research
- **Craft + Notion Agents analysis for Keg**: completed a two-round research sweep comparing Craft Agents and Notion Agents against Keg's current Agents area.
  - Verified strongest overlap: sources, skills, permission modes, session workflow metadata, automations, and auditability
  - Verified Keg already has usable account/auth, agent CRUD, session list/detail, and local storage primitives for skills/sources
  - Identified biggest gaps: skills/sources persistence wiring, source testing/runtime activation, permission modes, run history, and automation triggers
  - Recommended immediate tranche: finish Sources + Skills, then add permission modes and run logs before any automation or shared/autonomous agent layer
  - Follow-up extension added Open Agents as third comparison target; reinforced long-term recommendation to separate workflow orchestration from execution substrate if Keg later adopts remote/headless agent runs

### Added
- **Agent Area Foundation**: Initial Managed Agents API implementation for Keg
  - Core types: Agent, AgentEnvironment, Session, SessionEvent
  - Agent tools: Toolset, Custom tools, Built-in tools (bash, read, write, edit, glob, grep, web_fetch, web_search)
  - MCP server support
  - Skills configuration
  - Full CRUD API client with proper authentication headers
  - 34 spec tests with 100% coverage

### Files Added
- `Sources/Keg/Agent/Types.swift` - Agent and tool types
- `Sources/Keg/Agent/EnvironmentTypes.swift` - Environment configuration
- `Sources/Keg/Agent/SessionTypes.swift` - Session and event types
- `Sources/Keg/Agent/ManagedAgentsClient.swift` - API client
- `Tests/KegTests/ManagedAgentsSpec.swift` - API specification tests

## Research: Integration Platforms at Scale (2026-04-15)

### Research Completed
- **Topic**: How to enable integrations at scale like Nango.dev
- **Sources**: 6 primary sources verified
- **Output**: `outputs/integration-platforms-at-scale.md`

### Key Findings
- Nango: 700+ APIs, auth abstraction + TypeScript functions [1]
- Supaglue: Best OSS alternative for B2B SaaS (Apache 2.0) [2]
- Airbyte: 300+ connectors for data pipelines [3]
- Self-hosted costs: $80-400/month vs managed $0-1000+/month
