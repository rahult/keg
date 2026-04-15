# macOS Core App HIG Audit

Date: 2026-04-15
Scope: non-Agents core app surfaces (`Keg` area), with emphasis on menu/window/toolbar usage, sidebar behavior, dashboard, settings, containers, images, builds, empty states, destructive flows, and keyboard/pointer affordances.

## Summary
The app already uses solid Mac foundations in a few places:
- main window uses `NavigationSplitView` and unified toolbar styling
- list-heavy areas use `Table`
- many primary actions live in toolbars
- search is present on major collection views

The biggest macOS UX gaps are not visual polish first — they are command discoverability, destructive-flow safety, and keyboard completeness.

## Highest-value fixes

### 1. Sidebar is partially custom instead of a native source-list surface
**Severity:** high

**Problem:**
`SidebarView` builds a custom `VStack` with manual dividers, a segmented area picker, and a separate bottom Settings button outside the source list. This breaks native sidebar behavior: the whole leading column is not a consistent source-list surface, the bottom Settings button is not keyboard/list-selection integrated, and there is no visible standard sidebar toggle button in the toolbar.

**Files:**
- `Sources/Keg/Views/Sidebar/SidebarView.swift`
- `Sources/Keg/App/KegApp.swift`

**Why it misses modern macOS:**
Per macOS HIG, sidebars should behave like one coherent source list, remain collapsible from visible UI, and keep top-level navigation in a stable left-column model. The current layout feels like a hybrid between a custom panel and a sidebar.

**Fix direction:**
- make the full leading column a native sidebar/source list
- move Settings into the same list structure as the rest of the Keg navigation
- add a visible toolbar sidebar toggle in the window, not only a menu command
- keep the segmented area switch only if it is clearly acting like a scope switch; otherwise convert it into sidebar top-level rows

---

### 2. Dashboard quick actions are placeholder buttons in content, not real Mac commands
**Severity:** high

**Problem:**
`SystemDashboardDetailView` renders a custom dashboard with inline “Quick Actions” buttons, but several are placeholders (`Start System`, `Open Terminal`, `Settings`). The dashboard also keeps its own inline Refresh button instead of leaning more on toolbar/menu commands.

**Files:**
- `Sources/Keg/Views/Dashboard/SystemDashboardDetailView.swift`

**Why it misses modern macOS:**
Mac users expect commands to live first in the menu bar and toolbar, with dashboard content being informational or deeply contextual. Nonfunctional quick-action controls inside the main content area weaken trust immediately.

**Fix direction:**
- remove or wire all placeholder quick actions before shipping
- move dashboard actions into the toolbar/menu bar and keep the content area focused on status
- add empty/loading/error states that look like first-class `ContentUnavailableView` patterns instead of always rendering a bare custom layout

---

### 3. Container deletion is destructive with no confirmation and weak keyboard support
**Severity:** critical

**Problem:**
Container deletion fires directly from menu/context-menu/detail actions with no confirmation dialog. The main list also lacks explicit keyboard deletion handling (`onDeleteCommand`) and no standardized Escape behavior or search focus routing exists like the newer Agents surfaces.

**Files:**
- `Sources/Keg/Views/Containers/ContainerListView.swift`
- `Sources/Keg/Views/Containers/ContainerDetailView.swift`
- `Sources/Keg/ViewModels/ContainersVM.swift`
- `Sources/Keg/App/KegApp.swift`

**Why it misses modern macOS:**
Delete is one of the most expected places for confirmation + undo affordances on Mac. Even if the runtime operation is reversible in theory, the UI currently treats delete as immediate and silent. It also falls short of HIG keyboard expectations for selectable lists.

**Fix direction:**
- add confirmation dialogs before destructive container deletion
- add `onDeleteCommand` for selected container rows
- add `onExitCommand` / Escape behavior to clear selection or dismiss inspector
- route `Cmd+F` into container search explicitly, matching the Agents area

---

### 4. Image deletion has the same safety gap
**Severity:** high

**Problem:**
Images can be deleted from the context menu immediately, with no confirmation, and the view has no keyboard delete flow for selected rows.

**Files:**
- `Sources/Keg/Views/Images/ImageListView.swift`

**Why it misses modern macOS:**
This is the same destructive-flow gap as Containers. Images are persistent assets; accidental deletion should not happen from a single right-click tap.

**Fix direction:**
- add confirmation dialog for image deletion
- add `onDeleteCommand` for selected image
- add `onExitCommand` for selection clearing and explicit search-focus handling

---

