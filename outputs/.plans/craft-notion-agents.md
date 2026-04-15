# Research Plan: craft and notion agents feature implementation for Keg

## Assumption
Research target is Keg's existing Agents area. Goal: identify highest-value features from Craft Agents and Notion Agents, verify them against public evidence, map them onto Keg's current architecture, and produce implementation-ready recommendations with at least one concrete feature tranche suitable for immediate build-out.

## Questions
1. What user-facing capabilities does Craft Agents expose today across sessions, sources, skills, permissions, automations, background work, remote execution, and workspace UX?
2. What user-facing capabilities does Notion Agents expose today across personal agents, custom agents, triggers, schedules, enterprise controls, context sources, connected tools, and auditability?
3. Which features overlap between Craft and Notion, and which differentiated patterns matter most for Keg?
4. Which features are already present in Keg, partially present, stubbed, or missing entirely?
5. Which candidate features fit Keg's current SwiftUI + Managed Agents architecture with lowest implementation risk and highest product leverage?
6. What security, permissions, admin, provenance, and reversibility patterns should Keg adopt before copying automation or autonomous-edit features?
7. What phased implementation plan should Keg follow: immediate tranche, medium-term tranche, and deferred / out-of-scope items?

## Strategy
- Round 1: parallel product/feature capture
  - Craft Agents public site + OSS README/docs + architecture notes
  - Notion Agents product/help/admin docs + pricing/permissions/triggers details
  - Keg codebase gap analysis against current Agents implementation
- Round 2: synthesis and contradiction resolution
  - normalize both products into one feature matrix
  - validate critical claims with second-source reads
  - derive Keg implementation recommendations and sequencing
- Expected rounds: 2

## Researcher allocations and dimensions
- T1: Craft Agents feature inventory and operational model
- T2: Notion Agents feature inventory and enterprise/admin model
- T3: Keg baseline implementation audit and gap map
- T4: Cross-product synthesis into implementation priorities, risks, and phased architecture recommendations

## Evidence Types
- Product pages and marketing copy for current positioning
- Help docs / FAQs / admin docs for exact behavior and constraints
- OSS code/docs for Craft where behavior is implementation-visible
- Keg source files, changelog, and current UI surface
- Release notes or public change logs only if needed to resolve contradictions or recency questions

## Source priorities and time bounds
- Prioritize 2025-2026 sources for current feature sets
- For Craft, prefer official OSS README/docs plus first-party site demos
- For Notion, prefer official product page + help docs + admin docs
- Use third-party commentary only for triangulation, never as sole support for critical findings

## Acceptance Criteria
- [x] All key questions answered with >=2 independent sources for critical claims
- [x] Craft and Notion feature inventories normalized into one comparable matrix
- [x] Keg current-state audit grounded in actual source files, not assumptions
- [x] At least one immediate implementation tranche identified with concrete file-level touchpoints
- [x] Contradictions or ambiguity called out explicitly
- [x] No critical recommendation depends on a single unverifiable marketing claim

## Task Ledger
| ID | Owner | Task | Status | Output |
|---|---|---|---|---|
| T1 | researcher | Extract Craft Agents capabilities, workflows, permissions, sources, automations, server/client model, and UX patterns | done | outputs/craft-notion-agents-research-craft.md |
| T2 | researcher | Extract Notion Agents capabilities, triggers, enterprise controls, permissions, integrations, and reversibility model | done | outputs/craft-notion-agents-research-notion.md |
| T3 | researcher | Audit Keg current Agents implementation and identify present / partial / missing surfaces relevant to Craft and Notion features | done | outputs/craft-notion-agents-research-keg.md |
| T4 | lead / researcher | Build unified feature matrix, implementation priorities, risk notes, and phased recommendation set | done | outputs/craft-notion-agents-research-synthesis.md |

## Verification Log
| Item | Method | Status | Evidence |
|---|---|---|---|
| Craft supports MCP + REST + local file sources | first-party docs + OSS README cross-read | verified | outputs/craft-notion-agents-research-craft.md; https://agents.craft.do/ ; https://github.com/lukilabs/craft-agents-oss/blob/main/README.md |
| Craft supports automations and background / long-running work | docs cross-read | verified | outputs/craft-notion-agents-research-craft.md; https://agents.craft.do/docs/automations/overview.md ; https://agents.craft.do/docs/server/headless.md |
| Notion distinguishes personal agent vs custom agents | product page + help docs | verified | outputs/craft-notion-agents-research-notion.md; https://www.notion.com/product/agents ; https://www.notion.com/help/custom-agents |
| Notion custom agents support triggers / schedules / connected tools | product page + help docs | verified | outputs/craft-notion-agents-research-notion.md; https://www.notion.com/help/custom-agents ; https://www.notion.com/help/mcp-connections-for-custom-agents |
| Notion provides audit trails, permissions, and reversible changes | product page + admin/help docs | verified | outputs/craft-notion-agents-research-notion.md; https://www.notion.com/product/agents ; https://www.notion.com/help/custom-agents-sharing-and-permissions |
| Keg already has agent CRUD, sessions, account auth, skills, and sources surfaces | direct file read + changelog | verified | outputs/craft-notion-agents-research-keg.md; CHANGELOG.md + Sources/Keg/Agents + Sources/Keg/Views/Agents |
| Immediate implementation tranche is feasible within current Keg architecture | code audit + architecture reasoning | verified | outputs/craft-notion-agents-research-synthesis.md |

## Decision Log
- Initial assumption: implementation target is Keg's Agents area, not a separate product.
- Initial likely highest-value clusters to test: source onboarding, automations / background tasks, permission modes, audit / provenance, multi-session workflow, and enterprise-safe controls.
- Plan to stop after round 2 unless key feature claims remain single-sourced or Keg feasibility remains unclear.
- Round 1 complete: feature inventories and Keg audit written to dedicated research files.
- Round 2 complete: unified synthesis shows best next move is finishing Sources + Skills, then adding permission modes and run history before automations.
- Resolved strategy choice: copy Craft's UX patterns and Notion's governance patterns, not their entire product surfaces.
