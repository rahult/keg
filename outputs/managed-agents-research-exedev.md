# Managed Agents Research — exe.dev

Research date: 2026-09-29. All facts verified against exe.dev's own site, docs, and blog unless marked as inference.

## Scope

Covered: the full exe.dev product surface from primary sources — homepage, `/sandbox`, `/devbox`, `/pricing`, docs.exe.dev (incl. search-index excerpts of Shelley/agents/integrations pages), and blog posts (Series A, "Why exe.dev VMs Are Persistent", Antithesis case study, blog index through 2026-09-28). Lens: what it manages, execution substrate, continuation/handoff, control plane, pricing, target user.

Deliberately skipped: third-party reviews/comparisons (boxd, flaviocopes, mastra) except as leads; Shelley internals beyond what docs snippets confirm; the exe.dev iOS app details; Mayfly/ClickHouse internal-agent posts (peripheral to the core offering).

## Key Findings

1. **exe.dev is both a dev-environment product AND an agent-hosting product, built on one primitive: persistent Linux KVM VMs, sold as a resource pool rather than per-VM.** Positioning: "Computers for developers and agents — Durable Sandboxes that are fast, secure, and sharable" (https://exe.dev). Three product lines share the same VM primitive: Sandbox (disposable VMs for AI agents), Devbox (cloud dev environments), and persistent VPS/production hosting (homepage nav, https://exe.dev). VMs are KVM-isolated with root, systemd, your own kernel, a persistent disk, and a public HTTPS hostname (https://exe.dev/devbox).

2. **Architecture: own hardware, own cloud, container-image-booted VMs.** "We are not building on top of existing clouds; we are working with our own machines in data centers. We have written our own global load balancer. We do our own DNS" (https://blog.exe.dev/series-a). VMs boot from container images (default `exeuntu`, Ubuntu 24.04) rather than disk images — stated in docs and product copy (https://exe.dev/sandbox, https://docs.exe.dev). Execution substrate is cloud Linux VMs only — there is **no local/on-device component** and no macOS story.

3. **Continuation model is persistence-in-place, not migration.** "VMs are not 'quiesced' when there's no network traffic... Disks aren't wiped clean on reboot" (https://blog.exe.dev/persistent). exe.dev explicitly rejects hibernation: idle VMs drop to disk-only billing but "resume in seconds, right where you left off" (https://exe.dev/devbox); the Antithesis engineer confirms "Every other VM platform on the planet hibernates your VMs. Exe is the only one that doesn't" (https://blog.exe.dev/how-antithesis-turned-exe-into-a-sandbox-for-agentic-software-tests). Sandboxes are explicitly marketed for "agents that come back tomorrow" and long-running services (https://exe.dev/sandbox). Copy-on-write `cp base my-feature` forks a VM "in 0.4s" — checkpoints are filesystem clones, not snapshot/restore of a session (https://exe.dev/devbox). There is **no local→cloud handoff**: continuation across surfaces means the *same* VM reached from SSH, VS Code/Cursor remote, web, or the iOS app.

4. **Control plane is SSH-first with a second HTTPS API surface; auth uses signed, permission-carrying tokens.** Every operation is a CLI command over `ssh exe.dev` (create/rm/cp/share/ssh-key/billing), and the same commands are exposed over an HTTPS POST API (`https://exe.dev/exec`) (https://exe.dev/sandbox, https://blog.exe.dev — "Executing Commands With exe.dev's HTTPS API", 2026-09-14). API tokens "carry their permissions in the token, as signed JSON" — `cmds` whitelists allowed operations, `exp` bounds replay, `ctx` carries tenant tags; signed by the user's SSH key, rotated/revoked by key management (https://exe.dev/sandbox). This is an agent-friendly delegated-authority model: scoped, revocable, auditable credentials minted without a console.

5. **Secrets and git are handled by an in-VM HTTP proxy — the standout differentiator for agent security.** Integrations install an HTTP proxy inside the VM that attaches the auth header on egress; "The agent makes plain unauthenticated requests to an internal hostname; the proxy attaches the auth header on the way out. The secret never enters the model's context" (https://exe.dev/sandbox). GitHub integration is a full GitHub App with OAuth (no PATs); Stripe/OpenAI/Anthropic and any header-authed API work the same way; integrations are tag-scoped and inherited by `cp` clones (https://exe.dev/devbox, design notes at https://blog.exe.dev — "Some Secret Management Belongs in Your HTTP Proxy", 2026-04-18). Docs confirm the same pattern for private container registries (no `docker login` on the VM) and an LLM Gateway integration agents discover via a "reflection integration" (docs.exe.dev search index).

6. **Shelley is the bundled web coding agent; BYO agents are equally first-class.** Shelley runs on the VM (port 9999, `vmname.shelley.exe.xyz`) when using the default image; web-based, mobile-friendly, reads AGENTS.md/CLAUDE.md; state in SQLite on the VM; no permission prompts — "it assumes it is running in the right sandbox" (docs.exe.dev Shelley pages; https://blog.exe.dev — "Goodbye Sketch, Hello Shelley!", 2026-01-08). The default image also pre-installs Claude Code, Codex, and pi (docs "Running Agents"). Shelley ships with a monthly LLM credit (legacy $20/mo; docs "Billing") and supports bring-your-own keys/subscriptions (ChatGPT subscription connection, https://blog.exe.dev — 2026-07-03). This confirms the product thesis: the *sandbox* is the trust boundary, so the agent inside needs no per-action approval gate.

7. **Pricing posture: resource pools, not per-VM; idle VMs bill at disk rate.** Two models on the same VMs (https://exe.dev/sandbox): **Pool** — flat monthly bundle of CPU/RAM/disk/transfer shared across your whole fleet ("Spin up a thousand short-lived sandboxes against the same pool"); **Usage** — per-second: CPU $0.05/core-hour, active memory $0.016/GiB-hour, disk $0.08/GiB-month, "Idle VMs: no CPU charge, memory at disk rate". Current plan tiers (https://exe.dev/pricing, fetched 2026-09-29): Personal $15/mo (2 vCPU/4 GB pool, 50 VMs, 100 GB disk, 200 GB transfer); Work $0.21/hr with $150/mo minimum (4 vCPU/8 GB, 1000 VMs/pool, unlimited users + SSO); Enterprise custom (dedicated hardware, BYO cloud AWS/GCP VPC, nested KVM). Sandbox overage: $0.105 per 2 vCPUs/hour. NOTE: the `/sandbox` marketing page still shows older numbers (Personal $20/mo, Team $25/user/mo) — see Unverified.

8. **Target user and stage: solo developers through teams; agent fleets as the growth thesis.** Individual developers ("pay a flat rate, run as many computers as you need"), teams (pools, SSO, sharing with IAM-like controls, roles Member/Admin/Owner — https://exe.dev/pricing), and increasingly agent-driven orgs ("Software Factory" blog series). Company: $35M total funding, Series A announced 2026-04-22 led by Amplify with CRV and HeavyBit (https://blog.exe.dev/series-a); a "startup program" launched per the homepage. Regions: US, UK, JP, DE, AU ("Closer Compute", blog 2026-04-11).

## Comparison notes

- **Substrate:** cloud-only Linux KVM VMs on exe.dev's own bare metal (own LB, own DNS); boots from container images (default `exeuntu` Ubuntu 24.04); root + systemd; per-VM public HTTPS hostname behind their proxy. No containers-as-product, no local runtime, no macOS support.
- **What it manages:** VM lifecycle (new/cp/rm/share), disk persistence, DNS/TLS hostnames, idle→disk-only auto-stop, integrations (secrets proxy), LLM gateway/credits, signed API tokens, teams/SSO. It does *not* manage git state, checkpoints-as-sessions, or transcript portability — state lives on the VM's disk.
- **Control plane:** SSH CLI as the primary API (`ssh exe.dev ...`) + HTTPS exec endpoint; tokens are signed JSON carrying `cmds`/`exp`/`ctx`; credential rotation = SSH key rotation.
- **Continuation model:** persistence, not migration. Same VM keeps running (never hibernated); idle = disk-only billing, resumes in seconds; `cp` = copy-on-write fork of a whole disk in <1s. No push/pull of an agent session between local and cloud — cross-surface access is the *same* VM via SSH/web/mobile.
- **Pricing:** flat resource pools (Personal $15/mo) or per-second usage (CPU $0.05/core-hr; idle at disk rate); enterprise from custom with dedicated hardware/BYO-VPC. Anti-per-VM pricing is a stated design principle (Antithesis post).
- **Local component:** none. The laptop is only a client (SSH/VS Code remote/iOS app). This is the exact opposite end from Keg's local-first model.
- **Agent posture:** agent-agnostic substrate + one bundled agent (Shelley); sandbox-as-trust-boundary replaces permission prompts; secrets kept out of model context via egress proxy.

## Unverified / uncertain

- **Pricing discrepancy:** `/sandbox` page says Personal $20/mo, Team $25/user/mo; `/pricing` says Personal $15/mo and Work $0.21/hr ($150 min), with a 2026-09-28 blog post announcing "new Personal and Work plans" (https://blog.exe.dev index). Inference: `/pricing` is current and `/sandbox` is stale copy.
- **Hypervisor = Cloud Hypervisor** appears in exe.dev's FAQ per a third-party deep dive (flaviocopes.com), not confirmed on a primary page I fetched; only "KVM virtual machines" is primary-source confirmed.
- Shelley specifics (SQLite state path, no-permission-prompts behavior) come from docs search-index snippets and a secondary summary of the launch post; the launch post itself I did not fetch directly.
- Whether exe.dev offers any snapshot/export/migration of a VM disk off-platform (for a local→cloud continuation story) — not documented anywhere I found. Inference: none; disk is the unit of continuity and it stays on exe.dev.
- Usage-pricing availability: the `/sandbox` page says "Contact us about usage pricing" — inference: usage pricing is gated/sales-led rather than self-serve.

## Sources

1. https://exe.dev (homepage)
2. https://exe.dev/sandbox
3. https://exe.dev/devbox
4. https://exe.dev/pricing
5. https://docs.exe.dev (What is exe.dev)
6. https://docs.exe.dev/shelley (docs search index: Shelley, Running Agents, Integrations, Billing excerpts)
7. https://blog.exe.dev/series-a
8. https://blog.exe.dev/persistent (Why exe.dev VMs Are Persistent)
9. https://blog.exe.dev/how-antithesis-turned-exe-into-a-sandbox-for-agentic-software-tests
10. https://blog.exe.dev/ (post index through 2026-09-28)
