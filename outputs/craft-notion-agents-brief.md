# Craft Agents and Notion Agents: What Keg Should Implement Next

## Executive Summary
Craft Agents and Notion Agents solve adjacent but meaningfully different problems. Craft is strongest as an **agent-native desktop interface**: multi-session workflow, broad source connectivity, visible permission modes, local skills, and event-driven automations.[1][2][3][4][5][6][7] Notion is strongest as an **autonomous agent governance model**: shared vs personal agents, explicit agent-specific access, trigger/schedule configuration, activity logs, auditability, reversibility, and cost/usage guardrails.[8][9][10][11][12][13]

Keg already has more of the substrate than it may look at first glance. Its Agents area now includes account/authentication, agent CRUD, session listing and detail views, skill and source screens, dashboard routing, and local storage primitives for sources and skills.[14][15][16][17][18][19][20][21][22][23][24][25] However, much of that surface is still partially wired. The biggest missing pieces are not more top-level screens; they are the connective systems that make agents trustworthy and useful: durable source/skill persistence, source testing and activation, permission modes, session workflow metadata, run history, and eventually automations.[18][23][24][25]

The clearest recommendation is to copy **Craft's UX grammar** and **Notion's governance grammar**. In practical terms, Keg should first finish Sources and Skills, then add visible trust controls and auditability, then introduce scheduled/event-driven automation, and only after that consider a separate autonomous/shared agent model. Remote/headless multi-client architecture is strategically interesting, but it should wait until the local-first agent workflow is solid.[1][2][4][6][7][8][9][10][11][13][15][16][17][18][23][24][25]

## 1. What Craft Agents contributes
Craft shows what a desktop agent product looks like when the agent is the primary interaction model rather than an add-on. Its strongest ideas are:

- **Multi-session, workspace-scoped workflow.** Sessions persist, carry statuses, and can be organized and revisited as durable work artifacts.[1][2][6]
- **Broad source model.** MCP servers, REST APIs, and local folders are all first-class sources rather than custom hacks.[1][2][3]
- **Visible permission modes.** Explore, Ask to Edit, and Execute provide a simple user-facing trust model.[2][4]
- **Lightweight skills.** Skills are simple workspace artifacts with open-format instructions rather than a heavy internal abstraction.[2][5]
- **Automations.** Event-driven and scheduled automations create new sessions or execute commands when labels, statuses, tool events, or cron schedules match.[2][6]
- **Remote/headless operation.** Craft can run as a server with desktop, browser, and CLI clients.[2][7]

The most important lesson is not any one feature. It is the composition: sources + skills + sessions + permissions + automations all feel like parts of one coherent workflow.[2][3][4][5][6]

## 2. What Notion Agents contributes
Notion is less interesting as a desktop interaction model and more interesting as a **control plane for autonomous work**. Its strongest ideas are:

- **Personal vs custom agent split.** Notion Agent is an on-demand assistant; Custom Agents are autonomous, shared workflows that run in the background.[8][9][10]
- **Agent-specific access model.** Custom Agents do not simply inherit the triggering user's permissions. They have their own explicit access to pages, databases, Slack channels, MCP connections, and other tools.[9][10][11]
- **Trigger/schedule productization.** Schedules, Notion events, and Slack events are first-class configuration surfaces.[8][9]
- **Activity and auditability.** Activity logs, audit logs, analytics, and version history make autonomous work inspectable.[8][9][10]
- **Reversibility and admin controls.** Notion treats reversibility, disablement, ownership transfer, and creation restrictions as core safety features.[8][9][10]
- **Operational guardrails.** Credit limits and workspace-level usage monitoring act as runtime control mechanisms for autonomous systems.[13]

The key lesson is that autonomy without governance is not enough. Notion makes agents useful because it also makes them inspectable and governable.[8][9][10][13]

## 3. Keg's current position
Keg is not starting from zero. Its current Agents area already includes:

- separate Agents-area navigation and routing[15][16][17]
- API-key authentication and account management[18]
- Managed Agents CRUD and editing flows[19][20][21][22]
- session list/detail views and dashboard summaries[23][24]
- local storage primitives for sources and skills[25]
- shell UIs for sources and skills[23][25]

