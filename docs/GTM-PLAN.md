# Keg Go-To-Market Plan

Ship an infra app first, build the agents app on top later. Two products, one runtime.

## Context

Keg today bundles two bets under one binary: a Docker Desktop replacement on
Apple's `container` runtime, and a Claude-powered agent framework. That bundle
confuses the pitch. Users who came for `docker ps` bounce when they see the
Claude API key setup. Users who came for AI agents don't trust a runtime
they've never heard of.

The split: **Keg** is the infra app (containers + k8s + compose). **Keg
Agents** is a separate app that depends on Keg and talks to it over the
Docker API socket Keg already publishes. Agents deploy as labeled containers
on Keg. Same mental model as `kubectl` running on top of a cluster.

## Why this order

- Docker Desktop charges $5-21/user/month. On Apple Silicon + macOS 26,
  there's clear unmet demand for a native GUI on top of Apple's `container`
  CLI. Colima + OrbStack don't quite close the gap. Docker Desktop itself has
  license friction and weight.
- Agents are a future bet. The market isn't pulling for "a macOS app to run
  my AI agents" with anywhere near the urgency. Shipping agents first means
  shipping to an empty room.
- The infra app is the trojan horse. Free, open source, native. Get installs,
  build brand, build install base. Agents ships into that base, not into the
  void.

## Product split

### Keg (ship first)

What's in:
- Sidebar: Dashboard, Containers, Compose, Kubernetes, Logs (multi-container),
  Images, Builds, Networks, Volumes, Registries, Terminal, Dev Containers,
  Health, Ports.
- `DockerAPIServer` (the Unix socket that speaks Docker CLI protocol).
- `ContainerBridge`, `ContainerCLI` resolver, `ComposeOrchestrator`.
- Menu bar, Settings (without Claude section), auto-start Docker API.

What ships as: signed + notarized DMG, MIT or Apache 2.0 licensed, free.

### Keg Agents (ship second)

What's in:
- Agent definitions, sessions, use cases, skills, sources.
- Claude API integration, local model bridge, MCP client.
- Third-party integrations (Supaglue, Slack, GitHub, etc.).

What it talks to: the already-running Keg instance via
`DOCKER_HOST=unix:///~/.keg/docker.sock`. Spawns one container per running
agent, tagged `keg.agent.id=<uuid>` so Keg can optionally show a filtered
Agents view later.

What it ships as: separate DMG, separate repo. Depends on Keg being
installed. Price tier: free for 1 agent + community, paid for multi-agent +
Pro features.

### KegCore (shared Swift package)

A third repo, or a `Packages/KegCore` folder inside Keg. Contains:
- `ContainerBridge` API (actor, typed)
- Docker API types (`DockerContainer`, `DockerImage`, etc.)
- `ContainerCLI` resolver
- `ComposeOrchestrator`

Both apps import this. Versioned from day one (`v0.1.0`). This is the
contract agents will depend on. Keep the surface area small.

## What to delete/move from current Keg to ship v1

Move to `keg-agents` repo (create it, copy files over, delete here):
- `Sources/Keg/Agent/` (entire directory: `HybridAgentRunner`,
  `SessionManager`, `MCPClient`, `LocalModelBridge`, `SSEClient`, etc.)
- `Sources/Keg/Agents/` (UI for Agents area)
- `Sources/Keg/Integrations/` (Supaglue container, third-party connectors)
- `Sources/Keg/ViewModels/` files that only drive the agents UI
- `ManagedAgentsClient`, `AgentAuth`, `AgentApprovalItem`, `AgentUseCase`,
  `AgentAutomationService`

