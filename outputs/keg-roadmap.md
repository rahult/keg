# KEG — Docker Desktop Replacement for macOS with Kubernetes

> A native macOS application built on Apple Containerization that provides a Docker Desktop–class experience with first-class Kubernetes support.

---

## 1. Executive Summary

**KEG** (Kubernetes Engine on Guest) is a native macOS application that replaces Docker Desktop for developers on Apple Silicon. It layers a polished GUI, a Docker-compatible API, and a one-click Kubernetes cluster on top of Apple's open-source [Containerization](https://github.com/apple/containerization) framework and [container CLI](https://github.com/apple/container) (v0.11.0, 26K GitHub stars).

### Why Now

| Factor | Signal |
|--------|--------|
| Apple Containerization announced at WWDC 2025 | New first-party container runtime optimized for Apple Silicon |
| `apple/container` at v0.11.0, 9 releases in 9 months | Rapid maturation, breaking changes stabilizing toward 1.0 |
| macOS 26 (Tahoe) adds new Virtualization + Networking APIs | Required platform primitives are now in the OS |
| Docker Desktop licensing changes ($9/seat/mo for teams) | Enterprise demand for open alternatives |
| Existing partial solutions (`cluster` CLI, `gocker`, Colima) | Proven demand, but no integrated GUI product |

### Key Differentiators vs Docker Desktop

| | Docker Desktop | KEG |
|---|---|---|
| **Architecture** | Single large Linux VM running Docker Engine | Each container = its own lightweight Apple VM (hardware-level isolation) |
| **Boot time** | ~30s daemon startup | Sub-second container starts |
| **Idle RAM** | ~2 GB | Near-zero when no containers running |
| **Kubernetes** | Kind-based inside Docker | Native kubeadm cluster inside Apple Containerization |
| **Security** | Process-level (namespaces/cgroups) | Hardware-level (Apple Virtualization.framework per-container VMs) |
| **License** | Proprietary (paid for large teams) | Apache 2.0 (fully open source) |
| **macOS integration** | Electron app | Native Swift/SwiftUI |
| **Binary size** | ~2 GB app bundle | ~30-50 MB app + container CLI |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    KEG App (SwiftUI)                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐ │
│  │Container │ │  K8s     │ │ Image    │ │ Settings   │ │
│  │Dashboard │ │ Dashboard│ │ Explorer │ │ & Resources│ │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └─────┬──────┘ │
│       │             │            │              │        │
│  ┌────┴─────────────┴────────────┴──────────────┴──────┐│
│  │              KEG Core Layer (Swift)                  ││
│  │  ┌────────────┐  ┌──────────────┐  ┌─────────────┐  ││
│  │  │Docker API  │  │  K8s Cluster │  │ Compose     │  ││
│  │  │Compat Server│ │  Manager     │  │ Parser      │  ││
│  │  └─────┬──────┘  └──────┬───────┘  └──────┬──────┘  ││
│  │        │                │                  │         ││
│  │  ┌─────┴────────────────┴──────────────────┴──────┐  ││
│  │  │         Apple Container XPC Client             │  ││
│  │  └───────────────────┬───────────────────────────┘  ││
│  └──────────────────────┼──────────────────────────────┘│
└─────────────────────────┼───────────────────────────────┘
                          │ XPC / gRPC over vsock
┌─────────────────────────┼───────────────────────────────┐
│  Apple Container System Services                        │
│  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌──────────────┐ │
│  │API Server│ │ Network  │ │  DNS   │ │  Storage /   │ │
│  │ (XPC)    │ │ Service  │ │ Server │ │  Volumes     │ │
│  └──────────┘ └──────────┘ └────────┘ └──────────────┘ │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Containerization Framework (Swift)              │   │
│  │  Virtualization.framework │ vminitd │ OCI Client │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
         ┌──────────┐  ┌──────────┐  ┌──────────┐
         │ Container│  │ Container│  │ Container│   ← Each
         │   VM 1   │  │   VM 2   │  │   VM N   │     is a
         │ (Linux)  │  │ (Linux)  │  │ (Linux)  │   lightweight
         └──────────┘  └──────────┘  └──────────┘   Apple VM
