# Keg — Agent Instructions

## Project Overview

Keg is a native macOS SwiftUI app that wraps Apple's `container` framework (github.com/apple/container v1.3.1) to provide a Docker Desktop–class experience. Target: macOS 26+ (Tahoe), Apple Silicon only.

## Tech Stack

- **Language**: Swift 6.2 (strict concurrency, `.swiftLanguageMode(.v6)`)
- **UI**: SwiftUI (macOS 26+), NavigationSplitView, @Observable
- **Container runtime**: Apple Containerization (ContainerAPIClient + ContainerResource)
- **HTTP server**: Hummingbird 2.x (Docker API compat on Unix socket)
- **YAML parsing**: Yams 5.x (docker-compose.yml)
- **Build**: Swift Package Manager, Makefile for .app bundle

## Architecture

- **One VM per container** via Virtualization.framework — not a shared Linux VM like Docker Desktop
- `ContainerAPIClient` talks to `container-apiserver` (launchd XPC service)
- Most container operations go through `Process()` calling the `container` CLI
- Docker API server runs on `~/.keg/docker.sock` (Hummingbird)
- K8s uses kindest/node image with kubeadm inside a single Apple Container

## Code Conventions

- `@Observable @MainActor final class` for ViewModels
- `async throws` for all container operations via `Process()` + `container` CLI
- SwiftUI `Table` for list views, `.inset(alternatesRowBackgrounds: true)`
- Docker API types in `DockerTypes.swift` use `CodingKeys` matching Docker's PascalCase JSON
- `ContainerBridge` actor translates between Docker API and `container` CLI
- `ComposeOrchestrator` actor handles compose file parsing and execution

## Key Files

| File | Purpose |
|------|---------|
| `Package.swift` | Dependencies + targets: `Keg` app, `kegcli` companion CLI, `KegCLICore` shared library |
| `Sources/Keg/App/AppState.swift` | Global state, system lifecycle, Docker API control, NavigationSection enum |
| `Sources/Keg/App/KegApp.swift` | App entry, WindowGroup, MenuBarExtra, DetailView routing, `keg://` deep links |
| `Sources/Keg/DockerAPI/DockerAPIServer.swift` | Hummingbird HTTP server with Docker Engine API routes |
| `Sources/Keg/DockerAPI/ContainerBridge.swift` | CLI bridge: Docker API → `container` CLI translation |
| `Sources/Keg/DockerAPI/DockerHijackChannel.swift` | NIO 101-upgrade hijack channel for `docker run`/`exec` attach |
| `Sources/KegCLICore/` | Shared logic for the `keg` CLI: unix-socket HTTP client, models, PATH install rules |
| `Sources/KegCLI/` | The `keg` companion CLI (built as `kegcli`, bundled + installed as `keg`) |
| `Sources/Keg/App/KegCLIInstaller.swift` | App-side one-click CLI install (same location rules as `keg install`) |
| `Sources/Keg/Compose/ComposeOrchestrator.swift` | YAML parsing, topological sort, compose lifecycle |
| `Sources/Keg/Views/Kubernetes/KubernetesView.swift` | K8s cluster bootstrap (kindest/node + kubeadm) |

## Build & Run

```bash
make app          # Build Keg.app
make open         # Build and launch
make test         # Run tests
swift build -c release  # Build binary only
```

## Current Capabilities

- Container CRUD, logs, stats, exec (via container CLI)
- Image pull/push/build/delete/list
- Network and volume management
- Registry login/logout
- Build (Dockerfile via container build, BuildKit)
- Docker API compatibility (socket proxy)
- Docker Compose orchestration
- Kubernetes cluster lifecycle
- Menu bar popover, settings

## Known Limitations

- Apple Container is pre-1.0 — API may change between minor versions
- Memory pages not returned to macOS (partial ballooning support)
- No Docker socket streaming for exec/port-forward yet (stubs)
- K8s is single-node only
- No Intel Mac support (Apple Silicon required)
- No CRI shim yet (K8s uses containerd inside kindest/node)

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| apple/container | 1.3.1 | ContainerAPIClient, ContainerResource |
| hummingbird | 2.22+ | HTTP server for Docker API |
| Yams | 6.2+ | YAML parsing for Compose |
| Sparkle | 2.10+ | Auto-update feed |
| SwiftTerm | 1.11.2 | Embedded terminal emulator (PTY + VT100) |
