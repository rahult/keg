# Craft Agents Research

## Scope
Current Craft Agents product and OSS docs: feature surface, execution model, permissions, sources, skills, automations, remote/headless deployment, and implementation patterns relevant to Keg.

## Key Findings

### 1. Craft is built around a multi-session, workspace-scoped desktop agent UI
- Craft positions itself as an "open source desktop app for working with AI agents" with a document-centric, multitasking workflow rather than a terminal-first workflow.[1][2]
- Sessions are persistent, live in a multi-session inbox, carry workflow state, and can be shared as durable artifacts.[1][2]
- Workspaces are first-class isolation boundaries: each workspace has its own sources, skills, sessions, statuses, automations, and themes.[2][3]

### 2. Source connectivity is broader and more operationalized than Keg today
- Craft has three explicit source classes: MCP servers, REST APIs, and local folders/filesystems.[1][2][3]
- Source folders are concrete persisted entities with `config.json`, optional `guide.md`, optional `permissions.json`, and optional icons.[3]
- The agent can create and configure sources conversationally, including importing MCP config JSON, guiding OAuth/API-key setup, and configuring custom APIs from docs/specs/screenshots.[1][2]
- Sources are provider-agnostic: they work across Anthropic, OpenAI/Codex, Gemini, Copilot, and custom endpoints.[3]

### 3. Permissioning is a major product primitive, not only a runtime safety check
- Craft has three user-visible permission modes: Explore, Ask to Edit, Execute.[2][4]
- Explore is read-only by default, Ask to Edit prompts, Execute auto-runs trusted work.[2][4]
- Permission configuration is layered: global → workspace → source. Explore mode can be selectively extended with allowlisted bash patterns, MCP patterns, API endpoints, and write paths via JSON config.[4]
- Source-specific permissions allow partial autonomy without enabling global auto-execution.[3][4]

### 4. Skills are lightweight, interoperable, and tightly linked to sources
- Skills are folder-based `SKILL.md` artifacts following the open Agent Skills format and compatible with Claude Code–style skill semantics.[2][5]
- Skills can auto-trigger via globs, request always-allow rules, and declare `requiredSources` so source activation happens automatically when a skill runs.[5]
- Craft emphasizes agent-authored skill creation and editing rather than a heavy GUI abstraction.[2][5]

### 5. Automations are unusually strong and likely one of Craft's biggest differentiators
- Craft exposes event-driven automations configured per workspace in `automations.json`; changes take effect immediately without restart.[6]
- Automations support both command actions and prompt actions, allowing session creation from events or cron-like schedules.[6]
- Trigger surface is broad: app events (labels, flags, status changes, permission mode changes, scheduler ticks) and agent events (tool use, session start/end, subagent lifecycle, notification, compaction hooks, permission requests).[6]
- The UI can enable/disable/test automations, show execution history, and preserve a recent run log in JSONL history.[6]
- Craft explicitly treats automations as agent-configurable through natural language, not only manual JSON editing.[6]

### 6. Craft treats long-running and remote execution as first-class
- Product copy repeatedly emphasizes background tasks and long-running work.[1][2]
- Craft can run as a headless remote server with desktop, browser, and CLI clients against the same session/workspace backend.[2][7]
- Remote mode supports hybrid desktop + remote workspaces, thin client mode, browser login, Docker deployment, TLS/reverse proxy/Tailscale guidance, and startup management.[7]

### 7. Craft product pattern: agent-native configuration, not many setup wizards
- Many features are designed to be configured via natural language requests to the agent itself: adding sources, creating skills, changing permissions, setting up automations.[1][2][5][6]
- This implies an architecture where config files are stable, inspectable artifacts and the agent is trusted to edit them.

## Implementation-Relevant Patterns

### Pattern A: Persisted workspace artifacts
Craft stores durable configuration as files under `~/.craft-agent/workspaces/{id}/...` for sources, skills, statuses, and automations.[2][3][5][6]

**Keg relevance:** Strong fit. Keg already has local storage primitives for skills and sources. Extending from ad hoc JSON blobs to a richer workspace artifact model is feasible.

### Pattern B: Event-driven automation over session lifecycle
Craft's automation system triggers on agent/session/tool events and can spawn new sessions or shell commands.[6]

**Keg relevance:** High-value but higher-risk. Keg already has sessions and local UI state; adding event hooks + prompt scheduling could create a strong differentiator if paired with auditability.

### Pattern C: Layered permissions with source-scoped capability grants
Craft does not use only one global safety toggle; it layers app/workspace/source rules.[4]

**Keg relevance:** Strong. Keg currently has no visible permission-mode system for agents. Adopting this would improve trust before adding automations or broad source actions.

### Pattern D: Remote/headless execution + thin clients
Craft's remote server allows long-lived sessions and multi-client access.[7]

**Keg relevance:** Strategic, but likely medium-term. This is architecture-heavy and should follow a local-first feature tranche.

## What Looks Most Important to Copy
1. **Permission modes with visible state** — immediate trust layer.[4]
2. **Real source management with persisted/tested source configs** — Keg has UI shell but not full implementation.[3]
3. **Workspace-scoped skills + source auto-activation** — Keg has partial local skills but no runtime integration.[5]
4. **Automation system tied to session and schedule events** — high leverage once permission/audit foundations exist.[6]
5. **Multi-session workflow / status-driven inbox** — important but Keg already has partial navigation shells.[1][2]

## Risks / Caveats
- Some Craft claims come from first-party docs/README and may overstate polish relative to current OSS behavior. Treat remote/browser/automation breadth as documented capabilities, but re-verify implementation details if Keg copies them closely.[2][6][7]
- Craft's agent-native config editing assumes stable file schemas and strong local file access. Keg's Managed Agents model may require a different execution boundary.

## Evidence Table
| Claim | Evidence | Notes |
|---|---|---|
| Craft supports MCP, REST, and local files as source types | [1], [2], [3] | Repeated across homepage, intro docs, and sources docs |
| Craft uses visible permission modes Explore / Ask to Edit / Execute | [2], [4] | Appears in intro and permissions docs |
| Craft has workspace-scoped automations with event + cron triggers | [2], [6] | README + automation docs |
| Craft supports background tasks / long-running work | [1], [2], [7] | Product copy + remote server model |
| Craft supports remote headless server + desktop/browser/CLI clients | [2], [7] | README + headless docs |
| Skills can declare required sources and live as SKILL.md folders | [2], [5] | README + skills docs |

## Sources
1. Craft Agents homepage, https://agents.craft.do/
2. Craft Agents OSS README, https://github.com/lukilabs/craft-agents-oss/blob/main/README.md
3. Craft Agents docs — Sources overview, https://agents.craft.do/docs/sources/overview.md
4. Craft Agents docs — Permissions, https://agents.craft.do/docs/core-concepts/permissions.md
5. Craft Agents docs — Skills overview, https://agents.craft.do/docs/skills/overview.md
6. Craft Agents docs — Automations overview, https://agents.craft.do/docs/automations/overview.md
7. Craft Agents docs — Remote Server, https://agents.craft.do/docs/server/headless.md
