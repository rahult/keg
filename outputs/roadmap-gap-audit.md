# ROADMAP Gap Audit

Audit date: 2026-04-16

This audit compares `ROADMAP.md` against the committed app state at `d012d14` (`feat(app): polish macOS shell and agent onboarding`) after the earlier Agents roadmap, resilience, validation, and QA passes landed.

## Roadmap completion state after `d012d14`
No additional `ROADMAP.md` checklist items were honestly closed by `d012d14`.

The latest macOS pass added real product improvements that sit adjacent to the roadmap rather than changing the remaining checklist status:

- a Mac-native agent use-case library and onboarding flow
- standard-menu command placement cleanup in the app shell
- dedicated editor-sheet routing from agent detail instead of mixed inline inspector editing
- stronger dashboard quick actions and shell affordances
- destructive confirmations on Keg container/image surfaces

Those changes improve the product, but they do **not** provide enough evidence to newly check off the remaining manual accessibility items.

## Notes on superseded roadmap wording
These roadmap lines were not treated as remaining gaps because the product already exceeds the original intermediate plan shape:

- Phase 2 placeholder-shell goal: agents screens are implemented, not placeholders.
- Phase 5 edit flow is now concretely implemented as a detail view that launches the dedicated `AgentEditorView` sheet, so the roadmap should be read as satisfied by the shipped detail/editor flow rather than the earlier sketch code block.

---

## Real remaining gaps

### Accessibility checklist still needs manual QA proof
**Roadmap items:**
- `VoiceOver labels on all controls`
- `Dynamic Type support`
- `Sufficient color contrast`
- `Focus indicators`
- `Keyboard navigation`

**Current state:**
- The Agents area received a focused accessibility pass and now has stronger labels, hints, search focus routing, keyboard selection behavior, and cleaner edit/onboarding flows on the changed screens.
- `outputs/agents-accessibility-note.md` documents what is covered in code today.
- `outputs/qa-manual-checklist.md` now includes the latest macOS shell and onboarding flows introduced in `d012d14`, so the remaining checklist can be exercised against the current product shape.
- Broad completion of the accessibility checklist still requires running-app QA rather than static file inspection alone.

**Evidence:**
- `outputs/agents-accessibility-note.md`
- `outputs/qa-manual-checklist.md`
- improved accessibility and keyboard polish in:
  - `Sources/Keg/Views/Agents/AgentListView.swift`
  - `Sources/Keg/Agents/Views/SessionListView.swift`
  - `Sources/Keg/Agents/Views/SkillListView.swift`
  - `Sources/Keg/Agents/Views/SourceListView.swift`
  - `Sources/Keg/Views/Sidebar/SidebarView.swift`

---

## Summary
After reconciliation against `d012d14`, the remaining roadmap work is still manual-QA centered:

1. run a real accessibility QA pass for contrast, focus indicators, Dynamic Type, and full VoiceOver/keyboard coverage
2. exercise the new macOS shell and agent-onboarding flows with the updated manual checklist before checking any additional roadmap boxes
