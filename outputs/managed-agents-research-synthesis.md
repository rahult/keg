# Managed Agents Research — Synthesis & Keg Implications

*Compiled 2026-09-29 from five cluster reports (all claims cited there to primary sources): `outputs/managed-agents-research-anthropic.md`, `-cursor.md`, `-meta.md`, `-exedev.md`, `-field-infra.md`. Read those for evidence tables and source lists; this file is the cross-cutting read.*

***

## 1. Comparison table

| Offering                                           | Manages                                                                             | Substrate                                                                                                                        | Control plane                                                                                   | Continuation model                                                                                                    | Pricing posture                                                          | Local component                                                   |
| -------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| **Anthropic Claude Managed Agents** (beta 2026-04) | Agent versions, sessions, vault credentials, budgets, scheduled runs                | Isolated Linux container per session; Anthropic-hosted or **self-hosted sandbox**                                                | Anthropic platform (REST+SSE); harness runs server-side, decoupled from session log and sandbox | Session = append-only event log; resume after crashes via `wake()`; **no local↔cloud process migration**              | Tokens + **$0.08/session-hour** (running time only); hard budget caps    | None required; self-hosted sandbox = "your hardware, their brain" |
| **Claude Code cloud**                              | Cloud sessions, git proxy w/ scoped creds                                           | Per-session isolated Ubuntu VM                                                                                                   | claude.ai                                                                                       | Git branch + transcript; **running processes lost on VM reclaim**; `--cloud` new session / `--teleport` copy-to-local | Included in Pro/Max seats; no VM surcharge                               | CLI/IDE/Desktop (local sessions are user-managed)                 |
| **Cursor Cloud Agents** (ex-Background)            | Builds (env snapshots), secrets, egress policy, signed commits, event subscriptions | One **Firecracker microVM per agent**; alt: your machine via outbound-only worker, or 3rd-party sandboxes (E2B, Daytona, Modal…) | **Always Cursor's cloud — agent loop never runs on your machine, even on self-hosted workers**  | Git branch + draft PR; hibernating VMs; Builds = bootable warm snapshots (disk only)                                  | Included in Pro $20+; metered at model token rate only; Builds free      | IDE/web/iOS/Slack as surfaces; worker executes tools only         |
| **Meta Muse**                                      | Per-user agent, data, credentials, Sentinel approval agent, audit trail             | **One dedicated Secure VM per user** (browser + credential store)                                                                | Meta cloud                                                                                      | Cloud-native: session lives in the VM forever; all clients are thin views. **Nothing ever runs locally**              | Free + $20/$100 tiers (secondary), weekly token quotas                   | None (Mac app reported as action surface only)                    |
| **Meta Business Agent / Enterprise Platform**      | SMB/business agents, integrations                                                   | Meta-hosted                                                                                                                      | Meta                                                                                            | —                                                                                                                     | Free start; enterprise TBD                                               | None                                                              |
| **exe.dev** (Sandbox + Devbox + Shelley)           | VM lifecycle, DNS/TLS, secrets egress proxy, signed API tokens, LLM credits         | Own-bare-metal **KVM VMs**, boot from container images                                                                           | SSH-as-API + HTTPS exec; tokens carry `cmds`/`exp`/`ctx`                                        | **Persistence, not migration**: never hibernated, idle = disk-only billing, CoW `cp` forks a 40 GB disk in <1s        | Flat pools: Personal $15/mo (50 VMs on 2 vCPU/4 GB); $0.05/core-hr usage | None — laptop is a pure client                                    |
| **Devin**                                          | Autonomous engineer, IDE takeover                                                   | Cognition cloud workspace (shell+IDE+browser)                                                                                    | Cognition SaaS                                                                                  | `/handoff` local terminal → cloud; git/PR durable                                                                     | Free / Pro $20 / Max $200 / Teams $80 min                                | Devin CLI/Desktop/Terminal                                        |
| **OpenAI Codex**                                   | Cloud tasks, per-repo envs                                                          | Per-repo isolated cloud environments + OSS local CLI                                                                             | ChatGPT account                                                                                 | Shared auth/history across CLI/web/cloud; PR/diff                                                                     | Bundled in ChatGPT plans + credits; API rates                            | OSS Codex CLI                                                     |
| **GitHub Copilot coding agent**                    | Async tasks on GitHub itself                                                        | **Ephemeral GitHub Actions dev environment**                                                                                     | GitHub platform                                                                                 | PR/commits; 59-min session cap; **also brokers 3rd-party agents** (Claude, Codex)                                     | Pro $10 / Pro+ $39 / Max $100, AI credits $0.01; completions free        | VS Code agent mode, Copilot CLI                                   |
| **Google Jules**                                   | Async tasks                                                                         | Cloud VM per task                                                                                                                | Google                                                                                          | Resumable web sessions → PR; cloud-only                                                                               | Free 15 tasks/day; 100 (Pro) / 300 (Ultra) per day                       | None                                                              |
| **Sourcegraph Amp (Orbs)**                         | Remote machines for agents                                                          | Cloud "orbs": isolated envs that **sleep minutes after finish, wake weeks later with files+services+conversation intact**        | Amp                                                                                             | `amp sync` orb→local checkout; closest peer to sleep/wake-with-state                                                  | Hobby free w/ BYOK/BYO-compute; Individual $20/mo incl. 45k orb-min      | amp CLI/TUI                                                       |
| **Factory Droids**                                 | Cloud "Droid Computers" (Pro+)                                                      | Not disclosed                                                                                                                    | Factory SaaS                                                                                    | Repo/task-shaped                                                                                                      | Pro $20 / Plus $100 / Max $200                                           | Desktop app, CLI, SDK                                             |
| **Replit Agent**                                   | Build→run→deploy, checkpoints                                                       | Cloud IDE + hosting                                                                                                              | Replit                                                                                          | **Effort-priced checkpoints** (1/request) with rollback of files + agent memory + optional DB                         | Core $20/mo + $20 credits; Pro $100 + $100 credits                       | None                                                              |
| **E2B** (substrate)                                | Sandbox lifecycle, templates, pause/fork                                            | **Firecracker microVM per sandbox**, OSS Apache-2.0 runtime                                                                      | E2B cloud or BYOC                                                                               | Boot from memory+disk snapshots; **pause diffs memory+disk to object storage; fork live sandbox up to 100×**          | Pro $150/mo; $0.000014/s/vCPU; 24h sessions                              | n/a                                                               |
| **Cloudflare Sandboxes** (substrate, GA 2026-04)   | Named persistent sandboxes, snapshots, PTY                                          | Containers + Durable Objects at edge                                                                                             | Cloudflare (needs Workers)                                                                      | Sleep/wake on request; disk snapshot + session fork; **memory snapshots promised**; egress credential injection       | Active-CPU pricing on Containers rates                                   | n/a                                                               |
| **Modal / Daytona / Fly / Northflank** (substrate) | Sandbox/VM lifecycle                                                                | gVisor (Modal, unverified) / dedicated-kernel VMs (Daytona) / microVMs (Fly) / K8s (Northflank)                                  | Vendor or BYOC                                                                                  | FS snapshots; Modal **Memory Snapshots** (exact-state restore); Daytona stateful snapshots; Fly DIY                   | $0.016–0.05/vCPU-hr per second, idle-free (Fly stopped ≈ storage only)   | n/a                                                               |

