# Craft + Notion Agents Synthesis for Keg

## Goal
Translate the strongest, most implementation-relevant patterns from Craft Agents and Notion Agents into a concrete feature roadmap for Keg's existing Agents area.

## Short Answer
Keg should **not** try to copy both products wholesale. The best path is:
1. **Finish existing Sources + Skills foundation**
2. **Add visible permission modes and run/audit history**
3. **Introduce session workflow metadata (status, labels, flags, background-state)**
4. **Only then add automations / scheduled agents**
5. **Defer remote/headless multi-client architecture until local-first workflows are solid**

Craft contributes the best patterns for **agent-native desktop UX**. Notion contributes the best patterns for **governance, automation safety, and shared/autonomous agents**.

## Feature Matrix

| Capability | Craft Agents | Notion Agents | Keg today | Implication for Keg |
|---|---|---|---|---|
| Personal/manual agent chat | Yes | Yes (Notion Agent) | Yes | Keep |
| Shared/autonomous agent mode | Implicit via automation/shared sessions | Explicit Custom Agents | No | Add later as separate concept |
| MCP + REST + files sources | Strong | MCP + app integrations + Notion content | Partial shell | Finish now |
| Local skills / reusable instructions | Strong | Strong | Partial shell | Finish now |
| Multi-session workflow inbox | Strong | Moderate | Partial dashboard/session list | Add metadata/status/flags |
| Permission modes visible in UX | Strong | Tool/agent permission controls | No | High priority |
| Agent-specific access model | Weak-medium | Strong | No | High priority before automation |
| Activity/run log | Medium | Strong | Weak | High priority |
| Schedules + triggers | Strong | Strong | No | Medium priority |
| Quotas / budget limits | Weak | Strong | No | Add with automation |
| Remote/headless multi-client | Strong | Not core | No | Strategic, defer |
| Reversible edits / version history | Not core | Strong | No | Needed where Keg writes local state |

## Where Craft is Most Useful

### 1. Agent-native desktop interaction model
Craft proves users want:
- multiple concurrent sessions
- background task continuity
- source-rich workflows
- conversational configuration of tools, sources, skills, and automations

### 2. Source + skill composition
Craft's strongest product loop is: **source + skill + session + automation**.
That maps well onto Keg's current UI shells.

### 3. Permission mode ergonomics
Craft's Explore / Ask / Execute model is a clean user-facing abstraction for trust.
Keg currently has no equivalent, which makes future automations riskier.

## Where Notion is Most Useful

### 1. Governance model
Notion's best idea is not triggers. It is the separation of:
- what the agent can access
- who can invoke/edit/share the agent

Keg is single-user/local today, but this still matters conceptually. Keg needs an equivalent of **agent capability scope** before it lets agents run unattended against mutable sources.

### 2. Activity and reversibility
Notion treats autonomy as acceptable only when users can inspect what happened and undo damage.
Keg has session history but not a strong run-level provenance layer.

### 3. Autonomous agent product boundary
Notion keeps autonomous/shared agents separate from the personal assistant. Keg should do the same instead of bolting triggers directly onto the current basic agent object without distinction.

## Recommended Keg Architecture Direction

## Phase 1 — Finish existing foundations
**Target:** make current Skills and Sources screens real, not placeholder shells.

### Deliverables
- Persist skills with `AgentStorage`
- Persist sources with `AgentStorage`
- Save full source config payloads
- Implement source connection testing via `SourceConnectionTester`
- Add import/export for skills
- Add basic source enable/disable and status refresh

### Why first
This work is already scaffolded. It upgrades daily usability without forcing new architecture.

## Phase 2 — Add trust and observability primitives
**Target:** create safe substrate for more powerful agents.

### Deliverables
- Global permission mode visible in UI: `Explore`, `Ask`, `Execute`
- Optional source-specific policy overrides
- Session labels / flags / workflow statuses
- Run timeline per session: trigger, tools used, errors, outputs, approvals
- Basic provenance metadata for session actions

### Why second
Without this layer, automations and autonomous runs will feel unsafe and opaque.

## Phase 3 — Add local automations and scheduled workflows
**Target:** copy the strongest overlap between Craft and Notion.

### Deliverables
- Scheduled triggers (cron/time-based)
- Session-status or label-change triggers
- Prompt actions that create new sessions
- Optional command actions for local workflows only if permission model is solid
- Automation history with success/failure timeline
- Per-automation enable/disable/test

### Safety requirements
- approval-aware writes
- explicit source allowlists
- rate limiting / loop prevention
- timeout + failure handling
- per-automation run limits or monthly quota analog

## Phase 4 — Introduce autonomous/shared agent concept
**Target:** Notion-style separation between manual assistant and autonomous workflow agent.

### Deliverables
- new agent type or mode: `manual` vs `autonomous`
- independent capability scopes per agent
- explicit trigger config only for autonomous agents
- stricter default permissions for autonomous agents

### Why not earlier
Keg's current model is too thin. It would blur chat sessions and workflow automation too early.

## Phase 5 — Strategic / optional
- remote headless Keg Agents service
- thin-client or multi-client UI
- team/shared workspaces
- admin-level policy and analytics

## Immediate Implementation Tranche
If Keg wants one high-confidence tranche next, it should be:

### Tranche A: Real Sources + Real Skills + Light Trust Layer
1. Finish local persistence and testing for Skills/Sources
2. Add source config schemas and validation
3. Add source badges/statuses in UI
4. Add one global permission mode switch
5. Add session labels and flagging

**Why this tranche wins:**
- uses code that already exists
- aligns with both Craft and Notion patterns
- creates visible product improvement fast
- prepares architecture for automations without overcommitting

## Concrete File Touchpoints

### High-confidence now
- `Sources/Keg/Agents/Views/SourceListView.swift`
- `Sources/Keg/Agents/Views/SkillListView.swift`
- `Sources/Keg/Agents/Storage/AgentStorage.swift`
- `Sources/Keg/App/AppState.swift`
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
- `Sources/Keg/Agents/Views/SessionListView.swift`
- `Sources/Keg/Agents/Views/SessionDetailView.swift`

### Likely later
- `Sources/Keg/Agent/SessionManager.swift`
- `Sources/Keg/Agent/AgentRuntime.swift`
- `Sources/Keg/Agent/ToolExecutor.swift`
- new automation scheduler / event bus files

## Recommendations Ranked
1. **Finish Sources and Skills persistence/testing**
2. **Add permission modes visible in app chrome**
3. **Add session workflow metadata + activity timeline**
4. **Add scheduled and event-triggered automation**
5. **Split autonomous workflow agents from manual chat agents**
6. **Defer remote/headless server until above is solid**

## Open Questions
1. Should Keg remain single-user/local, or is multi-client access actually on roadmap?
2. Should Keg sources remain purely local metadata, or become executable tool providers with capability scopes?
3. Should autonomous runs use Anthropic Managed Agents sessions directly, or Keg-managed orchestration over them?
4. How much reversibility can Keg guarantee for source writes outside its own local store?

## Final Recommendation
Keg should copy **Craft's UX grammar** and **Notion's governance grammar**.

In practical terms:
- from Craft: sources, skills, multi-session workflow, permission modes, agent-native configuration, eventually automations
- from Notion: explicit access model, activity log, reversibility mindset, autonomous/manual split, quotas/limits

The best next build is **not** remote agents or enterprise controls. It is finishing the half-built local substrate so Keg can safely grow into autonomous workflows.
