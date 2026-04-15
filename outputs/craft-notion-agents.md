# Craft Agents and Notion Agents: What Keg Should Implement Next

## Executive Summary
Craft Agents, Notion Agents, and Open Agents solve adjacent but meaningfully different problems. Craft is strongest as an **agent-native desktop interface**: multi-session workflow, broad source connectivity, visible permission modes, lightweight skills, automations, and optional remote/headless execution.[1][2][3][4][5][6][7] Notion is strongest as a **governance model for autonomous agents**: a clean split between personal and custom agents, explicit agent-specific access, schedule/trigger configuration, activity and audit logs, reversible changes, and usage guardrails.[8][9][10][11][12][13] Open Agents is strongest as a **cloud-native execution architecture**: durable workflows outside the sandbox, resumable runs, isolated per-session sandboxes, and deep git/GitHub automation.[26][27]

Keg already has a real Agents foundation: account/authentication, agent CRUD, session list/detail views, dashboard routing, source and skill screens, and local storage primitives for sources and skills.[14][15][16][17][18][19][20][21][22][23][24][25] However, much of that surface is still only partially wired. The biggest missing pieces are not more top-level screens; they are the connective systems that make agents useful and trustworthy: durable source/skill persistence, source testing and activation, permission modes, session workflow metadata, run history, and eventually automations.[18][23][24][25]

The clearest recommendation is to copy **Craft's UX grammar**, **Notion's governance grammar**, and only selectively borrow **Open Agents' runtime grammar** for any later background or remote execution layer. In practical terms, Keg should first finish Sources and Skills, then add visible trust controls and auditability, then introduce scheduled/event-driven automation, and only after that consider a separate autonomous/shared agent model. Remote/headless multi-client architecture is strategically interesting, but it should wait until the local-first workflow is solid.[1][2][4][6][7][8][9][10][11][13][15][16][17][18][23][24][25][26][27]

## 1. What Craft Agents contributes
Craft shows what a desktop agent product looks like when the agent is the primary interaction model rather than an add-on. Its strongest public patterns are:

- **Multi-session, workspace-scoped workflow.** Sessions persist, carry workflow state, and live inside workspace-level isolation boundaries with their own sources, skills, statuses, and automations.[2][6]
- **Broad source model.** MCP servers, REST APIs, and local files/folders are all first-class source types rather than ad hoc integrations.[1][2][3]
- **Visible permission modes.** Explore, Ask to Edit, and Execute provide a clear user-facing trust model and can be customized with layered rules.[2][4]
- **Lightweight skills.** Skills are simple `SKILL.md` artifacts using an open standard and can declare required sources for automatic activation.[2][5]
- **Automations.** Event-driven and scheduled automations can create sessions or execute commands in response to labels, statuses, tool events, or cron schedules.[2][6]
- **Remote/headless operation.** Craft can run as a remote server with desktop, browser, and CLI access to the same workspace/session backend.[2][7]

The most important lesson is not any one feature. It is the composition: sources, skills, sessions, permissions, and automations feel like parts of one coherent workflow system.[2][3][4][5][6]

## 2. What Notion Agents contributes
Notion is less interesting as a desktop interaction model and more interesting as a **control plane for autonomous work**.

### Personal vs custom agent split
Notion distinguishes **Notion Agent** as a personal, on-demand assistant from **Custom Agents** that run in the background for shared workflows.[8][9][10] That distinction is productively clean: one mode is conversational and immediate, the other is workflow automation.

### Agent-specific access and sharing model
Custom Agents do not simply inherit the triggering user's permissions. They have their own explicit access to pages, databases, connected tools, Slack channels, MCP connections, and other resources, plus a separate sharing model governing which humans may interact with them.[9][10][11] This is one of Notion's strongest ideas because it separates **capability scope** from **user visibility**.[10][11]

### Trigger and schedule productization
Custom Agents run on recurring schedules and on events from Notion and Slack, including database/page events, comments, Slack messages, emoji reactions, and mentions.[8][9] Triggers and schedules are a core configuration surface, not a side scripting feature.[9]

### Activity, auditability, and reversibility
Notion repeatedly couples autonomy with visibility: activity logs, audit logs, analytics, version history, disablement controls, and reversible edits.[8][9][10] It also adds operational guardrails such as credit tracking and per-agent credit limits that can automatically pause agent runs.[13]

### Skills remain separate from autonomous agents
Skills in Notion are reusable saved prompts, distinct from both personal instructions and from Custom Agents.[12] That keeps the product model layered rather than monolithic.

## 3. What Open Agents contributes
Open Agents is useful as a third comparison target because it answers a different question than Craft or Notion. It is not mainly a desktop workspace UX or an enterprise governance layer. It is an architectural reference app for **background coding agents running on durable workflows and isolated sandboxes**.[26][27]

