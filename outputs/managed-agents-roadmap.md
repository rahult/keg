# Keg Managed Agents — Build Roadmap

*Follows `outputs/managed-agents-research-synthesis.md` (landscape + decisions 2026-09-29). Research base: `outputs/managed-agents-research-{anthropic,cursor,meta,exedev,field-infra}.md`.*

## Decisions locked

1. **Continuation = recipe-first recreation** (Cursor-Builds-style): world = git repo + keg.yaml recipe + append-only session event log. No disk checkpoints in v1; the Apple-VM→cloud portability spike is deferred, not cancelled.
2. **Hybrid brain**: Cooper is the default built-in loop; third-party harnesses run inside Keg containers as first-class alternatives — **pi is the first harness** (RPC mode, decided 2026-09-29); Claude Code / OpenHands adapters follow. Keg is the runtime/control plane, not the model vendor.
3. **Rent the substrate**: E2B-class sandbox provider for the cloud landing zone; self-hosting is a later option.
4. **Individual Mac devs first**; avoid IAM/audit decisions that would force a rewrite when teams arrive (Shape C stays a phase-3 option).
5. **Fold, don't supersede**: build on the dormant `Sources/Keg/Agent/` + `Sources/Keg/Agents/` stacks (gated by `keg.showAgents`); Cooper keeps its chat panel and becomes the default brain.

## North-star architecture

```
Keg.app (Mac)                          Cloud (rented substrate, E2B-class)
┌──────────────────────────────┐        ┌──────────────────────────────┐
│ Agent Control Plane          │        │ Agent Landing Zone           │
│ • Session inbox (SwiftUI)    │  push  │ • Sandbox from world recipe  │
│ • Append-only event log      │ ─────► │ • Session log replay/resume  │
│ • Permission gate (Gateway)  │        │ • Secrets via egress proxy   │
│ • Cooper (default brain)     │  pull  │ • Branch/PR back to GitHub   │
│ • Harness containers (BYO)   │ ◄───── │                              │
└──────────────────────────────┘        └──────────────────────────────┘
        │ Apple Container microVMs per agent (local substrate)
```

