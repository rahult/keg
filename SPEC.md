# Keg + Agents Architecture Specification

## Overview

Keg evolves from container management tool → **local AI infrastructure platform**. Two top-level areas: **Keg** (infrastructure) and **Agents** (personal AI).

**Key principle:** Agents abstraction allows future extraction into standalone app.

---

## 1. Navigation Architecture

### Top-Level: Area Selector

```swift
enum AppArea: String, CaseIterable {
    case keg = "Keg"
    case agents = "Agents"
}
```

**Sidebar redesign:** Replace flat `NavigationSection` list with **two-level hierarchy**:

```
┌─────────────────────────────────────────────┐
│  Keg                           [•] [⚙️]    │  ← Area header
├─────────────────────────────────────────────┤
│  ┌─────────────────────────────────────┐    │
│  │ Workloads                           │    │
│  │   • Containers                      │    │
│  │   • Compose                          │    │
│  │   • Kubernetes                       │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ Content                             │    │
│  │   • Images                           │    │
│  │   • Builds                           │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ System                              │    │
│  │   • Networks                        │    │
│  │   • Volumes                         │    │
│  │   • Registries                       │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

### Area-Specific Sidebar

**Keg area** sections:
- `NavigationSectionGroup.workloads`: containers, compose, kubernetes
- `NavigationSectionGroup.content`: images, builds
- `NavigationSectionGroup.system`: networks, volumes, registries

**Agents area** sections:
- `AgentSectionGroup.overview`: dashboard, active sessions
- `AgentSectionGroup.manage`: agents, skills, sources

---

## 2. AppState Changes

```swift
enum AppArea: String, CaseIterable {
    case keg
    case agents
}

@Observable
@MainActor
final class AppState {
    // Navigation state
    var currentArea: AppArea = .keg
    
    // Keg navigation
    var selectedKegSection: KegSection = .containers
    var selectedContainerID: String?
    var selectedImageReference: String?
    
    // Agents navigation
    var selectedAgentSection: AgentSection = .dashboard
    var selectedAgentID: String?
    var selectedSessionID: String?
    
    // ... existing fields
}

enum KegSection: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case compose = "Compose"
    case kubernetes = "Kubernetes"
    case images = "Images"
    case builds = "Builds"
    case networks = "Networks"
    case volumes = "Volumes"
    case registries = "Registries"
    
    var id: String { rawValue }
    var iconName: String { /* ... */ }
}

enum AgentSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case agents = "Agents"
    case sessions = "Sessions"
    case sources = "Sources"
    case skills = "Skills"
    
    var id: String { rawValue }
    var iconName: String { /* ... */ }
}
```

---

## 3. Detail View Routing

```swift
struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.currentArea {
            case .keg:
                KegDetailView()
            case .agents:
                AgentDetailView()
            }
        }
    }
}

struct KegDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedKegSection {
        case .containers: ContainerListView()
        case .compose: ComposeView()
        case .kubernetes: KubernetesView()
        case .images: ImageListView()
        case .builds: BuildView()
        case .networks: NetworkListView()
        case .volumes: VolumeListView()
        case .registries: RegistryListView()
        }
    }
}

