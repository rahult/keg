# Keg Agents: Automations and Autonomous Agents Architecture

**Plan:** `outputs/.plans/craft-notion-agents.md`

## Purpose
This artifact translates the completed Craft / Notion / Open Agents research into an implementation-grade architecture for the next phases of Keg's Agents area. It answers:

- how Keg should introduce automations without overloading the current manual session model
- how manual and autonomous agents differ
- what the first trigger/action model should be
- where workflow metadata and automation history should live
- where permission mode and capability scope should be enforced
- when Open Agents-style durable orchestration becomes relevant

This is a **local-first** design. It intentionally avoids jumping straight to remote/headless architecture.

---

## 1. Current runtime boundary in Keg

Keg already has four important runtime pieces:

### 1.1 `SessionManager`
File: `Sources/Keg/Agent/SessionManager.swift`

What it already does:
- persists sessions and events through `SessionStore`
- tracks active sessions and status listeners
- handles local session lifecycle transitions (`pending -> running -> completed/failed/cancelled`)
- records events to local JSONL
- provides convenience execution hooks around `HybridAgentRunner`

What this means:
- Keg already has a local lifecycle manager that can become the **automation execution coordinator** for local-first workflows
- it is the natural place to emit lifecycle events for automations
- it is **not yet** a scheduler, automation engine, or durable orchestration layer

### 1.2 `AgentRuntime`
File: `Sources/Keg/Agent/AgentRuntime.swift`

What it already does:
- creates Managed Agents sessions remotely
- sends user events
- loops over assistant/tool/status events
- executes tools through `ToolExecutor`
- supports streaming and non-streaming runs

What this means:
- this is the natural place to run **manual** and later **autonomous** prompt-driven agent sessions against Anthropic Managed Agents
- it currently assumes a user-driven runtime loop rather than a trigger-driven automation context

### 1.3 `ToolExecutor`
File: `Sources/Keg/Agent/ToolExecutor.swift`

What it already does:
- local implementations for bash/read/write/edit/glob/grep/web_fetch/web_search
- working directory–scoped execution
- direct shell and file mutation

What this means:
- permission mode and capability scope must eventually gate behavior here or in a wrapper immediately above it
- this file is part of the execution substrate, not the long-term orchestration control plane

### 1.4 `AppState`
File: `Sources/Keg/App/AppState.swift`

What it already does:
- area/section routing
- account/auth state
- global `AgentPermissionMode` persistence
- selected agent/session state

What this means:
- `AppState` should remain UI/session state, not become the long-running automation authority
- it is the right place for current global mode and visible user controls, but not for background workflow scheduling logic

---

## 2. Design principles

### Principle 1 — Manual and autonomous agents are different products
Keg should not overload the current manual chat/session model with automation behavior.

- **Manual agent** = user starts a session, sends prompts, inspects output interactively
- **Autonomous agent** = runs from a trigger or schedule with explicit capability scope and history

This follows Notion's strongest boundary and avoids muddling the UX.

### Principle 2 — Local-first before remote-first
Automations should begin as local Keg features using local persistence and local scheduling. Remote/headless architecture can come later.

### Principle 3 — Trust before autonomy
Permission mode, run history, and capability scope must exist before write-capable automation is introduced.

### Principle 4 — Orchestration should eventually be separable from execution substrate
Open Agents is right that orchestration should not be tied forever to one UI process or one container/VM lifecycle. Keg does not need to implement that now, but this architecture should leave room for it.

### Principle 5 — Prompt actions first, command actions later
First automation actions should create or resume agent sessions. Raw shell command actions should be deferred until permission and provenance controls are stronger.

---

## 3. Agent modes

## 3.1 Manual agents
Manual agents are the current default.

### Semantics
- user-created or user-selected
- runs begin from explicit user action
- session stays visible and conversational
- source usage is interactive and inspectable
- existing Agents/Session views remain the main UI

### Allowed behavior
- manual prompt sends
- tool execution during an interactive session
- workflow status/labels/flags in the session UI
- source selection and skill invocation

### Not allowed by default
- schedules
- event triggers
- unattended background runs

## 3.2 Autonomous agents
Autonomous agents are a new layer added later.

### Semantics
- associated with triggers and/or schedules
- have explicit capability scope
- run without a user pressing Send for each execution
- produce run history even if the UI is closed at run start

### Required configuration
- trigger set
- allowed source scope
- allowed action scope
- run limit / quota policy
- default execution mode (initially always bounded by permission rules)

### Minimum UI representation
- separate section or filter state, not mixed invisibly with manual sessions
- visible badge such as `Manual` / `Autonomous`
- visible trigger summary
- visible last run outcome

### Recommendation
Do **not** implement autonomous agents as a boolean on the current `Agent` UI until the trigger model and history model exist. Introduce them only after the automation layer is real.

---

## 4. Automation model

## 4.1 First release scope
Automations should be **workspace-local** and **prompt-driven**.

That means:
- local storage in Application Support
- local scheduler/event observer
- action creates or resumes a Keg-managed session
- no remote headless worker requirement