Delete from Keg repo:
- `AreaPicker` (there's no Keg/Agents toggle anymore; Keg is only containers)
- `AgentSidebarContent` in `SidebarView.swift`
- `AgentSection` enum from `AppState`, `selectedAgentSection`,
  `activeAgentCount`, `activeSessionCount`, `pendingAgentApprovals`,
  `agentServiceReachability`, `agentAutomationState`
- Claude Agents API section in `SettingsView.swift:142-144` (the whole
  `agentAPISection`, `authenticatedView`, `unauthenticatedView`)
- Agent-related NotificationCenter names

Keep in Keg:
- Everything container/compose/k8s/images/builds/logs related.
- `DockerAPIServer` — this is the integration point for agents later.
- Menu bar, toolbars, dev containers, health dashboard.

## Files at a glance

Delete or move (roughly 30 files):
```
Sources/Keg/Agent/**                          → move to keg-agents
Sources/Keg/Agents/**                         → move to keg-agents
Sources/Keg/Integrations/**                   → move to keg-agents
Sources/Keg/ViewModels/{Session,Agent}*.swift → move to keg-agents
Sources/Keg/Views/Settings/IntegrationSettingsView.swift → move to keg-agents
```

Modify:
```
Sources/Keg/App/AppState.swift        — drop agent state, AreaPicker, agent refresh timer
Sources/Keg/App/KegApp.swift          — drop AgentAreaView routing
Sources/Keg/Views/Sidebar/SidebarView.swift — drop AreaPicker + AgentSidebarContent
Sources/Keg/Views/Settings/SettingsView.swift — drop Claude section
Package.swift                         — drop any agent-only deps (none yet, verify)
```

Add:
```
Packages/KegCore/Package.swift        — new Swift package for shared types
Packages/KegCore/Sources/KegCore/**   — move ContainerBridge, DockerAPI types, CLI, Compose
```

Update `Sources/Keg` to import `KegCore`.

## Ship sequence

### Week 1 — strip + build

Branch: `release/v1-infra-only`

1. Extract `KegCore` into `Packages/KegCore`. Verify both Keg and Keg-CLI (if
   any) compile against it. Don't version it publicly yet.
2. Delete the agent code listed above. Fix the compile errors.
3. Update `AppState` to remove agent properties. Strip `AreaPicker` from the
   sidebar header.
4. Update Settings to be: Container CLI → Container System → Docker API →
   About. No Claude anything.
5. Verify `make install` works, app launches clean, every sidebar entry
   loads.
6. Record a 60-90 second demo: launch → run nginx → open a shell → kubectl
   get nodes → multi-container logs. One screen, no voiceover, loud silence.

### Week 2 — launch

1. Notarize: hardened runtime in `Info.plist`, `codesign --timestamp`,
   `xcrun notarytool submit --wait`, staple. Update Makefile's `sign` target
   to include `--options runtime`.
2. Landing page: single page, one screenshot, one video, one install button.
   Headline: "Docker Desktop for Apple Silicon, native." Subhead: "Built on
   Apple's container runtime. No Rosetta. No Electron. Drop-in compatible
   with `docker` and `docker-compose`."
3. Open source the repo with a clean README (keep agents branch private for
   now).
4. Post to Hacker News ("Show HN: Keg, a native Docker Desktop replacement
   for macOS 26"), Reddit r/macos + r/docker, direct DM 20 builders in your
   network who will actually try it.
5. Watch support channel like a hawk. First 48h of feedback > next 6 months.

### Week 3-4 — stabilize

1. Triage the top 10 issues from launch. Ship 2-3 dot releases.
2. Add minimal telemetry: opt-in crash reports only, no usage tracking. The
   Docker Desktop refugees care about this.
3. Polish the 3 rough surfaces: pulling a big image (progress UI), switching
   between many containers (list virtualization), first-run when
   `/opt/homebrew/bin/container` isn't installed (Settings already handles
   this).

### Week 5+ — start Keg Agents

1. New repo `keg-agents`. Imports `KegCore`.
2. MVP feature: Claude-powered agent that tails logs from another container
   and posts summaries. Proves the deploy model (one container per agent,
   labeled, talks to Keg's Docker API).
3. Ship to the Keg install base with an "Agents" download button on the Keg
   landing page. "New: Keg Agents, now in beta."

## Pricing

**Keg**: free, MIT or Apache 2.0. No paid tier. This is the brand and the
install base. Don't monetize the runtime.

**Keg Agents**:
- Free: 1 active agent, community support, bring your own Claude API key.
- Pro ($15-25/mo): unlimited agents, managed secrets, usage analytics,
  priority support.
- Team (later): shared agent library, org-level audit, SSO.

The money is downstream of installs. Get the installs first.

## Non-obvious angles

- **Security story**: because Keg publishes a Docker API socket, agents don't
  need privileged host access. They talk to Keg over the same socket that
  `docker` CLI uses. "Agents run in sandboxed Apple containers, not as root
  on your Mac." OrbStack can't say this as cleanly.
- **Compose-as-agent-spec**: each agent is a compose project under the hood.
  Users who already know compose can author agents in YAML. Lower learning
  curve than a bespoke DSL.
- **Release cadence**: agents evolves fast. Containers should be boring and
  stable. Splitting the apps lets you ship agents nightly without scaring
  the infra users.

## Verification

Launch v1 success looks like:
- [ ] App builds clean, no warnings above baseline.
- [ ] Sidebar has no "Agents" area or picker.
- [ ] Settings has no Claude section.
- [ ] All sidebar routes load without crash, docker CLI works against Keg's
  published socket.
- [ ] DMG notarized successfully.
- [ ] Landing page live with install button.
- [ ] Show HN post submitted.

Phase 2 (Keg Agents) success:
- [ ] `KegCore` Swift package versioned `v0.1.0` and consumed by both apps.
- [ ] Keg Agents can spawn + inspect + tear down an agent container via
  Docker API.
- [ ] Agent containers appear in Keg's Containers view with a `keg.agent`
  label filter.

## Risks

- **Brand confusion during the cutover**: if existing users have the bundled
  version installed, the split needs a migration note ("Agents are moving to
  a separate app. Install it here."). Ship the split in one major version.
- **Apple `container` churn**: Apple could change the runtime protocol in a
  minor release and break Keg. Mitigate by pinning `container` to 0.11.x and
  vendoring a compat layer for future versions.
- **Docker CLI compat gaps**: tools like `testcontainers`, `lazydocker`,
  `lima` expect specific Docker API endpoints. Test against the top 5 before
  launch, publish a compat matrix on the landing page.
- **Premature agent launch**: don't ship Keg Agents the same week as Keg.
  Let infra users settle in for 4-6 weeks before adding the AI story.

## Out of scope for this plan

- Windows / Linux ports.
- Commercial Keg tier.
- Agent marketplace / skill sharing.
- Multi-user / org features.

## Next action

Approve this split direction, then start Week 1 by creating
`release/v1-infra-only` and pulling the agent code out. First PR touches
`Sources/Keg/Agent/`, `Sources/Keg/Agents/`, `Sources/Keg/Integrations/`,
and the routing + sidebar changes.