### 5. Build view exposes a “Cancel Build” command that does nothing
**Severity:** critical

**Problem:**
`BuildView` swaps its primary toolbar button to “Cancel Build” while building, but the action body is a TODO. That means the UI presents a trusted Mac toolbar command that does not actually work.

**Files:**
- `Sources/Keg/Views/Builds/BuildView.swift`

**Why it misses modern macOS:**
A visible primary command in a toolbar must be real. Shipping a no-op cancel button is worse than omitting cancellation entirely, because it lies about control.

**Fix direction:**
- either implement cancellation with real process termination + state cleanup
- or remove the button until cancellation is actually supported

---

### 6. Core collection views are behind the newer Agents standard for keyboard/pointer polish
**Severity:** high

**Problem:**
Containers and Images use `Table`, but they do not yet match the richer keyboard behavior already added in Agents: no explicit delete command handling, no explicit Escape-to-clear behavior, no shared search focus routing, and no list-level accessibility hints.

**Files:**
- `Sources/Keg/Views/Containers/ContainerListView.swift`
- `Sources/Keg/Views/Images/ImageListView.swift`
- `Sources/Keg/App/KegApp.swift`

**Why it misses modern macOS:**
Mac users expect keyboard parity across similar list surfaces. Right now Agents feels more Mac-native than the core app collections.

**Fix direction:**
- port the newer Agents keyboard pattern to core Keg tables
- add explicit search focus support for Containers and Images
- add Escape handling for selection clearing and inspector dismissal
- add list-level accessibility labels/hints

---

## Medium-priority issues

### 7. Settings is functional but not especially Mac-native in command/disclosure terms
**Severity:** medium

**Problem:**
`SettingsView` is mainly a large form with inline controls. It works, but it does not expose much command structure beyond buttons in rows, and repeated copy buttons are icon-only borderless controls embedded inside text-heavy rows.

**Files:**
- `Sources/Keg/Views/Settings/SettingsView.swift`

**Fix direction:**
- consider using clearer grouped disclosure / utility rows for Docker API and account sections
- make copy actions more legible on hover and keyboard focus
- add better success/error feedback patterns for account reload/connect flows

---

### 8. Container context menu contains visible TODO actions
**Severity:** medium

**Problem:**
The container context menu shows `Start`, `Restart`, `View Logs`, and `Exec Shell`, but several are TODO/no-op actions.

**Files:**
- `Sources/Keg/Views/Containers/ContainerListView.swift`

**Why it matters:**
Context menus are part of the Mac app’s command memory. Showing dead actions hurts credibility and discoverability.

**Fix direction:**
- hide unfinished commands
- or implement them before exposing them in the menu

---

### 9. Dashboard cards are visually custom but not strongly aligned to toolbar/menu hierarchy
**Severity:** medium

**Problem:**
`SystemDashboardDetailView` relies heavily on custom metric/status cards. This is not wrong, but without stronger toolbar/menu integration it reads more like a cross-platform dashboard than a Mac-first utility window.

**Files:**
- `Sources/Keg/Views/Dashboard/SystemDashboardDetailView.swift`

**Fix direction:**
- make the toolbar the primary command surface
- keep cards informational, with fewer embedded action controls
- use more system-native grouping and less bespoke “dashboard panel” framing

---

## Lower-priority observations

### 10. Main window command structure is usable but not yet ideal Mac command memory
**Severity:** medium

**Problem:**
Keg adds custom menus (`Dashboard`, `Container`, `Image`, `Agent`, `Navigate`, `Find`) rather than leaning more on standard menu groups and command placement. The app is still usable, but command discoverability would improve if more actions lived in predictable standard locations.

**Files:**
- `Sources/Keg/App/KegApp.swift`

**Fix direction:**
- keep app-specific menus, but consider migrating navigation/find/toggle behavior into more standard command groups where possible
- ensure every custom menu action has a clear keyboard shortcut and stable location

---

## Recommended fix order
1. fix destructive container/image flows and keyboard delete behavior
2. remove or implement dead commands (`Cancel Build`, container TODO menu items)
3. modernize sidebar into a coherent native source-list surface with visible sidebar toggle
4. bring Containers/Images up to Agents-level keyboard/search/Escape polish
5. simplify dashboard actions so toolbar/menu owns commands and content owns status

## Net assessment
The core app is already structurally closer to a real Mac app than a naive iPad port, but the **Agents area currently feels more Mac-native than the core Keg area**. The fastest path to a more modern macOS feel is to port the same command/keyboard/destructive-flow discipline from Agents into Containers, Images, Settings, and the dashboard.
