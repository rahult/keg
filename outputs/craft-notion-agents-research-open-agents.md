# Open Agents Research

## Scope
Current `open-agents.dev` product page plus official `vercel-labs/open-agents` README. Focus: architecture, runtime model, workflow durability, sandboxing, git integration, and what that means for Keg.

## Key Findings

### 1. Open Agents is not primarily a desktop UX or governance product
Open Agents positions itself as an open-source **reference app for building and running background coding agents on Vercel** rather than as a source/skills-heavy desktop workspace like Craft or a governed business workflow layer like Notion.[1][2]

### 2. Its core idea is architectural separation: agent != sandbox
The official README makes the main design decision explicit: the agent does **not** run inside the VM. The agent runs as a durable workflow outside the sandbox and interacts with the sandbox through tools (file read/edit/search/shell, etc.).[2]

That yields several properties:
- agent execution is not tied to one request lifecycle
- sandbox lifecycle can hibernate/resume independently
- model/provider choices can evolve separately from execution environment
- the VM remains execution substrate, not control plane[2]

### 3. Durable workflow execution is the center of the product
Open Agents emphasizes:
- durable multi-step execution
- resumable agent loops
- automatic checkpointing
- reconnectable streams
- cancellation and retry behavior
- post-run hooks like usage tracking, diff caching, auto-commit, and push[1][2]

This is closer to a **cloud orchestration runtime** than to a local desktop app.

### 4. Cloud sandboxes are first-class
Each session runs in an isolated Vercel sandbox with:
- its own branch
- filesystem + shell + git + preview ports
- snapshot/restore behavior
- inactivity hibernation and instant restore[1][2]

The product page says work is committed and pushed automatically if configured, and sandbox state can be snapshotted/restored.[1]

### 5. Git/GitHub workflow integration is deep
Open Agents is designed to move from prompt to repo changes without keeping a laptop involved.[2]
Current capabilities include:
- repo cloning into sandbox
- branch work inside sandbox
- optional auto-commit, push, and PR creation
- GitHub App integration for repo access and PR workflows[2]

### 6. UI model is session/chat centric, but lighter than Craft
Open Agents does have a web UI that handles auth, sessions, chat, and streaming UI.[2]
But compared with Craft, the differentiator is not workspace UX customization, skills/sources composition, or user-facing permission modes. It is the fact that the whole loop is **durable, resumable, and cloud-hosted**.[1][2]

### 7. Infrastructure stack is product-defining
The landing page highlights Vercel primitives: AI SDK, Gateway, Sandbox, Workflow SDK.[1]
The README repo layout reflects this split:
- `apps/web` for auth/chat/workflows/UI
- `packages/agent` for agent logic/tools/subagents/skills
- `packages/sandbox` for sandbox abstraction
- `packages/shared` for shared utilities[2]

This is a strong example of infrastructure-driven agent architecture.

## Implementation-Relevant Patterns

### Pattern A: Durable workflow outside execution VM
This is the strongest reusable idea. It keeps orchestration separate from execution substrate.[2]

**Keg relevance:** High long-term value if Keg ever adds remote/headless/background agents or cloud/container execution beyond current local UI shells.

### Pattern B: Sandbox as plain execution environment
Open Agents treats the sandbox as replaceable execution substrate rather than as the agent runtime itself.[2]

**Keg relevance:** Conceptually strong. Keg already sits near container/VM infrastructure, so this separation could map well if Keg later orchestrates agent runs across Apple Container or remote execution backends.

### Pattern C: Built-in git lifecycle
Branch-per-session, optional auto-commit/push/PR, and repo cloning are all native product concerns.[1][2]

**Keg relevance:** Medium. Useful if Keg wants coding-agent workflows, but less immediately important than sources/skills/trust layer.

### Pattern D: Reconnectable streams and resumable runs
Open Agents assumes clients may disconnect while work continues.[1][2]

**Keg relevance:** Strong medium-term signal for session resilience and background task UX.

## What Open Agents Adds to Prior Craft/Notion Comparison
- **Craft** answers: what should local agent-native desktop UX feel like?
- **Notion** answers: how should autonomous agents be governed and shared safely?
- **Open Agents** answers: how should long-running coding-agent execution be architected so it survives disconnects, retries, and environment churn?

That makes Open Agents most useful as an architectural reference, not as the primary product UX model for Keg.

## Recommendation Impact for Keg
Open Agents does **not** change the immediate recommendation.

It reinforces:
1. Do **not** couple orchestration too tightly to execution environment.
2. If Keg adds background/autonomous work later, it should separate:
   - session/workflow orchestration
   - execution substrate (container/VM/sandbox)
   - UI client lifecycle
3. Remote/headless work is more plausible if Keg adopts a durable workflow model rather than embedding all logic in one UI-bound process.

But it does **not** move ahead of the earlier priorities. Keg still needs to finish Sources + Skills + trust/audit basics before chasing cloud-resumable agent infrastructure.

## Evidence Table
| Claim | Evidence | Notes |
|---|---|---|
| Open Agents is a reference app for background coding agents on Vercel | [1], [2] | Stated directly on site and README |
| Agent runs outside sandbox and interacts through tools | [2] | Core architectural decision in README |
| Durable workflows / resumable loops are central | [1], [2] | Product page + README |
| Sessions run in isolated sandboxes with git branches and snapshots | [1], [2] | Product page + runtime notes |
| Auto-commit/push/PR are supported | [1], [2] | Product page + README |

## Sources
1. Open Agents product page, https://open-agents.dev/
2. Open Agents README, https://github.com/vercel-labs/open-agents/blob/main/README.md