### Durable orchestration outside the execution environment
Open Agents explicitly separates the agent workflow from the sandbox VM. The agent runs as a durable workflow outside the sandbox and interacts with the sandbox through tools such as file reads, edits, search, and shell commands.[27] This means workflow lifecycle, sandbox lifecycle, and client connection lifecycle can evolve independently.[27]

### Resumable cloud execution
The product emphasizes isolated per-session sandboxes, branch-per-session git work, snapshots, hibernation/restore, reconnectable streams, and optional auto-commit/push/PR behavior.[26][27] This is the cleanest of the three products as a model for long-running coding-agent execution that survives disconnects or environment churn.[26][27]

### Why this matters to Keg
Open Agents does **not** change Keg's immediate product priorities. Keg still most urgently needs better sources, skills, permissions, and run history. But Open Agents is the strongest reference if Keg later wants remote/headless execution or durable background workflows. It suggests Keg should avoid coupling orchestration too tightly to one UI process or to one container/VM lifecycle.[26][27]

## 4. Keg's current position
Keg is not starting from zero. Its current codebase already includes:

- a dedicated `Agents` area parallel to core Keg/container navigation, with sections for dashboard, agents, sessions, sources, skills, and account.[15][16][17]
- a dedicated account/authentication flow with connect, disconnect, replace-key, and masked-key display.[18]
- Managed Agents CRUD via `AgentListView`, `CreateAgentSheet`, `AgentDetailView`, and `AgentEditorView`.[19][20][21][22]
- session list/detail UI and dashboard summaries of active agents and recent sessions.[23][24]
- local JSON-file storage primitives for `sources.json` and `skills.json`, plus a `SourceConnectionTester` actor for MCP, REST, and filesystem checks.[25]

That means Keg already has the right **surface area**. The problem is that several of those surfaces are only partially implemented.

## 5. What is incomplete in Keg today

### Sources are still mostly shells
`SourceListView` exposes source creation and editing UI for MCP, REST, and filesystem sources, but `SourceListVM.load()` and persistence methods are still marked `TODO`, and the editor currently saves only shallow fields instead of the full config payload needed for runtime use.[23][25] The `Test Connection` button is also still unimplemented in the view even though `SourceConnectionTester` already exists.[23][25]

### Skills are local but not fully wired
`SkillListView` exposes CRUD UI, but `SkillListVM.load()` is still `TODO` and add/update/delete are currently in-memory mutations rather than true persistence flows through `AgentStorage`.[25] There is also no visible equivalent of Craft's `requiredSources` activation or Notion's clean distinction between reusable skills and autonomous agents.[12][25]

### Sessions lack workflow and audit depth
`SessionListView` can list, search, filter, and inspect sessions, but it does not yet expose richer workflow metadata such as status pipelines, labels, flags, or a dedicated run/activity timeline.[23][24] Session deletion in the context menu is still explicitly marked `TODO` in current code comments.[23]

### No visible trust/governance layer yet
Keg has account auth, but it does **not** yet have:
- a Craft-style visible permission mode system
- a Notion-style agent capability scope model
- a run log / audit trail / reversibility layer
- scheduled or event-triggered automations[15][16][17][18][23][24][25]

Those omissions matter more than missing screens, because they are the systems required to make autonomous behavior safe.

## 6. Where Craft, Notion, and Open Agents overlap most usefully
The overlapping high-value cluster is where Keg should focus.

### Shared patterns worth implementing
1. **Richer source connectivity** with explicit configuration and validation.[1][2][3][8][9][11]
2. **Reusable skills/instructions** separated from one-off chat.[2][5][12]
3. **Background or scheduled workflows** once the substrate is trustworthy.[6][8][9]
4. **Permission and safety controls** that are visible in the UI.[4][10][11]
5. **Auditability and run history** for autonomous behavior.[8][9][10][13]
6. **Multi-session workflow organization** rather than treating every session as flat chat history.[1][2][6]
7. **Durable orchestration separated from execution substrate** for any future remote/background architecture.[26][27]

These are the features that matter in both products, even though each product emphasizes them differently.

## 7. Recommended implementation sequence for Keg

## Phase 1: Finish Sources and Skills
This is the best immediate tranche because Keg already has the UI shells and storage primitives.[23][25]

### Build now
- persist skills through `AgentStorage`[25]
- persist sources through `AgentStorage`[25]
- store full source config payloads instead of only shallow metadata[23][25]
- implement source connection testing in UI using `SourceConnectionTester`[23][25]
- support source enable/disable and status refresh[23][25]
- add import/export for skills[25]
- make source and skill usage more visible in agent/session flows[19][21][22][23][24]

