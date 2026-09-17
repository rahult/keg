# Keg Design System

Keg serves two audiences on the same screens: people who have never touched
containers, and experienced operators who want every knob. Every UI decision
is checked against the principles below, in priority order.

Grounded in Apple's Human Interface Guidelines (Toolbars, Buttons, Labels,
Writing). When in doubt, clarity beats cleverness.

---

## 1. Principles

### 1.1 Never make the user guess
"Don't make people guess or experiment to figure out what a toolbar item
does." (HIG: Toolbars) A control whose meaning isn't obvious from a
universally recognized symbol gets a **text label** — always icon + text,
never a cryptic glyph.

### 1.2 One primary action per screen
Each screen has exactly one prominent (accent-tinted) action — the thing a
user most likely came to do. It sits in the toolbar trailing position. All
other actions are plain toolbar items. (HIG: "Only specify one primary
action, and put it on the trailing side.")

### 1.3 Plain language first, jargon defined
Controls, statuses, and errors are written for someone who has never heard
the word "compose". Domain terms may appear, but only after the plain
meaning is established — help popovers carry the translation (see
`SectionHelpGuide`). Button labels are **verbs** that say what happens:
"Start Services", not "Up". (HIG: Writing — "be action oriented", "avoid
the temptation to be too cute or clever".)

### 1.4 State lives next to the object it describes
A screen's state ("4 services running") is shown as a first-class status
element — colored dot + text — not buried in a settings-style form row.
Errors appear next to the problem, say what happened, and say what to do
next. (HIG: Writing — "display it as close to the problem as possible… be
clear about what someone can do to fix it.")

### 1.5 Progressive disclosure
Friendly summaries are the default. Raw detail — command lines, IDs,
digests, low-level flags — is one disclosure away, collapsed by default,
and never the first thing a newcomer sees. Experience level can drop
whole advanced sections (Getting Started) but never gates capability.

### 1.6 Consistency is the contract
The same word means the same thing everywhere, the same control looks and
behaves the same everywhere, and every screen offers help the same way
(the ⓘ toolbar button). Deviations require a reason recorded here.

---

## 2. Toolbar vocabulary

| Rule | Examples |
|------|----------|
| **Icon-only** is reserved for universally recognized symbols | + (new/run), ⟳ (refresh), 🔍-style search, trash (delete), sidebar toggle, ⓘ (help) |
| **Icon + text label** for everything domain-specific | Start Services / Stop Services (Compose), Create Cluster (Kubernetes), Login… (Registries) |
| Exactly one `.borderedProminent` per screen, trailing | Start Services on Compose; Run… on Containers |
| Text-labeled actions are visually separated from icon-only neighbors (HIG: "Keep actions with text labels separate") | Separate `ToolbarItem`s; no icon+text squashed against icon-only |
| Every toolbar control carries `.help()` | Hover explains what it does; when disabled, hover explains *why* |
| Text-labeled toolbar buttons use `.labelStyle(.titleAndIcon)` | macOS hides `Label` titles in toolbars by default — without this the label silently disappears and the button degrades to the icon-only case above |

### 2.1 Disabled states must explain themselves
A disabled button with no explanation reads as a bug. The `.help()` tooltip
states the blocking condition: "Choose a compose file first", "Services are
already running".

---

## 3. Status language

| State | Vocabulary | Visual |
|-------|-----------|--------|
| Workloads active | "N services running" | Green dot (`circle.fill`) + text |
| Workloads stopped | "Stopped" / "No services running" | Gray dot + text |
| Busy | "Starting…" / "Stopping…" | Spinner or animated label |
| Problem | Plain sentence + next step | Orange/red, near the problem, plus the standard error banner |

Sentence case everywhere in UI copy.

---

## 4. Section anatomy

Every main section follows the same skeleton:

1. **Toolbar** — primary action (labeled), secondary actions (icon-only
   where recognized), ⓘ help, refresh where lists are cached.
2. **Content** — the object table/cards first; configuration second.
3. **Empty state** — one sentence of explanation + one primary action
   button (HIG: "Provide clear next steps on any blank screens").
4. **Detail/inspector** — per-object actions and raw detail.

---

## 5. Voice

- Sentence case, verb-first, no abbreviations without need (`ID` is fine).
- "You/your" for the user's things: "your containers".
- Errors never blame; they instruct: "Choose a compose file first."
- Beginner copy may be warm ("it's safe — nothing touches your Mac");
  expert surfaces stay terse. Tone follows experience level, vocabulary
  does not.

---

## 6. Change log

- 2026-09-17 — Initial system. Compose toolbar converted from icon-only
  Up/Down arrows to labeled Start/Stop Services; status promoted to a
  first-class element; "Import Preview" renamed "What Will Run".