## 4.2 Trigger types for first implementation
Start with triggers Keg can observe reliably from its own state.

### A. Schedule trigger
Examples:
- every day at 9:00
- every weekday at 17:00
- every Monday

Why first:
- easy to reason about
- no dependency on external integrations
- close to both Craft and Notion patterns

### B. Session workflow trigger
Examples:
- when a session is flagged
- when a session status changes to `Needs Review`
- when a label is added

Why first:
- Keg now has local workflow overlay models
- these events are local and inspectable
- good bridge between manual workflow and automation

### C. Session lifecycle trigger
Examples:
- when a session starts
- when a session completes
- when a session fails

Why later in phase 1/2 of automation:
- natural fit to `SessionManager`
- useful for summaries and follow-ups

## 4.3 Deferred trigger types
Not in first automation release:
- source-native external webhooks
- Notion/Slack-style connector events
- tool pre/post hooks
- remote agent lifecycle hooks

These come later after local automation patterns are proven.

---

## 5. Action model

## 5.1 Prompt action (first-class, first release)
This is the default automation action.

### Shape
- create a new session or resume an existing one
- optionally target an agent by ID
- send a prompt
- optionally apply labels/status on the created session
- record run history

### Example
- Every weekday at 9 AM, create a new session with `Daily Briefing` label and send `Summarize high-priority containers and flagged agent sessions`.

### Why first
- aligns with Keg's current Managed Agents + Session model
- easier to govern than arbitrary shell commands
- produces visible session artifacts users already understand

## 5.2 Deferred actions
### Raw command action
- execute local shell command without creating a conversation session
- high risk
- only useful once permission enforcement and provenance are stronger

### Source write action
- direct writes to REST/MCP/file sources without full session loop
- defer until capability scope is explicit

### Notification/webhook action
- useful, but should come after prompt actions and history storage are proven

---

## 6. Storage model

## 6.1 New local models
These should live alongside current local Agents storage, not in `AppState`.

### `AutomationDefinition`
Suggested home: `Sources/Keg/Agents/Storage/AgentAutomationStorage.swift` or alongside `AgentStorage.swift` if kept small initially.

```swift
struct AutomationDefinition: Codable, Identifiable {
    let id: String
    var name: String
    var isEnabled: Bool
    var targetAgentID: String
    var mode: AutomationMode
    var trigger: AutomationTrigger
    var action: AutomationAction
    var labelsToApply: [String]
    var createdAt: Date
    var updatedAt: Date
}
```

### `AutomationTrigger`
```swift
enum AutomationTrigger: Codable {
    case schedule(ScheduleTrigger)
    case sessionStatus(SessionStatusTrigger)
    case sessionFlag(SessionFlagTrigger)
    case sessionLabel(SessionLabelTrigger)
}
```

### `AutomationAction`
```swift
enum AutomationAction: Codable {
    case prompt(PromptAction)
}
```

### `AutomationRunRecord`
```swift
struct AutomationRunRecord: Codable, Identifiable {
    let id: String
    let automationID: String
    let triggeredAt: Date
    let triggerSummary: String
    let sessionID: String?
    let outcome: AutomationRunOutcome
    let message: String
}
```

### `AgentCapabilityScope`
This is not a permission mode. It is the explicit scope of what an autonomous agent may touch.

```swift
struct AgentCapabilityScope: Codable {
    var sourceIDs: [String]
    var allowWebAccess: Bool
    var allowPromptRuns: Bool
    var allowWrites: Bool
}
```

## 6.2 File persistence
Recommended paths under Application Support:

- `Keg/Agents/automations.json`
- `Keg/Agents/automation-history.jsonl`
- `Keg/Agents/agent-capability-scopes.json`

Why:
- consistent with current `AgentStorage` patterns
- keeps local-first implementation simple
- easy migration path later to per-workspace storage if Keg adds workspaces

---

## 7. History and observability model

## 7.1 Session history remains user-facing truth
Prompt-driven automations should create/resume sessions so users can inspect the result in existing UI.

## 7.2 Automation run history is separate
Do not force automation history into session events alone.

Session history answers:
- what happened in the conversation

Automation history answers:
- what triggered the run
- which automation fired
- whether session creation succeeded
- whether the run failed before a session existed
- how many runs happened in a period

This is more like Notion's Activity tab than chat history.

## 7.3 First history UI
Minimum later UI:
- list of automations
- last run timestamp
- last outcome
- detail page showing recent run records

Do not require full analytics in the first release.

---

## 8. Permission and capability enforcement

## 8.1 Global permission mode
Current `AgentPermissionMode` in `AppState` stays as the user-facing top-level trust mode.

### Intended semantics
- `Explore`: no mutation-capable autonomous runs
- `Ask`: automations may propose or create sessions, but any direct mutation actions remain gated
- `Execute`: trusted background prompt runs allowed within scoped capabilities

## 8.2 Capability scope
Autonomous behavior needs **capability scope**, distinct from global permission mode.

Global mode answers:
- how much autonomy is currently allowed overall?

