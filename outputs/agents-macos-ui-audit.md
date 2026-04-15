# Agents Area macOS UI Audit

Date: 2026-04-15
Scope: Agents area only, audited against the macOS design guidelines with emphasis on menu/toolbar/search/sidebar consistency, inspector/detail flows, tables, keyboard affordances, empty states, settings/account UX, context menus, and accessibility/macOS polish.

## Overall assessment
The Agents area already has a solid macOS baseline:
- native `NavigationSplitView` shell
- sidebar-based navigation
- searchable list screens
- table-based management views
- inspectors for Agents and Sessions
- broad keyboard affordances (`Cmd+F`, `Cmd+Delete`, `Escape`, `Cmd+1/2`)
- good use of `ContentUnavailableView`

The highest-value remaining work is not broad visual restyling. It is **interaction consistency**: menu placement, inspector/edit patterns, settings/account placement, and removal of dead or inconsistent UI affordances.

---

## Highest-value fixes

### 1. Move Agents commands into standard macOS menu locations
**Priority:** Critical

**Why it matters:**
The app exposes Agents commands via custom `CommandMenu("Agent")` and `CommandMenu("Navigate")`, but the guidelines expect stable command discovery in standard menu locations (`File`, `Edit`, `View`, `Window`, `Help`) with app-specific menus used sparingly. The current structure is functional, but not very Mac-native.

**Evidence:**
- `Sources/Keg/App/KegApp.swift`
  - custom `CommandMenu("Agent")`
  - custom `CommandMenu("Navigate")`
  - custom `CommandMenu("Find")`

**Fix direction:**
- Put `New Agent` into `CommandGroup(after: .newItem)` so it lives with File/New.
- Move sidebar toggle into a View-oriented command group.
- Keep `Find` aligned with standard find commands rather than a standalone custom menu.
- Prefer one stable app-specific menu only if Agents commands genuinely do not fit File/View/Window.

---

### 2. Make inspector/detail flows consistent across Agents screens
**Priority:** Critical

**Why it matters:**
Agents and Sessions use inspectors, but Sources and Skills use sheets only. Agent editing is also split across two paradigms: `AgentDetailView` performs inline editing inside the inspector, while `AgentEditorView` exists as a full editor. This inconsistency makes the area feel stitched together rather than intentionally Mac-native.

**Evidence:**
- `Sources/Keg/Views/Agents/AgentListView.swift`
  - selection opens `AgentDetailView` in `.inspector`
- `Sources/Keg/Agents/Views/SessionListView.swift`
  - selection opens `SessionDetailView` in `.inspector`
- `Sources/Keg/Agents/Views/SourceListView.swift`
  - create/edit only via `.sheet`
- `Sources/Keg/Agents/Views/SkillListView.swift`
  - create/edit only via `.sheet`
- `Sources/Keg/Views/Agents/AgentDetailView.swift`
  - inline editing in inspector
- `Sources/Keg/Views/Agents/AgentEditorView.swift`
  - separate full editor already exists

**Fix direction:**
Pick one clear pattern:
- inspectors are read/inspect surfaces, editors are sheets/windows, **or**
- all management surfaces use the same trailing-detail model.

Best Mac fit here:
- keep inspectors for read-only / operational detail
- open dedicated editor sheets or windows for edit/create
- reuse `AgentEditorView` instead of inline inspector editing
- consider adding inspector-style detail for Skills and Sources if they need parity with Agents/Sessions

---

### 3. Remove or implement dead controls in Agent detail
**Priority:** Critical

**Why it matters:**
The inspector currently shows Add buttons that do nothing. Dead controls are worse than missing controls on macOS because they violate user trust and the menu/toolbar/inspector command model.

**Evidence:**
- `Sources/Keg/Views/Agents/AgentDetailView.swift`
  - `// TODO: Add tool picker`
  - `// TODO: Add skill picker`
  - `// TODO: Add MCP server`
  - edit affordances are visible inside the inspector

**Fix direction:**
Until implemented, remove these controls from the inspector.
If implemented, route them into the existing `AgentEditorView` / pickers so the interaction model stays coherent.

---

### 4. Re-think Account as an Agents sidebar destination
**Priority:** High

**Why it matters:**
On macOS, account/authentication settings fit naturally into the Settings window (`Cmd+,`). In the Agents area, many screens route users to an in-content `Account` section. It works, but it feels more like a web app settings page than a Mac app preference flow.

**Evidence:**
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
  - Agents sidebar includes `.account`
- `Sources/Keg/App/KegApp.swift`
  - app already has a `Settings` scene
- `Sources/Keg/Views/Settings/SettingsView.swift`
  - `Mode.agentAccount` duplicates account UI inside content routing
- `Sources/Keg/Agents/Views/AgentDashboardView.swift`
- `Sources/Keg/Agents/Views/SessionListView.swift`
- `Sources/Keg/Agents/Views/SourceListView.swift`
- `Sources/Keg/Agents/Views/SkillListView.swift`
  - unauthenticated/error actions route to sidebar Account

**Fix direction:**
Prefer the Settings window as the canonical home for API key/account management.
If the in-app Account surface remains, treat it as a lightweight status page with a button to open Settings, not as a parallel settings system.

---

### 5. Sidebar composition is functional but not fully source-list-native
**Priority:** High

**Why it matters:**
The sidebar uses a good source-list foundation, but it mixes a segmented area picker, a permission mode card, a list, and a manually rendered bottom settings button outside the list. That weakens the single coherent source-list feel expected in Mac sidebars.

