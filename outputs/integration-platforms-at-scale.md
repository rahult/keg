# Integration Platforms at Scale: Nango, Alternatives, and Architecture

## Executive Summary

Building integrations at scale requires handling authentication across hundreds of APIs, managing data synchronization, and maintaining reliability under variable load. Platforms like Nango.dev address these challenges through unified authentication abstraction and function-based integration logic.

For teams seeking alternatives, several open-source options exist: **Supaglue** offers a B2B SaaS-focused approach with unified APIs; **Airbyte** provides the largest connector ecosystem for data pipelines; **n8n** enables workflow-based integrations with visual builder. Self-hosted deployment remains viable for teams with operational capacity and data privacy requirements.

## How Nango Enables Integrations at Scale

### Architecture Overview

Nango's platform centers on two primitives: **Auth** and **Functions**. Auth handles authentication flows for 700+ APIs, including OAuth 1/2, API keys, and automatic token refresh. Functions are TypeScript integrations deployed on Nango's runtime with built-in retries, storage, and observability. [1]

### Key Scaling Mechanisms

1. **Per-tenant isolation**: Each customer's credentials and state are isolated, preventing cross-tenant data leakage and enabling elastic scaling. [1]

2. **Unified API abstraction**: Pre-built integrations abstract provider-specific quirks into consistent interfaces, reducing per-connector maintenance. [1]

3. **AI Integration Builder**: Natural language to integration code generation accelerates development of new connectors. [1]

4. **Real-time webhooks + durable execution**: Combines event-driven patterns with reliable execution guarantees. [1]

### Integration Patterns Used

| Pattern | Description | Use Case |
|---------|-------------|----------|
| Hub-and-spoke | Central hub connects to all APIs | Unified auth, monitoring |
| Function composition | Chain multiple API calls | Complex workflows |
| Event-driven | Webhooks trigger execution | Real-time sync |
| Scheduled sync | Cron-based data refresh | Periodic data export |

## Open Source Alternatives

### Supaglue
**Focus:** B2B SaaS product integrations (CRM, Marketing, Support)

Supaglue provides unified APIs across providers, managed authentication, and managed syncs to Postgres or data warehouses. Self-hostable via Docker Compose. [2][3]

**Best for:** SaaS companies building native integrations with customer tools

### Airbyte
**Focus:** Data pipelines and ELT

300+ connectors with strong data transformation capabilities. Airbyte 2.0 emphasizes AI-ready data. Both cloud and self-hosted options. [4]

**Best for:** Data engineering teams, analytics pipelines

### n8n
**Focus:** Workflow automation

Visual workflow builder with 400+ integrations. No-code/low-code friendly. SSPL license (限制条件). [5]

**Best for:** Teams wanting visual workflows, less technical users

### Temporal
**Focus:** Reliable workflow orchestration

Durable execution engine with built-in retries and timeouts. Not an integration platform itself but enables reliable integration orchestration. [6]

**Best for:** Teams needing strong consistency guarantees

### Comparison Matrix

| Platform | Connectors | Self-Hosted | License | Best For |
|----------|------------|-------------|---------|----------|
| Supaglue | 20+ | Yes | Apache 2.0 | B2B SaaS |
| Airbyte | 300+ | Yes | MIT | Data pipelines |
| n8n | 400+ | Yes | SSPL | Workflows |
| Temporal | 0 | Yes | MIT | Orchestration |

## Architecture Patterns for Integration Platforms

### Authentication Abstraction

Successful integration platforms abstract authentication through:
- Centralized credential storage with encryption
- OAuth callback standardization
- Automatic token refresh rotation
- Per-user/per-tenant isolation

### Rate Limiting Strategies

Integration platforms must handle third-party rate limits through:
- **Token bucket**: Smooths bursty traffic
- **Sliding window**: Fair per-customer limits  
- **Queue-based decoupling**: Producers don't block on API calls
- **Per-provider tracking**: Know each API's quota

### Data Synchronization Approaches

| Strategy | Pros | Cons |
|----------|------|------|
| Full refresh | Simple, consistent | Expensive at scale |
| Incremental | Efficient | Requires audit fields |
| CDC (Change Data Capture) | Real-time | Complex setup |
| Webhook-triggered | Event-driven | Requires webhook support |

## Self-Hosted vs Managed Tradeoffs

### Self-Hosted Advantages
- **Data privacy**: Full control, no third-party access
- **Cost control**: Fixed infrastructure costs, no per-integration fees
- **Customization**: Full code access, fork and modify
- **Compliance**: Easier HIPAA/GDPR for sensitive data

### Managed Platform Advantages
- **Speed**: Zero setup, production-ready
- **Scale**: Elastic without capacity planning
- **Reliability**: SLA guarantees, 24/7 support
- **Updates**: Continuous connector improvements

### Estimated Costs

**Self-hosted:** $80-400/month (compute, DB, storage)
**Managed:** $0-1000+/month (tiered pricing)

### Decision Framework

Choose **self-hosted** when:
- Data privacy is critical (healthcare, finance)
- Heavy customization needed
- Budget fixed at scale
- Team has DevOps capacity

Choose **managed** when:
- Speed to market priority
- Limited DevOps resources
- Variable/unpredictable load
- Standard integrations suffice

## Recommendations

1. **For B2B SaaS integrations**: Start with Supaglue (Apache 2.0, self-hostable, CRM focus)

2. **For data pipelines**: Airbyte (largest ecosystem, strong community)

3. **For workflow automation**: n8n (visual builder, no-code friendly)

4. **For maximum control**: Self-hosted Supaglue + Temporal for orchestration

5. **For fastest time-to-market**: Nango managed (if budget allows)

## Open Questions

- How do open source platforms maintain connector quality without dedicated teams?
- What are the real-world limits of self-hosted at high scale (millions of sync jobs)?
- How do hybrid approaches (managed auth + self-hosted processing) perform?

## Sources

[1] Nango Documentation - https://nango.dev/docs/getting-started/intro-to-nango

[2] Supaglue Overview - https://docs.supaglue.com/platform/overview

[3] Supaglue GitHub - https://github.com/supaglue-labs/supaglue

[4] Airbyte - https://airbyte.com/

[5] n8n - https://n8n.io

[6] Temporal - https://temporal.io