***

## 2. Repeated patterns vs unique bets

**Repeated patterns (the converged shape of the space):**

1. **One isolated VM/microVM per agent** — Firecracker (Cursor, E2B, Fly), KVM (exe.dev), dedicated Secure VM (Meta Muse), per-session containers (Anthropic). Keg's one-microVM-per-container is the same bet; the field has validated it.
2. **The durable artifact is git-shaped.** Branch + PR (+ persisted transcript) is the universal handoff. Nobody's durable state is a live process.
3. **Warm-start environments are the moat layer** — Cursor Builds (commit-pinned, bootable, free), E2B templates, exe.dev container-image boots. Environment prep, not model cleverness, is where products differentiate on UX.
4. **Secrets live outside the model's context** — vault-held creds injected by proxies (Anthropic, Cursor KMS, exe.dev's egress-header proxy, Cloudflare credential injection). exe.dev's "agent makes plain requests, proxy attaches auth" is the cleanest formulation.
5. **Two-layer human-in-the-loop**: a review gate on the artifact (draft PR) plus live takeover surfaces (remote desktop, shared tmux, IDE takeover).
6. **Pricing converges on bundling compute**: cloud agents included in $20/mo tiers, metered only on model tokens (Cursor, Claude Code, Codex, Jules, Devin). Only Anthropic meters session-hours ($0.08), and only Replit meters checkpoints (effort-priced). Sandbox/infra layer is commoditized ($0.016–0.05/vCPU-hr, per second, idle-free).
7. **Event subscriptions let agents sleep and wake** (Cursor timers ≤180d, Slack/GitHub events; Meta "comes back when something changes").