```

### Core Dependencies

| Component | Source | License |
|-----------|--------|---------|
| [apple/containerization](https://github.com/apple/containerization) | Swift framework for Linux containers on macOS | Apache 2.0 |
| [apple/container](https://github.com/apple/container) | CLI + XPC services for container management | Apache 2.0 |
| [Virtualization.framework](https://developer.apple.com/documentation/virtualization) | Apple's native VM framework | System |
| [Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html) | Cross-compile vminitd from Mac | Apache 2.0 |

### What NOT to Build (Use Existing)

- **Container runtime** → Use `apple/container` CLI and its XPC services directly
- **Image registry client** → Use Containerization's `ContainerizationOCI` package
- **EXT4 filesystem** → Use `ContainerizationEXT4` package  
- **Init system inside VMs** → Use `vminitd` from Containerization
- **Linux kernel** → Use Containerization's optimized kernel config (or Kata Containers `vmlinux`)

---

## 3. Phased Roadmap

### Phase 0 — Foundation (Weeks 1–4)

**Goal:** Set up the project skeleton, understand the Containerization APIs, get a basic container running programmatically.

| # | Feature | Description | Priority |
|---|---------|-------------|----------|
| 0.1 | **Project scaffolding** | Swift Package Manager project structure, Xcode project, CI (GitHub Actions), linting (swift-format) | P0 |
| 0.2 | **Containerization API exploration** | Build a `cctl`-like test harness that exercises image pull, container create, container run, exec, stop | P0 |
| 0.3 | **XPC client wrapper** | Wrap the `ContainerXPC` client in a clean async Swift API that KEG Core can consume | P0 |
| 0.4 | **Container lifecycle manager** | State machine for container states: Created → Running → Stopped → Deleted, with event emission | P0 |
| 0.5 | **CLI proof-of-concept** | A minimal `keg` CLI that can `keg run alpine:latest echo hello` using the Containerization framework | P0 |

**Exit criteria:** `keg run alpine:latest echo hello` works from terminal, container starts in <1s.

---

### Phase 1 — Docker-Compatible API (Weeks 5–10)

**Goal:** Build a Docker Engine–compatible REST API so existing tools (docker CLI, Compose, Portainer, Testcontainers, IDE integrations) work unmodified.

Reference implementation: [gocker API server](https://github.com/lunguini/gocker/blob/main/api/server.go).

| # | Feature | Description | Priority |
|---|---------|-------------|----------|
| 1.1 | **Unix socket HTTP server** | Listen on `~/.keg/docker.sock`, implement Docker API routes | P0 |
| 1.2 | **`/_ping` + `/version`** | Health check and version endpoints | P0 |
| 1.3 | **Container CRUD API** | `POST /containers/create`, `POST /containers/{id}/start`, `POST /containers/{id}/stop`, `DELETE /containers/{id}`, `GET /containers/json` | P0 |
| 1.4 | **Container inspect + logs** | `GET /containers/{id}/json`, `GET /containers/{id}/logs` (streaming) | P0 |
| 1.5 | **Container exec** | `POST /containers/{id}/exec`, `POST /exec/{id}/start` with TTY/STDIN support | P0 |
| 1.6 | **Image API** | `GET /images/json`, `POST /images/create` (pull), `DELETE /images/{name}`, `GET /images/{name}` (inspect) | P0 |
| 1.7 | **Network API** | `GET /networks`, `POST /networks/create`, `DELETE /networks/{id}`, connect/disconnect | P1 |
| 1.8 | **Volume API** | `GET /volumes`, `POST /volumes/create`, `DELETE /volumes/{name}`, inspect | P1 |
| 1.9 | **Port mapping** | Translate Docker `-p hostPort:containerPort` to Apple Container's dedicated-IP model (may require network proxy or DNAT) | P0 |
| 1.10 | **`docker context` support** | `docker context create keg --docker "host=unix://$HOME/.keg/docker.sock"` should work | P1 |
| 1.11 | **Event stream** | `GET /events` with container lifecycle events for tool compatibility | P1 |
| 1.12 | **`DOCKER_HOST` integration** | `export DOCKER_HOST=unix://$HOME/.keg/docker.sock` makes all Docker CLI commands route to KEG | P0 |

**Exit criteria:** `docker ps`, `docker run -d -p 8080:80 nginx`, `docker exec -it <id> sh`, `docker pull`, `docker images` all work using standard Docker CLI pointed at KEG's socket.

