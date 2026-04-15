# Nango.dev Research: How It Enables Integrations at Scale

## Overview

Nango is an open-source integration platform that enables SaaS products to build and manage API integrations at scale. Founded in 2022, Nango raised $7.5M from Gradient (April 2026) to build product integrations with AI. [1]

---

## 1. Architecture Overview

### 1.1 Platform Model

Nango operates as an **embedded iPaaS** (Integration Platform as a Service) that sits between your application and third-party APIs. [2]

```
┌─────────────────┐
│  Your App       │
└────────┬────────┘
         │
    ┌────▼─────┐
    │  Nango   │  ← Unified API Layer
    │ Platform │
    └────┬─────┘
         │
    ┌────▼──────────────────────────────┐
    │         External APIs             │
    │  (Salesforce, HubSpot, Notion...) │
    └───────────────────────────────────┘
```

### 1.2 Deployment Options

- **Cloud**: Managed hosted solution
- **Self-hosted**: Full control for enterprise customers with RBAC support [3]

### 1.3 Core Infrastructure

Nango provides:
- **Unified API Layer**: Standardized interface across 700+ external APIs
- **Connection Management**: Handles OAuth flows, token refresh, credential storage
- **Sync Engine**: Bidirectional data synchronization with conflict resolution
- **Webhook Handler**: Normalizes webhook formats across providers

---

## 2. Key Features

### 2.1 Authentication & Authorization (OAuth)

Nango handles the complexity of OAuth across multiple providers: [4]

- **Managed OAuth**: Pre-built OAuth flows for all supported integrations
- **Token Management**: Automatic token refresh, rotation, and secure storage
- **Multiple Auth Models**:
  - User-level auth: Individual user credentials
  - Organization-level auth: Shared credentials for team access
  - Server-to-server auth: API keys and OAuth client credentials

```javascript
// Example: Initiating an OAuth connection
const connection = await nango.auth('salesforce', 'user-123');
// Returns connection with access token, refresh token, etc.
```

### 2.2 Data Synchronization

Nango Sync enables reliable data synchronization between external APIs and your database: [5]

- **Incremental Syncs**: Only fetch changed records using timestamps/cursors
- **Real-time Syncs**: Immediate data propagation on changes [6]
- **Custom Objects**: Support for provider-specific data models (Salesforce custom objects, etc.)
- **Field Mappings**: Transform data between external and internal schemas [7]

```javascript
// Example: Triggering a sync
await nango.sync('salesforce', 'contacts', {
  syncType: 'incremental',
  cursor: lastSyncTimestamp
});
```

### 2.3 Webhooks

Nango normalizes webhooks from different providers into a unified format:

- **Provider Normalization**: Converts provider-specific formats to standard structure
- **Reliability**: Handles retries, deduplication, and ordering
- **Real-time Triggers**: Enables event-driven workflows

---

## 3. How Nango Handles 700+ Integrations

### 3.1 Integration Templates

Nango uses a template-based approach for scaling integrations: [8]

1. **Pre-built Templates**: Starting points for each integration type
2. **AI-Assisted Customization**: CLI tool to clone and customize templates with AI
3. **Open-source Templates**: Community-contributed integration patterns

```bash
# CLI command to customize an integration template
nango clone salesforce --template=crm/contacts
```

### 3.2 The "Just-in-Time" Integration Model

Nango pioneered the concept of **just-in-time integrations**: [9]

- Integrations are built on-demand when customers request them
- No need to pre-build every possible integration
- Reduces time-to-market from months to days

### 3.3 OpenCode Background Agent

Nango built a background agent using AI to assist with integration development: [10]

- Automated code generation for new integrations
- Learning from 200+ built integrations
- Pattern recognition for common API patterns

---

## 4. API Design Patterns

### 4.1 Unified API Abstraction

Nango abstracts provider-specific quirks into a consistent interface:

```javascript
// Same interface across all CRMs
const contacts = await nango.listRecords({
  provider: 'salesforce',  // or 'hubspot', 'pipedrive'
  model: 'Contact'
});
```

### 4.2 Standard Data Models

Nango provides normalized data models where possible:

- **Common Objects**: Contact, Company, Deal, Task (cross-provider)
- **Provider-Specific Objects**: Custom objects for advanced use cases
- **Extensible Schemas**: Add custom fields as needed

### 4.3 SDK Design

Multi-language SDK support:

```javascript
// REST API also available
const response = await fetch('https://api.nango.dev/v1/connections', {
  headers: { 'Authorization': `Bearer ${token}` }
});
```

### 4.4 Configuration as Code

```yaml
# nango.yaml - Integration configuration
integrations:
  salesforce:
    syncs:
      contacts:
        runs: every hour
        type: incremental
        object: Contact
        fields:
          - id
          - email
          - name
          - custom_field__c
```

---

## 5. Security & Enterprise Features

### 5.1 Role-Based Access Control (RBAC)

Enterprise-grade permission system for team access control. [3]

### 5.2 Trust & Compliance

- SOC 2 compliant infrastructure
- Secure credential storage
- Audit logging
- Data encryption at rest and in transit

### 5.3 Multi-tenant Architecture

Proper isolation for:
- Connection-level access control
- Per-customer configuration
- Usage metering and limits

---

## 6. AI Agent Integration

Nango recently expanded into AI agent tooling: [11]

- **Skill-based Actions**: Define agent capabilities that call external APIs
- **Permission Enforcement**: Control what AI agents can access
- **Agent Memory**: Persist context across agent interactions

---

## 7. Key Differentiators from Competitors

| Feature | Nango | Merge | Traditional iPaaS |
|---------|-------|-------|-------------------|
| Approach | Infrastructure + Templates | Unified API Only | Pre-built Only |
| Customization | Full code access | Limited | None |
| Deployment | Cloud + Self-hosted | Cloud only | Cloud only |
| AI Integration | Native | No | No |
| Open Source | Yes | No | Varies |

---

## 8. Summary

Nango enables integrations at scale through:

1. **Template-based approach**: Start from proven templates, customize with AI
2. **Managed infrastructure**: Handle OAuth, tokens, webhooks, retries
3. **Unified API layer**: Consistent interface across 700+ providers
4. **Just-in-time model**: Build integrations on-demand, not upfront
5. **Self-service capability**: Empower end-users to connect their accounts
6. **AI-assisted development**: Accelerate integration building with coding agents

---

## Sources

1. **Nango Raises $7.5M**: https://nango.dev/blog/nango-raises-7-5m-led-by-gradient
2. **What is an Embedded iPaaS**: https://nango.dev/blog/what-is-an-embedded-ipaas
3. **RBAC Launch**: https://nango.dev/blog/launching-rbac-and-our-commitment-to-the-enterprise
4. **User-level vs Org-level Auth**: https://nango.dev/blog/user-level-vs-org-level-auth-api-integrations
5. **Best Unified API for CRM/ERP**: https://nango.dev/blog/best-unified-api-for-crm-erp-integrations
6. **Google Calendar Real-time Sync**: https://nango.dev/blog/how-to-build-a-real-time-google-calendar-api-integration
7. **Custom Objects & Field Mappings**: https://nango.dev/blog/how-to-build-api-integrations-with-custom-objects-and-field-mappings
8. **Nango Clone CLI**: https://nango.dev/blog/nango-clone-customize-integration-templates
9. **Just-in-Time Integrations**: https://nango.dev/blog/just-in-time-integrations
10. **Building 200+ Integrations**: https://nango.dev/blog/learned-building-200-api-integrations-with-opencode
11. **AI Agent Integration**: https://nango.dev/blog/composio-alternatives
