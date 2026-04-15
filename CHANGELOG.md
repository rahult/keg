# Changelog

## [Unreleased]

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
