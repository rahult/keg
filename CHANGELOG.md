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