---

### Phase 2 — Compose Support (Weeks 11–15)

**Goal:** Run multi-container applications from `docker-compose.yml` files.

| # | Feature | Description | Priority |
|---|---------|-------------|----------|
| 2.1 | **Compose file parser** | YAML parser for docker-compose.yml (v3.8+ spec), validate services, networks, volumes | P0 |
| 2.2 | **Service orchestration** | Start services in dependency order, health check gates, parallel startup where possible | P0 |
| 2.3 | **Project isolation** | Compose project scoping (`-p projectname`), labels for resource tracking | P0 |
| 2.4 | **Compose lifecycle** | `keg compose up`, `keg compose down`, `keg compose ps`, `keg compose logs`, `keg compose restart` | P0 |
| 2.5 | **Volume + network compose** | Named volumes, compose-defined networks, `depends_on` with condition | P1 |
| 2.6 | **Environment + `.env` files** | Variable substitution, env_file support, `.env` auto-loading | P1 |
| 2.7 | **Build in compose** | `build:` context in compose file, trigger image build before start | P2 |
| 2.8 | **Shared VM mode** | Optional mode where compose services share a single VM (like Docker) for lower overhead, using Containerization's `LinuxPod` API | P2 |

**Exit criteria:** A typical 3-service compose file (web + API + database) starts with `keg compose up -d`, services communicate, logs aggregate, `keg compose down` cleans up.

---

### Phase 3 — Kubernetes Integration (Weeks 16–24)

