# Changelog

## [Unreleased]

### Research
- **Craft + Notion Agents analysis for Keg**: completed a two-round research sweep comparing Craft Agents and Notion Agents against Keg's current Agents area.
  - Verified strongest overlap: sources, skills, permission modes, session workflow metadata, automations, and auditability
  - Verified Keg already has usable account/auth, agent CRUD, session list/detail, and local storage primitives for skills/sources
  - Identified biggest gaps: skills/sources persistence wiring, source testing/runtime activation, permission modes, run history, and automation triggers
  - Recommended immediate tranche: finish Sources + Skills, then add permission modes and run logs before any automation or shared/autonomous agent layer
  - Follow-up extension added Open Agents as third comparison target; reinforced long-term recommendation to separate workflow orchestration from execution substrate if Keg later adopts remote/headless agent runs

### Added
- **Agent Area Foundation**: Initial Managed Agents API implementation for Keg
  - Core types: Agent, AgentEnvironment, Session, SessionEvent
  - Agent tools: Toolset, Custom tools, Built-in tools (bash, read, write, edit, glob, grep, web_fetch, web_search)
  - MCP server support
  - Skills configuration
  - Full CRUD API client with proper authentication headers
  - 34 spec tests with 100% coverage

### Files Added
- `Sources/Keg/Agent/Types.swift` - Agent and tool types
- `Sources/Keg/Agent/EnvironmentTypes.swift` - Environment configuration
- `Sources/Keg/Agent/SessionTypes.swift` - Session and event types
- `Sources/Keg/Agent/ManagedAgentsClient.swift` - API client
- `Tests/KegTests/ManagedAgentsSpec.swift` - API specification tests

## Research: Integration Platforms at Scale (2026-04-15)

### Research Completed
- **Topic**: How to enable integrations at scale like Nango.dev
- **Sources**: 6 primary sources verified
- **Output**: `outputs/integration-platforms-at-scale.md`

### Key Findings
- Nango: 700+ APIs, auth abstraction + TypeScript functions [1]
- Supaglue: Best OSS alternative for B2B SaaS (Apache 2.0) [2]
- Airbyte: 300+ connectors for data pipelines [3]
- Self-hosted costs: $80-400/month vs managed $0-1000+/month
