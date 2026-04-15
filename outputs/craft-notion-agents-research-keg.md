# Keg Agents Area Audit

## Scope
Audit of Keg's current Agents implementation against features inspired by Craft Agents and Notion Agents. Grounded in current source files in `Sources/Keg/...` plus `CHANGELOG.md`.

## Executive Assessment
Keg has a credible **phase-1 Agents foundation**: account auth, agent CRUD, session list/detail shell, skills and sources screens, dashboard, area-based navigation, and local storage primitives. But several of the highest-leverage differentiators from Craft and Notion are still missing or only scaffolded: durable source/skill wiring, permission modes, automations, background triggers, run/audit history, source activation semantics, and agent-specific governance.

## Present Today

### 1. Top-level Agents area and routing exist
- Keg has a separate `Agents` area parallel to core container management, selected via `AppArea` and `AgentSection` enums in `AppState.swift`.[1]
- Sidebar routing includes `Dashboard`, `Agents`, `Sessions`, `Sources`, `Skills`, and `Account`.[1][2]
- `KegApp.swift` routes each of these sections to dedicated views, including a dedicated agent account mode for settings.[3]

### 2. Managed Agents account/auth foundation exists
- `SettingsView(mode: .agentAccount)` provides API key connect/disconnect/update flows, masked key preview, and account reload behavior.[4]
- `AgentAuth` stores keys in Keychain and `ManagedAgentsClient.validateCredentials()` performs a minimal API probe rather than assuming a fully-typed list response.[4]
- Recent fixes moved auth state into observable `AppState.isAgentAuthenticated` and added a dedicated Agents → Account route.[1][3][4]

### 3. Agent CRUD works at baseline level
- `AgentListView` shows live agents from Managed Agents API and offers create/archive flows.[5]
- `CreateAgentSheet` allows basic create with name, description, system prompt, and model selection.[6]
- `AgentDetailView` and `AgentEditorView` expose model/description/tools/skills/MCP editing shells and update via `ManagedAgentsClient`.[7][8]
- Model picker was recently corrected to currently-supported managed-agent model IDs (`claude-sonnet-4-6`, `claude-opus-4-6`, `claude-haiku-4-5`, `claude-sonnet-4-5`, `claude-opus-4-5`).[6][8]

### 4. Session listing and inspection exist
- `SessionListView` loads sessions by enumerating agents then listing sessions per agent.[9]
- Selection opens `SessionDetailView` in an inspector.[9]
- Dashboard also surfaces recent sessions and active agents.[10]

### 5. Local storage primitives for skills and sources already exist
- `AgentStorage` defines local JSON persistence for `sources.json` and `skills.json` in `~/Library/Application Support/Keg/Agents`.[11]
- Storage actor supports load/save plus skill import/export helpers.[11]
- `SourceConnectionTester` already implements MCP/REST/files test helpers.[11]

## Partial / Stubbed

### 1. Skills UI exists, but runtime integration is mostly local and not wired through
- `SkillListView` presents CRUD UI, search, duplicate, and edit flows.[12]
- `SkillListVM.load()` is still `TODO`; add/update/delete mutate in-memory arrays only and do not persist through `AgentStorage` yet.[12]
- There is no source auto-activation or explicit relationship between a skill and required sources, unlike Craft.[12]
- There is no clear bridge from local `AgentSkillItem` artifacts to Managed Agents remote skill objects or prompt-time skill invocation semantics.[12]

### 2. Sources UI exists, but storage + testing + runtime activation are incomplete
- `SourceListView` offers add/edit shell for MCP, REST, and filesystem sources.[13]
- `SourceListVM.load()` and save/delete methods are still `TODO`; the local storage actor is not used.[13]
- `SourceEditorView` has a `Test Connection` button, but action body is still `TODO` even though `SourceConnectionTester` exists.[11][13]
- Source config is not persisted from editor fields into `AgentSource.config`; current save path only writes id/name/type/enabled/status.[13]
- No evidence of source activation, mention semantics, or runtime tool injection into sessions today.[13]

### 3. Sessions UI is usable, but operational controls are thin
- `SessionListView` supports filtering/search and selection, but delete flow is still a `TODO` comment despite the context menu UI being present.[9]
- Session loading is simple fan-out over agents; there is no session workflow status, inbox/archive, labels, flags, or background-task monitoring akin to Craft.[9][10]
- Dashboard `messageCount` is placeholder `0` rather than real event-derived counts.[10]

### 4. Agent editing surface is ahead of backend guarantees
- `AgentEditorView` exposes tools, skills, and MCP servers, but some row actions are placeholders and picker/config UX is still shallow.[8]
- `AgentDetailView` allows direct model text editing and exposes TODO placeholders for adding tools/skills/MCP servers in-place.[7]
- This is enough for manual editing, but not yet an opinionated agent-native workflow.

## Missing Relative to Craft / Notion Patterns

