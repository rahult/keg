# macOS App Architecture Audit

Date: 2026-04-15
Scope: menu bar, command placement, keyboard shortcuts, settings integration, window behavior, toolbar/sidebar architecture.
Reference: `macos-design-guidelines`

## Executive summary
Keg already has a solid native base:
- `NavigationSplitView` shell
- unified title bar / toolbar
- sidebar-driven navigation
- searchable list screens
- Settings scene
- MenuBarExtra

The main gaps are not visual polish first — they are **command architecture** issues:
1. commands are in custom top-level menus instead of standard Mac locations
2. several shortcuts conflict globally
3. sidebar visibility/state is not modeled like a standard Mac sidebar
4. settings exist in two places (Settings scene and in-app settings section)
5. menu bar extra window-opening path does not match the main `WindowGroup`

---

## 1. Menu bar architecture

### 1.1 Custom top-level menus are doing standard-menu work
**Severity:** High

**Evidence**
- `Sources/Keg/App/KegApp.swift`
  - `CommandMenu("Dashboard")`
  - `CommandMenu("Container")`
  - `CommandMenu("Image")`
  - `CommandMenu("Agent")`
  - `CommandMenu("Navigate")`
  - `CommandMenu("Find")`

**Why this misses modern macOS convention**
- macOS users look first in **File / Edit / View / Window / Help**.
- `Find` should not be its own top-level menu.
- sidebar/window/view actions should live in **View** or **Window**.
- app-level help/support should be discoverable from **Help**.

**Recommended fix**
- `KegApp.swift`
  - move Find into the standard Find command group / Edit menu
  - move area switching + sidebar toggling into View
  - keep app-specific runtime menus only where they add real value
  - add Help menu items (documentation, issue reporting, keyboard shortcuts/help)

---

### 1.2 Keyboard shortcut collisions in global commands
**Severity:** Critical

**Evidence**
- `Sources/Keg/App/KegApp.swift`
  - `Cmd+D` = `System Dashboard`
  - `Cmd+R` = `Refresh Metrics`
  - `Cmd+R` = `Refresh`
- `Sources/Keg/Views/Agents/AgentListView.swift`
  - `Cmd+D` = `Duplicate`

**Why this is a problem**
- `Cmd+D` is a well-known duplicate shortcut on Mac.
- assigning `Cmd+D` to dashboard navigation conflicts with actual duplication semantics in the app.
- two enabled `Cmd+R` actions in app-level commands create ambiguous behavior.

**Recommended fix**
- `KegApp.swift`
  - remove `Cmd+D` from dashboard navigation entirely
  - reserve `Cmd+D` for duplicate only
  - define one app-level refresh shortcut, or scope refresh shortcuts to active views only
  - avoid duplicate global shortcuts unless one command is context-disabled

---

### 1.3 Agent menu contains navigation duplicate without shortcut
**Severity:** Medium

**Evidence**
- `Sources/Keg/App/KegApp.swift`
  - `CommandMenu("Agent")` contains `Go to Agents` with no shortcut
  - `CommandMenu("Navigate")` already contains `Cmd+2` to go to Agents

**Why this is a problem**
- duplicate command in two menus with different semantics
- violates the guideline that actionable menu items should have shortcuts
- weakens command-location memory

**Recommended fix**
- `KegApp.swift`
  - remove `Go to Agents` from `Agent` menu
  - keep `Agent` menu for agent-specific actions only
  - keep navigation in View/Navigate only

---

### 1.4 No app-specific Help surface
**Severity:** Medium

**Evidence**
- no help/support/documentation commands found in `KegApp.swift`
- only About-like content is embedded inside `SettingsView`

**Why this is a problem**
- modern Mac apps expose docs/support/release notes from Help
- Help is a primary discovery surface for unfamiliar features

**Recommended fix**
- `KegApp.swift`
  - add Help menu items for docs, issue reporting, release notes, keyboard shortcuts/help

---

## 2. Settings integration

### 2.1 Settings exists in two different models
**Severity:** High

**Evidence**
- `Sources/Keg/App/KegApp.swift`
  - `Settings { SettingsView() }`
  - `KegDetailView` routes `.settings` to `SettingsView()` inside the main split view
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
  - persistent bottom `settingsButton` changes the sidebar selection to in-app Settings
- `Sources/Keg/App/AppState.swift`
  - `KegSection.settings`

**Why this is a problem**
- Mac users expect app preferences in the standard Settings window (`Cmd+,`).
- duplicating preferences as a main-content destination creates two mental models for the same thing.
- the sidebar bottom settings item feels like an iPad-style tab destination instead of a Mac preferences command.

**Recommended fix**
- choose one model:
  1. **Preferred:** keep app preferences only in the Settings scene and remove `KegSection.settings`
  2. if a sidebar item is kept, make it explicitly open the Settings scene via `SettingsLink` / open-settings behavior rather than rendering a second in-content copy

**Files**
- `Sources/Keg/App/KegApp.swift`
- `Sources/Keg/App/AppState.swift`
- `Sources/Keg/Views/Sidebar/SidebarView.swift`

