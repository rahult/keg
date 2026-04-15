# Keg Agents Area Audit

## Scope
Audit of Keg’s current Agents implementation against likely Craft/Notion-inspired features. Grounded in actual Keg source files plus `CHANGELOG.md`. No external product claims are made here except as comparison categories already established in the broader research run.

## Executive Assessment
Keg already has a credible **phase-1 Agents foundation** across three layers:
1. **Surface/UI layer** — dedicated Agents navigation, account screen, dashboard, agent CRUD, sessions, sources, skills
2. **Managed Agents API layer** — Anthropic client/types/auth/session CRUD
3. **Local runtime/persistence layer** — session store, event persistence, local tool executor, lightweight runtime orchestration

That is a stronger baseline than the current UI alone suggests. However, many of the highest-value Craft/Notion-inspired features are still either **stubbed in UI** or **implemented privately in runtime but not exposed as product features**. The biggest gaps remain:
- durable Sources and Skills wiring
- visible permission/trust model
- session workflow metadata and run history in UI
- automations/triggers/schedules
- explicit agent-specific governance model
- coherent bridge between local runtime primitives and the Agents UX

## Present Today

## 1. Top-level Agents area and routing exist
- `AppState.swift` defines a dedicated `AppArea.agents` plus `AgentSection` routing for `dashboard`, `agents`, `sessions`, `sources`, `skills`, and `account`.[1]
- `SidebarView.swift` renders a separate Agents sidebar with grouped sections and selection binding.[2]
- `KegApp.swift` routes each agent section to a dedicated view, including a dedicated account/settings mode for Agents.[3]

**What this means:** Keg already has the structural shell needed for a Craft-style agent workspace.

## 2. Managed Agents account/auth foundation is real
- `SettingsView.swift` includes a dedicated account mode with connect/disconnect/update-key flows, masked stored key preview, and account reload behavior.[4]
- `AppState.isAgentAuthenticated` is observable and refreshed from Keychain-backed auth state.[1][4]
- `ManagedAgentsClient.validateCredentials()` is used as a lightweight auth probe rather than depending on more fragile typed reads.[4]

**What this means:** Keg already has a usable personal/manual agent account surface.

## 3. Agent CRUD is functional at baseline
- `AgentListView.swift` loads live agents from the Managed Agents API and supports create/archive flows.[5]
- `CreateAgentSheet.swift` creates agents with name, description, system prompt, and supported managed-agent model IDs.[6]
- `AgentDetailView.swift` and `AgentEditorView.swift` expose model/description/tools/skills/MCP editing surfaces and call back into the Managed Agents client for updates.[7][8]
- `Agents/ViewModels/AgentListVM.swift` provides a narrower CRUD-focused VM variant over the same client layer.[14]

**What this means:** Keg already supports the core “manual agent object” model.

## 4. Sessions list/detail and dashboard exist
- `SessionListView.swift` enumerates agents then sessions, supports selection/search/filter, and opens `SessionDetailView` in an inspector.[9]
- `AgentDashboardView.swift` summarizes active agents and recent sessions.[10]

**What this means:** There is already a visible session surface to grow into a richer multi-session workflow model.

## 5. Local storage primitives for Skills and Sources already exist
- `AgentStorage.swift` persists `sources.json` and `skills.json` under `~/Library/Application Support/Keg/Agents`.[11]
- That same file includes `SkillExportFile` import/export helpers and `SourceConnectionTester` for MCP/REST/files checks.[11]

**What this means:** Keg already has the substrate for the first recommended tranche; it just is not fully wired into the current views.

## 6. A local runtime/session-management layer already exists
This is the biggest hidden asset in the codebase and the most important architectural extension point.

- `SessionManager.swift` persists session metadata and event streams to disk via `SessionStore`, including `session.json` and `events.jsonl` per session.[12]
- `SessionManager` supports status transitions, event recording, session restoration, cleanup, and convenience helpers for starting/completing/failing/canceling sessions.[12]
- `AgentRuntime.swift` implements a local agent loop over Managed Agents sessions: create session, send message, react to tool-use events, execute tools, and stream results.[13]
- `ToolExecutor.swift` implements concrete local tools (`bash`, `read`, `write`, `edit`, `glob`, `grep`, `web_fetch`, `web_search`).[13]
- `SessionManager` also references `HybridAgentRunner` and lightweight container prewarming, indicating a local/runtime execution direction beyond pure remote Managed Agents CRUD.[12]

