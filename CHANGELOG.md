# Changelog

## [Unreleased]

### Added (0.4.0)
- **Docker CLI daily-driver parity**: the Docker API socket now backs the full `docker` workflow, verified end-to-end against the real docker CLI (29.x) by `Scripts/docker-cli-contract-test.sh` — all 15 checks green:
  - `docker run` streams stdout/stderr and propagates real exit codes (verified `exit 7` round-trips)
  - `docker exec` works (including `-i` stdin and exit codes) via a from-scratch HTTP connection hijack: Hummingbird has no upgrade support, so Keg runs a custom NIO child channel that answers `101 Switching Protocols` + `Upgrade: tcp` and splices the socket to the container's stdio over XPC
  - `POST /wait` follows the daemon's ≥1.30 contract — headers flush immediately, the JSON body arrives at exit — which the CLI's synchronous ContainerWait handshake requires before it will issue `/start`
  - `docker stats` (XPC-backed CPU/memory/network/pids with pre/post samples for CPU%), `docker events` (poll-differed lifecycle stream that also finally dispatches the webhook manager), `docker volume create/ls/rm`, `docker system df`, `containers prune`, and the classic `POST /build` (tar context, streamed NDJSON output) used by API clients like Testcontainers
  - `docker pull`/`push` stream Docker-format JSON progress mapped from the Apple CLI's plain progress
  - API version negotiation is honest: `HEAD /_ping` (auto-generated) carries `Api-Version`, `OSType`, `Builder-Version`
- **Launch at login** (Settings → Docker API) via SMAppService, with socket cleanup on quit — a stale bound socket makes every Docker client hang instead of failing fast.
- **Compose Topology**: the Compose screen renders an interactive dependency graph of the file's services — nodes show service, image and live state; arrows point at dependencies, reading left to right like request flow. Click a node to trace its edges; right-click for logs, restart, or copy. Derived from the same parsed plan as "What Will Run".
- **Real embedded terminal**: the Terminal section is now a genuine pseudo-terminal (SwiftTerm) running your login shell with full VT100/xterm support — colors, line editing, full-screen apps like vim. `DOCKER_HOST`, `KUBECONFIG` and Homebrew `PATH` are pre-wired; presets type into the live session instead of restarting it.
- **Welcome screen with live sidebar preview**: picking an experience level shows exactly what the sidebar will look like before you commit.
- **Sidebar reoriented per experience level**: Getting Started groups tasks in plain language (My Apps, Essentials); the full operator surface appears at Comfortable/Full Control. New sidebar footer switches levels in place — no Settings trip.
- New dependencies: SwiftTerm 1.11.2 (MIT) for the terminal emulator; NIOHTTPTypesHTTP1 (swift-nio-extras) and ContainerizationOS (containerization 0.42.0, matching apple/container 1.3.1) for the hijack channel and exec resize.

### Known limitations (0.4.0)
- `docker build` from the docker CLI requires the BuildKit protocol (docker 29 dropped the classic builder client-side); the classic `POST /build` works for API clients. BuildKit session support is future work.
- Attaching to an already-running container (`docker attach`) is unsupported — init-process stdio is fixed at start (same limitation as Apple's own CLI).
- Networks remain bookkeeping on the Docker API side; all containers share the runtime's NAT (real networks planned).

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