But several of those surfaces are still only partially implemented.[23][24][25]

### What is already solid enough to build on
- **Account/auth foundation** is usable.[18]
- **Agent CRUD** is real enough to create, edit, and inspect agents.[19][20][21][22]
- **Session listing and detail UI** already exist.[23][24]
- **Storage and connection-testing primitives** for sources/skills already exist in code.[25]

### What is visibly incomplete
- Sources are not fully persisted, configured, or tested through the current UI.[23][25]
- Skills are not fully persisted or connected to runtime behavior.[25]
- Session operations lack richer workflow metadata and run-level history.[23][24]
- There is no visible permission-mode system.[15][16][17][25]
- There is no automation/trigger/scheduler layer.[15][16][17][23][24][25]
- There is no explicit split between manual agents and autonomous/shared agents.[10][25]
- There is no strong agent-specific capability scope model.[10][11][25]

## 4. Where the two products overlap
The overlapping feature cluster is where Keg should focus.

### Shared high-value patterns
1. **Richer source connectivity**.[1][2][3][8][9][11]
2. **Reusable skills/instructions**.[2][5][12]
3. **Background or scheduled workflows**.[6][8][9]
4. **Permission and safety controls**.[4][10][11]
5. **Auditability and run history**.[8][9][10][13]
6. **Multi-session workflow organization**.[1][2][6]

These are the features that matter in both products, even though each product emphasizes them differently.[2][8][9]

## 5. What Keg should implement next

## Phase 1: Finish Sources and Skills
This is the best immediate tranche.[23][25]

### Why
Keg already has the UI shells and storage primitives. The missing work is mostly wiring and polish, not deep architecture.[23][25]

### What to build
- persist skills through `AgentStorage`[25]
- persist sources through `AgentStorage`[25]
- store full source config payloads, not just name/type/status[23][25]
- implement source connection testing in UI using the existing tester actor[23][25]
- support source enable/disable and status refresh[23][25]
- add import/export for skills[25]
- make source and skill usage visible inside agent/session flows[19][21][22][23][24]

### Expected outcome
Keg moves from placeholder management screens to a genuinely useful local configuration layer.[23][25]

## Phase 2: Add trust and observability primitives
Before Keg introduces automation, it should make agent behavior understandable and controllable.[4][8][9][10]

### What to build
- visible permission mode switch, ideally with Craft-like semantics: Explore, Ask, Execute[4]
- session labels, flags, and workflow statuses[2][6][23][24]
- run timeline / activity history in session detail[8][9][10][23][24]
- clear indication of which sources an agent/session may use[3][10][11]
- provenance metadata for tool usage, errors, and approvals[9][10][13]

### Why
This is the layer that makes later automation safe enough to ship.[8][9][10][13]

## Phase 3: Add automations and scheduled workflows
Once trust and auditability exist, Keg can borrow the strongest common idea from both products: autonomous workflows.[6][8][9]

### What to build
- cron/time-based schedules[6][9]
- triggers based on session labels/status or other Keg-local events[6]
- prompt actions that create or resume sessions[6][9]
- execution history and failure logs for automations[6][8][9][10]
- enable/disable/test controls for each automation[6]
- loop prevention, rate limits, timeouts, and explicit permission checks[6][13]

### Why not first
Automation without permission modes and run logs would create opaque failure modes and unsafe write behavior.[4][6][8][9][10]

## Phase 4: Introduce autonomous/shared agent mode
This is the Notion-inspired boundary.[8][9][10]

### What to build
- separate manual vs autonomous agent type or mode[8][9][10]
- explicit capability scopes per agent[10][11]
- trigger configuration only for autonomous agents[9]
- stricter defaults and quota/limit controls for autonomous agents[13]

### Why separate it
Keg should not overload today's manual CRUD/session model with too many responsibilities. A separate autonomous mode will remain conceptually cleaner and safer.[8][9][10]

## Phase 5: Consider remote/headless architecture
This is the Craft-inspired strategic feature, but not the next one.[7]

### Why defer
Remote/headless mode becomes valuable after Keg proves its local workflow model and automation stack. Otherwise Keg risks building distribution before it finishes the core product.[7][14][25]

