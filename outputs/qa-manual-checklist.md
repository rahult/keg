# Manual QA Checklist

Date: 2026-04-16

Use this after `make qa` passes.

## Build / launch
- [ ] `make open` launches app
- [ ] sidebar renders
- [ ] toolbar sidebar toggle works
- [ ] switching between Keg and Agents works
- [ ] `Cmd+1` / `Cmd+2` switch areas
- [ ] View-menu navigation items land on the expected surfaces

## Agents core flows
### Dashboard / onboarding
- [ ] dashboard refresh works
- [ ] dashboard "Browse Use Cases" opens the use-case library
- [ ] use-case library renders cards and explanatory content
- [ ] creating an agent from a use case opens the create sheet with seeded content
- [ ] "Blank Agent" opens the create sheet without a preset use case
- [ ] returning from use cases to Manage Agents works

### Agents
- [ ] create agent
- [ ] edit agent opens the dedicated editor sheet
- [ ] duplicate selected agent
- [ ] archive selected agent
- [ ] `Cmd+F` focuses agent search
- [ ] `Escape` clears agent selection/search
- [ ] `Cmd+Delete` archives selected agent

### Sessions
- [ ] sessions load
- [ ] date filters: Today / This Week / This Month / All Time
- [ ] workflow filter works
- [ ] flagged filter works
- [ ] session inspector opens
- [ ] selected session deletes via context menu
- [ ] `Cmd+Delete` deletes selected session

### Sources
- [ ] add MCP source
- [ ] add REST source
- [ ] add file source
- [ ] enabled toggle persists
- [ ] enabled save tests connection before persist
- [ ] invalid source config shows validation feedback
- [ ] disabled source save leaves status disconnected
- [ ] delete selected source with keyboard

### Skills
- [ ] create skill
- [ ] import skill
- [ ] export skill
- [ ] duplicate skill
- [ ] delete selected skill with keyboard

### Account / auth / resilience
- [ ] missing API key routes to Account
- [ ] auth error surfaces Open Account action
- [ ] timeout/offline error surfaces Retry action
- [ ] unavailable state appears when remote service unreachable

## Keg shell flows
- [ ] container delete requires confirmation
- [ ] image delete requires confirmation
- [ ] `Cmd+F` focuses Keg search on container/image lists
- [ ] `Escape` clears Keg selection/search on container/image lists
- [ ] running build can be cancelled from Builds view

## Accessibility / keyboard
- [ ] keyboard-only navigation across Agents area
- [ ] VoiceOver labels read clearly on changed screens
- [ ] focus ring visible on actionable controls
- [ ] contrast acceptable in light and dark mode
- [ ] Dynamic Type / larger text does not clip critical controls

## Notes
- Host machine:
- macOS version:
- container system state:
- Anthropic API available:
- Failures / regressions:
