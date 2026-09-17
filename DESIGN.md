# Keg — UX Design Guide

macOS developer-tool conventions we follow. Reference when building or reviewing any view.

Keg serves two audiences on the same screens: people who have never touched
containers, and experienced operators who want every knob. Every UI decision
is checked against the principles below, in priority order. Grounded in
Apple's Human Interface Guidelines (Toolbars, Buttons, Labels, Writing).
When in doubt, clarity beats cleverness.

---

## 0. Design Principles

### 0.1 Never make the user guess
"Don't make people guess or experiment to figure out what a toolbar item
does." (HIG: Toolbars) A control whose meaning isn't obvious from a
universally recognized symbol gets a **text label** — always icon + text,
never a cryptic glyph.

### 0.2 One primary action per screen
Each screen has exactly one prominent (accent-tinted) action — the thing a
user most likely came to do. It sits in the toolbar trailing position. All
other actions are plain toolbar items. (HIG: "Only specify one primary
action, and put it on the trailing side.")

### 0.3 Plain language first, jargon defined
Controls, statuses, and errors are written for someone who has never heard
the word "compose". Domain terms may appear, but only after the plain
meaning is established — help popovers carry the translation (see
`SectionHelpGuide`). Button labels are **verbs** that say what happens:
"Start Services", not "Up". (HIG: Writing — "be action oriented", "avoid
the temptation to be too cute or clever".)

### 0.4 State lives next to the object it describes
A screen's state ("4 services running") is shown as a first-class status
element — colored dot + text — not buried in a settings-style form row.
Errors appear next to the problem, say what happened, and say what to do
next. (HIG: Writing — "display it as close to the problem as possible… be
clear about what someone can do to fix it.")

### 0.5 Progressive disclosure
Friendly summaries are the default. Raw detail — command lines, IDs,
digests, low-level flags — is one disclosure away, collapsed by default,
and never the first thing a newcomer sees. Experience level can drop
whole advanced sections (Getting Started) but never gates capability.

### 0.6 Consistency is the contract
The same word means the same thing everywhere, the same control looks and
behaves the same everywhere, and every screen offers help the same way
(the ⓘ toolbar button). Deviations require a reason recorded here.

---

## 1. Toolbar vs Inline HStack

**Always use `.toolbar` with `ToolbarItem` placements.** Never hand-roll an HStack toolbar with `.background(.bar)`.

```swift
// ✅ Correct
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        Button("Run...") { showRunSheet = true }
    }
    ToolbarItem(placement: .automatic) {
        Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .keyboardShortcut("r", modifiers: .command)
    }
}

// ❌ Wrong
VStack(spacing: 0) {
    HStack {
        Button("Run") { ... }
        Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.bar)   // hand-rolled toolbar
    Divider()
    // content...
}
```

**Why:** `.toolbar` integrates with the window title bar, supports customization, appears in View → Customize Toolbar, and handles spacing/alignment automatically.

### Toolbar Placement Cheat Sheet

| Placement | Use For |
|-----------|---------|
| `.primaryAction` | Primary action (Run, Pull, Create, Build) |
| `.cancellationAction` | Cancel buttons |
| `.confirmationAction` | Confirm/Save |
| `.automatic` | Secondary actions (Refresh, Filter) |
| `.principal` | Centered picker/segmented control |
| `.navigation` | Back/forward, sidebar toggle |
| `.status` | Status indicators on trailing edge |

### Toolbar Button Style Conventions

- Primary actions: `.buttonStyle(.borderedProminent)`
- Destructive actions: `Button("Delete", role: .destructive)`
- Secondary actions: default style (no `.buttonStyle`)
- Always add `Label` (icon + text) for accessibility

### Toolbar Labeling Rules

| Rule | Examples |
|------|----------|
| **Icon-only** is reserved for universally recognized symbols | + (new/run), ⟳ (refresh), search, trash (delete), sidebar toggle, ⓘ (help) |
| **Icon + text label** for everything domain-specific | Start Services / Stop Services (Compose), Create Cluster (Kubernetes), Login… (Registries) |
| Text-labeled toolbar buttons use `.labelStyle(.titleAndIcon)` | macOS hides `Label` titles in toolbars by default — without this the label silently disappears and the button degrades to icon-only |
| Text-labeled actions are visually separated from icon-only neighbors (HIG: "Keep actions with text labels separate") | Separate `ToolbarItem`s; no icon+text squashed against icon-only |
| Every toolbar control carries `.help()` | Hover explains what it does; when disabled, hover explains *why* |

### Disabled States Explain Themselves

A disabled button with no explanation reads as a bug. The `.help()` tooltip
states the blocking condition: "Choose a compose file first", "Services are
already running — stop them first".

---

## 2. Search

**Use `.searchable()` on list/table views.** Never use a manual `TextField` for search.

```swift
// ✅ Correct
.searchable(text: $searchText, prompt: "Search containers")
.onChange(of: searchText) { vm.searchText = searchText }

// ❌ Wrong
HStack {
    TextField("Search...", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
}
```

**Binding pattern:** SwiftUI's `.searchable` manages its own state. Sync to VM via `.onChange`:

```swift
@State private var searchText = ""

.searchable(text: $searchText, prompt: "Search")
.onChange(of: searchText) { vm.searchText = searchText }
```

The VM still owns filtering logic. The view just syncs the text.

---

## 3. Context Menus

**Every table must have a context menu.** Developers right-click everything.

```swift
.tableStyle(.inset(alternatesRowBackgrounds: false))
.contextMenu(forSelectionType: String.self) { ids in
    if let id = ids.first {
        ContainerContextMenu(id: id, vm: vm)
    }
}
```

### Context Menu Structure

Follow this order (top to bottom):
1. **Actions** — Start, Stop, Restart
2. **Divider**
3. **Navigation** — View Logs, Exec Shell
4. **Divider**
5. **Copy** — Copy ID, Copy Reference
6. **Divider**
7. **Destructive** — Delete (with `role: .destructive`)

```swift
struct ContainerContextMenu: View {
    let id: String
    let vm: ContainersVM

    var body: some View {
        Button("Stop") { Task { await vm.stop(id: id) } }
        Divider()
        Button("View Logs") { /* open logs */ }
        Divider()
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(id.prefix(12)), forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await vm.delete(id: id) } }
    }
}
```

---

## 4. Copy to Clipboard

**Developer tools need one-click copy on IDs, paths, and commands.**

### Inline Copy Button

Use a small `doc.on.doc` button next to copyable text:

```swift
HStack(spacing: 4) {
    Text("/path/to/kubeconfig")
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    } label: {
        Image(systemName: "doc.on.doc")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
}
```

### Reusable Component

```swift
struct CopyableRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}
```

**Pattern:** Always pair `textSelection(.enabled)` with a copy button. `textSelection` lets users select+Cmd+C, the button is for one-click.

---

## 5. Tables

**Use `Table` for structured data.** Use `List` only for simple single-column content.

### Table Anatomy

```swift
Table(items, selection: $selectedID) {
    TableColumn("Name") { item in
        Text(item.name)
    }
    .width(min: 120)

    TableColumn("Status") { item in
        StatusBadge(status: item.status)
    }
    .width(min: 80, max: 120)

    TableColumn("ID") { item in
        Text(String(item.id.prefix(12)))     // short IDs
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
    .width(min: 90, max: 120)
}
.tableStyle(.inset(alternatesRowBackgrounds: false))
```

### Table Rules

- **Always** `.width(min:)` on every column — prevents layout collapse
- **Short IDs** — show 12 chars in tables, full ID via copy
- **Monospaced** — IDs, digests, paths, ports, IPs get `.monospaced`
- **Secondary color** — metadata (dates, sizes, types) get `.foregroundStyle(.secondary)`
- **No alternating rows** — always `.inset(alternatesRowBackgrounds: false)`. On macOS 26, `alternatesRowBackgrounds: true` paints phantom stripes down the full table viewport beyond the last real row
- **Identifiable** — items must conform to `Identifiable`. Wrap external types:

```swift
// External types (from container framework) may not be Identifiable
struct IdentifiableNetwork: Identifiable {
    let id: String
    let network: NetworkState

    init(_ network: NetworkState) {
        self.id = network.id
        self.network = network
    }
}
```

---

## 6. Sidebar

**Group into semantic sections.** Flat lists are disorienting.

```swift
List(selection: $selectedSection) {
    Section("Workloads") {
        ForEach([.containers, .compose]) { section in
            Label(section.rawValue, systemImage: section.iconName)
                .tag(section)
        }
    }
    Section("Content") { /* images, builds */ }
    Section("Networking") { /* networks, registries */ }
    Section("Storage") { /* volumes */ }
    Section("Tools") { /* terminal, kubernetes */ }
    Section("System") { /* settings */ }
}
.listStyle(.sidebar)
.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
```

### Sidebar Rules

- Section names are short nouns: "Workloads", "Content", "Tools"
- Icons use SF Symbols that match the concept
- Always constrain column width with `.navigationSplitViewColumnWidth`
- Tags must be unique per section item

---

## 7. Error Display

**Overlay banners, not inline toolbars.** Errors in toolbars break the toolbar layout.

```swift
.overlay(alignment: .bottom) {
    if let error = vm.errorMessage {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Dismiss") { vm.errorMessage = nil }
                .controlSize(.small)
            Spacer()
        }
        .padding(8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }
}
```

**Why overlay:** Keeps the toolbar clean, dismissable, doesn't steal vertical space from content.

---

## 8. Empty States

**Use `ContentUnavailableView`** for zero-data states.

```swift
ContentUnavailableView(
    "No Running Containers",
    systemImage: "cube.box",
    description: Text("Run a container to get started")
)
```

Rules:
- Title describes what's missing
- Icon matches the section's SF Symbol
- Description tells the user what to do next, naming toolbar actions by their label ("choose Start Services in the toolbar", not "run Up")
- Give one primary action button when a clear next step exists (HIG: "Provide clear next steps on any blank screens")
- Dynamic: change title when filter is active ("No Running Containers" vs "No Containers")

---

## 9. Keyboard Shortcuts

### Standard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+R` | Refresh current view |
| `Cmd+N` | New/Create |
| `Cmd+,` | Settings (automatic with `Settings` scene) |
| `Esc` | Dismiss sheet/popover (automatic) |
| `Return` | Confirm default action in dialogs |

### Dialog Shortcuts

Every sheet/dialog needs these:

```swift
Button("Cancel") { dismiss() }
    .keyboardShortcut(.cancelAction)   // Esc

Button("Save") { save() }
    .buttonStyle(.borderedProminent)
    .keyboardShortcut(.defaultAction)  // Return
```

### Adding Shortcuts to Toolbar

```swift
ToolbarItem(placement: .automatic) {
    Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        .keyboardShortcut("r", modifiers: .command)
}
```

---

## 10. Inspector Pattern

**Use `.inspector` for detail panels** (right sidebar). Not sheets.

```swift
.inspector(isPresented: .init(
    get: { selectedID != nil },
    set: { if !$0 { selectedID = nil } }
)) {
    if let id = selectedID {
        DetailView(id: id)
    }
}
```

Inspector rules:
- Opens when a table row is selected
- Closes when selection is cleared
- Width constrained with `.inspectorColumnWidth(min: 280, ideal: 320)`

---

## 11. Sheet Sizing

Sheets need explicit width for forms:

```swift
.sheet(isPresented: $showSheet) {
    FormView()
        .padding(20)
        .frame(width: 400)  // or 500 for complex forms
}
```

| Content | Width |
|---------|-------|
| Simple form (1-2 fields) | 400 |
| Medium form (3-6 fields) | 500 |
| Complex form (7+ fields) | 600 |

---

## 12. Monospaced Text

Use `.monospaced` for anything a developer would copy or grep:

```swift
// IDs
.font(.system(.body, design: .monospaced))

// Code/commands
.font(.system(.caption, design: .monospaced))

// Terminal output
.font(.system(.caption, design: .monospaced))
```

**When to use monospaced:**
- Container/image IDs
- Digests
- Image references
- IP addresses
- Port mappings
- File paths
- CLI commands
- Environment variables
- URLs
- Terminal output

**When NOT to use monospaced:**
- Status labels ("Running", "Stopped")
- Column headers
- Button labels
- Section titles

---

## 13. StatusBadge

Consistent status indicator across all views:

```swift
struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status.lowercased() {
        case "running": .green
        case "stopped", "exited": .red
        case "created": .blue
        case "paused": .yellow
        default: .gray
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

---

## 14. Color Conventions

| Element | Color |
|---------|-------|
| Primary content | `.primary` (default) |
| Secondary/metadata | `.secondary` |
| Tertiary/hints | `.tertiary` |
| Status: running | `.green` |
| Status: stopped/errored | `.red` |
| Status: created/pending | `.blue` |
| Status: paused | `.yellow` |
| Destructive actions | `role: .destructive` (auto red) |
| Warning icon | `.orange` |

**Never hardcode colors.** Use semantic colors that adapt to light/dark mode.

---

## 15. Status Language

Sentence case everywhere in UI copy.

| State | Vocabulary | Visual |
|-------|-----------|--------|
| Workloads active | "N of M services running" | Green dot (`circle.fill`) + text |
| Workloads stopped | "Stopped" / "No services running" | Gray dot + text |
| Busy | "Starting…" / "Stopping…" / "Working…" | Spinner or animated label |
| Problem | Plain sentence + next step | Orange/red, near the problem, plus the standard error banner |

Status counts reflect reality: "N services running" must count actually
running services, not just defined ones (see ComposeView.statusText).

---

## 16. Voice

- Sentence case, verb-first, no abbreviations without need (`ID` is fine).
- "You/your" for the user's things: "your containers".
- Errors never blame; they instruct: "Choose a compose file first."
- Beginner copy may be warm ("it's safe — nothing touches your Mac");
  expert surfaces stay terse. Tone follows experience level, vocabulary
  does not.

---

## 17. Agent Session View

**Use structured panels for streaming agent output.** Like Xcode build phases, not chat bubbles.

### Session Layout

```swift
ScrollView {
    LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(sessionEvents) { event in
            SessionEventRow(event: event)
        }
    }
    .padding()
}
```

### Event Row Pattern

Each step in the agent session is a collapsible section:

```swift
DisclosureGroup(isExpanded: $isExpanded) {
    // Tool input (monospaced, secondary color)
    Text(toolInput)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

    Divider()

    // Tool output (monospaced)
    Text(toolOutput)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
} label: {
    HStack(spacing: 8) {
        StatusIndicator(status: event.status) // spinning while running
        Text(event.toolName)
            .font(.headline)
        Spacer()
        Text(event.duration)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

### Session Event Types

| Event | Display |
|-------|---------|
| User message | Left-aligned text, `.secondary` background, no disclosure |
| Assistant message | Left-aligned text, default background, markdown rendered |
| Tool call (running) | DisclosureGroup, expanded, spinning indicator |
| Tool call (complete) | DisclosureGroup, collapsed by default, green checkmark |
| Tool call (error) | DisclosureGroup, expanded, red X, error in `.red` |
| Status update | Small centered label: "Session completed" / "Session failed" |

### Session Rules

- **Auto-scroll** to bottom during streaming (stop auto-scroll if user scrolls up)
- **Collapse completed tool calls** by default (user can expand)
- **Keep running tool call expanded** with a spinning progress indicator
- **Copy button** on each tool output for one-click copy
- **Monospaced** for all tool inputs and outputs
- **Elapsed time** shown for each tool call (e.g., "2.3s")
- **Error tool calls** stay expanded and show red status
- Assistant messages render markdown (bold, code blocks, lists)

---

## Quick Reference: File Checklist

Before submitting a new view, verify:

- [ ] `.toolbar` (not inline HStack)
- [ ] `.searchable()` on list/table views
- [ ] `.contextMenu` on table rows
- [ ] Short IDs (12 chars) in tables
- [ ] `.textSelection(.enabled)` on copyable text
- [ ] Copy buttons on IDs/paths/commands
- [ ] Monospaced font on technical values
- [ ] `.keyboardShortcut(.defaultAction/.cancelAction)` on dialog buttons
- [ ] `.tableStyle(.inset(alternatesRowBackgrounds: false))` on tables
- [ ] `ContentUnavailableView` for empty states
- [ ] Overlay error banners (not toolbar errors)
- [ ] `.foregroundStyle(.secondary)` on metadata
- [ ] Destructive buttons use `role: .destructive`
- [ ] Domain-specific toolbar buttons are icon + text with `.labelStyle(.titleAndIcon)` (§1 labeling rules)
- [ ] Every toolbar control has `.help()`; disabled buttons explain why
- [ ] Screen status shown as dot + text, counting real state (§15)