Capability scope answers:
- what may this automation/autonomous agent access or mutate?

### Enforcement order
1. Global `AgentPermissionMode`
2. Automation enabled/disabled state
3. Agent capability scope
4. Source enabled state
5. Tool/action-specific enforcement

## 8.3 Enforcement points in code

### `AppState`
Use for:
- current global mode
- UI presentation
- top-level gating for starting autonomous runs from the app process

Do not use for:
- storing automation definitions
- long-running scheduler state

### `SessionManager`
Use for:
- emitting local session lifecycle events
- creating sessions for prompt actions
- attaching run records / local history hooks

### `AgentRuntime`
Use for:
- executing prompt-driven autonomous runs after policy checks pass
- reusing current session run loop

### `ToolExecutor`
Use for:
- final low-level enforcement for mutation-capable local tools if/when direct automation actions exist

### Source layer
When source runtime activation becomes real, capability scope should also gate:
- allowed source IDs
- write-capable source operations

---

## 9. Scheduler and event bus

## 9.1 First local scheduler
Implement a lightweight local scheduler service.

Suggested service shape:

```swift
actor AutomationScheduler {
    func start() async
    func stop() async
    func reloadDefinitions() async
}
```

Responsibilities:
- load automation definitions
- compute next fire times for schedules
- wake and trigger prompt actions
- record run history

## 9.2 First local event bus
Do not build a general-purpose event bus abstraction too early.

Instead, start with specific event emission from existing local flows:
- session status changed
- session flagged/unflagged
- session label changed

These can later be unified behind a dedicated event layer if needed.

---

## 10. Runtime boundary and Open Agents relevance

## 10.1 What Keg should do now
For the next automation phase, Keg can remain local-first:
- app launches scheduler
- scheduler evaluates local triggers
- prompt actions create sessions through `SessionManager` / `AgentRuntime`
- history writes locally

## 10.2 When Open Agents-style durable orchestration matters
Open Agents becomes relevant when **any** of these become true:
- automations must keep running while the UI is closed
- multiple clients must reconnect to the same long-running run
- execution must survive app restarts without relying on app process state
- Keg wants remote/headless agents or a server mode
- Keg wants execution substrate replacement (local Apple Container vs remote sandbox) without rewriting orchestration

## 10.3 What to borrow later
When Keg reaches that point, adopt these Open Agents patterns:
- orchestration process/service outside the execution VM/container
- resumable workflow state with checkpointing
- client reconnection to active runs
- execution substrate treated as replaceable runtime target

## 10.4 What not to borrow yet
Do **not** build now:
- cloud sandbox layer
- branch-per-session git orchestration
- remote service + browser client
- workflow checkpoint engine

Those are strategic architecture only after local automations prove valuable.

---

## 11. Phased delivery order after current Tranche A

## Phase B — Local automation design and models
- add `AutomationDefinition`, trigger/action models, run-history models
- add local storage files
- add scheduler skeleton without UI

## Phase C — First prompt automations
- add schedule triggers
- add session status / flag / label triggers
- add prompt action only
- add automation history list/detail UI

## Phase D — Autonomous agent mode
- add `Manual` vs `Autonomous` concept in UI/data model
- attach capability scope to autonomous agents
- add stricter defaults and run limits

## Phase E — Stronger enforcement and quotas
- add source-scoped enforcement
- add run quotas / monthly limits / timeout policies
- add disable/pause controls

## Phase F — Strategic runtime separation
- extract orchestration into a process/service boundary
- support resumable background runs across app restarts
- revisit remote/headless execution

---

## 12. Recommended artifact/file touchpoints for later implementation

### High-confidence first implementation files
- `Sources/Keg/Agent/SessionManager.swift`
- `Sources/Keg/Agent/AgentRuntime.swift`
- `Sources/Keg/Agent/ToolExecutor.swift`
- `Sources/Keg/App/AppState.swift`
- `Sources/Keg/Agents/Storage/AgentStorage.swift`
- new `Sources/Keg/Agents/Automation/AutomationScheduler.swift`
- new `Sources/Keg/Agents/Automation/AutomationTypes.swift`
- new `Sources/Keg/Agents/Views/AutomationListView.swift`
- later routing additions in `SidebarView.swift` and `KegApp.swift`

### Strong warning
Do not put the scheduler and automation definitions inside SwiftUI views or `AppState`. That would block the later Open Agents-style separation we already know we may want.

---

## 13. Final recommendation
Build automations in Keg as **local, prompt-driven, policy-gated workflows** first.

- Keep current manual session model intact.
- Add autonomous behavior as a distinct layer, not a hidden flag on existing flows.
- Use `SessionManager` and `AgentRuntime` as the initial execution path.
- Keep scheduler/history/storage local.
- Enforce global mode + capability scope before write-capable autonomy.
- Only when local automations are clearly valuable should Keg adopt Open Agents-style durable orchestration outside the UI/runtime process.

This gives Keg the safest path from today's real foundations to tomorrow's autonomous workflows without prematurely building a remote systems platform.