**What this means:** Keg already contains runtime-oriented building blocks for future Craft/Open-Agents-style background work, but they are not yet surfaced as a coherent product capability in the Agents UI.

## Partial / Stubbed

## 1. Skills UI exists, but durable behavior is not fully wired
- `SkillListView.swift` has a good shell: table, create/edit sheet, duplicate action, search, and empty state.[15]
- But `SkillListVM.load()` is still a stub, and add/update/delete currently operate only in memory rather than via `AgentStorage`.[15]
- Export is still `TODO` in the context menu despite `AgentStorage.exportSkill()` already existing.[11][15]
- There is no visible source activation model or runtime invocation linkage similar to Craft-style `requiredSources` or even a clear Keg-local execution path for skills.[15]

**Assessment:** Partial. The UI is there, the storage substrate is there, but the feature is not product-complete.

## 2. Sources UI exists, but config persistence + testing + activation are incomplete
- `SourceListView.swift` supports MCP/REST/files source creation/editing in UI.[16]
- `SourceListVM.load()`, save, update, and delete are still stubbed against storage.[16]
- `Test Connection` is still a placeholder despite `SourceConnectionTester` being implemented already.[11][16]
- `SourceEditorView.save()` currently creates only shallow `AgentSource` values and does not preserve the actual MCP URL / REST endpoint / filesystem patterns in `AgentSource.config`.[16]
- There is no evidence of runtime source activation semantics, per-session source selection, or mention-style usage.

**Assessment:** Partial. This is the clearest “finish-now” area.

## 3. Sessions UI is usable, but workflow + audit depth are thin
- `SessionListView.swift` gives table/search/filter/inspector behavior, but not workflow state such as labels, flags, or status stages beyond the remote API’s session status.[9]
- The context menu delete path still notes `TODO: Implement delete` behavior even though the API supports `deleteSession` elsewhere.[9][13]
- `AgentDashboardView.swift` still uses placeholder `messageCount: 0` in session summaries.[10]
- `SessionManager.swift` already persists events to `events.jsonl`, but the UI audit/history model does not appear to exploit that local store in the visible session surfaces.[12]

**Assessment:** Partial. UI and persistence exist, but they are not joined into a richer run-history/governance model yet.

## 4. Agent editing surface is ahead of backend guarantees
- `AgentEditorView.swift` exposes tools, skills, and MCP server sections, but some row operations remain shallow and the model is still a generic editor rather than an opinionated agent-native workflow.[8]
- `AgentDetailView.swift` still contains TODO-style placeholders for adding tools/skills/MCP servers in-place.[7]

**Assessment:** Partial. Enough for CRUD, not enough for a differentiated workflow product.

## 5. Local runtime is present, but disconnected from Agents product language
- `AgentRuntime.swift` and `ToolExecutor.swift` already embody concepts like local tool execution, iterative agent loops, and streaming runs.[13]
- `SessionManager.swift` already has event persistence and lifecycle transitions.[12]
- But none of this is surfaced to users as visible permission modes, local workflow automations, activity timelines, or background execution controls.

**Assessment:** Partial. Architecture exists below the UI, but the product has not claimed it yet.

## Missing Relative to Craft / Notion / Open Agents Patterns

## A. No visible permission mode system
- No Explore / Ask / Execute mode in current UI surfaces reviewed.[1][2][3][4][5][16]
- No source-scoped or agent-scoped visible trust state.
- No user-facing bridge from `ToolExecutor` power to explicit safety semantics.

**Why this matters:** This is the main prerequisite before automations, autonomous runs, or write-capable source workflows.

## B. No automations / triggers / schedules
- No automation models, scheduler UI, trigger config, or automation history surfaced in current Agents views.[1][2][3][9][10][15][16]
- `SessionManager` has lifecycle hooks and persistence, but no productized trigger system built on top of them.[12]

**Why this matters:** Both Craft and Notion derive a lot of product value from automation after trust/governance are in place.

## C. No strong run log / activity timeline in product UI
- Keg persists events locally in `events.jsonl` through `SessionStore`, but the user-facing Agents experience does not yet expose a clear activity log / audit trail / reversible action history.[12]

**Why this matters:** Notion-style governance and even Craft-style background work need better observability.

