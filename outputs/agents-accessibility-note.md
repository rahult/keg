# Agents Accessibility and Keyboard Pass

Date: 2026-04-15

## Scope
Focused pass on the changed Agents surfaces:
- `AgentListView`
- `SessionListView`
- `SkillListView`
- `SourceListView`
- `AgentPermissionModeControl`
- supporting source editor accessibility copy where helpful

## Covered in code

### Keyboard affordances
- `Cmd+F` now focuses search in all major Agents list screens via the shared `kegFocusSearch` notification and per-screen `searchFocused` bindings.
- `Escape` now clears selection or closes the active editor sheet in changed Agents screens where selection/sheets are present.
- Delete-key affordances now exist for keyboard-driven destructive actions where they are safe and local:
  - Agents list: archive selected agent
  - Skills list: delete selected skill
  - Sources list: delete selected source
- Table-driven screens expose clearer keyboard hints so arrow-key selection behavior is discoverable to assistive tech users.

### VoiceOver / spoken labels
- Added or strengthened spoken labels and hints on:
  - session filters
  - workflow and label columns in the session table
  - sources table columns and enable toggle
  - source editor fields
  - skills list selection table
  - permission mode segmented control
  - area picker hinting
- Session/source/skill tables now expose list-level labels, values, and usage hints.

### Focus / selection polish
- Selection-clearing behavior is now explicit in changed Agents tables instead of leaving stale selection active.
- Search focus is routable from the global Find command into the relevant Agents screen.

## Roadmap items credibly closed for the Agents area
These are now reasonably covered for the Agents surfaces touched in this pass:
- `Cmd+F: Focus search`
- `Escape: Clear selection/close`
- `VoiceOver labels on all controls` **for the changed Agents screens in scope**
- `Keyboard navigation` **for the changed Agents tables and selection flows in scope**

## Still requires manual QA / broader app audit
These should not be marked globally complete without manual validation across the full app:
- Dynamic Type support
- Sufficient color contrast
- Focus indicators
- App-wide VoiceOver coverage outside the changed Agents screens
- App-wide keyboard navigation outside the changed Agents screens

## Notes
- This pass intentionally focused on concrete high-value polish in the active Agents workstream rather than claiming whole-app accessibility completion.
- macOS system-native controls (segmented pickers, tables, menus, searchable fields) now have stronger labels/hints, but contrast and focus-ring behavior still require interactive QA in the running app.