---

## 3. Window behavior

### 3.1 Menu bar extra opens a window id that the app does not define
**Severity:** Critical

**Evidence**
- `Sources/Keg/Views/MenuBar/MenuBarPopover.swift`
  - `openWindow(id: "main")`
- `Sources/Keg/App/KegApp.swift`
  - main scene is `WindowGroup { ... }` with no matching `id: "main"`

**Why this is a problem**
- this is not aligned with SwiftUI’s window scene model
- even if it happens to work inconsistently, it is not a clean modern macOS window architecture

**Recommended fix**
- `KegApp.swift`
  - make the main scene `WindowGroup(id: "main")`
- or change the menu bar extra to open the default window model without a nonexistent id

---

### 3.2 Sidebar/window state is not persisted
**Severity:** Medium

**Evidence**
- `Sources/Keg/App/KegApp.swift`
  - `@State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn`
  - local ephemeral state only

**Why this is a problem**
- modern Mac apps should remember sidebar visibility and split-view state across launches/windows
- current toggle is transient per view lifetime

**Recommended fix**
- hoist sidebar visibility into `@SceneStorage` or persisted app/window state
- use that same state to drive menu item labels (`Show Sidebar` / `Hide Sidebar`)

**Files**
- `Sources/Keg/App/KegApp.swift`
- possibly `Sources/Keg/App/AppState.swift`

---

## 4. Sidebar architecture

### 4.1 Sidebar is half source list, half custom control stack
**Severity:** Medium

**Evidence**
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
  - custom `VStack`
  - segmented `AreaPicker` above the list
  - custom permission mode card above the list
  - custom bottom settings button outside the list
  - inner `List` views use `.sidebar` style, but the overall sidebar is not one coherent source list

**Why this is a problem**
- the main navigation surface feels more like a custom utility panel than a standard Mac source list
- segmented control at the top reads more iPad-like than Mac-like for top-level navigation
- custom bottom settings row visually competes with the native source list sections

**Recommended fix**
- move app-area switching into either:
  - a toolbar segmented control, or
  - a first-class top sidebar section inside the source list
- keep the sidebar as one coherent source list where possible
- if permission mode remains visible, consider placing it in the toolbar or an inspector/settings surface rather than permanent sidebar chrome

**Files**
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
- optionally `Sources/Keg/App/KegApp.swift`

---

### 4.2 Sidebar toggle exists as shortcut only, not as standard visible control
**Severity:** Medium

**Evidence**
- `Sources/Keg/App/KegApp.swift`
  - notification-based `Toggle Sidebar` command with `Cmd+Ctrl+S`
- no obvious toolbar/sidebar toggle button defined in the shared window chrome

**Why this is a problem**
- modern Mac split-view apps normally provide a visible sidebar toggle in the toolbar in addition to menu/shortcut access
- relying on command-only discovery is weaker than standard toolbar affordance

**Recommended fix**
- add a visible sidebar toggle toolbar item in shared window chrome
- keep the shortcut, but back it with the same stateful toggle model

**Files**
- `Sources/Keg/App/KegApp.swift`
- possibly shared root content view / toolbar host

---

## 5. Command placement and modern Mac fit

### 5.1 Find should use the standard Find command path
**Severity:** High

**Evidence**
- `Sources/Keg/App/KegApp.swift`
  - `CommandMenu("Find")`

**Recommended fix**
- replace with standard Find-group integration in Edit
- preserve `Cmd+F`, but do not make Find a custom top-level menu

---

### 5.2 View-like navigation is split across Dashboard/Navigate/toolbar command groups
**Severity:** Medium

**Evidence**
- `Dashboard` menu contains navigation and refresh
- `Navigate` menu contains area switching
- `CommandGroup(after: .toolbar)` contains sidebar toggle

**Recommended fix**
- consolidate into a proper View command structure:
  - Show/Hide Sidebar
  - Go to Keg / Go to Agents
  - possibly view-specific refresh if truly global

---

## Recommended implementation order

### Phase 1 — command cleanup (highest value)
1. Fix menu bar extra window id mismatch
2. remove shortcut collisions (`Cmd+D`, duplicate `Cmd+R`)
3. move Find into standard Find placement
4. remove duplicate navigation command from `Agent` menu

### Phase 2 — settings + sidebar cleanup
5. choose one settings model and remove the duplicate surface
6. make sidebar visibility stateful + persistent
7. add visible sidebar toggle button in toolbar

### Phase 3 — stronger Mac-native navigation feel
8. consolidate sidebar into a more standard source-list architecture
9. move area switching out of the custom sidebar segmented control or make it a real source-list section
10. add Help menu entries

---

## Files to change
- `Sources/Keg/App/KegApp.swift`
- `Sources/Keg/Views/MenuBar/MenuBarPopover.swift`
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
- `Sources/Keg/App/AppState.swift`
- potentially `Sources/Keg/Views/Settings/SettingsView.swift` depending on settings unification strategy