**Unique bets (what one player does that others don't):**

* **Anthropic**: virtualized harness components — session (append-only event log) / harness (brain) / sandbox (hands) as swappable interfaces; claims 60–90% TTFT improvement from the decoupling. The architectural reference for anyone building continuation.

* **Meta**: a **second agent (Sentinel)** as the permission boundary, plus per-user dedicated VMs at consumer scale, plus payments in the loop (one-time-use virtual cards).

* **exe.dev**: anti-hibernation (VMs never quiesce), anti-per-VM pricing (resource pools), SSH-as-API with permission-carrying signed tokens.

* **Amp**: orbs that sleep for weeks at zero cost and wake with full state — the closest thing to "continuation as a product."

* **GitHub**: the control-plane play — broker other vendors' agents, don't just be one.

* **Replit**: checkpoints as the billing primitive.

* **Cloudflare/E2B**: sandbox substrate as a product, including **fork** (clone a live session) — a primitive no agent product exposes to users yet.

***

## 3. The gap: local-first control plane + cloud continuation

**Nobody runs the managed control plane on the user's personal machine.** Cursor's self-hosted machines still run the agent loop in Cursor's cloud; Anthropic's self-hosted sandbox option keeps the harness server-side; exe.dev and Muse are cloud-only. A user's local sessions (Claude Code CLI, Codex CLI, amp CLI) are *user-managed* — no vendor operates agents on your hardware.

**Nobody migrates a running local world to the cloud.** Every handoff is artifact-shaped (git/PR) or session-shaped within one vendor's cloud (pause/resume/fork). `claude --cloud` creates a *new* session; `--teleport` copies down and diverges; Cursor's local→cloud is git-based; Devin's `/handoff` is task-shaped. Even the substrate layer's pause/fork/memory-snapshot primitives are only exposed cloud→cloud. The gap decomposes into two honest claims:

* **Live-process migration: impossible and unclaimed everywhere.** Anthropic explicitly loses running processes on VM reclaim; all "resume" is transcript+filesystem. This is not a Keg differentiator to promise — no one can do it.

* **World-transfer continuation (stop locally → resume in cloud with disk + transcript + session log intact): technically feasible today and unclaimed.** The substrate exists (E2B snapshot-boot, Cloudflare named sandboxes, Fly machines, exe.dev-style persistent VMs). What's missing is a product that owns *both ends*: a local runtime that can serialize its agent world and a cloud landing zone that can boot it. Whoever owns the local control plane is the only one who can offer this — which is exactly Keg's position, because Keg already owns the local execution substrate (Apple Container microVMs) on the only platform (macOS) where the user's real context lives.

***

## 4. Implications for Keg

### 4.1 Asset mapping

| Keg has                                                                        | Maps to                                                                                                  | Precedent                                                       |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| One-microVM-per-container (Apple Container)                                    | The "hands" layer — per-agent isolation, validated by Cursor/E2B/Muse                                    | Anthropic Managed Agents sandbox; Meta Muse Secure VM           |
| Cooper + `CooperGateway` permission gate (Explore/Ask/Execute, approval cards) | Human-in-the-loop + permission boundary                                                                  | Meta Sentinel; Cursor review surfaces                           |
| Cooper remote backend (any OpenAI-compatible provider)                         | Model-agnostic brain — **Keg sells no models**, so it can be the neutral runtime                         | OGX (model-agnostic loop); Amp BYOK                             |
| `keg project` / keg.yaml / CLI skill                                           | Agent workspace definition (repo + services + env) — the portable "world" description                    | Cursor `.cursor/environment.json`; exe.dev container-image boot |
| Apps store + `ComposeOrchestrator`                                             | Databases/services an agent's world needs (`keg db`) — recreation on the cloud side                      | Cursor Builds (env prep as moat)                                |
| Gateway (loopback DNS + TLS)                                                   | Local addressing for agent-run services; the same Host-routing pattern transfers to a cloud landing zone | exe.dev per-VM HTTPS hostnames                                  |
| Docker API compat (`docker` CLI works against Keg)                             | Agent harnesses that expect Docker-shaped environments run locally unchanged                             | —                                                               |
| Menu bar / notification / deep-link surfaces                                   | Mac-native agent surfaces (start, approve, nudge from anywhere)                                          | Cursor's multi-surface follow-ups                               |

**Architecture lesson from Anthropic (adopt verbatim):** session state must be an **append-only event log stored outside the harness and outside the sandbox**. If Keg's agent sessions are (event log + filesystem + environment recipe), then "continue in cloud" reduces to: serialize log + world, boot a matching sandbox in the cloud, replay from the last checkpoint. If session state instead lives in-process (as Cooper's current transcript model partly does), migration is impossible no matter the substrate. **This is the single most important design decision, and it must be made before any continuation feature is built.**

