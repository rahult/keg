# Keg Settings Redesign — Proposal

Direction seed `32e05c27` · mode: Operate · status: **implemented & visually verified 2026-10-01** (all nine panes, dark mode; both inspection-round defects fixed; awaiting your Folio review for tweaks)

---

## Direction contract

- **THESIS:** Settings should read as a calm operations console — every row says what it does and why, state sits on top, and nothing looks like a puzzle. We refuse the incumbent's seven-toolbar-tab, fixed 140/280-grid preferences window.
- **OWN-WORLD:** Light, grouped sidebar (`NavigationSplitView`, macOS System Settings idiom) + stacked pane groups; row anatomy = bold label + secondary description caption + control trailing right; hairline row separators in 10pt-radius cards; status cards crown each pane with the primary action trailing (Vercel header-action idiom); destructive controls quarantined in a bottom group; neutrals + system accent only, SF Pro + mono for technical values.
- **STORY:** A newcomer reads a row and understands it without knowing containers ("Start the Docker-compatible API so the `docker` CLI works"). An operator scans state dots and jumps via sidebar search-less muscle memory. Nobody hunts across seven same-looking tabs.
- **FIRST VIEWPORT:** Sidebar (~220pt) grouped General / Runtime / Features; first pane (General) opens with no status card, just calm groups. Apple Containers pane opens with the system status card on top — dot, headline, one-line detail, Start/Stop trailing — then Data Location, Boot Kernel, Platform groups.
- **FORM:** Mobbin-grounded candidate 4 of 7 — Buffer Preferences' calm descriptive rows — fused with Linear's trailing-control anatomy, Vercel's per-card header actions, Railway's bottom danger group. Seed key 32e05c27.
- **FINISH:** unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md.

## Grounded candidates (Mobbin channel, ordered by resonance)

