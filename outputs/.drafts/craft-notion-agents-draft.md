# Craft Agents and Notion Agents: What Keg Should Implement Next

## Executive Summary
Craft Agents and Notion Agents solve adjacent but meaningfully different problems. Craft is strongest as an **agent-native desktop interface**: multi-session workflow, rich source connectivity, visible permission modes, local skills, and event-driven automations. Notion is strongest as an **autonomous agent governance model**: shared vs personal agents, explicit agent-specific access, trigger/schedule configuration, activity logs, auditability, reversibility, and cost/usage guardrails.

Keg already has more of the substrate than it may look at first glance. Its Agents area now includes account/authentication, agent CRUD, session listing and detail views, skill and source screens, dashboard routing, and local storage primitives for sources and skills. However, much of that surface is still partially wired. The biggest missing pieces are not more top-level screens; they are the connective systems that make agents trustworthy and useful: durable source/skill persistence, source testing and activation, permission modes, session workflow metadata, run history, and eventually automations.

The clearest recommendation is to copy **Craft's UX grammar** and **Notion's governance grammar**. In practical terms, Keg should first finish Sources and Skills, then add visible trust controls and auditability, then introduce scheduled/event-driven automation, and only after that consider a separate autonomous/shared agent model. Remote/headless multi-client architecture is strategically interesting, but it should wait until the local-first agent workflow is solid.

## 1. What Craft Agents contributes
Craft shows what a desktop agent product looks like when the agent is the primary interaction model rather than an add-on. Its strongest ideas are:

- **Multi-session, workspace-scoped workflow.** Sessions persist, carry statuses, and can be organized and revisited as durable work artifacts.
- **Broad source model.** MCP servers, REST APIs, and local folders are all first-class sources rather than custom hacks.
- **Visible permission modes.** Explore, Ask to Edit, and Execute provide a simple user-facing trust model.
- **Lightweight skills.** Skills are simple workspace artifacts with open-format instructions rather than a heavy internal abstraction.
- **Automations.** Event-driven and scheduled automations create new sessions or execute commands when labels, statuses, tool events, or cron schedules match.
- **Remote/headless operation.** Craft can run as a server with desktop, browser, and CLI clients.

The most important lesson is not any one feature. It is the composition: sources + skills + sessions + permissions + automations all feel like parts of one coherent workflow.

## 2. What Notion Agents contributes
Notion is less interesting as a desktop interaction model and more interesting as a **control plane for autonomous work**. Its strongest ideas are:

- **Personal vs custom agent split.** Notion Agent is an on-demand assistant; Custom Agents are autonomous, shared workflows that run in the background.
- **Agent-specific access model.** Custom Agents do not simply inherit the triggering user's permissions. They have their own explicit access to pages, databases, Slack channels, MCP connections, and other tools.
- **Trigger/schedule productization.** Schedules, Notion events, and Slack events are first-class configuration surfaces.
- **Activity and auditability.** Activity logs, audit logs, analytics, and version history make autonomous work inspectable.
- **Reversibility and admin controls.** Notion treats reversibility, disablement, ownership transfer, and creation restrictions as core safety features.
- **Operational guardrails.** Credit limits and workspace-level usage monitoring act as runtime control mechanisms for autonomous systems.

The key lesson is that autonomy without governance is not enough. Notion makes agents useful because it also makes them inspectable and governable.

## 3. Keg's current position
Keg is not starting from zero. Its current Agents area already includes:

- separate Agents-area navigation and routing
- API-key authentication and account management
- Managed Agents CRUD and editing flows
- session list/detail views and dashboard summaries
- local storage primitives for sources and skills
- shell UIs for sources and skills

But several of those surfaces are still only partially implemented.

### What is already solid enough to build on
- **Account/auth foundation** is usable.
- **Agent CRUD** is real enough to create, edit, and inspect agents.
- **Session listing and detail UI** already exist.
- **Storage and connection-testing primitives** for sources/skills already exist in code.

### What is visibly incomplete
- Sources are not fully persisted, configured, or tested through the current UI.
- Skills are not fully persisted or connected to runtime behavior.
- Session operations lack richer workflow metadata and run-level history.
- There is no visible permission-mode system.
- There is no automation/trigger/scheduler layer.
- There is no explicit split between manual agents and autonomous/shared agents.
- There is no strong agent-specific capability scope model.