## D. No explicit manual-vs-autonomous agent split
- Current agent objects are all the same kind of thing: manually created and manually interacted with.[5][6][7][8][14]
- There is no Notion-style distinction between personal/manual agents and trigger-driven/shared/autonomous agents.

## E. No source governance / capability scope model
- Sources are currently just local definitions, not explicit capability grants attached to agents or sessions.[11][16]
- There is no model for “this agent can access X” separate from “this user can invoke Y”.

## F. No productized background execution / remote-headless mode
- There is no Keg-native remote server, thin client mode, or session resilience UX analogous to Craft/Open Agents.[2][3][7]
- However, the local runtime layer suggests Keg could evolve that way later.[12][13]

## G. No durable agent workspace concept
- Keg stores sources/skills globally under Application Support, not as Craft-style isolated workspaces with per-workspace skills/sources/statuses/automations.[11]

## Best Concrete Extension Points

## 1. Finish local Skills and Sources first
Use code that already exists:
- `AgentStorage.swift` for persistence
- `SourceConnectionTester` for real source validation
- `SkillListView.swift` and `SourceListView.swift` for existing UX shells

**Why first:** Lowest-risk, highest visible upgrade.

## 2. Surface trust state before autonomy
Natural insertion points:
- `AppState.swift` for authoritative global agent permission mode
- `SidebarView.swift` or shared app chrome for mode display/toggle
- `SourceListView.swift` and `AgentDetailView.swift` for later source/agent-level scope indicators

## 3. Turn SessionStore/SessionManager into a user-visible run-history feature
Natural insertion points:
- `SessionListView.swift` for local workflow metadata columns/filters
- `SessionDetailView.swift` for activity timeline backed by persisted `events.jsonl`
- `SessionManager.swift` as the authoritative writer for later automation/run events

## 4. Build automations on top of existing lifecycle primitives, not from scratch
Best likely foundation:
- local scheduler + trigger model over `SessionManager` lifecycle events
- prompt-first automation actions before command-heavy autonomy
- explicit approvals or later permission-mode enforcement before write actions

## 5. Keep later remote/background work architecturally separate from execution substrate
If Keg later expands toward Open-Agents-style remote execution, the clean extension path is:
- keep orchestration/workflow state above execution substrate
- treat Apple Container / lightweight containers / future remote sandboxes as replaceable execution environments
- avoid binding all run state to one UI process

`SessionManager.swift` + `AgentRuntime.swift` are the main seeds for that future direction.[12][13]

## Recommended Keg Feature Mapping
| External pattern | Current Keg status | Best next move |
|---|---|---|
| Craft-style MCP/REST/files sources | Partial shell + storage substrate | Finish now |
| Craft-style local skills | Partial shell + storage substrate | Finish now |
| Craft-style permission modes | Missing | Build before automation |
| Craft-style automations | Missing in product, weak runtime seeds exist | Build after permission + activity layer |
| Craft-style multi-session workflow inbox/status | Partial | Add labels/status/flags next |
| Notion-style personal vs autonomous split | Missing | Introduce later as separate mode/type |
| Notion-style agent-specific access model | Missing | Design before write-capable automations |
| Notion-style audit/reversible run history | Runtime persistence exists, UI missing | Surface next |
| Open Agents-style durable orchestration outside sandbox | Architectural seeds only | Defer, but preserve separation |
| Open Agents-style remote/headless execution | Missing | Defer |

## Verdict
Keg is **not starting from zero**. It already has the screens, the remote API layer, and — importantly — a hidden local runtime/session-management layer that could support richer agent workflows later. But today the strongest next move is still the same:

1. finish Skills and Sources as real local features
2. add visible trust/governance primitives (permission modes, session workflow metadata, activity history)
3. only then build automations and later autonomous/background agent modes

The codebase is closer to those next steps than the current UI suggests.

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
12. `Sources/Keg/Agent/SessionManager.swift`
13. `Sources/Keg/Agent/AgentRuntime.swift`, `Sources/Keg/Agent/ToolExecutor.swift`
14. `Sources/Keg/Agents/ViewModels/AgentListVM.swift`
15. `Sources/Keg/Agents/Views/SkillListView.swift`
16. `Sources/Keg/Agents/Views/SourceListView.swift`
17. `CHANGELOG.md`