1. **Linear — Preferences** (developer-tool gold standard): grouped dense sidebar; hairline rows; label + micro-caption; control trailing. [ref](https://mobbin.com/screens/8720abc2-c855-44ee-911d-bc15fc1707eb)
2. **macOS System Settings idiom** (Apple grouped family, confirmed by iOS refs): sidebar + grouped panes is the platform's own settings grammar. [ref](https://mobbin.com/screens/07d9ec6a-cb0e-4cb3-9a3c-4505d32f74ab)
3. **Vercel — Project Settings**: stacked config cards; per-card header + description + primary action top-right; inline confirm feedback. [ref](https://mobbin.com/screens/42170271-f4d5-45f9-bd85-38f0a55bd655)
4. **Buffer — Preferences ← ASSIGNED**: calm light rows; bold label + description + trailing picker; airy spacing; grouped nav with mini section headers. [ref](https://mobbin.com/screens/0398e56b-5120-4055-9348-2b046ded2e97)
5. **Railway — Project Settings**: dark; sidebar's last group is a red **Danger** zone. [ref](https://mobbin.com/screens/a1ee572f-24ca-494c-b1f4-a3d49cbeabd1)
6. **Graphite — Preferences**: two-tier scope sidebar (workspace vs user settings). [ref](https://mobbin.com/screens/102736c8-9a2a-4185-a155-025f1c0b3217)
7. **Ghost — Settings**: editorial minimal; small-caps sidebar labels; hairline rows. [ref](https://mobbin.com/screens/e3a69991-68a8-4be8-b703-f8a70eb0d010)

The roll assigned candidate 4. It wins on both axes against every catalog challenger: audience identification (macOS developers read calm confidence, not spectacle) and product clarity (Operate mode + HIG bindings). Challenger cases: phosphor terminal is the nearest neighbor but hardcoded green-on-black violates our semantic-colors-only commitment; cloud quarry / sneaker archive / ASCII / CD-ROM / zine are Persuade-world material with no settings-task grammar. The canon (macOS System Settings played straight) is already absorbed into the assigned direction's sidebar grammar.

## Structural change: tabs → sidebar

Current: `TabView` + 7 toolbar tabs inside a 720×640 window, `SettingsWindowFrame` NSView hack.
Proposed: `NavigationSplitView` settings window (the macOS 26 System Settings idiom), resizable, min ~640×540.

**Sidebar groups → panes**

| Group | Panes | Sourced from |
|---|---|---|
| **General** | General (experience level, terminal preference, launch at login), Software Update, About | Keg tab |
| **Runtime** | Apple Containers (CLI, system, data location, boot kernel, platform defaults), Docker API, Kubernetes | Apple Containers / Docker / Kubernetes tabs |
| **Features** | Gateway, Cooper, Agents (Claude API, when enabled) | Gateway / Cooper tabs |

Rationale: tabs scale linearly with features (7 already, more coming); grouped sidebar scales hierarchically and matches the platform. No external coupling — the only entry points are the `Settings` scene and the main-window `.settings` section (verified: no deep links target specific tabs).

## Pane anatomy

1. **Status card first** (panes with system state): existing `SettingsStatusCard`, upgraded so the pane's primary action sits *trailing in the card header* (Start/Stop, Enable, Connect) instead of below.
2. **Groups**: `SettingsGroup` title + new mandatory caption line (one sentence, what this group controls). Spacing rhythm kept (12/4/10).
3. **Rows**: replace the 140pt-label/280pt-control grid with the convergent anatomy — leading `VStack { Text(label); SettingsCaption(description) }`, trailing control (toggle, picker, button), hairline separators between rows inside a card. Pickers/trailing controls right-align; no fixed control column.
4. **Danger group** at the bottom of panes that have destructive actions (Cooper: Clear Conversation; Gateway: remove custom routes; Kubernetes: delete cluster) — red-tinted group title, destructive-role buttons.
5. **About pane**: add website/repo/releases links, copyable version row (SettingsCopyLine), keep LabeledContent facts.

## Component work (`SettingsComponents.swift`)

- **New `SettingsNavList`**: sidebar with `Section` headers (General/Runtime/Features), SF Symbol icons, badge for "needs attention" states (e.g. boot kernel unregistered → orange dot on Apple Containers).
- **`SettingsRow` → `SettingsValueRow`**: new label+caption+trailing anatomy; old fixed-grid row deleted.
- **`SettingsCard`**: corner radius 6 → 10 (macOS 26 grouped-content convention); hairline separators between rows.
- **`SettingsStatusCard`**: optional `headerAction:` trailing slot (replaces `AnyView` erasure with proper generic overloads).
- **Retire**: hand-rolled `BootKernelStatusCard` dot layout → rebuild on `SettingsStatusCard` (kept its 5-state notices as detail content); `CopyableRow` in K8s → `SettingsCopyLine`.
- **Moved**: `TerminalPreferenceSection` out of `PlatformSettingsSection.swift` into the General pane file.

## Inventoried inconsistencies this fixes

From the code audit (explore agent, 2026-09-30): two copy idioms → one; GroupBox → SettingsCard; AnyView workarounds → overloads; SoftwareUpdate frequency picker and Platform "DNS Domains" header breaking the grid → both absorbed by new row anatomy; mixed native/grid rows in Claude Agents section → unified; Gateway "HTTPS"/"HTTPS" duplicate label → group caption + unnamed row; stale "690pt" comment and the NSView frame hack → deleted.

## Risks

- **Main-window embedding**: `SettingsView` also renders as the main window's `.settings` detail — a NavigationSplitView in a narrow column needs `.navigationSplitViewColumnWidth(min: 200, ideal: 220)` and a verified compact layout; if it reads cramped, the embedded variant collapses to the pane column with a compact picker.
- **DESIGN.md §18** documents the old rules — it must be rewritten with this proposal's anatomy after build (per AGENTS.md, docs stay in sync).
- **Window behavior**: standalone Settings window keeps ⌘,; instance guard untouched; new window size replaces `SettingsWindowFrame`.
- Native SwiftUI, so the impeccable visual-verify pass = build (`make app`), launch, screenshot each pane (computer-use), one batched fix round.

## Build order (after this proposal is approved)

1. `SettingsComponents` kit (nav list, value row, card radius, status-card action slot)
2. `SettingsView` → NavigationSplitView + pane routing; delete frame hack
3. Pane-by-pane migration (General → Runtime → Features), fixing inventoried inconsistencies per pane
4. About pane links/copy
5. DESIGN.md §18 rewrite → `make app` → visual verify pass (all panes, light + dark) → one fix batch