## 4. Where the two products overlap
The overlapping feature cluster is where Keg should focus.

### Shared high-value patterns
1. **Richer source connectivity**
2. **Reusable skills/instructions**
3. **Background or scheduled workflows**
4. **Permission and safety controls**
5. **Auditability and run history**
6. **Multi-session workflow organization**

These are the features that matter in both products, even though each product emphasizes them differently.

## 5. What Keg should implement next

## Phase 1: Finish Sources and Skills
This is the best immediate tranche.

### Why
Keg already has the UI shells and storage primitives. The missing work is mostly wiring and polish, not deep architecture.

### What to build
- persist skills through `AgentStorage`
- persist sources through `AgentStorage`
- store full source config payloads, not just name/type/status
- implement source connection testing in UI using the existing tester actor
- support source enable/disable and status refresh
- add import/export for skills
- make source and skill usage visible inside agent/session flows

### Expected outcome
Keg moves from placeholder management screens to a genuinely useful local configuration layer.

## Phase 2: Add trust and observability primitives
Before Keg introduces automation, it should make agent behavior understandable and controllable.

### What to build
- visible permission mode switch, ideally with Craft-like semantics: Explore, Ask, Execute
- session labels, flags, and workflow statuses
- run timeline / activity history in session detail
- clear indication of which sources an agent/session may use
- provenance metadata for tool usage, errors, and approvals

### Why
This is the layer that makes later automation safe enough to ship.

## Phase 3: Add automations and scheduled workflows
Once trust and auditability exist, Keg can borrow the strongest common idea from both products: autonomous workflows.

### What to build
- cron/time-based schedules
- triggers based on session labels/status or other Keg-local events
- prompt actions that create or resume sessions
- execution history and failure logs for automations
- enable/disable/test controls for each automation
- loop prevention, rate limits, timeouts, and explicit permission checks

### Why not first
Automation without permission modes and run logs would create opaque failure modes and unsafe write behavior.

## Phase 4: Introduce autonomous/shared agent mode
This is the Notion-inspired boundary.

### What to build
- separate manual vs autonomous agent type or mode
- explicit capability scopes per agent
- trigger configuration only for autonomous agents
- stricter defaults and quota/limit controls for autonomous agents

### Why separate it
Keg should not overload today's manual CRUD/session model with too many responsibilities. A separate autonomous mode will remain conceptually cleaner and safer.

## Phase 5: Consider remote/headless architecture
This is the Craft-inspired strategic feature, but not the next one.

### Why defer
Remote/headless mode becomes valuable after Keg proves its local workflow model and automation stack. Otherwise Keg risks building distribution before it finishes the core product.

## 6. Most important product decision
Keg should avoid trying to become both Craft and Notion at once.

The highest-leverage decision is:

**Build a strong single-user, local-first agent workspace first. Then add governed autonomy. Only then consider remote multi-client infrastructure.**

That sequence aligns with the current codebase and minimizes architectural thrash.

## 7. Immediate recommendation
If Keg chooses only one concrete implementation tranche next, it should be:

### Tranche A: Real Sources + Real Skills + Light Trust Layer
- finish sources persistence, validation, and test flows
- finish skills persistence and import/export
- add one global permission-mode indicator/switch
- add session labels/flags/statuses

This tranche is the best next move because it:
- uses code already present in the repo
- creates visible product improvement quickly
- aligns with both Craft and Notion patterns
- lays necessary groundwork for automations later

## Open Questions
- Should Keg remain single-user/local for the foreseeable future, or is server mode actually on roadmap?
- Should source permissions be session-scoped, agent-scoped, or both?
- Can Keg offer reversible writes for all source types, or only for its own local metadata and selected integrations?
- Should autonomous workflows be backed directly by Managed Agents sessions, or by a Keg orchestration layer above them?

## Bottom Line
Craft provides the best template for **how Keg's agent experience should feel**. Notion provides the best template for **how Keg should make autonomous agents safe and governable**. Keg's best next move is to finish the partially built foundation it already has, then add permission modes and run history, then build automations on top of that. That path is more realistic, safer, and more likely to produce a differentiated product than jumping straight to remote agents or enterprise admin features.
