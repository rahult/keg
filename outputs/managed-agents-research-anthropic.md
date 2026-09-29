# Managed Agents Research — Anthropic

## Scope

Covered: Claude Code on the web (cloud sessions), Claude Code GitHub Actions, the Claude Agent SDK and its relationship to the Messages API, Claude Managed Agents (Anthropic's literal "managed agents" product, public beta since 2026-04-08), session/checkpoint mechanics across surfaces, and pricing for each. Deliberately skipped: Claude Cowork, Claude Code in Slack / Claude Tag, Code Review, Enterprise admin/SCIM details, third-party cloud-provider routing (Bedrock / Vertex / Foundry) beyond what the primary docs state, and anything about model capability. All facts below were verified against vendor primary sources on 2026-09-29; training-data memory was used only to pick search terms.

## Key Findings

1. **Anthropic does ship a product literally named "managed agents": Claude Managed Agents, public beta since April 8, 2026.** It is "a suite of composable APIs for building and deploying cloud-hosted agents at scale" — an Anthropic-managed agent harness plus production infrastructure for state, memory, permissions, and scheduled execution. You define the agent's tasks/tools/guardrails; Anthropic runs it on its infrastructure. ([launch blog](https://claude.com/blog/claude-managed-agents))
2. **The architecture is explicitly "virtualized harness components": session, harness, sandbox as swappable interfaces.** The session is an append-only event log stored *outside* the harness and sandbox; the harness (brain) calls the sandbox (hands) via `execute(name, input) → string`; a crashed harness resumes via `wake(sessionId)` + `getSession(id)`; a crashed sandbox is re-provisioned with `provision({resources})`. Credentials live in a vault outside the sandbox, injected by a proxy (git tokens wired into the sandbox's git remote; MCP OAuth tokens fetched by a dedicated proxy). Anthropic reports this decoupling cut session p50 time-to-first-token ~60% and p95 >90%. ([engineering blog](https://www.anthropic.com/engineering/managed-agents))
3. **The Managed Agents API surface is Agent / Environment / Session / Events.** Agents are versioned resources (model, system prompt, tools, MCP servers, skills); Environments define where sessions run (Anthropic-managed cloud sandbox, or a self-hosted sandbox on your own infrastructure); Sessions are running agent instances with server-side persisted event history, steerable/interruptible mid-execution via SSE; the beta header is `managed-agents-2026-04-01`, enabled by default for API accounts. Multi-agent orchestration, outcomes/rubric self-evaluation, "dreaming," and MCP tunnels are a more limited research preview inside the beta. ([overview docs](https://platform.claude.com/docs/en/managed-agents/overview), [launch blog](https://claude.com/blog/claude-managed-agents))
4. **Sessions have hard budgets, per-session config overrides, and vault-backed MCP auth.** A session can carry a `max_list_cost` budget in whole US cents; on reaching it the session pauses with stop reason `budget_reached`. Agent config (model/system/tools/MCP/skills) can be overridden per session without versioning the agent. MCP OAuth credentials are stored in vaults; Anthropic manages token refresh. ([sessions docs](https://platform.claude.com/docs/en/managed-agents/sessions))
5. **Each Managed Agents session gets its own isolated Linux container; environments are reusable config, not shared state.** Multiple sessions can reference one environment but "sessions do not share filesystem state." Environments support pre-installed packages (apt, cargo, gem, go, npm, pip — cached across sessions) and network modes `unrestricted` (default, safety blocklist) or `limited` (allowlist hosts + package managers + MCP). Self-hosted sandboxes are a documented environment type for running "on your own infrastructure." ([environments docs](https://platform.claude.com/docs/en/managed-agents/environments), [overview docs](https://platform.claude.com/docs/en/managed-agents/overview))
6. **Pricing: tokens at standard model rates plus $0.08 per session-hour, metered only while the session status is `running`** (millisecond precision; idle/rescheduling/terminated time is free). Prompt caching, web-search, data-residency, and fast-mode modifiers apply; Batch discount does not (no batch mode). Worked example in the docs: 1-hour Opus 5 session with 50k in / 15k out tokens = $0.705. During beta, Managed Agents is not eligible for Zero Data Retention or HIPAA BAA. ([pricing docs](https://platform.claude.com/docs/en/about-claude/pricing))
7. **Claude Code cloud sessions (web/mobile/desktop/`claude --cloud`) are per-session isolated VMs that persist after you close your laptop; state survives VM reclamation but running processes do not.** Each session runs in an isolated Anthropic-managed VM; sessions expire after inactivity and the VM is reclaimed — reopening restores the conversation history onto a fresh VM, but "background work that was still running when the VM was reclaimed, such as subagents and shell commands, isn't restored." GitHub credentials stay encrypted on Anthropic's servers and never enter the VM; git ops go through a server-side proxy with scoped credentials. There is no separate compute charge for the cloud VM; cloud sessions share the account's normal rate limits. ([cloud sessions docs](https://code.claude.com/docs/en/claude-code-on-the-web))
8. **Continuation between local and cloud is git-and-transcript based, not live-process migration — and from the CLI it is one-way.** `claude --cloud "task"` creates a *new* cloud session that clones the current directory's GitHub remote at the current branch (or, for repos without GitHub access, bundles and uploads the local repo — <100 MB, credential-like files such as `.env`/`*.pem` excluded). `claude --teleport` pulls a cloud session into the terminal: it verifies clean git state, same repo, branch pushed to remote, same account, then fetches the branch and loads full conversation history — but the terminal copy then diverges ("new work there stays local and doesn't appear in the cloud session"). The docs state "you can't push an existing terminal session to the cloud" from the CLI; the Desktop app has a **Continue in** menu that can send a local session to the cloud. ([cloud sessions docs](https://code.claude.com/docs/en/claude-code-on-the-web))
9. **Claude Code GitHub Actions is a workflow-level integration, not a hosted agent runtime.** `anthropics/claude-code-action@v1` runs Claude Code on GitHub-hosted runners in two modes: interactive (responds to `@claude` mentions) and automation (a `prompt` input on any GitHub event, including cron). Auth is a repo secret (`ANTHROPIC_API_KEY`), a subscription OAuth token (`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`), or OIDC workload-identity federation to a Console service account. Guards: triggering user needs write access; bot actors rejected unless allowlisted. Cost = GitHub Actions minutes + Claude API tokens (or subscription usage via OAuth token). Inference can be routed through Bedrock / Google Agent Platform / Microsoft Foundry. ([GitHub Actions docs](https://code.claude.com/docs/en/github-actions))
10. **The Claude Agent SDK is the in-process sibling: same tools, agent loop, and context management as Claude Code, programmable in Python/TypeScript, running in your own process.** Anthropic's own comparison table positions it as "building an agent without implementing the tool loop yourself," explicitly contrasted with Managed Agents ("hosted REST API… Anthropic runs the agent and the sandbox") and the Client SDK (raw Messages API, you build the loop). Sessions support resume and fork. There is no separate product named "Agent API" — the hosted agent-runtime surface is Claude Managed Agents, and the raw model surface remains the Messages API. ([Agent SDK overview](https://platform.claude.com/docs/en/agent-sdk/overview), [Managed Agents overview](https://platform.claude.com/docs/en/managed-agents/overview))
11. **Claude Code checkpoints are automatic per-prompt file snapshots stored with the conversation, not git.** A checkpoint is captured before each turn-starting prompt; the 100 most recent are kept; `/rewind` (or double-Esc) can restore code, conversation, or both, or summarize a span into the context window. Limitations: Bash-mutated files, subagent edits, and external edits aren't restored; snapshots are swept ~30 days after last save (configurable via `cleanupPeriodDays`); symlinked/hard-linked paths are skipped. ([checkpointing docs](https://code.claude.com/docs/en/checkpointing))

## Comparison notes

**Claude Managed Agents (the literal "managed agents" product)**
- Substrate: isolated Linux container sandbox per session; Anthropic-hosted or self-hosted sandbox
- Control plane: Anthropic Claude Platform (REST + SSE, Console for tracing); harness runs server-side, outside the sandbox
- State model: append-only server-side session event log + per-session sandbox filesystem (not shared between sessions); vault-held credentials outside the sandbox
- Continuation/handoff: sessions resume after pauses via persisted event log; steer/interrupt mid-run; no local↔cloud migration of a *running* process — the harness itself is the substrate
- Pricing: standard token rates + $0.08/session-hour (running-time only); session budgets with hard caps
- Local component: none required — but a self-hosted sandbox option moves execution into the customer's perimeter (closest analog to Keg's "your hardware, their control plane")

**Claude Code cloud sessions (web/mobile/desktop/`--cloud`)**
- Substrate: isolated Anthropic-managed Ubuntu VM per session; per-org "cloud environments" (network access, env vars, setup scripts)
- Control plane: claude.ai (session list, diff review, sharing, archiving); org policy `allow_remote_sessions`
- State/continuation: git branch on GitHub is the durable artifact; conversation transcript restored on VM re-provision; **running processes are lost on environment expiry**
- Handoff: `--cloud` (new session, clone remote or upload bundle) / `--teleport` (pull to terminal: transcript + branch; copies, doesn't sync) / Desktop "Continue in"; CLI cannot push an existing local session to cloud
- Pricing: included in Pro/Max/Team/Enterprise seats; shares account rate limits; no separate VM charge
- Local component: Claude Code CLI / IDE extensions / Desktop app; local sessions run on the user's machine and are user-managed (steerable remotely via Remote Control, which is monitoring, not migration)

**Claude Code GitHub Actions**
- Substrate: GitHub-hosted runners (standard CI VMs); Claude Code runs inside a workflow job
- Control plane: GitHub (workflow files, repo/org secrets, App permissions); no session persistence beyond the run
- Continuation: none across runs; each trigger is a fresh run; outputs are PR comments / pushed commits / run logs
- Pricing: GitHub Actions minutes + Claude tokens (API key or subscription OAuth token)
- Local component: none (setup via `/install-github-app` run locally, but execution is cloud CI)

**Claude Agent SDK**
- Substrate: the developer's own process/machine (Python/TS library)
- Control plane: developer's application
- Continuation: session resume/fork, file checkpointing hooks available in-process
- Pricing: API tokens only
- Local component: *is* the local component — this is the bring-your-own-runtime option

## Unverified / uncertain

- The launch announcement URL `anthropic.com/news/introducing-managed-agents` (cited in an arXiv paper) returned 404 on 2026-09-29; the canonical announcement appears to be [claude.com/blog/claude-managed-agents](https://claude.com/blog/claude-managed-agents). The blog itself is confirmed live.
- Self-hosted sandboxes for Managed Agents are referenced from the environments docs and described in the launch blog, but I did not fetch the dedicated self-hosted-sandbox page (GA timing, supported substrates, networking requirements unconfirmed from primary source).
- "Dreaming," outcomes/rubric evaluation, and multi-agent orchestration are flagged research-preview by both the overview docs and launch blog; exact availability/waitlist mechanics not verified beyond that.
- GitHub Actions per-minute pricing and Claude token rates for current models were not independently fetched from GitHub/Anthropic billing pages — the integration docs state the cost model (minutes + tokens) but defer to GitHub's and Anthropic's billing pages for numbers.
- Inference: Anthropic's local Claude Code sessions are *user-managed* on the user's machine; nothing in the fetched docs positions Anthropic as managing/operating agents on end-user personal hardware. This is my inference from the absence of such a surface in the official docs, not a confirmed negative.
- Remote Control (steering a live local session from phone/browser) is mentioned in the cloud docs but I did not deep-read its page; it appears to be a monitoring/steering channel over a live local process, not session migration.

## Sources

1. https://code.claude.com/docs/en/claude-code-on-the-web
2. https://code.claude.com/docs/en/github-actions
3. https://platform.claude.com/docs/en/managed-agents/overview
4. https://platform.claude.com/docs/en/about-claude/pricing
5. https://claude.com/blog/claude-managed-agents
6. https://www.anthropic.com/engineering/managed-agents
7. https://platform.claude.com/docs/en/agent-sdk/overview
8. https://platform.claude.com/docs/en/managed-agents/sessions
9. https://platform.claude.com/docs/en/managed-agents/environments
10. https://code.claude.com/docs/en/checkpointing
