# Keg — Design Review

**Date:** 2026-09-16
**Scope:** Every screen in the app (Keg area, Agents area, menu bar, sheets), reviewed from source (`Sources/Keg/Views/**`, `Sources/Keg/Agents/Views/**`, `Sources/Keg/App/**`, `Sources/Keg/Components/**`) plus the provided screenshot.
**Measured against:** Apple Human Interface Guidelines (macOS), the repo's own `DESIGN.md`, and the goal of a light, minimal, developer-focused tool.

---

## TL;DR

Keg's bones are good — consistent tables, search everywhere, context menus, monospaced identifiers, copy affordances, empty states, and strong accessibility labeling. The problems are concentrated in five places:

1. **The window chrome has a visible bug** — two sidebar-toggle buttons render at the top left (the exact issue in the screenshot).
2. **Two destructive actions have no confirmation** — deleting a container from its detail header, and deleting a Kubernetes cluster from the toolbar. One misclick, no undo. This contradicts the rest of the app, which confirms deletes.
3. **Whole screens are unreachable or dead code** — Ports is routed but absent from the sidebar; the entire Agents area (6 sections, ~7,300 lines) cannot be reached because the sidebar never switches; `IntegrationSettingsView` is never instantiated.
4. **The sidebar carries a mini system dashboard** that duplicates the Dashboard section and steals navigation space.
5. **The "Terminal" screen is not a terminal** — it's a line-based command runner with hardcoded green-on-black colors that break light mode and accessibility.

Everything else is polish: unify error banners (4 competing implementations), typography (rounded vs. default numerals), corner radii (2–12pt used interchangeably), and decorative colors that don't carry meaning.

---

## P0 — Functional / UX bugs visible to users

### 1. Duplicate sidebar toggle in the window title bar
*Seen in the screenshot: a pill-wrapped sidebar icon next to the traffic lights, and a second sidebar icon before the "Images" title.*

`MainView` adds a custom `ToolbarItem(placement: .navigation)` with a `sidebar.left` button, while `NavigationSplitView` + `.windowToolbarStyle(.unified)` already renders its own toggle.
[KegApp.swift, MainView toolbar, lines 190–199](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/App/KegApp.swift "citation")

**Fix:** Delete the custom `ToolbarItem`. The built-in toggle plus `SidebarCommands()` (⌃⌘S) and the `kegToggleSidebar` notification already cover all entry points.

### 2. Force-delete with no confirmation — container detail header
The trash button in `ContainerDetailView`'s header calls `vm.delete()` → `client.delete(id:, force: true)` immediately. No alert, no undo. The list view, by contrast, confirms. Same screen family, opposite safety model.
[ContainerDetailView.swift, headerActions, lines 230–236](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/Views/Containers/ContainerDetailView.swift "citation")

**Fix:** Wrap in a confirmation alert identical to the list's ("Delete <name>? This action cannot be undone.").

### 3. Delete Cluster with no confirmation — Kubernetes toolbar
`Delete Cluster` sits directly in the toolbar next to Stop, styled destructive, and runs `container delete -f` on tap — also deleting the extracted kubeconfig. A cluster that took ~60s to bootstrap is gone in one click.
[KubernetesView.swift, toolbar, lines 366–392](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/Views/Kubernetes/KubernetesView.swift "citation")

**Fix:** Confirmation alert; also consider moving Delete out of the toolbar into the config section so the primary row only carries Stop/Start.

### 4. Ports screen is unreachable
`KegSection.ports` exists, `KegDetailView` routes it, `PortDashboardView` is fully built (search, conflict badges, open-in-browser) — but `KegSidebarContent`'s section list never includes it. Users can never open it.
[SidebarView.swift, sections array, lines 149–155](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/Views/Sidebar/SidebarView.swift "citation")

**Fix:** Add `.ports` to the System (or a Networking) sidebar section.

