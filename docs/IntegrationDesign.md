# Meadow Integration Platform Design

## Context

Meadow runs containers natively on Apple Silicon. Integration platform patterns (like Nango/Supaglue) can leverage this infrastructure for lightweight, scalable integrations.

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────┐
│                    Meadow Integration Hub                   │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐ │
│  │ Auth Manager │  │ Sync Engine │  │ Connector Pool   │ │
│  │ - OAuth     │  │ - Schedule  │  │ - Pre-warmed    │ │
│  │ - API Keys  │  │ - CDC       │  │ - Per-provider   │ │
│  │ - Sessions  │  │ - Webhooks  │  │ - Container exec │ │
│  └─────────────┘  └─────────────┘  └─────────────────┘ │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              HybridAgentRunner (existing)            │ │
│  │  - Process mode (~5ms, safe ops)                   │ │
│  │  - Container mode (~15ms, dangerous ops)           │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              ContainerPool (existing)                │ │
│  │  - Pre-warmed containers                            │ │
│  │  - Warm exec ~15-18ms                              │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
      ┌──────────┐  ┌──────────┐  ┌──────────┐
      │ Provider  │  │ Provider  │  │ Provider  │
      │ Container │  │ Container │  │ Container │
      │ (alpine)  │  │ (node)    │  │ (python)  │
      └──────────┘  └──────────┘  └──────────┘
```

### Integration with Existing Meadow Components

| Component | Role | Status |
|-----------|------|--------|
| `HybridAgentRunner` | Execute connector code | ✅ Existing |
| `ContainerPool` | Pre-warmed containers for providers | ✅ Existing |
| `ContainerBridge` | Docker API → container CLI | ✅ Existing |
| `AppState` | System metrics, health checks | ✅ Existing |

### New Components Needed

1. **AuthStore** - Secure credential storage (Keychain)
2. **ConnectorRegistry** - Provider definitions, API specs
3. **SyncScheduler** - Cron-based sync jobs
4. **WebhookHandler** - Inbound webhook processing
5. **IntegrationVM** - Per-integration isolated execution

## Implementation Plan

### Phase 1: Auth & Connector Foundation
```
Sources/Meadow/Integrations/
├── Auth/
│   ├── CredentialStore.swift      # Keychain-backed
│   ├── OAuthHandler.swift          # OAuth 1/2 flows
│   └── SessionManager.swift        # Token refresh
├── Connectors/
│   ├── Connector.swift             # Protocol
│   ├── Registry.swift              # Provider registry
│   └── Builtin/
│       ├── GitHub.swift
│       ├── Slack.swift
│       └── Docker.swift
```

### Phase 2: Sync Engine
```
Sources/Meadow/Integrations/
├── Sync/
│   ├── Scheduler.swift             # Cron-based
│   ├── IncrementalSync.swift       # Cursor-based
│   ├── WebhookReceiver.swift       # Inbound
│   └── ChangeDetector.swift        # CDC
```

### Phase 3: UI Integration
```
Sources/Meadow/Views/Integrations/
├── IntegrationListView.swift
├── ConnectorDetailView.swift
├── CredentialEditor.swift
└── SyncHistoryView.swift
```

## Key Design Decisions

### 1. Container-per-Provider vs Process-per-Request

| Approach | Latency | Memory | Isolation |
|----------|---------|--------|----------|
| Process (existing) | ~5ms | ~0MB | None |
| Container warm (existing) | ~15ms | ~10MB | Full |
| Container-per-provider | ~50ms cold | ~20MB | Full + per-provider |

**Decision:** Use `HybridAgentRunner` pattern:
- Safe ops → Process mode (~5ms)
- Untrusted → Container warm (~15ms)
- Per-provider isolation → ContainerPool per provider

### 2. Credential Storage

Using existing `AgentAuth` Keychain integration:
```swift
// Store API credentials
KeychainStore.save(provider: "github", credentials: OAuthCredentials(...))
KeychainStore.save(provider: "slack", credentials: APIKeyCredentials(...))
```

### 3. Sync Strategy

| Data Pattern | Approach |
|--------------|----------|
| Continuous | Webhooks (immediate) |
| Periodic | Cron sync (configurable) |
| On-demand | API trigger |
| Bulk | Manual sync job |

### 4. API Design

```swift
// Unified integration API
struct Integration {
    let id: UUID
    let provider: String
    let credentials: CredentialRef  // Never expose raw
    let syncConfig: SyncConfig
    let status: IntegrationStatus
}

// Actions
POST /integrations          // Create
GET  /integrations/:id      // Get
POST /integrations/:id/sync // Trigger sync
GET  /integrations/:id/logs // Sync history
```

## Comparison with Nango

| Feature | Nango | Meadow Integration |
|---------|-------|----------------|
| Self-hosted | Enterprise only | ✅ Built-in |
| Infrastructure | 5 services + Postgres + Redis + ES | ✅ Single app |
| Min resources | Heavy (8GB+ RAM) | ✅ Lightweight (~50MB) |
| Container model | VMs/containers | ✅ Native Apple Container |
| Connectors | 700+ | Built-in + custom |
| Code execution | TypeScript functions | ✅ Swift/process |

## Next Steps

1. [ ] Design `AuthStore` protocol (leverage AgentAuth)
2. [ ] Create `Connector` protocol
3. [ ] Implement first builtin connector (Docker registry?)
4. [ ] Add integration to sidebar navigation
5. [ ] Build UI for credential management
