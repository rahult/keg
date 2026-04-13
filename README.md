# Keg

**Docker Desktop replacement for macOS** — native SwiftUI app built on Apple Containerization.

Keg provides containers, Docker API compatibility, Compose, and Kubernetes — all running on Apple's first-party container runtime with hardware-level isolation per container.

## Features

| Feature | Status |
|---------|--------|
| Container lifecycle (run/stop/kill/exec/logs) | ✅ |
| Image management (pull/push/build/delete) | ✅ |
| Networks (create/delete/list) | ✅ |
| Volumes (create/delete/list) | ✅ |
| Registry auth (login/logout) | ✅ |
| Docker-compatible API (`~/.keg/docker.sock`) | ✅ |
| Docker Compose (`docker-compose.yml`) | ✅ |
| Kubernetes (kubeadm on kindest/node) | ✅ |
| Menu bar widget | ✅ |
| Build (Dockerfile/Containerfile via BuildKit) | ✅ |

## Requirements

- **macOS 26+** (Tahoe)
- **Apple Silicon** (M1/M2/M3/M4)
- **Xcode 26**
- **Apple `container` CLI** — install from [github.com/apple/container/releases](https://github.com/apple/container/releases)

## Build

```bash
git clone https://github.com/rahult/keg.git
cd keg
make app     # Build Keg.app
make open    # Build and open
```

Or build the binary directly:

```bash
swift build -c release
```

## Usage

### Start the container system

```bash
container system start
```

Or start it from Keg's Settings view.

### Run containers

Use the GUI, or use the `container` CLI directly:

```bash
container run -d --name web -p 8080:80 nginx:latest
```

### Docker API compatibility

Start the Docker API server from Keg Settings, then:

```bash
export DOCKER_HOST=unix://$HOME/.keg/docker.sock
docker ps
docker run -d -p 3000:3000 my-app
docker compose up -d
```

### Docker Compose

Select a `docker-compose.yml` file in the Compose view and click **Up**.

### Kubernetes

1. Open **Kubernetes** in the sidebar
2. Click **Create Cluster** (~60s)
3. Connect:

```bash
export KUBECONFIG="$HOME/.keg/kubeconfig"
kubectl get nodes
kubectl apply -f deployment.yaml
```

## Architecture

Keg wraps Apple's [Containerization](https://github.com/apple/containerization) framework — each container runs in its own lightweight Linux VM via Virtualization.framework:

```
Keg App (SwiftUI)
  → Docker API Server (Hummingbird, ~/.keg/docker.sock)
  → Compose Orchestrator (YAML parser, dependency resolution)
  → Kubernetes Bootstrap (kindest/node + kubeadm)
  → ContainerAPIClient (XPC/gRPC)
    → container-apiserver → container-runtime-linux
      → Virtualization.framework → Linux VM per container
```

**Key properties:**
- Sub-second container starts (optimized kernel + vminitd)
- Hardware-level isolation per container (not shared-kernel namespaces)
- Near-zero idle RAM (no daemon running when empty)
- OCI-compatible images (pull/push from any registry)

## Project Structure

```
Sources/Keg/
├── App/                    # App entry, state, navigation
├── DockerAPI/              # Docker Engine API compatibility layer
│   ├── DockerAPIServer.swift
│   ├── ContainerBridge.swift
│   └── DockerTypes.swift
├── Compose/                # Docker Compose parser + orchestrator
│   └── ComposeOrchestrator.swift
├── ViewModels/             # Container and image list VMs
├── Views/
│   ├── Containers/         # List, detail, logs, stats, run
│   ├── Images/             # Image list, pull
│   ├── Builds/             # Build view
│   ├── Compose/            # Compose file orchestrator UI
│   ├── Kubernetes/         # Cluster create/delete/status
│   ├── Networks/           # Network list
│   ├── Volumes/            # Volume list
│   ├── Registries/         # Registry login/logout
│   ├── Settings/           # System + Docker API controls
│   ├── MenuBar/            # Menu bar popover
│   ├── Sidebar/            # Navigation sidebar
│   └── Shared/             # Reusable components
└── Tests/
```

## Why Keg?

| | Docker Desktop | OrbStack | **Keg** |
|---|---|---|---|
| Container runtime | containerd in Linux VM | containerd in Linux VM | Apple Containerization (native VMs) |
| Isolation | Process-level (namespaces) | Process-level | Hardware-level (per-container VM) |
| Boot time | ~30s | ~2s | Sub-second |
| Idle RAM | ~2GB | ~500MB | Near-zero |
| Docker API | ✅ | ✅ | ✅ |
| Kubernetes | ✅ | ✅ | ✅ |
| Native macOS app | Electron | Native-ish | **SwiftUI** |
| License | Proprietary (paid) | Proprietary (paid) | **Apache 2.0** |

## License

Apache License 2.0