### 4.2 Three candidate product shapes (ranked)

**Shape A — "Keg Agents: local runtime, artifact handoff" (the wedge).**
Agents run as Keg containers on the Mac under a Keg control plane (session inbox à la prior `agent-platform-spec`, permission gate, Mac-native surfaces). Continuation v1 is what the whole field already ships: push branch + open PR + export transcript; cloud side is a thin "resume from PR" that rents any sandbox substrate (E2B/Fly/Cloudflare) or just points the user at GitHub. *Trade-offs: honest, shippable, but differentiation is "local-first + Mac-native + model-agnostic" rather than continuation.*

**Shape B — "Keg Cloud Push: world-transfer continuation" (the bet).**
Same local runtime, but built on the Anthropic-style decoupled session log from day one. "Continue in cloud" = checkpoint the agent's container disk + session log + keg.yaml world recipe → ship to a cloud landing zone (E2B template / Fly Machine / self-hosted Firecracker on a VPS) → resume the loop there → `keg pull` back down (Amp-`sync`-style). The unclaimed whitespace from §3. *Trade-offs: genuinely differentiated, but adds a cloud service to build/operate (or a substrate partnership), and needs Apple-Silicon→cloud VM image compatibility resolved (open question 1). The resume is from checkpoint, not live process — market it as "your agent keeps working", never as migration.*

**Shape C — "Fleet on your hardware" (the expansion).**
Keg as the managed control plane for agents across *the user's own machines and their team's Macs* (self-hosted machines, but with the control plane local-first — the inversion of Cursor), with cloud continuation as overflow. *Trade-offs: team/IAM story, bigger surface, later. C builds on whichever of A/B exists.*

**Recommendation: build A's runtime with B's session architecture** (decoupled event log + world recipe from day one), so Cloud Push lands as a feature, not a rewrite. C is a phase-3 option.

### 4.3 Pricing implication

Keg cannot meter tokens (it sells no models) — so the Cursor lesson applies in reverse: **bundle compute, charge for the plane**. Shape A can be free/included with Keg Pro; cloud continuation (Shape B) is where metered economics live, and the substrate is cheap enough ($0.016–0.05/vCPU-hr, idle-free) to mark up like Anthropic's $0.08/session-hour or sell as credits à la Replit/GitHub.

***

## 5. Decisions (2026-09-29)

Q1–Q4 all answered (a): recipe-first recreation; hybrid brain (Cooper default + third-party harnesses); rent the substrate first (E2B-class); individual Mac devs first, individual-first/team-shaped. Q5 defaulted (unanswered): fold into the existing dormant stacks rather than supersede — `Sources/Keg/Agent/` already contains `ManagedAgentsClient`, `HybridAgentRunner`, `ContainerPool`, `ModelRouter`, `MCPClient`, and Supaglue hooks; Cooper stays as the built-in chat panel and becomes the default brain of the hybrid. See `outputs/managed-agents-roadmap.md` for the resulting build plan.

Original questions, for the record:

1. **VM portability**: can an Apple Container filesystem/boot recipe be replayed on a cloud Firecracker/KVM host (aarch64 availability on E2B/Fly/Daytona, boot compatibility, image conversion)? Needs a spike — it determines whether Shape B is "checkpoint the world" or "recreate the world from keg.yaml" (recipe-only continuation, like Cursor Builds).
2. **Brain**: is the agent loop Cooper (on-device/remote-OpenAI), or does Keg run third-party harnesses (Claude Code, Codex, OpenHands) inside its containers? The latter makes Keg a neutral runtime — closer to exe.dev's agent-agnostic substrate — but competes on convenience, not model.
3. **Cloud landing zone**: rent a substrate (E2B/Fastest-to-integrate), self-host Firecracker on a VPS, or both? Renting first matches "arbitrage the commoditized layer"; self-hosting matches Keg's local-first ethos but is an ops burden.
4. **Who pays**: individual devs (Devin/Cursor price points), or is the fleet/team play (Shape C) the actual business?
5. **Sequencing vs existing roadmap**: does this supersede the dormant `Sources/Keg/Agent(s)/` stacks and the `agent-platform-spec` (Supaglue/llama.cpp) plan, or fold Cooper into it?