## 6. Most important product decision
Keg should avoid trying to become both Craft and Notion at once.

The highest-leverage decision is:

**Build a strong single-user, local-first agent workspace first. Then add governed autonomy. Only then consider remote multi-client infrastructure.**[2][7][8][9][10][25]

That sequence aligns with the current codebase and minimizes architectural thrash.[14][25]

## 7. Immediate recommendation
If Keg chooses only one concrete implementation tranche next, it should be:

### Tranche A: Real Sources + Real Skills + Light Trust Layer
- finish sources persistence, validation, and test flows[23][25]
- finish skills persistence and import/export[25]
- add one global permission-mode indicator/switch[4][15][17]
- add session labels/flags/statuses[23][24]

This tranche is the best next move because it:
- uses code already present in the repo[18][19][20][21][22][23][24][25]
- creates visible product improvement quickly
- aligns with both Craft and Notion patterns[2][3][4][5][9][10][12]
- lays necessary groundwork for automations later[6][8][9][10][13]

## Open Questions
- Should Keg remain single-user/local for the foreseeable future, or is server mode actually on roadmap?[7]
- Should source permissions be session-scoped, agent-scoped, or both?[4][10][11]
- Can Keg offer reversible writes for all source types, or only for its own local metadata and selected integrations?[8][9][10]
- Should autonomous workflows be backed directly by Managed Agents sessions, or by a Keg orchestration layer above them?[19][23][24]

## Bottom Line
Craft provides the best template for **how Keg's agent experience should feel**. Notion provides the best template for **how Keg should make autonomous agents safe and governable**. Keg's best next move is to finish the partially built foundation it already has, then add permission modes and run history, then build automations on top of that. That path is more realistic, safer, and more likely to produce a differentiated product than jumping straight to remote agents or enterprise admin features.[2][4][6][7][8][9][10][13][18][23][24][25]

## Sources
1. Craft Agents homepage, https://agents.craft.do/
2. Craft Agents OSS README, https://github.com/lukilabs/craft-agents-oss/blob/main/README.md
3. Craft Agents docs — Sources overview, https://agents.craft.do/docs/sources/overview.md
4. Craft Agents docs — Permissions, https://agents.craft.do/docs/core-concepts/permissions.md
5. Craft Agents docs — Skills overview, https://agents.craft.do/docs/skills/overview.md
6. Craft Agents docs — Automations overview, https://agents.craft.do/docs/automations/overview.md
7. Craft Agents docs — Remote Server, https://agents.craft.do/docs/server/headless.md
8. Notion Agents product page, https://www.notion.com/product/agents
9. Notion Help — Custom Agents, https://www.notion.com/help/custom-agents
10. Notion Help — Custom Agents sharing and permissions, https://www.notion.com/help/custom-agents-sharing-and-permissions
11. Notion Help — MCP connections for Custom Agents, https://www.notion.com/help/mcp-connections-for-custom-agents
12. Notion Help — Skills for Notion Agent, https://www.notion.com/help/skills-for-notion-agent
13. Notion Help — Custom Agent pricing, https://www.notion.com/help/custom-agent-pricing
14. `CHANGELOG.md`
15. `Sources/Keg/App/AppState.swift`
16. `Sources/Keg/App/KegApp.swift`
17. `Sources/Keg/Views/Sidebar/SidebarView.swift`
18. `Sources/Keg/Views/Settings/SettingsView.swift`
19. `Sources/Keg/Views/Agents/AgentListView.swift`
20. `Sources/Keg/Views/Agents/CreateAgentSheet.swift`
21. `Sources/Keg/Views/Agents/AgentDetailView.swift`
22. `Sources/Keg/Views/Agents/AgentEditorView.swift`
23. `Sources/Keg/Agents/Views/SessionListView.swift`
24. `Sources/Keg/Agents/Views/AgentDashboardView.swift`
25. `Sources/Keg/Agents/Storage/AgentStorage.swift`

## Notes on changes
- Softened the claim that Keg already has a fully usable agent workflow by explicitly distinguishing solid foundations from partially wired surfaces.
- Kept conclusions unchanged; only grounded claims received citations and a few absolute statements were narrowed to match the research files.
