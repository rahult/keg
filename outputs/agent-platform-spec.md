# Keg Agent Platform: Spec + Roadmap

## Vision

A local-first, Mac-native agent platform that runs **alongside** the user's desktop — not inside a browser tab. The agent has live desktop context, connects to real SaaS tools via integrations, can route between cloud and local models, and surfaces everything through Mac-native UI patterns: menu bar, Finder, Shortcuts, notifications, and session management.

Core principle: **agent-native software** — the agent figures out how to connect to tools by being told what you want, not by configuring JSON files.

---

## What We're Building

```
┌─────────────────────────────────────────────────────────────┐
│  Keg (this repo)                                          │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │ Agents UI   │  │ MCP Client │  │ Integration Bus │  │
│  │ (SwiftUI)   │  │ (existing)│  │                 │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
│         │                │                   │              │
│         ▼                ▼                   ▼              │
│  ┌─────────────────────────────────────────────────┐    │
│  │  Agent Runtime (HybridAgentRunner)                │    │
│  │  • Cloud model: Anthropic via MCP                │    │
│  │  • Local model: MLX / llama.cpp bridge         │    │
│  └─────────────────────────────────────────────────┘    │
│         │                           │                      │
│         ▼                           ▼                      │
│  ┌──────────────┐        ┌──────────────────────────┐   │
│  │ macOS Surface │        │ Integration Layer         │   │
│  │ • Menu Bar    │        │ • Supaglue (SaaS APIs)  │   │
│  │ • Finder      │        │ • MCP servers (native)   │   │
│  │ • Shortcuts   │        │ • AppleScript / osascript│   │
│  │ • Notifs      │        │ • Local model runner     │   │
│  └──────────────┘        └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 1. Integration Platform: Supaglue

### What it is
Open-source (MIT), self-hostable platform for user-facing SaaS integrations. Two main patterns:
- **Managed Syncs**: continuous data sync from SaaS tools into your DB/data warehouse
- **Actions API**: unified REST API to read/write multiple SaaS providers with a single interface

### Why Supaglue
- Already covers Google Calendar, Gmail, Notion, Linear (roadmap), HubSpot, Salesforce, Slack, Intercom, and 30+ others
- Supaglue handles OAuth flows, token refresh, rate limits, and response normalization
- Docker compose deploy, MIT license, 5-minute quickstart
- Keg agent talks to Supaglue Actions API — not to each SaaS API directly
- Self-hosted = data stays local = aligns with local-first agent principle

### What Keg agent gets from Supaglue
| Integration | Agent Use Case |
|---|---|
| Google Calendar | Read/write events, meeting prep, scheduling |
| Gmail | Email triage, draft replies, follow-up reminders |
| Notion | Read/write pages, project notes |
| Linear | Issues, projects, sprint planning |
| Slack | Channel messages, notifications |
| HubSpot/Salesforce | CRM context for sales agents |

### Architecture
```
Keg Agent
  └── Supaglue Actions API (local HTTP)
        ├── Google Calendar provider
        ├── Gmail provider
        ├── Notion provider
        └── ...
```
Run Supaglue via Docker compose alongside Keg. Keg agent makes unified API calls to `http://localhost:3000/v1/actions`.

### Implementation path
1. Add Supaglue to docker-compose in Keg (api + Postgres)
2. Add `SupaglueClient` actor: wraps HTTP calls to local Supaglue instance
3. Add tools: `supaglue_calendar_create_event`, `supaglue_email_send`, `supaglue_notion_page_create`, etc.
4. Register tools in `HybridAgentRunner`
5. Add OAuth connection UI for each provider in Settings

### Key files to create/modify
- `Sources/Keg/Integrations/SupaglueClient.swift`
- `Sources/Keg/Integrations/Tools/SupaglueTools.swift`
- `docker-compose.yml` (add Supaglue service)
- `Sources/Keg/Views/Settings/IntegrationSettingsView.swift`

---

## 2. Model Routing: Cloud vs Local

### What it is
Agents can run on either:
- **Cloud**: Anthropic models via existing MCP/Anthropic API client
- **Local**: LLMs running on Apple Silicon via MLX or llama.cpp

