# QA Automation Strategy

Date: 2026-04-15

## Goal
Automate as much Keg QA as possible without pretending remote CI can fully exercise a macOS 26 + Apple Containerization app.

## Constraints
- Keg targets macOS 26+ only.
- Container-backed flows need local Apple `container` runtime.
- Managed Agents integration needs a real Anthropic API key.
- Accessibility and visual polish still need running-app QA.

## Strategy
Use a layered local-first QA pipeline with safe defaults and opt-in live suites.

### Layer 1 — always-on fast checks
Run on every change and before every push:
- `swift build`
- `swift test`

This must stay safe on any contributor machine. Live tests should skip unless explicitly enabled.

### Layer 2 — opt-in live integration suites
Only run when developer has required dependencies:
- Managed Agents API integration
  - enable with `KEG_RUN_MANAGED_AGENTS=1`
  - requires `ANTHROPIC_API_KEY`
- Container runtime E2E
  - enable with `KEG_RUN_CONTAINER_E2E=1`
  - requires working local `container` system

### Layer 3 — release/build smoke
Optional bundle validation:
- `KEG_QA_BUILD_APP=1 ./Scripts/qa.sh`
- verifies `.app` bundle assembly via `make app`

### Layer 4 — manual QA checklist backed by artifacts
Keep manual checks narrow and explicit:
- accessibility pass
- contrast/focus ring review
- VoiceOver pass
- keyboard-only navigation pass
- critical user flows: agent CRUD, sessions, sources, skills, account/auth

Manual QA should produce short checked-in notes, not vague claims.

## Implemented now
- `Scripts/qa.sh`
  - writes logs to `outputs/qa/latest`
  - runs build + tests by default
  - runs live suites only when env flags are set
- `make qa`
- `make qa-agents`
- `make qa-live`
- `outputs/qa-manual-checklist.md`
  - manual follow-up template for accessibility, keyboard, and critical Agents flows
- test suites now skip safely unless explicitly enabled:
  - `KegE2ETests`
  - `ManagedAgentsIntegrationTests`
- new unit coverage for:
  - `AgentIssuePresentation`
  - `SessionListVM` date/flag filters

## Recommended workflow
### Normal dev loop
```bash
make qa
```

### Agents API verification
```bash
ANTHROPIC_API_KEY=... make qa-agents
```

### Full live local sweep
```bash
ANTHROPIC_API_KEY=... KEG_RUN_CONTAINER_E2E=1 make qa-live
```

### Bundle smoke
```bash
KEG_QA_BUILD_APP=1 make qa
```

## Next implementation steps
1. Add more unit tests for form validation logic once that logic is extracted from SwiftUI views.
2. Add smoke tests around source editor validation and session delete flow.
3. When macOS 26 runners are practical, add hosted CI for Layer 1 only.
4. If app UI testability matters more, split more stateful logic from SwiftUI views into testable view models.

## Non-goals
- fake cross-platform CI that claims to verify macOS-only runtime behavior
- brittle screenshot automation before stable test seams exist
- network-heavy tests in default `swift test`