struct AgentDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.selectedAgentSection {
        case .dashboard: AgentDashboardView()
        case .agents: AgentListView()
        case .sessions: SessionListView()
        case .sources: SourceListView()
        case .skills: SkillListView()
        }
    }
}
```

---

## 4. Agents Area Components

### 4.1 Dashboard (`AgentDashboardView`)

**Purpose:** At-a-glance view of active agents and recent activity.

**Content:**
- Active agents card grid (name, model, status, last used)
- Recent sessions list (agent name, duration, summary)
- Quick actions: "New Agent", "New Session", "Configure Sources"

**States:**
- Empty: "Set up your first agent"
- Loading: Skeleton cards
- Populated: Agent grid + activity feed

### 4.2 Agents List (`AgentListView`)

**Purpose:** CRUD for agent configurations.

**Table columns:**
- Name (editable)
- Model
- Tools count
- Skills count
- Created
- Actions

**Actions:**
- Create: Sheet with agent configuration form
- Edit: Sheet with agent configuration form
- Delete: Confirmation dialog
- Duplicate: Creates copy with "(Copy)" suffix
- Archive: Soft delete

**Toolbar:**
- "+" New Agent
- Search
- Filter by model/status

### 4.3 Sessions List (`SessionListView`)

**Purpose:** View and manage conversation history.

**Table columns:**
- Agent name
- Started
- Duration
- Message count
- Status (active/completed)

**Features:**
- Click to open session detail (read-only transcript)
- Search sessions
- Export session (markdown/PDF)
- Delete old sessions

**Toolbar:**
- Search
- Filter by agent
- Filter by date range

### 4.4 Sources List (`SourceListView`)

**Purpose:** Configure data sources for agents (MCP, REST, files).

**Source types:**
- MCP Server: server config, auth, enabled tools
- REST API: endpoint, auth, request/response schemas
- File System: path patterns, watch behavior

**Table columns:**
- Name
- Type (MCP/REST/Files)
- Status (connected/error)
- Last sync

**Actions:**
- Add source (type-specific sheet)
- Configure
- Enable/disable
- Test connection
- Delete

### 4.5 Skills List (`SkillListView`)

**Purpose:** Manage reusable agent skills.

**Skill structure:**
- YAML: `name`, `description`, `instructions`
- Markdown: Detailed usage guide

**Table columns:**
- Name
- Description (truncated)
- Agents using
- Updated

**Actions:**
- Create skill (editor with YAML + markdown tabs)
- Edit
- Delete
- View usage

---

## 5. File Structure

```
Sources/Keg/
├── App/
│   ├── AppState.swift          # Updated with area navigation
│   ├── KegApp.swift            # Updated routing
│   └── Components/
│       ├── SidebarView.swift   # Area-aware sidebar
│       └── AreaHeader.swift    # Keg/Agents toggle
├── Agents/                     # Agents module (extraction-ready)
│   ├── Views/
│   │   ├── AgentDashboardView.swift
│   │   ├── AgentListView.swift
│   │   ├── AgentDetailView.swift
│   │   ├── AgentEditorView.swift  # Create/edit sheet
│   │   ├── SessionListView.swift
│   │   ├── SessionDetailView.swift
│   │   ├── SourceListView.swift
│   │   ├── SourceEditorView.swift
│   │   ├── SkillListView.swift
│   │   └── SkillEditorView.swift
│   ├── ViewModels/
│   │   ├── AgentDashboardVM.swift
│   │   ├── AgentListVM.swift
│   │   ├── SessionListVM.swift
│   │   ├── SourceListVM.swift
│   │   └── SkillListVM.swift
│   └── Types/                  # Already created
│       ├── Types.swift
│       ├── EnvironmentTypes.swift
│       ├── SessionTypes.swift
│       ├── ManagedAgentsClient.swift
│       ├── SSEClient.swift
│       └── AgentAuth.swift
├── Keg/                        # Keg infrastructure module
│   ├── Views/
│   │   ├── ContainerListView.swift
│   │   ├── ComposeView.swift
│   │   ├── KubernetesView.swift
│   │   └── ... (existing)
│   └── ViewModels/
│       └── ... (existing)
└── Shared/
    ├── Design.swift            # Shared design tokens
    └── Components/             # Shared UI components
        ├── StatusBadge.swift
        ├── CopyableText.swift
        └── ContentUnavailableView+Extensions.swift
```

---

## 6. API Integration

### Managed Agents Client

Already implemented in `Sources/Keg/Agent/`:

```swift
// Base URL configurable in settings
static var baseURL: URL = URL(string: "https://api.claude.ai")!

// Key endpoints used:
POST   /v1/agents                          → Create agent
GET    /v1/agents                           → List agents
GET    /v1/agents/{id}                      → Get agent
PATCH  /v1/agents/{id}                      → Update agent
DELETE /v1/agents/{id}                      → Archive agent
POST   /v1/agents/{id}/sessions             → Create session
GET    /v1/agents/{agentId}/sessions        → List sessions
GET    /v1/agents/{agentId}/sessions/{id}   → Get session
POST   /v1/environments                     → Create environment
GET    /v1/environments                     → List environments
POST   /v1/sessions/{id}/events/stream     → SSE for events
```

### Authentication Flow

1. User enters API key in Settings
2. `AgentAuth.storeAPIKey()` → macOS Keychain
3. All client requests include `Authorization: Bearer <key>`
4. Test connection on save
5. Clear key on sign out

---

## 7. Design Tokens

Shared across Keg and Agents areas:

```swift
enum Design {
    // Colors
    enum Colors {
        static let primary = Color.accentColor
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red
        