**Evidence:**
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
  - `AreaPicker()` above the list
  - `AgentPermissionModeControl()` above the list
  - custom bottom `settingsButton` outside the list
- `Sources/Keg/Views/Sidebar/SidebarView.swift` / `AgentSidebarContent`
  - Agents navigation itself is a proper `List(...).listStyle(.sidebar)`

**Fix direction:**
For a more native sidebar:
- integrate settings as a normal sidebar row or rely on Settings scene only
- consider moving area switching to toolbar/title bar if the segmented control feels too app-specific for permanent sidebar placement
- avoid mixing list and non-list navigation affordances unless they are clearly utility/status controls

---

### 6. Agent dashboard should behave more like a navigation surface
**Priority:** High

**Why it matters:**
The dashboard looks good, but major content blocks are mostly static. On Mac, overview cards and recent tables usually act as launch points into deeper detail or provide context menus.

**Evidence:**
- `Sources/Keg/Agents/Views/AgentDashboardView.swift`
  - `AgentCard` is visual only
  - recent sessions table is visual only
  - navigation relies on `View All` links rather than direct row/card interaction

**Fix direction:**
- make agent cards clickable or selectable, routing to the Agents section and selecting the target agent
- let recent session rows open the Sessions section and target that session
- consider context menus on cards/rows for common actions

---

### 7. Table behavior is mostly strong, but row/open semantics are uneven
**Priority:** Medium

**Why it matters:**
Mac tables should make selection, opening, deletion, and contextual actions feel predictable. Agents/Sessions are more complete than Skills/Sources, but the area still mixes immediate selection, sheet editing, and context-menu-only actions.

**Evidence:**
- `Sources/Keg/Views/Agents/AgentListView.swift`
  - selection opens inspector immediately
- `Sources/Keg/Agents/Views/SessionListView.swift`
  - selection opens inspector immediately
- `Sources/Keg/Agents/Views/SourceListView.swift`
  - edit is context-menu-only
- `Sources/Keg/Agents/Views/SkillListView.swift`
  - edit is context-menu-only

**Fix direction:**
- define one open behavior for management tables: single-click select + inspector, or double-click edit/open
- expose edit actions in toolbars when selection exists, not only via context menus
- keep delete/archive shortcuts aligned with selected-row semantics

---

### 8. Settings/Account form UX needs more Mac preference polish
**Priority:** Medium

**Why it matters:**
The account form is now materially better thanks to inline validation, but the overall experience still reads more like a generic form than a Mac preference pane.

**Evidence:**
- `Sources/Keg/Views/Settings/SettingsView.swift`
  - account UI is embedded in a `Form`, which is good
  - however, operational actions (`Connect`, `Reload Account`, `Get API Key`) are somewhat flat and not clearly grouped as a preference workflow

**Fix direction:**
- separate connection state, credential replacement, and account metadata into smaller preference groups
- add a clearer “Open in Settings” path when Agents screens surface auth failures
- consider surfacing auth/help actions in toolbar or section footers more like native preference panes

---

### 9. Accessibility/macOS polish gaps are now mostly environment-level, not control-level
**Priority:** Medium

**Why it matters:**
The Agents area has many labels and hints already. The remaining gaps are more about full macOS adaptation than missing labels.

**Evidence:**
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
- `Sources/Keg/Views/Agents/AgentListView.swift`
- `Sources/Keg/Agents/Views/SessionListView.swift`
- `Sources/Keg/Agents/Views/SourceListView.swift`
- `Sources/Keg/Agents/Views/SkillListView.swift`
- `Sources/Keg/Views/Settings/SettingsView.swift`
- custom cards and panels use `Color(nsColor: .controlBackgroundColor)` and custom compositions but there is little visible use of:
  - `accessibilityReduceTransparency`
  - `colorSchemeContrast`
  - `legibilityWeight`

**Fix direction:**
- audit custom cards/panels for Reduce Transparency and Increase Contrast behavior
- make sure keyboard focus appearance is obvious on custom cards/buttons, not only standard controls
- keep this as a QA-backed pass, not just a code pass

---

## What is already strong
These areas already align well with modern macOS patterns:
- `NavigationSplitView` shell: `Sources/Keg/App/KegApp.swift`
- searchable management views: Agents / Sessions / Sources / Skills
- table-heavy management UI with alternating row backgrounds
- context menus on core list surfaces
- keyboard affordances (`Cmd+F`, delete, `Escape`, `Cmd+1/2`)
- use of `ContentUnavailableView` for empty/auth/unavailable states
- use of `SettingsView(mode: .agentAccount)` instead of inventing a second account form from scratch

---

## Recommended implementation order
1. **Menu cleanup in `KegApp.swift`**
2. **Unify inspector/editor pattern across Agents/Sessions/Sources/Skills**
3. **Remove or implement dead Add controls in `AgentDetailView.swift`**
4. **Decide whether Account belongs in Settings only or also in sidebar**
5. **Make dashboard cards/rows navigable**
6. **Run final accessibility/visual adaptation QA pass**

---

## Bottom line
The Agents area does not need a visual redesign first. It needs a **Mac interaction model cleanup**:
- standardize menu placement
- standardize detail/edit behavior
- remove dead controls
- make account/settings feel like Mac settings
- tighten dashboard and table navigation semantics

That will do more to make the app feel like a modern macOS product than changing colors or adding more chrome.