**Goal:** One-click Kubernetes cluster using Apple Containerization as the runtime, inspired by [willswire/cluster](https://github.com/willswire/cluster).

Reference: The `cluster` CLI uses `kubeadm` + `kindnet` inside a single Apple Containerization VM with a custom kernel.

| # | Feature | Description | Priority |
|---|---------|-------------|----------|
| 3.1 | **K8s node image** | Build/customize a lightweight Linux image with kubeadm, kubelet, kubectl, containerd (or direct Containerization shim), kindnet CNI | P0 |
| 3.2 | **Custom kernel for K8s** | Kernel with required features: iptables/netfilter, bridge, overlayfs, cgroups v2, veth devices — use Cluster's pre-built kernel or Containerization's kernel build system | P0 |
| 3.3 | **Cluster bootstrap** | Automate: create container VM → wait for boot → `kubeadm init` → install CNI → generate kubeconfig → copy to host | P0 |
| 3.4 | **Kubeconfig management** | Write kubeconfig to `~/.kube/keg/<cluster>.config`, merge into `~/.kube/config`, support multiple clusters | P0 |
| 3.5 | **Cluster lifecycle** | `keg k8s create`, `keg k8s stop`, `keg k8s start`, `keg k8s delete`, `keg k8s status` | P0 |
| 3.6 | **API server port forwarding** | Expose K8s API server (port 6443) from the container VM to the macOS host | P0 |
| 3.7 | **Multi-node clusters** | Support `--nodes N` to create multi-node clusters by booting multiple container VMs and joining them with `kubeadm join` | P1 |
| 3.8 | **Ingress support** | Optional nginx/traefik ingress controller, automatic `/etc/hosts` entries for `.test` domains | P1 |
| 3.9 | **Persistent volumes** | HostPath + local PV provisioner that maps to macOS directories shared via virtiofs | P1 |
| 3.10 | **Load balancer** | MetalLB or similar for `type: LoadBalancer` services with dedicated container IPs | P2 |
| 3.11 | **Helm integration** | `keg k8s helm install/upgrade/uninstall` wrappers or guide for using Helm with KEG kubeconfig | P2 |
| 3.12 | **Registry mirror** | Optional local registry cache for faster image pulls inside the cluster | P2 |

**Exit criteria:** `keg k8s create` → `kubectl get nodes` shows Ready → `kubectl apply -f deployment.yaml` works → pods get IPs → services reachable from host.

---

### Phase 4 — Native macOS GUI (Weeks 25–34)

**Goal:** Build a native SwiftUI application that provides the Docker Desktop dashboard experience.

| # | Feature | Description | Priority |
|---|---------|-------------|----------|
| 4.1 | **App skeleton** | SwiftUI macOS app with sidebar navigation, menu bar icon, system service management | P0 |
| 4.2 | **Container list view** | Table showing running containers: name, image, status, ports, CPU/memory usage, age | P0 |
| 4.3 | **Container detail view** | Logs (streaming), exec terminal, environment variables, mounted volumes, network info | P0 |
| 4.4 | **Image list view** | Pulled images with size, tags, creation date; pull/delete actions | P0 |
| 4.5 | **K8s dashboard** | Cluster status, nodes, pods (with status), deployments, services, configmaps/secrets viewer | P1 |
| 4.6 | **Resource monitor** | Real-time CPU/memory/disk charts per container and aggregate, using Containerization statistics API | P1 |
| 4.7 | **Settings pane** | CPU/memory limits, default kernel, DNS config, registry mirrors, auto-start on login | P1 |
| 4.8 | **Menu bar widget** | Quick status: running containers, K8s cluster state, CPU/RAM summary, start/stop controls | P1 |
| 4.9 | **Drag-and-drop deploy** | Drag a compose file or K8s manifest onto the app to deploy | P2 |
| 4.10 | **Notification center** | Container crashes, OOM events, K8s pod failures → macOS notifications | P2 |
| 4.11 | **Dark/light mode** | Native appearance support | P2 |
| 4.12 | **Terminal integration** | Built-in terminal tab using SwiftUI `TerminalView` or PTY wrapper for `keg exec` | P2 |

**Exit criteria:** A user can open KEG, see their running containers, click into one to see logs and exec a shell, pull new images, create/destroy a K8s cluster — all from the GUI without touching the CLI.

---

### Phase 5 — Build System & Advanced Features (Weeks 35–42)

**Goal:** Image building, Dockerfile support, and developer productivity features.

| # | Feature | Description | Priority |
|---|---------|-------------|----------|
| 5.1 | **Dockerfile parser** | Parse Dockerfile syntax (FROM, RUN, COPY, ENV, EXPOSE, WORKDIR, etc.) | P0 |
| 5.2 | **Build pipeline** | Execute Dockerfile steps inside container VMs, commit layer snapshots using EXT4 | P0 |
| 5.3 | **BuildKit-compatible builder** | Investigate using `apple/container`'s built-in builder (it has `Sources/ContainerBuild/` with BuildKit-compatible gRPC) | P0 |
| 5.4 | **Layer caching** | Cache build layers locally for fast rebuilds | P1 |
| 5.5 | **Multi-platform builds** | Use Rosetta 2 to build amd64 images on Apple Silicon (Containerization supports this natively) | P1 |
| 5.6 | **SBOM generation** | Generate Software Bill of Materials from built images | P2 |
| 5.7 | **Vulnerability scanning** | Integrate Grype or Trivy for image scanning | P2 |
| 5.8 | **Dev environments** | `keg dev start` that creates a container with source code mounted, hot-reload, port-forwarding | P2 |

---

### Phase 6 — Polish & Distribution (Weeks 43–48)

**Goal:** Production readiness, installer, documentation, community building.

| # | Feature | Description | Priority |
|---|---------|-------------|----------|
| 6.1 | **Signed + notarized DMG** | Apple Developer ID signing, notarization, drag-to-Applications installer | P0 |
| 6.2 | **Homebrew formula** | `brew install keg` distribution via Homebrew Cask | P0 |
| 6.3 | **Auto-update** | Sparkle framework or similar for in-app updates | P1 |
| 6.4 | **Docker Desktop migration guide** | One-page guide: uninstall Docker Desktop → install KEG → `docker context create keg` → done | P0 |
| 6.5 | **Documentation site** | MkDocs or similar with API reference, CLI reference, tutorials, architecture docs | P0 |
| 6.6 | **First-run wizard** | Guided setup: check macOS version → install container CLI → start system service → pull test image → verify | P1 |
| 6.7 | **Diagnostics** | `keg doctor` command that checks all prerequisites and common issues | P1 |
| 6.8 | **Uninstaller** | Clean uninstall script that removes all KEG data, container data, kubeconfig entries | P0 |
| 6.9 | **Performance benchmarks** | Automated benchmark suite comparing against Docker Desktop (startup, pull, run, compose, K8s) | P1 |

---

## 4. Technical Deep Dives

### 4.1 Docker API Compatibility Strategy

The Docker Engine API is a RESTful HTTP API served over a Unix socket. The key endpoints to implement (based on [gocker's route map](https://github.com/lunguini/gocker)):

```
Core endpoints (P0):
├── GET  /_ping                          # Health check
├── GET  /version                        # Version info
├── GET  /info                           # System info
├── GET  /events                         # Event stream (SSE)
├── Containers
│   ├── GET    /containers/json          # List
│   ├── POST   /containers/create        # Create
│   ├── POST   /containers/{id}/start    # Start
│   ├── POST   /containers/{id}/stop     # Stop
│   ├── POST   /containers/{id}/kill     # Kill
│   ├── DELETE /containers/{id}          # Remove
│   ├── GET    /containers/{id}/json     # Inspect
│   ├── GET    /containers/{id}/logs     # Logs (streaming)
│   ├── POST   /containers/{id}/exec     # Create exec
│   └── POST   /exec/{id}/start          # Start exec
├── Images
│   ├── GET    /images/json              # List
│   ├── POST   /images/create            # Pull
│   ├── DELETE /images/{name}            # Remove
│   └── GET    /images/{name}            # Inspect
├── Networks (P1)
│   ├── GET    /networks                 # List
│   ├── POST   /networks/create          # Create
│   ├── DELETE /networks/{id}            # Remove
│   ├── POST   /networks/{id}/connect    # Connect container
│   └── POST   /networks/{id}/disconnect # Disconnect container
└── Volumes (P1)
    ├── GET    /volumes                  # List
    ├── POST   /volumes/create           # Create
    ├── DELETE /volumes/{name}           # Remove
    └── GET    /volumes/{name}           # Inspect
```

**Implementation approach:** Build a Swift HTTP server (using `Hummingbird` or `Vapor`) that translates Docker API requests into Apple Container XPC calls. The `gocker` project proves this mapping is viable — they use Go, but the same translation layer works in Swift.

### 4.2 Kubernetes Architecture

Based on [willswire/cluster](https://github.com/willswire/cluster)'s proven approach:

```
┌─────────────────────────────────────────────────────┐
│                    macOS Host                        │
│                                                      │
│  ┌───────────┐  ┌───────────┐  ┌─────────────────┐ │
│  │ kubectl   │  │  KEG GUI  │  │ kubeconfig      │ │
│  │ (host)    │  │  K8s view │  │ ~/.kube/config  │ │
│  └─────┬─────┘  └─────┬─────┘  └────────┬────────┘ │
│        │               │                  │          │
│        └───────────────┼──────────────────┘          │
│                        │ :6443                       │
│         ┌──────────────┴──────────────┐              │
│         │   Apple Containerization    │              │
│         │   Network (bridged)         │              │
│         └──────────────┬──────────────┘              │
│                        │                              │
│  ┌─────────────────────┴──────────────────────────┐  │
│  │         Container VM (K8s Node)                 │  │
│  │  ┌──────────────────────────────────────────┐  │  │
│  │  │  kube-apiserver :6443                    │  │  │
│  │  │  kube-controller-manager                │  │  │
│  │  │  kube-scheduler                         │  │  │
│  │  │  etcd                                   │  │  │
│  │  │  kubelet                                │  │  │
│  │  │  kube-proxy                             │  │  │
│  │  │  kindnet (CNI)                          │  │  │
│  │  │  containerd (inner runtime)             │  │  │
│  │  └──────────────────────────────────────────┘  │  │
│  │  Custom kernel (netfilter, bridge, cgroups v2) │  │
│  └────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Key decisions:**

1. **Single-node first:** Use `kindest/node` image with kubeadm init (proven by `cluster` CLI)
2. **Inner runtime:** The K8s node VM runs `containerd` internally — pods are process-isolated within the VM. Future: explore a Containerization-native CRI shim.
3. **Custom kernel:** Required for iptables, bridge, overlayfs, cgroups v2. The `cluster` project provides a pre-built kernel.
4. **Networking:** Container VM gets a dedicated IP via Containerization's network service. K8s API port 6443 is forwarded to host.
5. **Multi-node:** Each additional node is another container VM, joined via `kubeadm join`.

### 4.3 Port Mapping Challenge

Docker Desktop uses `-p hostPort:containerPort` with iptables DNAT inside its shared VM. Apple Containerization gives each container its own IP, so containers are *directly reachable* without port mapping.

**Strategy:**
- **Default:** No port mapping needed — containers are accessible at their dedicated IPs
- **Compatibility mode:** For Docker API compat, implement a lightweight TCP proxy on the host that forwards `localhost:hostPort` → `containerIP:containerPort`
- **Long-term:** Encourage users to use direct container IPs (better security model, no port conflicts)

### 4.4 Build System

`apple/container` already includes a [builder](https://github.com/apple/container/tree/main/Sources/ContainerBuild) with:
- BuildKit-compatible gRPC interface
- Filesystem sync (BuildFSSync)
- Remote content proxy
- Terminal command execution

**Strategy:** Consume the existing builder rather than building from scratch. Expose via `keg build` CLI and `POST /build` API endpoint.

---

## 5. Technology Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| **GUI** | SwiftUI (macOS 26+) | Native performance, menu bar support, dark mode, accessibility |
| **Core logic** | Swift 6 (strict concurrency) | Same language as Containerization framework, type-safe |
| **HTTP API server** | Hummingbird 2.x | Lightweight async HTTP server in Swift, Unix socket support |
| **Container runtime** | apple/container (XPC client) | First-party, hardware-isolated, sub-second starts |
| **K8s bootstrap** | kubeadm + kindnet | Proven by cluster CLI, standard tooling |
| **Compose parser** | Yams (Swift YAML) + custom logic | Swift-native YAML parsing |
| **CLI** | ArgumentParser (Swift) | Apple's recommended CLI framework |
| **Persistence** | SQLite via GRDB.swift | Container state, settings, image cache metadata |
| **Networking** | ContainerizationNet + Network.framework | Dedicated IPs, DNS, virtio networking |
| **Logging** | Apple Unified Logging (os.Logger) | Native macOS logging, Console.app integration |
| **Testing** | Swift Testing + XCTest | Unit + integration tests |
| **CI** | GitHub Actions | Build, test, sign, notarize |

---

## 6. Project Structure

```
keg/
├── Package.swift                    # SPM manifest
├── Sources/
│   ├── KEGApp/                      # SwiftUI macOS app
│   │   ├── KEGApp.swift
│   │   ├── Views/
│   │   │   ├── ContainerListView.swift
│   │   │   ├── ContainerDetailView.swift
│   │   │   ├── ImageListView.swift
│   │   │   ├── K8sDashboardView.swift
│   │   │   ├── ComposeView.swift
│   │   │   └── SettingsView.swift
│   │   ├── ViewModels/
│   │   │   ├── ContainerVM.swift
│   │   │   ├── ImageVM.swift
│   │   │   └── K8sVM.swift
│   │   └── MenuBar/
│   │       └── MenuBarController.swift
│   ├── KEGCore/                    # Business logic (no UI)
│   │   ├── ContainerManager.swift
│   │   ├── ImageManager.swift
│   │   ├── NetworkManager.swift
│   │   ├── VolumeManager.swift
│   │   ├── ComposeOrchestrator.swift
│   │   ├── K8sClusterManager.swift
│   │   └── SystemManager.swift
│   ├── KEGAPI/                     # Docker-compatible REST API
│   │   ├── APIServer.swift
│   │   ├── Routes/
│   │   │   ├── ContainerRoutes.swift
│   │   │   ├── ImageRoutes.swift
│   │   │   ├── NetworkRoutes.swift
│   │   │   ├── VolumeRoutes.swift
│   │   │   └── SystemRoutes.swift
│   │   └── DockerTypes.swift       # Docker API JSON models
│   ├── KEGCLI/                     # CLI interface
│   │   ├── KEGCLI.swift
│   │   ├── RunCommand.swift
│   │   ├── ComposeCommand.swift
│   │   ├── K8sCommand.swift
│   │   └── SystemCommand.swift
│   ├── KEGCompose/                 # Compose file handling
│   │   ├── ComposeParser.swift
│   │   ├── ComposeProject.swift
│   │   └── ComposeTypes.swift
│   └── KEGXPCClient/               # Apple Container XPC bridge
│       ├── XPCContainerClient.swift
│       ├── XPCNetworkClient.swift
│       └── XPCImageClient.swift
├── Tests/
│   ├── KEGCoreTests/
│   ├── KEGAPITests/
│   ├── KEGComposeTests/
│   └── IntegrationTests/
├── docs/
│   ├── architecture.md
│   ├── docker-compat.md
│   ├── kubernetes.md
│   └── migration-guide.md
├── keg-k8s/                        # K8s node image build
│   ├── Dockerfile
│   └── kernel/
└── .github/
    └── workflows/
        ├── ci.yml
        ├── release.yml
        └── benchmark.yml
```

---

## 7. Key Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Containerization API breaking changes** (pre-1.0) | High | Medium | Pin to minor versions, abstract behind KEGCore interfaces |
| **macOS 26 requirement limits audience** | Medium | High | Accept as constraint; macOS 26 adoption will grow rapidly |
| **Port mapping perf overhead** (compat mode) | Medium | Low | Default to direct-IP mode, proxy only for Docker compat |
| **K8s node image maintenance burden** | Medium | Medium | Start from kindest/node (actively maintained), automate rebuilds |
| **Docker API surface too large** | Medium | Medium | Implement P0 endpoints first, expand based on user demand; gocker proves subset works |
| **Multi-node K8s networking complexity** | Medium | Medium | Ship single-node first, multi-node as P1 feature |
| **Container system service conflicts** | Low | High | KEG manages the `container system start/stop` lifecycle explicitly |
| **Apple Silicon only (no Intel)** | Low | Low | Accept — Apple Containerization requires Apple Silicon |

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Container cold start | < 500ms (matching bare `container run`) |
| Docker API compatibility | > 90% of `docker` CLI commands work unmodified |
| K8s cluster create time | < 90 seconds |
| App binary size | < 50 MB |
| Idle memory footprint | < 100 MB (no containers running) |
| Homebrew installs in first 3 months | > 5,000 |
| GitHub stars in first 6 months | > 2,000 |

---

## 9. Open Research Questions

1. **CRI shim for Containerization:** Can we build a CRI (Container Runtime Interface) plugin that uses Containerization directly, eliminating the need for containerd inside K8s node VMs? This would be the "holy grail" — pods as individual Apple VMs.

2. **Shared VM for compose:** Containerization has a `LinuxPod` API. Can compose services share a single VM with process-level isolation (Docker-like semantics) while maintaining the security model?

3. **Apple Container's APIServer:** `apple/container` includes an `APIServer` target (XPC-based). Should KEG use this directly instead of shelling out to the `container` CLI? The XPC route is cleaner but less documented.

4. **GPU passthrough:** Can Apple Containerization VMs access Metal/GPU for ML workloads? This would be a major differentiator over Docker Desktop.

5. **Filesystem performance:** virtiofs vs Docker Desktop's gRPC-FUSE for bind mounts — benchmark needed, as this is the #1 Docker Desktop pain point.

---

## 10. References & Sources

| Resource | URL |
|----------|-----|
| Apple Containerization (framework) | https://github.com/apple/containerization |
| Apple Container (CLI) | https://github.com/apple/container |
| WWDC25 "Meet Containerization" session | https://developer.apple.com/videos/play/wwdc2025/346/ |
| willswire/cluster (K8s on Containerization) | https://github.com/willswire/cluster |
| lunguini/gocker (Docker API compat) | https://github.com/lunguini/gocker |
| Apple Virtualization.framework docs | https://developer.apple.com/documentation/virtualization |
| Containerization API docs | https://apple.github.io/containerization/documentation/ |
| Container CLI docs | https://apple.github.io/container/documentation/ |
| Kind issue: Apple Containerization support | https://github.com/kubernetes-sigs/kind/issues/3958 |
| OrbStack architecture reference | https://docs.orbstack.dev/architecture |
| Docker Engine API reference | https://docs.docker.com/engine/api/ |
| Swift Static Linux SDK | https://www.swift.org/documentation/articles/static-linux-getting-started.html |
| Kata Containers kernel | https://github.com/kata-containers/kata-containers |

---

## 11. Suggested Working Name

**KEG** — Kubernetes Engine on Guest. 

Alternatives considered: `keg`, `cask`, `tun`, `grain`, `mash`. "KEG" is memorable, short, hints at containers (casks/kegs), and maps to the CLI command `keg`.
