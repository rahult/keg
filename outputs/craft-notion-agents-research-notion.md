# Notion Agents Research

## Scope
Current Notion Agents public product/help/admin documentation: personal Notion Agent, Custom Agents, skills/instructions, triggers/schedules, sharing/permissions, MCP connections, auditability, and cost/admin controls.

## Key Findings

### 1. Notion intentionally splits on-demand personal AI from autonomous team agents
- Notion distinguishes **Notion Agent** (personal, on-demand assistant) from **Custom Agents** (shared, autonomous agents that run in the background via triggers and schedules).[1][2][3]
- Product positioning emphasizes that the personal agent inherits your own permissions, while Custom Agents have their own permissions and can be shared with teams.[1][3]

### 2. Custom Agents are built around recurring workflows, not only chat
- Custom Agents can run on recurring schedules and on events from Notion and Slack.[2]
- Supported Notion triggers include comments added, pages added to databases, property updates, and page removal from databases.[2]
- Supported Slack triggers include posted messages, emoji reactions, thread starts, and explicit mentions.[2]
- Agents continue running in the background after publication.[1][2]

### 3. Context and integrations are explicit configuration surfaces
- Custom Agents use existing Notion pages/databases plus connected apps as context; this is configured in each agent's settings under Tools and Access.[1][2][4]
- Notion exposes dedicated integrations for Slack and supports MCP connections for external systems.[1][2][4]
- Web access is a separate toggle in agent settings, meaning internet access is a product-level policy control.[2]

### 4. Permissions are separated into agent access and user access
- Custom Agents have their **own** permissions; they do not inherit creator or triggering-user permissions.[3]
- There are two orthogonal concerns: what the agent can access, and who can access the agent.[3]
- Sharing levels are simplified but strong: `Can view and interact`, `Can edit`, `Full access`.[2][3]
- This creates a deliberate security model where users can retrieve information through an agent even if they lack direct access to the underlying page/app, provided the agent has access.[3]

### 5. Admin and governance controls are first-class product features
- Workspace admins can restrict who can create custom agents, view an Agent Directory, disable editing/chatting/triggers, and in enterprise contexts inspect audit logs, AI analytics, and content search exposure.[1][3][5]
- Ownership transfer is explicitly supported so business-critical agents do not die when employees leave.[3]
- Notion repeatedly frames safety as reviewability + reversibility: activity logs, audit logs, version history, and reversible edits.[1][2][3]

### 6. MCP is treated as a governed connection surface
- MCP connections are available to Business/Enterprise plans and can be pre-configured or custom hosted servers.[4]
- Each MCP connection is unique to a single Custom Agent and uses the credentials of the person who authenticated it; connections are not shared across agents.[4]
- Tool-level controls exist: enable/disable tools and choose `run automatically` vs `always ask`, with write tools defaulting to confirmation.[4]
- Custom MCP server enablement itself is admin-governed.[4]

### 7. Cost/usage controls matter because agents run autonomously
- Notion is moving Custom Agents to a credit model as of May 4, 2026, with usage tied to complexity, connected tools, run frequency, and model choice.[6]
- Admins and agent owners can set per-agent monthly credit limits, and agents pause automatically when limits or workspace credits are exhausted.[6]
- This is not only billing; it is also a runtime guardrail pattern for autonomous systems.[6]

### 8. Skills and instructions exist separately from autonomous agents
- Skills are saved prompts backed by pages, reusable in personal Notion Agent and also accessible to Custom Agents if the agent can access the skill page.[5]
- Instructions are persistent preferences for the personal agent, while Custom Agents have their own instructions/connections/triggers.[5]
- This separation implies a three-layer model: personal defaults, reusable skills, and autonomous agents.

## Implementation-Relevant Patterns

### Pattern A: Personal assistant vs shared autonomous agent split
Notion does not overload one entity with every behavior. Personal and custom/team agents differ in permissions, lifecycle, and automation model.[1][2][3]

**Keg relevance:** Strong. Keg already has an Account screen, agent CRUD, and sessions. It can preserve personal/manual sessions while separately introducing scheduled/shared automations later.

### Pattern B: Agent-level permissions independent from user permissions
Custom Agents have explicit access grants and explicit sharing grants.[3]

**Keg relevance:** Critical if Keg adds shared workspaces, automations, or source write-actions. Without this split, Keg risks confusing user authority with agent authority.

### Pattern C: Activity/audit/reversibility as core safety UX
Notion repeatedly couples autonomy with logs, run history, reversible changes, and admin visibility.[1][2][3]

**Keg relevance:** Very strong. Keg currently exposes sessions but not a dedicated run/audit/governance layer.

### Pattern D: Trigger + schedule abstraction with app integrations
Notion treats triggers and schedules as first-class agent configuration, not a separate scripting product.[2]

**Keg relevance:** Strong medium-term target. Keg can likely map this onto sessions plus a local scheduler and source/event hooks.

### Pattern E: Per-agent budget / quota controls
Credit limits and pause behavior function as safety and operational control, not merely billing.[6]

**Keg relevance:** If Keg adds autonomous or scheduled agents, a local analog could be run quotas, time quotas, or approval budgets.

## What Looks Most Important to Copy
1. **Strong distinction between manual/personal use and autonomous/shared agents**.[1][2][3]
2. **Agent-specific access model** for sources/pages/integrations, separate from who may invoke the agent.[3][4]
3. **Activity log + reviewable run history + reversible writes** before scaling automation.[1][2][3]
4. **Trigger/schedule UI tied to existing content/integration events**.[2]
5. **Per-agent operational guardrails** analogous to credit/run limits.[6]
6. **Skills as reusable, page-like instructions** rather than burying all behavior in one monolithic agent config.[5]

## Risks / Caveats
- Notion's help docs are highly productized; some details are plan-gated or beta-limited, so Keg should copy the pattern rather than the exact permission names.[2][3][4][6]
- Notion's security model assumes centralized admin controls and rich workspace identity; Keg will need a simpler local-first adaptation unless it adds multi-user/server modes.

## Evidence Table
| Claim | Evidence | Notes |
|---|---|---|
| Notion separates personal agent and custom agents | [1], [2], [3] | Product page + help docs |
| Custom Agents run on triggers and schedules in background | [1], [2], [6] | Product page + custom agents docs + pricing docs |
| Custom Agents have independent permissions | [1], [3], [4] | Product page + permissions docs + MCP docs |
| Admin controls include creation controls, audit, analytics, disable/pause | [1], [3], [6] | Product page + permissions/admin docs + pricing docs |
| MCP connections are per-agent, credential-bound, with tool-level auto/ask controls | [1], [4] | Product page + MCP docs |
| Skills are reusable saved prompts and can be used by Custom Agents | [5], [1] | Help doc + product framing |

## Sources
1. Notion Agents product page, https://www.notion.com/product/agents
2. Notion Help — Custom Agents, https://www.notion.com/help/custom-agents
3. Notion Help — Custom Agents sharing and permissions, https://www.notion.com/help/custom-agents-sharing-and-permissions
4. Notion Help — MCP connections for Custom Agents, https://www.notion.com/help/mcp-connections-for-custom-agents
5. Notion Help — Skills for Notion Agent, https://www.notion.com/help/skills-for-notion-agent
6. Notion Help — Custom Agent pricing, https://www.notion.com/help/custom-agent-pricing