### 5. The Agents area is unreachable — ~7,300 lines of dead UI
`SidebarView` always renders `KegSidebarContent`; `DetailView` always renders `KegDetailView`. `AreaPicker`, `AgentSidebarContent`, `CrossAreaLink`, `AgentPermissionModeControl`, and `AgentAccountStatusCard` are defined but instantiated nowhere (verified by search — zero call sites). Setting `appState.currentArea = .agents` (from the dashboard's "Get Started" card or the New Agent menu command) changes no visible UI. `IntegrationSettingsView` (Supaglue OAuth settings, 384 lines) is likewise never referenced.
[SidebarView.swift, line 17](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/Views/Sidebar/SidebarView.swift "citation")

**Decision needed:** either wire the area picker into the sidebar (segmented control at top, swap sidebar content + detail routing on `currentArea`), or strip the Agents area from the shipping target until it's ready. Shipping unreachable code is worse than either — it's already causing design drift (e.g. agent views navigate via toolbar buttons because the sidebar doesn't work there).

Also dead: the `.settings` case in `KegDetailView` — the sidebar opens Settings via `SettingsLink` (a separate window), so the in-detail Settings route never fires.

### 6. Menu bar "Quick Access" rows look clickable and do nothing
`MenuBarPopover`'s Quick Access section renders Terminal and Containers rows as plain `HStack`s with icons — no `Button`, no action. Users will click them, get no feedback, and learn not to trust the popover.
[MenuBarPopover.swift, lines 107–129](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/Views/MenuBar/MenuBarPopover.swift "citation")

**Fix:** Make each row a button that opens the main window at that section (`openWindow(id: "main")` + set `selectedKegSection`), or delete the section.

### 7. Logs "Follow" toggle icon never changes
Both branches of the ternary use `arrow.down.to.line.compact`, so the toggle gives no visual state feedback (only the tint changes subtly).
[ContainerLogsView.swift, lines 158–166](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/Views/Containers/ContainerLogsView.swift "citation")

**Fix:** Use `arrow.down.to.line` when following, `pause`/`arrow.down.to.line.compact` otherwise — or just label it.

### 8. Leftover learning prompt shipped in production code
`KubernetesVM.waitForAPIServer` contains `// TODO(you): implement the readiness check — see the Learning prompt in the chat. 5-10 lines. This is where your domain input matters.` — and the body is a 5-second sleep. The cluster is reported "Running" without verifying the API server.
[KubernetesView.swift, lines 184–188](/Volumes/Atlas/Code/projects/meadow/Sources/Keg/Views/Kubernetes/KubernetesView.swift "citation")

**Fix:** Implement the `/readyz` poll as the comment describes, and remove the prompt text.

---

## P1 — Global design-system inconsistencies

### Error presentation: four competing implementations
- `ErrorBannerModifier` (`.errorBanner($vm.errorMessage)`) — the good one, bottom overlay pill.
- Hand-rolled copies of the same pill pasted into Compose, Builds, Dev Containers, Networks, Volumes (5 duplicates, subtly different paddings/corner radii).
- A separate `ErrorBanner` component used only by the Agents area, anchored **top** instead of bottom.
- Red inline `Text(error)` inside sheets (Pull, Tag, Login, Run, Recreate).

**Fix:** Route every detail-view error through `.errorBanner`; keep sheet errors inline (that's fine and standard); delete the 5 hand-rolled copies and the top-anchored variant.

### Typography: two number personalities
- Sidebar `MetricCard` and Dashboard `MetricTile` use `.rounded` design for values.
- `StatCard`, tables, and health scores use the default design with `.monospacedDigit()`.
Same kind of data, two typefaces. **Pick one** — recommendation: default design + `.monospacedDigit()` everywhere (tabular alignment in lists matters more than friendliness here; the rounded style also reads slightly less "developer tool"). Monospaced usage for IDs/digests/paths is otherwise excellent and matches `DESIGN.md` §12.

### Color: decorative vs. semantic
Semantic threshold coloring (CPU/memory green→orange→red) is good. But several assignments are pure decoration with no meaning: Storage = purple, Latency = blue, Network I/O = purple, Block I/O = orange, Health "warning" = yellow (poor contrast on light backgrounds; `StatusBadge` uses yellow for "paused" too). Per HIG, color should carry information; five pastel accents on one dashboard read as candy.

**Fix:** Neutral `.secondary` icons by default; reserve green/orange/red for thresholds and state. Change Health's warning tier to `.orange`.

### Corner radii: 2, 4, 6, 8, 10, 12 all in use
Log chips 2, code blocks 4, metric cards 6, standard cards 8, menu-bar approval rows 10, dashboard tiles 12. **Fix:** two radii only — 8 for cards, 4–6 for small chips/inline elements.

### Surfaces: too many background recipes
`controlBackgroundColor`, `windowBackgroundColor`, `textBackgroundColor`, `.bar`, `.thinMaterial`, `.regularMaterial`, `.quaternary`, and `.primary.opacity(0.04 / 0.06 / 0.08)` are all used as "card background" somewhere. StatCard alone layers material + stroke + tint wash. **Fix:** one card recipe (`controlBackgroundColor` fill, 8pt radius, no border — separators via spacing), one code/terminal surface (`textBackgroundColor`).

### Toolbar inconsistencies
- **Ellipsis style mixed:** `"Run..."`, `"Pull..."` (three ASCII dots) vs. `"Prune…"`, `"Login…"` (typographic). Use `…` everywhere (HIG punctuation).
- **`.keyboardShortcut(.defaultAction)` on toolbar buttons** (Compose "Up", Builds "Build", K8s "Create Cluster"): Return triggers these from anywhere in the window, even when focus is in a text field. Reserve `.defaultAction` for sheets/dialogs.
- **⌘R refresh on every screen** is fine for a dev tool, but each view re-implements its own Refresh item while `AppState` already runs an adaptive refresh timer — consider pushing fresh data down and demoting Refresh to a menu command.
- **`toolbarRole(.editor)` everywhere** — editor role is meant for document-editing apps; it also affects title placement. Verify visually whether `.browser` (or default) gives a cleaner title/toolbar relationship for list-browsing screens.
- **Icon-only vs. text buttons mixed arbitrarily** (e.g. Terminal presets are bare text: "docker ps", "images", "kubectl").

### Inspector deviates from the repo's own guide
`DESIGN.md` §10 mandates `.inspectorColumnWidth(min: 280, ideal: 320)`; neither the Containers nor Agents inspector sets it, so the detail column floats wider/narrower by content. Also worth reconsidering the guide itself: opening the inspector on *single-click selection* means every arrow-key navigation resizes the window. Double-click-to-inspect (or a dedicated "Get Info" ⌘I) is calmer.

---

## Screen-by-screen

### Sidebar
- **Mini system dashboard duplicates the Dashboard section.** It shows CPU/Memory/Storage/Latency cards + counts + a "10:06 AM" timestamp — then the user clicks Dashboard and sees the same four numbers again as big tiles. The sidebar's job is navigation; this is the single biggest source of visual weight in the app.
  **Recommendation:** collapse it to one quiet status row — a status dot, "System running", and `1/1 containers · 7 images` — or remove it and let the menu bar own glanceable status.
- **"Keg" header inside the card** restates the sidebar's navigation title; the timestamp updates on every refresh tick and is noise. Drop both.
- Section grouping (Overview / Workloads / Content / System / Tools) is good; consider "Networking" for Networks + Registries + Ports per `DESIGN.md` §6.
- Health badge shows a raw count in the default accent color — unread as "needs attention". A red badge when `unhealthyContainerCount > 0` would signal properly.
- Column width 220–340 is sensible.

### Dashboard
- Title reads **"Keg Dashboard"** in `.largeTitle.bold` — the user knows the app is Keg; "Dashboard" alone is enough.
- **Quick Actions duplicates existing UI:** "Refresh" repeats the header button next to it; "Containers" and "Terminal" repeat the sidebar. Cut the section or replace it with actions that *aren't* navigation (e.g. Prune Images, Start System — Start/Stop System is the one keeper).
- Auto-refresh toggle in the header is fine but visually heavier than the value it provides — a small `.toggleStyle(.checkbox)` or a menu item would do.
- `MetricTile` puts the metric *name* at the bottom under value and subtitle — inverted hierarchy. Name on top (caption, secondary), value big, subtitle below.
- The Agent discovery card is good onboarding, but its purple `cpu` icon at `.largeTitle` is the most colorful thing on screen; tone to `.secondary`.
- Structure is otherwise right: platform setup card surfaces only when needed, services list is live, disk usage table is genuinely useful.

### Containers
- 9 columns is dense but defensible for a dev tool; live CPU/Memory columns are the differentiator vs. the CLI. Consider hiding the **ID** column by default (right-click table headers to toggle columns is free with `Table`).
- No row-level quick actions — Start/Stop requires a context menu. Docker Desktop shows hover actions; at minimum add Start/Stop to the toolbar when a selection exists.
- Inspector opens on single selection (see P1).
- Escape handling (clear selection → clear search → unfocus) is thoughtful; keep.

### Container Detail (inspector)
- Header + segmented tabs is the right pattern.
- The `ellipsis.circle` menu contains exactly **one** item ("Edit & Recreate…") — make it a plain button.
- "CPU" stat card shows cumulative seconds ("3.2 s") — meaningless as a headline metric. Show live % (the data exists via stats polling) or label it "CPU Time".
- Environment tab renders an always-visible copy button per row; `SectionGrid` uses hover-reveal. Pick the hover pattern for both.
- Mounts/Environment/Files/Logs/Stats tabs are all solid. Files tab's path bar with back/up/go is genuinely nice.

### Images
- Digest column shows `sha256:d32cdf619f63` — the `sha256:` prefix is identical in every row; strip it (keep it on copy).
- "Calculating..." per-row in Size is noisy; a single "—" until resolved is calmer.
- Run/Tag exist only in the context menu — discoverability is poor. Add a toolbar "Run" when a selection exists, or hover actions.
- Prune alert with "Prune Unused" vs. "Prune All" is a good, honest destructive dialog. More of this pattern, please (see P0-2/3).

### Builds
- Config GroupBox + Grid is clean; Browse buttons next to path fields are correct.
- `.defaultAction` on the toolbar Build button (see P1).
- Output pane is good. No build history — the screen is named "Builds" but is a one-shot form; either rename to "Build" or keep a list of past builds below the form.

### Compose
- Same solid config pattern as Builds. Import Preview with dependency order + per-service warnings is a standout feature.
- Output joins entries with `"\n\n"` — every line renders double-spaced. Use `"\n"`.
- "Up" is prominent + `.defaultAction` (see P1); "Down" is a plain toolbar button with no confirmation — stopping and *removing* all services deserves at least a confirmation when services are running.
- Hand-rolled error pill (see P1).

### Kubernetes
- Toolbar carries Create/Stop/Start/**Delete Cluster** — delete without confirmation (P0-3).
- `StatusBadge` + a separate caption `Text(displayName)` ("Running" twice, basically) — the badge already says it; drop the text.
- Connection section's `CopyableRow`s (`export KUBECONFIG=…`) are exactly right for developers.
- `waitForAPIServer` TODO (P0-8).
- Cluster name/image fields are editable pre-create, disabled after — good state modeling.

### Logs (merged, multi-container)
- HSplitView with a source rail + merged pane is the right shape. Color-dot-per-container palette works.
- Rail rows toggle via `onTapGesture` with only a checkmark as feedback — use real `Toggle`/checkbox styling so it reads as multi-select at a glance.
- Single-container logs have level filtering; this view doesn't — unify (level filter here matters *more*, not less).
- 5,000-line cap and pause control: good.

### Logs (single container)
- Every line gets a colored rounded level chip (blue INF chip on nearly every line) — very heavy. Color the text (already done) and drop the chip, or render the 3-letter label in plain monospaced secondary.
- Follow icon bug (P0-7).
- "Copy All" copies **unfiltered** lines even when a filter/search is active — surprising. Copy what's on screen.
- Line-number gutter: nice.

### Networks / Volumes
- Minimal and correct. Networks has **no** delete confirmation; Volumes **does** — inconsistent. Confirm both.
- Both hand-roll the error pill (P1). No create actions — if the CLI supports network/volume create, a "+" belongs here; if not, fine.

### Registries
- Uses `List` while every other list screen uses `Table` — violates `DESIGN.md` §5. Convert to a one- or two-column Table.
- Logout is context-menu only; a destructive account action should be visible (trailing button per row).
- Login sheet is well-formed (Esc/Return, disabled-until-valid).

### Health
- Gauge + legend + table is clear and useful. Yellow warning tier (contrast) — switch to orange.
- Rows aren't clickable — tapping a container here should open its detail. This screen also overlaps the Containers list's live CPU/Memory columns; that's OK (this is the triage view), but the sidebar badge should deep-link here.
- Selection is `.constant(nil)` — intentional, but then the Table loses keyboard affordances for free.

### Terminal
- **Not a terminal:** `Process` + a TextField per line means no ANSI, no arrows, no `vim`, no tab completion. Users will discover this the hard way. Either rename it honestly ("Command Runner") or embed a real PTY (SwiftTerm).
- **Hardcoded `.green` text on `Color.black`** ignores system appearance, and the input row renders `.white` text on `windowBackgroundColor` — in light mode that's white-on-light-gray, effectively unreadable.
- Toolbar preset buttons ("docker ps", "container ls", "images", "kubectl") are bare text — move them into a single `Menu` ("Presets") or a segmented control.
- The "Open Terminal" container action correctly hands off to Terminal.app/iTerm via `TerminalLauncher` — arguably the in-app view should lean into being a *launcher/preset runner* and leave real shells to the terminal emulator.

### Dev Containers
- Minimal and fine: scan project → summary → "Open in Container". Multi-line env/mounts dumped into `DetailRow` values render as monospaced blocks — acceptable, though a two-column table would scan better when long.

### Settings (window)
- Standard grouped form, right choice. Status rows (CLI / System / Docker API) follow one pattern with dot + state + action — consistent.
- "About" section carries marketing copy ("Docker Desktop replacement for macOS — …") — trim to version/runtime/requirements.
- The Docker API section with copyable socket path + `export DOCKER_HOST=…` is excellent — the kind of detail that makes a dev tool feel considered.
- Platform section is dense but organized; DNS guidance text is helpful.

### Menu bar popover
- Quick Access rows are dead (P0-6).
- Five sections separated by four Dividers in a 340pt popover — heavy. The Approvals Inbox (multi-row cards with Reject/Approve) is a lot of UI for a menu bar surface; consider badge count + "Review in Keg" deep link instead of full triage cards.
- Status header + Start/Stop + Open Keg + Settings: keep, that's the core.

### Sheets (Run / Recreate / Pull / Tag / Registry Login)
- Consistent 400–520pt widths, Esc/Return wired, disabled-until-valid — matches `DESIGN.md` §11. Good.
- The "Edit & Recreate" explanatory caption ("Containers are immutable — …") is exactly the right kind of teaching copy.
- Comma-separated text fields for env/ports/volumes are the weakest part — no per-entry validation until the CLI errors out. A key-value row editor is a worthwhile v2, not a blocker.

### Agents area (currently unreachable — see P0-5)
If you wire it up: the area switch belongs in the sidebar (segmented control at top), not toolbar buttons; `AgentDashboardView` currently navigates via "Use Cases" / "Manage Agents" toolbar buttons purely because the sidebar doesn't switch. The list/detail/sheet patterns mirror the Keg area and are fine. Resolve the duplicated `ErrorBanner` (top-anchored) vs. `.errorBanner` (bottom) before shipping it.

---

## What already works well (keep doing)

- `.searchable` on every list, with ⌘F routing to the right field per screen.
- Context menus on every table, ordered sanely (actions → navigation → copy → destructive).
- Monospaced identifiers + `.textSelection(.enabled)` + copy buttons — the developer ergonomics are genuinely good.
- `ContentUnavailableView` empty states with next-step copy, dynamically renamed when filtered.
- `StatusBadge` respects increased-contrast mode; metric tiles respect Reduce Motion; accessibility labels/hints are present nearly everywhere.
- Adaptive refresh cadence (2s active / 10s idle) and careful pipe-handler teardown — invisible, but exactly the craft that keeps the app feeling light.

---

## Prioritized fix list

| # | Severity | Fix | Effort |
|---|----------|-----|--------|
| 1 | P0 | Remove custom sidebar-toggle toolbar item in `MainView` | 5 min |
| 2 | P0 | Confirmation alert on container-detail Delete | 15 min |
| 3 | P0 | Confirmation alert on K8s Delete Cluster; move out of toolbar | 20 min |
| 4 | P0 | Add Ports to the sidebar | 5 min |
| 5 | P0 | Wire or strip the Agents area; decide `IntegrationSettingsView` | half-day decision |
| 6 | P0 | Make menu-bar Quick Access rows real buttons (or remove) | 15 min |
| 7 | P0 | Fix Follow toggle icon; make Copy All respect the active filter | 15 min |
| 8 | P0 | Implement `waitForAPIServer` readiness poll; delete TODO prompt | 30 min |
| 9 | P1 | Consolidate all error pills onto `.errorBanner` | 1 hr |
| 10 | P1 | Unify numeral typography (default + `.monospacedDigit()`), corner radii (8/6), card surface recipe | 1–2 hr |
| 11 | P1 | Slim sidebar: replace mini dashboard with one status row | 30 min |
| 12 | P1 | Toolbar pass: `…` punctuation, drop `.defaultAction` from toolbar buttons, Terminal presets into a menu | 1 hr |
| 13 | P1 | Container detail: single-item menu → button; CPU card shows %; env copy on hover | 45 min |
| 14 | P1 | Images: strip `sha256:` prefix, "—" while sizing, visible Run action | 30 min |
| 15 | P1 | Terminal: rename to Command Runner + fix light-mode input colors, or adopt SwiftTerm | rename: 30 min |
| 16 | P2 | Registries List → Table; visible logout; Networks/Volumes delete confirmations | 45 min |
| 17 | P2 | Health: orange warning tier, row → container detail navigation | 20 min |
| 18 | P2 | Dashboard: retitle "Dashboard", cut Quick Actions duplication, reorder MetricTile hierarchy | 30 min |