### Why first
This work upgrades daily usability without forcing new architecture. It also directly matches the strongest Craft/Notion overlap around composable sources and reusable instructions.[2][3][5][9][11][12]

## Phase 2: Add trust and observability primitives
Before Keg introduces automation, it should make agent behavior understandable and controllable.

### Build next
- visible permission mode switch, ideally with Craft-like semantics: Explore, Ask, Execute[4]
- session labels, flags, and workflow statuses inspired by Craft's inbox/state model[2][6]
- run timeline / activity history in session detail, informed by Notion's activity/audit model[8][9][10]
- clear indication of which sources an agent/session may use[3][10][11]
- provenance metadata for tool usage, errors, and approvals[9][10][13]

### Why second
This is the layer that makes later automation safe enough to ship. Without it, Keg would add power before it adds trust.

## Phase 3: Add automations and scheduled workflows
Once trust and auditability exist, Keg can borrow the strongest common idea from both products: autonomous workflows.

### Build later
- cron/time-based schedules inspired by both Craft and Notion.[6][9]
- triggers based on session labels/status or other Keg-local events, similar to Craft's app-event model.[6]
- prompt actions that create or resume sessions, analogous to Craft prompt automations and Notion background runs.[6][9]
- execution history and failure logs for automations.[6][8][9][10]
- enable/disable/test controls for each automation.[6]
- loop prevention, rate limits, timeouts, approval gates, and quotas/limits.[6][13]

### Why not first
Automation without permission modes and run logs would create opaque failure modes and unsafe write behavior.

## Phase 4: Introduce autonomous/shared agent mode
This is the Notion-inspired boundary that should come only after Keg can observe and constrain automation safely.

### Build later still
- separate manual vs autonomous agent type or mode[8][9][10]
- explicit capability scopes per autonomous agent[10][11]
- trigger configuration only for autonomous agents[9]
- stricter defaults and quota/limit controls for autonomous agents[13]

### Why separate it
Keg should not overload today's manual CRUD/session model with too many responsibilities. A distinct autonomous mode will remain conceptually cleaner and safer.

## Phase 5: Consider remote/headless architecture
This is where Open Agents becomes most relevant and where Craft remains useful as a client/workspace reference.[7][26][27]

### Why defer
Remote/headless mode becomes valuable after Keg proves its local workflow model and automation stack. Otherwise Keg risks building distribution before it finishes the core product.

### What to borrow later from Open Agents
- durable workflow orchestration outside the execution container/VM[27]
- resumable/background runs that survive client disconnects[26][27]
- clearer separation between orchestration layer and execution substrate[27]
- deeper git/session coupling for coding-agent workflows if Keg chooses to support them[26][27]

## 8. Immediate recommendation
If Keg chooses only one concrete implementation tranche next, it should be:

## Tranche A: Real Sources + Real Skills + Light Trust Layer
- finish sources persistence, validation, and test flows[23][25]
- finish skills persistence and import/export[25]
- add one global permission-mode indicator/switch in app chrome and state[15][17]
- add session labels/flags/statuses[23][24]

This tranche is the best next move because it:
- uses code already present in the repo[18][19][20][21][22][23][24][25]
- creates visible product improvement quickly
- aligns with both Craft and Notion patterns[2][3][4][5][9][10][12]
- lays necessary groundwork for automations later[6][9][10][13]

## Open Questions
- Should Keg remain single-user/local for the foreseeable future, or is server mode actually on roadmap? This affects how much of Craft's remote model is worth copying now.[7]
- Should source permissions be session-scoped, agent-scoped, or both? Notion suggests agent-specific access; Craft suggests workspace/source layering.[4][10][11]
- Can Keg offer reversible writes for all source types, or only for its own local metadata and selected integrations? Notion's reversibility model is strongest where the platform itself controls the write surface.[8][9][10]
- Should autonomous workflows be backed directly by Managed Agents sessions, or by a Keg orchestration layer above them? Current Keg code supports manual/session CRUD but not yet an automation control plane.[19][23][24]

## Bottom Line
Craft provides the best template for **how Keg's agent experience should feel**. Notion provides the best template for **how Keg should make autonomous agents safe and governable**. Open Agents provides the best template for **how a future remote/background execution layer should be architected**. Keg's best next move is still to finish the partially built foundation it already has, then add permission modes and run history, then build automations on top of that. Only after that should it borrow Open Agents-style durable orchestration or cloud-sandbox patterns.[2][4][6][7][8][9][10][13][18][23][24][25][26][27]

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
26. Open Agents product page, https://open-agents.dev/
27. Open Agents README, https://github.com/vercel-labs/open-agents/blob/main/README.md
