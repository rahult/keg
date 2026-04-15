# Research Plan: how to leverage macos automation to provide unique agent experience

Focus refinement: product-focused study centered on building distinctive agent experiences on macOS, not generic automation tooling.

## Questions
1. Which native macOS automation primitives matter most for agent products on macOS: Shortcuts, AppleScript/JXA, Accessibility API, UI scripting, Services, Share extensions, Quick Actions, LaunchAgents, Folder Actions, URL schemes, x-callback-url, Handoff, menu bar surfaces, notification actions, file providers, Automator legacy hooks, and Terminal/shell integrations?
2. What hard constraints shape viable product design: TCC permissions, sandboxing, notarization, App Store limits, background execution rules, accessibility consent, automation consent prompts, Apple Events restrictions, user trust, observability, and failure recovery?
3. Which existing macOS-native or Mac-first products already use automation for agent-like experiences on Mac, and what product patterns appear repeatedly or differentiate strongly?
4. Which automation patterns create uniquely good agent UX on macOS versus web-only or cross-platform agents?
5. Which patterns are robust enough for production now versus brittle, permission-heavy, or likely to break across OS/app updates?
6. What concrete product opportunities exist for an agent on macOS: proactive triggers, context capture, app control, workflow composition, local-first execution, human-in-loop review, and persistent background helpers?
7. What implementation stack would best support such experience for a modern macOS app, including where native APIs beat shell/UI scripting and where hybrid approaches are necessary?
8. What evaluation framework should decide whether a proposed automation feature is worth shipping: user value, reliability, trust cost, permission burden, maintenance cost, and defensibility?

## Strategy
- Scope: modern macOS automation for agent products on Mac, with explicit product focus: differentiated user experience, defensibility, adoption friction, and why macOS-native agents can outperform web-only or cross-platform approaches. Emphasis on 2023-2026 Apple platform behavior and current third-party product patterns. Use older sources only for stable primitives like Apple Events/Accessibility where still authoritative.
- Evidence mix:
  - Apple primary docs: Shortcuts, App Intents, Accessibility, Apple Events, LaunchServices, Services/Quick Actions, background tasks, security/TCC, sandbox/notarization docs.
  - Product docs/blogs/changelogs: Raycast, Shortcat, Keyboard Maestro, BetterTouchTool, Alfred, OpenAI desktop app, Anthropic desktop app, Apple examples, other Mac agent products if relevant.
  - Code/examples: open-source macOS automation tools, GitHub repos demonstrating Shortcuts/App Intents/AX patterns.
  - Commentary/analysis: practitioner posts on brittleness, permission friction, sandbox limits, automation reliability.
- Researcher allocations and dimensions:
  - R1: Apple-native primitives and platform constraints.
  - R2: Product landscape and differentiated UX patterns in shipping Mac tools and Mac agent apps.
  - R3: Technical implementation patterns, code examples, and reliability tradeoffs.
  - R4: Opportunity synthesis focused on agent-on-macOS design patterns, trust model, defensibility, and evaluation rubric.
  - Gap fill: official OpenAI macOS product docs + Apple QA1888 on sandbox/automation tension.
- Expected rounds:
  - Round 1: 4 parallel researchers covering disjoint dimensions.
  - Round 2: targeted lead-run gap fill for OpenAI macOS product evidence and Apple sandbox/automation guidance.

## Acceptance Criteria
- [x] All key question areas covered with multi-source evidence; remaining uncertain areas called out explicitly.
- [x] At least one primary Apple source anchors each major platform-constraint section.
- [x] Product-pattern findings draw from multiple shipping tools, not single showcase.
- [x] Production recommendations separate robust native API paths from brittle UI scripting paths.
- [x] Final recommendations identify what is uniquely compelling for an agent on macOS, not automation software in general.
- [x] Contradictions/gaps identified and addressed or carried into open questions.
- [x] No single-source claims on critical findings in plan-stage evidence ledger.
- [ ] Final brief includes concrete feature opportunities, anti-patterns, and evaluation rubric.