### A. No visible permission mode system
- Keg has no user-visible Explore / Ask / Execute mode, no source-scoped permission policies, and no agent-level confirmation policy surface in UI files reviewed.[1][2][3][4][5][13]
- This is a major prerequisite before introducing automations or write-capable source workflows.

### B. No automations / triggers / schedules
- No automation sidebar section, config model, scheduler, event bus, or trigger UI found in reviewed Agents files.[1][2][3][9][10][13]
- Keg lacks both Craft-style local automations and Notion-style schedule/trigger configuration.

### C. No activity log / run log / audit trail layer
- Session history exists, but there is no dedicated run log showing what triggered a run, what the agent did, what tools fired, what failed, and whether changes are reversible.
- This makes governance and debugging weaker than Notion and Craft.

### D. No explicit shared-vs-personal agent split
- All Keg agents currently look like the same object type. There is no distinction between on-demand personal agents and autonomous/shared agents as in Notion.

### E. No source governance or agent-specific access control model
- Source definitions exist locally, but there is no model for "what this agent can access" versus "who can invoke this agent".
- Notion's strongest governance idea is absent.

### F. No background execution / remote headless mode
- Keg uses Anthropic Managed Agents and can inspect sessions, but there is no Keg-native remote server, thin client mode, or hybrid local/remote workspace model analogous to Craft.

### G. No durable workspace concept for agents
- Keg has global local storage for skills/sources, but not Craft-style workspaces with isolated source/skill/session/status/automation bundles.[11]

## Best Immediate Extension Points

### 1. Finish local skills and sources before adding new abstraction layers
Use `AgentStorage` and `SourceConnectionTester` immediately:
- wire `SkillListVM.load/add/update/delete` to `AgentStorage`
- wire `SourceListVM.load/add/update/delete` to `AgentStorage`
- persist real config payloads from `SourceEditorView`
- implement `Test Connection` using `SourceConnectionTester`

**Why first:** large user-visible upgrade, low architectural risk, aligns with existing shells.

### 2. Add permission mode + source trust state before automation
Natural insertion points:
- `AppState.swift` for current mode and persisted preferences
- `SidebarView.swift` / top chrome for mode indicator and quick toggle
- `SourceListView.swift` / `AgentDetailView.swift` for source-specific or agent-specific permission policy display

### 3. Add session metadata: status, flag, labels, and run log
Natural insertion points:
- `SessionListView.swift` table columns and filters
- `SessionDetailView.swift` for activity timeline
- local JSONL persistence for run events if API lacks native concepts

### 4. Add automations only after logs + permission policies exist
Best likely form for Keg:
- local scheduler + event hooks over session lifecycle and source events
- prompt actions that create/reuse sessions
- explicit approvals or allowlisted trusted actions

### 5. Consider a later shared/autonomous agent type
Do not overload the current CRUD surface immediately. Add autonomy only after:
- run logs
- permission model
- quotas/limits
- source governance

## Recommended Keg Feature Mapping
| External pattern | Keg status | Recommendation |
|---|---|---|
| Craft-style MCP/REST/files sources | Partial shell | Finish now |
| Craft-style local skills | Partial shell | Finish now |
| Craft-style permission modes | Missing | Build before automations |
| Craft-style automations | Missing | Build after permission + audit |
| Craft-style multi-session inbox/status | Partial | Add labels/status/flags next |
| Craft-style remote/headless workspace | Missing | Defer |
| Notion-style personal vs autonomous split | Missing | Introduce later as separate mode/type |
| Notion-style agent-specific access model | Missing | Design before write-capable automations |
| Notion-style audit/reversible run history | Missing | High priority |
| Notion-style quotas/limits | Missing | Add with automations |

## Verdict
Keg is **not starting from zero**. It already has the screens and basic API scaffolding needed to absorb many Craft/Notion patterns. But the most important next step is **not** adding more top-level screens. It is completing the existing Skills/Sources foundation, then adding a trust/governance layer: permission modes, run logs, and later automations.

## Sources
1. `Sources/Keg/App/AppState.swift`
2. `Sources/Keg/Views/Sidebar/SidebarView.swift`
3. `Sources/Keg/App/KegApp.swift`
4. `Sources/Keg/Views/Settings/SettingsView.swift`
5. `Sources/Keg/Views/Agents/AgentListView.swift`
6. `Sources/Keg/Views/Agents/CreateAgentSheet.swift`
7. `Sources/Keg/Views/Agents/AgentDetailView.swift`
8. `Sources/Keg/Views/Agents/AgentEditorView.swift`
9. `Sources/Keg/Agents/Views/SessionListView.swift`
10. `Sources/Keg/Agents/Views/AgentDashboardView.swift`
11. `Sources/Keg/Agents/Storage/AgentStorage.swift`
12. `Sources/Keg/Agents/Views/SkillListView.swift`
13. `Sources/Keg/Agents/Views/SourceListView.swift`
14. `CHANGELOG.md`
