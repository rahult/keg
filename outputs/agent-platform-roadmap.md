# Agent Platform Roadmap

## Context

Keg already has: Agents CRUD, Sessions, Skills, Sources, MCP client, menu bar, and macOS automation prototypes (live context, approval inbox). Next phase: connect to real SaaS tools, support local models, and adopt Craft Agents UX patterns.

## Research Base

- `outputs/agent-platform-spec.md` — full spec with architecture diagrams
- `outputs/macos-automation-agent-experience.md` — macOS automation patterns research
- `outputs/macos-agent-use-case-approach.md` — product approach
- Craft Agents OSS: `github.com/lukilabs/craft-agents-oss` (Apache 2.0)
- Supaglue: `github.com/supaglue-labs/supaglue` (MIT, self-hostable SaaS integrations)
- MCP spec: `modelcontextprotocol.io` + Python SDK on GitHub
- Gemma 4 MLX benchmarks: `sudoall.com/gemma-4-31b-apple-silicon-local-guide`

## Key Decisions Made

### Integration Platform → Supaglue (not build-in-house)
Self-hosted, MIT license, 30+ connectors, OAuth/token management built-in. Keg agent talks to local Supaglue instance over HTTP. Covers Google Calendar, Gmail, Notion, Linear (roadmap), Slack, HubSpot, Salesforce.

### Local Models → llama.cpp server mode (not raw MLX Swift)
llama.cpp supports MMURGEKA / Q4_K_M quantization, stdio and HTTP server modes, and broad model format support. Wrap in a `LocalModelBridge` actor. MLX is faster but requires Python bridge; llama.cpp is pure C and simpler to integrate.

Default local model: **Gemma 4 3B** (~6GB, ~150 tok/s on M3). Upgrade path: Gemma 4 7B for reasoning tasks.

### UX Patterns → Craft Agents inspiration
Inbox-first, not chat-first. Status workflow (Todo → In Progress → Needs Review → Done). @mentions for tools. Skills as first-class managed resources. Permission modes (Explore / Ask / Auto).

## Tranches

### Tranche A — Supaglue Integration
| Task | File | Notes |
|---|---|---|
| Add Supaglue to docker-compose | `docker-compose.yml` | api + postgres services |
| SupaglueClient actor | `Sources/Keg/Integrations/SupaglueClient.swift` | HTTP calls to localhost:3000 |
| Calendar tool | `Sources/Keg/Integrations/Tools/SupaglueTools.swift` | create_event, list_events |
| OAuth connection UI | `Sources/Keg/Views/Settings/IntegrationSettingsView.swift` | connect per provider |
| Register tools in HybridAgentRunner | `Sources/Keg/Agent/HybridAgentRunner.swift` | |

### Tranche B — Local Model Bridge
| Task | File | Notes |
|---|---|---|
| LocalModelBridge actor | `Sources/Keg/Agent/LocalModelBridge.swift` | llama.cpp server lifecycle |
| ModelRouter | `Sources/Keg/Agent/ModelRouter.swift` | cloud vs local routing |
| Model source picker | `Sources/Keg/Views/Agents/AgentEditorView.swift` | cloud / local / auto |
| LocalModelConfig | `Sources/Keg/Agent/LocalModelConfig.swift` | model path, quantization |

### Tranche C — Craft-Style UX
| Task | File | Notes |
|---|---|---|
| Session inbox with status workflow | `Sources/Keg/Agents/Views/SessionInboxView.swift` | Todo/Active/Needs Review/Done |
| Session flagging | `Sources/Keg/Agent/SessionTypes.swift` | add isFlagged field |
| Enhance Skills with templates | `Sources/Keg/Agents/SkillTemplate.swift` | Craft-style prompt templates |
| Tool mention syntax | `Sources/Keg/Agent/SessionManager.swift` | parse @toolname in input |
| Permission mode per agent | `Sources/Keg/Views/Agents/AgentEditorView.swift` | Explore/Ask/Auto |

### Tranche D — MCP Tool Discovery
| Task | File | Notes |
|---|---|---|
| MCPServerRegistry | `Sources/Keg/Agent/MCPServerRegistry.swift` | tool discovery from /tools endpoint |
| Enhance MCPClient | `Sources/Keg/Agent/MCPClient.swift` | registry + import Craft config |
| MCP server management UI | `Sources/Keg/Views/Agents/MCPServerConfigSheet.swift` | add/edit/remove servers |
| Tool picker with browsing | `Sources/Keg/Views/Agents/ToolPickerSheet.swift` | browse MCP tool registry |

## Verification

Each tranche:
1. Add unit tests for new actors/services
2. Run `swift build` + `swift test`
3. Manual QA: create agent → connect tool → run session → verify tool call

Final:
- Supaglue health check in Settings
- Local model benchmark (tokens/second on target hardware)
- MCP tool discovery demo: "connect to Linear" → agent auto-configures OAuth

## Out of Scope (this phase)

- LoRA fine-tuning of local models
- Self-hosted Supaglue in production (Docker compose dev setup only)
- Windows/Linux support
- Claude Code integration (separate project)
- App Intents / Shortcuts Siri integration (wait for macOS 26+ APIs)