## Task Ledger
| ID | Owner | Task | Status | Output |
|---|---|---|---|---|
| T1 | lead / researcher | Map macOS automation primitives, permissions, sandbox/TCC constraints, and authoritative Apple docs | completed | outputs/macos-automation-agent-experience-research-apple.md |
| T2 | lead / researcher | Survey shipping Mac automation/agent products and extract differentiated UX patterns | completed | outputs/macos-automation-agent-experience-research-products.md |
| T3 | lead / researcher | Gather technical implementation examples, open-source code, and reliability tradeoffs across automation methods | completed | outputs/macos-automation-agent-experience-research-implementation.md |
| T4 | lead / researcher | Synthesize product opportunities, trust model, evaluation rubric, and feature prioritization for unique agent UX on macOS | completed | outputs/macos-automation-agent-experience-research-opportunities.md |
| T4b | lead | Gap fill: verify OpenAI macOS product features and Apple sandbox/automation guidance | completed | outputs/macos-automation-agent-experience-research-supplement.md |
| T5 | lead | Integrate findings, resolve contradictions, update verification log, and write draft brief | in_progress | outputs/.drafts/macos-automation-agent-experience-draft.md |
| T6 | verifier | Add inline citations, verify URLs, and produce cited brief | todo | outputs/macos-automation-agent-experience-brief.md |
| T7 | reviewer | Verification pass for evidence sufficiency and confidence calibration | todo | outputs/macos-automation-agent-experience-verification.md |
| T8 | lead | Publish final brief + provenance | todo | outputs/macos-automation-agent-experience.md |

## Verification Log
| Item | Method | Status | Evidence |
|---|---|---|---|
| Which macOS automation primitives are supported and current | Apple doc cross-read | complete | outputs/macos-automation-agent-experience-research-apple.md |
| Permission and sandbox constraints for app control / automation | Apple doc cross-read + QA1888 gap fill | complete | outputs/macos-automation-agent-experience-research-apple.md; outputs/macos-automation-agent-experience-research-supplement.md |
| Real-world product patterns users accept in Mac-first tools | multi-product source comparison | complete | outputs/macos-automation-agent-experience-research-products.md |
| Technical implementation options and reliability tradeoffs | code/doc cross-read | complete | outputs/macos-automation-agent-experience-research-implementation.md |
| Concrete feature opportunities and ranking rubric for agent-on-macOS product | synthesis grounded in T1-T4 | complete | outputs/macos-automation-agent-experience-research-opportunities.md |
| OpenAI macOS app as current agent-product reference point | official help/release-note cross-read | complete | outputs/macos-automation-agent-experience-research-supplement.md |
| Final critical claims in brief | claim sweep against research files | pending | outputs/.drafts/macos-automation-agent-experience-draft.md |

## Decision Log
- 2026-04-15: User refined scope toward product focus and broader "agent on macOS" framing. Plan prioritizes differentiated UX, defensibility, trust cost, and product opportunities over API cataloging alone.
- 2026-04-15: Chose 4-way first round. Topic broad enough to justify parallel coverage across platform docs, products, implementation, and synthesis.
- 2026-04-15: Slug set to `macos-automation-agent-experience` for all artifacts.
- 2026-04-15: `memory_remember` tool not available in this session; plan persisted to file artifact instead.
- 2026-04-15: Round 1 launched with four parallel researchers across Apple docs, products, implementation patterns, and opportunity synthesis.
- 2026-04-15: After round 1, biggest remaining gaps were official OpenAI macOS product evidence and stronger Apple support for sandbox/automation tradeoffs. Chose targeted lead-run gap fill instead of another full researcher batch.
- 2026-04-15: Evidence now sufficient to draft brief. Remaining uncertainty belongs in Open Questions, not another research round.