The load-bearing invariant (from Anthropic Managed Agents' design): **session state is an append-only event log stored outside the brain and outside the sandbox**. Everything continuation-shaped — export, cloud resume, crash recovery, `keg pull` — is a transform over that log + the world recipe. Get this wrong and Cloud Push becomes a rewrite.

## Tranche 0 — Session event log (the enabler) · foundation for everything

*Status 2026-09-29: **done** (plus the SessionStore JSONL compact-encoding fix — pretty-printed event lines silently broke reload). `SessionManager` keeps its existing API; `AgentRunner` owns the write-through-the-log turn flow, so no separate refactor was needed.*

| Task | File | Notes |
|---|---|---|
| `AgentSessionLog`: append-only, Codable events (user msg, tool call/result, approval, checkpoint refs) | `Sources/Keg/Agent/SessionLog.swift` | New. Mirrors Anthropic session/event model; persisted at `~/.keg/agents/sessions/<id>.jsonl` |
| Refactor `SessionManager` to write through the log | `Sources/Keg/Agent/SessionManager.swift`, `SessionTypes.swift` | Transcript becomes a projection of the log, not the source of truth |
| World recipe type: repo URL/commit, keg.yaml doc, env vars, required `keg db` engines | `Sources/Keg/Agent/WorldRecipe.swift` | Serializable; this is what gets pushed |
| Round-trip tests: log → replay → same transcript; recipe → render → same keg.yaml | `Tests/KegTests/AgentSessionLogTests.swift` | Pure logic, no sockets |

**Exit**: a session can be torn down and reconstructed from log + recipe alone (tests prove it).

## Tranche 1 — Local agent runtime (Shape A) · the wedge

*Status 2026-09-29: **done**. Exit criteria met: `AgentService` (session lifecycle + provision + turn) assembled in production on `AppState.agentService`, sharing Cooper's gateway so approval mutations card in the panel; recipe → microVMs proven live; session log renders in the inbox (local sessions list when no cloud client) and detail view (`loadLocalEvents`). Deferred polish: a "start session" UI flow (today the service API is the entry point), live event streaming during a turn (the log is read on refresh; streaming projection is Tranche 4 polish).*

| Task | File | Notes |
|---|---|---|
| Wake `ContainerPool`: per-agent microVM via existing container CLI, warm-pool reuse | `Sources/Keg/Agent/ContainerPool.swift` | Verify cold/warm numbers still hold on this machine |
| Agent container from `WorldRecipe` (keg project engine reuse: build/create/recreate) | `Sources/Keg/Agent/AgentEnvironment.swift` | Delegates to `KegProjectEngine`-style flow; agent containers named `kegagent-<session>` |
| Cooper as default brain over a session (its remote backend already speaks OpenAI-compatible) | `Sources/Keg/Cooper/` (minor) + `Sources/Keg/Agent/Brain.swift` | Brain protocol: `run(logSlice, tools) → events`; Cooper and remote both conform |
| Harness adapter: run **pi** ([earendil-works/pi](https://github.com/earendil-works/pi), MIT) via `pi --mode rpc` as a long-lived subprocess in the agent container, translate its JSONL session events into the append-only log | `Sources/Keg/Agent/HarnessAdapter.swift` | pi is first because its [RPC mode](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md) is a language-independent JSONL protocol (commands in, session events out) with an `agent_settled` idle signal, on-disk session files, and a unified OpenAI/Anthropic/Google provider API. Bonus alignments: `pi-durable` (durable conversation/task/document runtime) matches the Tranche 0 event-log model, and pi's own [containerization docs](https://github.com/earendil-works/pi) (plain Docker, Gondolin micro-VM tool routing, OpenShell) assume exactly the sandboxed-on-Keg posture. Event normalization (run/message/tool/compaction/retry events → log events) is the hard part. Claude Code / OpenHands adapters follow the same `Brain` protocol |
| Un-gate Agents section (default off → visible setting) | `Sources/Keg/App/AppState.swift` (`keg.showAgents`) | Session inbox UI already exists in `Sources/Keg/Agents/Views/` |

**Exit**: create agent → assign a repo → session runs in its own microVM → transcript streams to the inbox; approve a mutation via the existing permission gate.

## Tranche 2 — Artifact handoff (continuation v1)

| Task | File | Notes |
|---|---|---|
| "Push for review": branch commit + draft PR + session-log export bundle | `Sources/Keg/Agent/Handoff.swift` | Exactly what Cursor/Devin ship today; the honest v1 |
| Session export/import: `.kegsession` bundle (log + recipe + diff) | `Sources/Keg/Agent/SessionLog.swift` (extend) | Shareable, archivable; also the payload Tranche 3 transports |

**Exit**: agent work on the Mac lands on GitHub as a reviewable PR with a replayable session attached.

## Tranche 3 — Cloud Push (Shape B) · the differentiator

| Task | File | Notes |
|---|---|---|
| Substrate abstraction: `CloudSandbox` protocol (create from recipe, exec, sleep/wake, destroy, fork later) | `Sources/Keg/Agent/CloudSandbox.swift` | E2B backend first behind the protocol |
| E2B backend (REST; template = repo image + keg.yaml setup; aarch64 availability must be confirmed — see open question) | `Sources/Keg/Agent/CloudSandboxE2B.swift` | If aarch64 unavailable: build x86 world images from the recipe instead of shipping local disk state (recipe-first pays off) |
| Push: serialize log+recipe → create cloud sandbox → replay log → agent resumes in cloud, branch/PR continues there | `Sources/Keg/Agent/CloudPush.swift` | UI: "Continue in Cloud" on a session; menu-bar notification when it needs approval |
| Pull: `keg pull` — replay cloud log slice onto the local session, sync branch down | `Sources/Keg/Agent/CloudPush.swift` | Amp-`sync`-shaped |
| Secrets: egress-proxy pattern (exe.dev/Cloudflare lesson) — credentials never enter the log or model context | `Sources/Keg/Agent/SecretProxy.swift` | Applies locally too; store in Keychain (`CooperKeychain` pattern) |

**Exit**: start a session on the Mac, Continue in Cloud, close the lid; agent finishes, PR opens; `keg pull` merges the session back locally.

## Tranche 4 — Surfaces & polish (ongoing)

- Menu bar: session status, one-tap approvals (Cooper panel patterns reused)
- Event subscriptions (wake on PR comment/CI result — Cursor pattern)
- Team-shaped-but-not-team: shared `.kegsession` bundles, no IAM yet
- Optional portability spike: Apple Container disk → cloud Firecracker boot (unlocks full-disk continuation if recipe-first proves too lossy)

## Pricing shape (decision, not build)

Local runtime bundled with Keg (free/pro tier). Cloud Push metered as credits or per-session-hour (Anthropic's $0.08/hr is the reference), substrate cost passed through with margin. No token metering — Keg sells no models.

## Verification

- Tranche 0: new unit tests + `make test`
- Tranches 1–3: each ends with a live E2E on this machine (`KEG_RUN_*`-style opt-in env flag, matching `CooperRemoteLiveTests` convention) — agent session in a real microVM; Cloud Push against a real E2B sandbox (Hobby tier)
- Post-commit build hook (`githooks/post-commit`) keeps every tranche compiling

## Open questions (revisited)

1. **aarch64 on rented substrates** — E2B/Fly/Daytona arm support must be confirmed before Tranche 3 lands; recipe-first (decision 1) means x86 rebuild-from-recipe is the fallback, but cross-arch image builds have their own wrinkles.
2. ~~First harness~~ — **resolved 2026-09-29: [pi](https://github.com/earendil-works/pi) (earendil-works, MIT)** via RPC mode (rationale in the Tranche 1 table).
3. **Where `keg db` fits** — shared engine containers (`kegdb-postgres`) need an answer for the cloud side (provision alongside the sandbox? switch the recipe to a managed URL?). Defer to Tranche 3 design.