### Why both matter
- Local models: privacy-sensitive tasks (reading local files, calendar, email drafts) stay on-device
- Cloud models: reasoning-heavy tasks (planning, complex code, multi-step agents) use frontier models
- User preference per agent, per session, or per task
- Local inference is free and fast on Apple Silicon for 3B-7B parameter models

### Local model options (Apple Silicon)

| Model | Size | MLX Speed | Memory | Best For |
|---|---|---|---|---|
| Gemma 4 3B | 3B | ~150 tok/s | ~6GB | Fast classification, summarization |
| Gemma 4 7B | 7B | ~80 tok/s | ~14GB | Coding assistant, reasoning |
| Llama 4 Scout | 17B | ~40 tok/s | ~34GB | Complex agentic tasks |
| Mistral Small 3B | 3B | ~180 tok/s | ~6GB | Lightweight local inference |
| Qwen 3 4B | 4B | ~120 tok/s | ~8GB | Code + multilingual |

### Architecture
```
Agent Runtime
  ├── Cloud Bridge → Anthropic API (existing)
  └── Local Bridge → llama.cpp / MLX server
        ├── llama.cpp HTTP server (stdio or HTTP)
        └── MLX via Swift <-> Python bridge OR llama.cpp server mode
```

### Implementation path
1. Add `LocalModelBridge` actor: manages llama.cpp server lifecycle
2. Configure via `Sources/Keg/Agent/LocalModelConfig.swift`
3. Add model selection to agent editor (cloud / local / auto)
4. Auto-routing: sensitive data → local model; complex tasks → cloud model
5. Prompt template adaptation per model family

### Key files to create/modify
- `Sources/Keg/Agent/LocalModelBridge.swift`
- `Sources/Keg/Agent/ModelRouter.swift`
- `Sources/Keg/Views/Agents/AgentEditorView.swift` (add model source picker)

---

## 3. Agent UX: Craft Agents-Inspired Patterns

### What Craft Agents does differently
From the Craft Agents OSS codebase and product:

1. **Natural language tool connection** — "add Linear as a source" → agent reads Linear API docs, sets up OAuth, configures credentials. No config files.
2. **Session inbox with status workflow** — Todo → In Progress → Needs Review → Done
3. **Permission modes** — Explore (read-only), Ask to Edit (confirm changes), Auto (trusted autonomous)
4. **Sources vs Skills** — Sources = tool connections; Skills = system prompts
5. **Automations** — event-driven: run session on label change, schedule, or tool use
6. **Multi-file diff** — VS Code-style window showing all file changes in one turn
7. **Background tasks** — long-running ops with progress tracking

### Which patterns to adopt in Keg

| Craft Pattern | Keg Adoption | Priority |
|---|---|---|
| Session inbox with status workflow | Existing Sessions list already has status; add flagging + custom workflow states | High |
| Permission modes (Explore/Ask/Auto) | AgentPermissionMode already in AppState (Explore/Ask/Execute) | High |
| Natural language tool setup | Tool discovery via MCP + Supaglue Actions API; agent suggests tools based on task | Medium |
| Sources (tool connections) | Sources list already in Agents area; connect to Supaglue and MCP | High |
| Skills (system prompts) | Skills list already exists; enhance with Craft-style prompt templates | High |
| Automations (event-driven sessions) | Future: trigger sessions on file changes, schedules, notifications | Low |
| Multi-file diff viewer | Session detail view shows tool results; add unified diff panel | Medium |
| Background tasks with progress | Existing session streaming; enhance with structured progress | Medium |

### What makes Craft-style UX different from generic chat
- **Inbox first, not chat first** — sessions organized by status, not chronological chat
- **@mentions for tools** — `@linear create issue` inline in conversation
- **Skills are first-class** — not just a text field, but a managed resource with versioning and testing
- **Status is a first-class concept** — not just "running" vs "done" but a workflow state machine
- **Permission is a slider, not a binary** — Explore / Ask / Auto maps cleanly to the trust spectrum

### Key files to create/modify
- `Sources/Keg/Agents/Views/SessionInboxView.swift` (status workflow, flagging)
- `Sources/Keg/Agent/SkillTemplate.swift` (Craft-style skill templates)
- `Sources/Keg/Views/Agents/AgentEditorView.swift` (permission mode, model source)
- `Sources/Keg/Views/Agents/SessionDetailView.swift` (multi-file diff panel)

---

