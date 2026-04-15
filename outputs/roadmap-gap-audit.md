# ROADMAP Gap Audit

Audit date: 2026-04-15

This audit compares `ROADMAP.md` against the latest shared workspace state after all Agents roadmap implementation waves landed locally.

## Newly verified as implemented
These roadmap items are now concretely implemented in code and were checked off in `ROADMAP.md`:

- `Keyboard shortcuts (Cmd+1 for Keg, Cmd+2 for Agents?)`
- `Duplicate agent`
- `Filter by date works`
- `Cmd+1/2: Switch areas`
- `Cmd+Delete: Delete selected`
- `Cmd+F: Focus search`
- `Escape: Clear selection/close`
- `Network errors with retry`
- `Auth errors with re-auth flow`
- `Timeout handling`
- `Offline state handling`

## Notes on superseded roadmap wording
These roadmap lines were not treated as remaining gaps because the product already exceeds the original intermediate plan shape:

- Phase 2 placeholder-shell goal: agents screens are implemented, not placeholders
- Phase 5 `edit existing agent via sheet`: editing exists today via inspector/detail/editor flow rather than the originally sketched sheet-only UI

---

## Real remaining gaps

### Validation feedback is still uneven across forms
**Roadmap item:** `Validation errors in forms`

**Current state:**
- `SourceEditorView` now has explicit inline validation messages and test-on-save behavior.
- Other forms still rely more on disabled actions or generic error alerts than field-level validation.

**Evidence:**
- stronger validation in `Sources/Keg/Agents/Views/SourceListView.swift`
- still limited/uneven in:
  - `Sources/Keg/Agents/Views/SkillListView.swift`
  - `Sources/Keg/Views/Agents/CreateAgentSheet.swift`
  - `Sources/Keg/Views/Agents/AgentEditorView.swift`
  - `Sources/Keg/Views/Settings/SettingsView.swift`

### Accessibility checklist still needs manual QA proof
**Roadmap items:**
- `VoiceOver labels on all controls`
- `Dynamic Type support`
- `Sufficient color contrast`
- `Focus indicators`
- `Keyboard navigation`

**Current state:**
- The Agents area received a focused accessibility pass and now has stronger labels, hints, search focus routing, and keyboard selection behavior on the changed screens.
- `outputs/agents-accessibility-note.md` documents what is covered in code today.
- Broad completion of the accessibility checklist still requires running-app QA rather than static file inspection alone.

**Evidence:**
- `outputs/agents-accessibility-note.md`
- improved accessibility and keyboard polish in:
  - `Sources/Keg/Views/Agents/AgentListView.swift`
  - `Sources/Keg/Agents/Views/SessionListView.swift`
  - `Sources/Keg/Agents/Views/SkillListView.swift`
  - `Sources/Keg/Agents/Views/SourceListView.swift`
  - `Sources/Keg/Views/Sidebar/SidebarView.swift`

---

## Summary
After final reconciliation, the remaining roadmap work is narrow:

1. make validation feedback more consistent across non-source forms
2. run a real accessibility QA pass for contrast, focus indicators, Dynamic Type, and full VoiceOver/keyboard coverage