        // Status colors
        static let statusRunning = Color.green
        static let statusStopped = Color.red
        static let statusPending = Color.blue
        static let statusWarning = Color.yellow
    }
    
    // Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }
    
    // Corner radius
    enum CornerRadius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }
}
```

---

## 8. Implementation Phases

### Phase 1: Navigation Foundation
- [ ] Update `AppArea` enum and navigation state
- [ ] Create area-aware sidebar
- [ ] Update detail view routing
- [ ] Add area header with toggle

### Phase 2: Agents Module Shell
- [ ] Create `Agents/` directory structure
- [ ] Create placeholder views for all 5 screens
- [ ] Create placeholder ViewModels
- [ ] Verify routing works

### Phase 3: Agents Dashboard
- [ ] Implement `AgentDashboardVM`
- [ ] Implement `AgentDashboardView`
- [ ] Add active agent cards
- [ ] Add recent sessions list
- [ ] Add quick action buttons

### Phase 4: Agents CRUD
- [ ] Implement `AgentListVM` with `ManagedAgentsClient`
- [ ] Implement `AgentListView` with Table
- [ ] Implement `AgentEditorView` (create/edit sheet)
- [ ] Implement context menu and toolbar

### Phase 5: Sessions
- [ ] Implement `SessionListVM`
- [ ] Implement `SessionListView`
- [ ] Implement `SessionDetailView` (read-only transcript)
- [ ] Add session search/filter

### Phase 6: Sources
- [ ] Implement `SourceListVM`
- [ ] Implement `SourceListView`
- [ ] Implement `SourceEditorView` (MCP/REST/Files)
- [ ] Add connection testing

### Phase 7: Skills
- [ ] Implement `SkillListVM`
- [ ] Implement `SkillListView`
- [ ] Implement `SkillEditorView` (YAML + markdown)
- [ ] Add skill import/export

### Phase 8: Polish
- [ ] Error handling and empty states
- [ ] Keyboard shortcuts
- [ ] Accessibility
- [ ] macOS HIG compliance

---

## 9. Future Extraction

When Agents becomes standalone:

```
agents/
├── Sources/Agents/
│   ├── App/
│   │   └── AgentApp.swift      # New app entry
│   ├── Views/                  # Existing views
│   └── ViewModels/             # Existing VMs
├── Package.swift               # New package
└── README.md
```

**Changes needed:**
1. Create new `Package.swift` with `Agents` library target
2. Create `AgentApp.swift` entry point
3. Extract shared components to `Shared/` submodule
4. Update imports from `Keg.Agent` → `Agents`

**Unchanged:**
- All Agent types (`Types.swift`, etc.)
- `ManagedAgentsClient`, `SSEClient`, `AgentAuth`
- View logic and ViewModels

---

## 10. Testing Strategy

### Unit Tests
- ViewModels: test state transitions, API calls
- Types: test Codable conformance
- Client: test request/response parsing

### Integration Tests
- API integration (requires API key)
- Keychain storage
- SSE streaming

### UI Tests
- Navigation flows (Keg ↔ Agents)
- Agent CRUD operations
- Session viewing
- Error state handling

### E2E Tests
- Full user flows
- Multi-agent scenarios
- Long-running session handling

---

## 11. Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| apple/container | 0.11.0 | Container management (Keg) |
| hummingbird | 2.22+ | HTTP server (Keg Docker API) |
| Yams | 5.4+ | YAML parsing (Compose, Skills) |
| swift-collections | 1.1+ | OrderedDictionary for agents |
| swift-algorithms | 1.2+ | Sequence utilities |

**No new dependencies required** for Agents module — uses Foundation, SwiftUI, and existing packages.