## 4. MCP Tool Discovery

### What MCP is
Model Context Protocol — stdio/HTTP-based protocol for exposing tools to LLM agents. Agents discover and use tools via a standardized interface. Anysphere (Claude Desktop) pioneered it; now an open spec.

### Why it matters for Keg
- MCP servers are the native way to extend Claude/Anthropic agents
- Craft Agents shows: agents can self-configure MCP connections by being told what to do
- Keg already has an MCP client — the gap is **tool discovery** and **server management**

### Architecture
```
Keg MCP Client (existing)
  └── Tool Registry
        ├── Supaglue Actions (HTTP MCP bridge)
        ├── Native macOS tools (Finder, Calendar, Notes — via osascript)
        └── User-installed MCP servers (stdio or HTTP)
```

### Tool discovery patterns
1. **MCP server registry** — user adds server URL or path; Keg inspects `/tools` endpoint
2. **Auto-discovery from Craft Agents** — import existing `claude_desktop_config.json`
3. **Agent-suggested tools** — when agent sees missing capability, it suggests adding a source

### Implementation path
1. Enhance existing `MCPClient.swift` with tool registry inspection
2. Add MCP server management UI (server URL, auth, enabled/disabled tools)
3. Add `/tools` endpoint discovery for stdio servers
4. Add `mcp_server` type to agent's tool list (existing `MCPServer` type already in codebase)
5. Support importing from Craft Agents config: parse `~/.claude/descriptors/`

### Key files to create/modify
- `Sources/Keg/Agent/MCPClient.swift` (enhance)
- `Sources/Keg/Agent/MCPServerRegistry.swift` (new)
- `Sources/Keg/Views/Agents/MCPServerConfigSheet.swift` (enhance)
- `Sources/Keg/Views/Agents/ToolPickerSheet.swift` (add MCP tool browsing)

---

## Roadmap

### Phase 1: Foundation (1-2 weeks)
**Goal**: Agent can route to cloud or local model, and has Supaglue integration.

- [ ] Supaglue Docker compose setup alongside Keg
- [ ] `SupaglueClient` actor with calendar, email, notion actions
- [ ] Local model bridge with llama.cpp server management
- [ ] Model source picker in agent editor (cloud / local / auto)
- [ ] `LocalModelConfig` and `ModelRouter`

### Phase 2: Integration Surface (2-3 weeks)
**Goal**: Agent connects to real SaaS tools; MCP tool discovery works.

- [ ] Supaglue OAuth connection UI in Settings
- [ ] MCP server registry with tool browsing
- [ ] Import Craft Agents / Claude Desktop MCP config
- [ ] Agent suggests tool connections based on task context
- [ ] Connect Sources list to Supaglue + MCP unified tool registry

### Phase 3: Craft-Style UX (2-3 weeks)
**Goal**: Session inbox with status workflow, permission modes, skill templates.

- [ ] Session inbox view with Todo / In Progress / Needs Review / Done states
- [ ] Session flagging and bulk actions
- [ ] Enhance Skills with Craft-style templates and versioning
- [ ] Permission mode picker (Explore / Ask / Auto) per agent
- [ ] Tool mention syntax in session input (`@linear create issue`)

### Phase 4: Automation + Polish (2-4 weeks)
**Goal**: Event-driven sessions, multi-file diff, local model fine-tuning hooks.

- [ ] Automations: trigger sessions from file changes, schedules
- [ ] Multi-file diff panel in session detail
- [ ] Background task progress tracking
- [ ] Local model fine-tuning or LoRA hooks for custom agent personas
- [ ] Accessibility QA, performance tuning

---

## Open Questions

1. **Local model size on Apple Silicon** — Gemma 4 7B fits in 32GB M3 Pro; 3B fits everywhere. Start with 3B as default local model?
2. **Supaglue managed vs self-hosted** — self-hosted is MIT and private. But OAuth flow UX needs careful design for user-facing connection UI.
3. **MCP server security** — stdio servers run as child processes. Need sandboxing story for untrusted third-party MCP servers.
4. **Model routing policy** — auto-route sensitive tasks to local; keep cloud for reasoning. What counts as "sensitive"? (email drafts → local; complex planning → cloud)
5. **Craft Agents import scope** — import just MCP servers, or also skills and permission modes? Partial import makes sense.
