# Keg Feature List

Canonical, user-visible feature inventory. One bullet per feature — keep it
current when a feature ships, changes, or is removed. Group order matches the
app: runtime foundation first, then the sidebar's Workloads → Content → System
→ Tools flow, then app-wide capabilities.

## Foundation

- **Native Apple containers** — runs containers on Apple's Containerization
  framework (the same engine as the `container` CLI), not a Linux VM
  emulation layer.
- **One virtual machine per container** — every container gets its own
  hardware-isolated VM via Apple's Virtualization.framework.
- **Apple Silicon, macOS 26 or later** — built for the modern Mac stack.
- **Automatic runtime management** — Keg starts and stops the container
  runtime for you, detects when it is unresponsive, and offers one-click
  recovery with diagnostics.
- **Per-machine data location** — choose where containers, images, volumes,
  and snapshots live (default `~/.container`), including dedicated volumes;
  a built-in check refuses to start against a missing volume.

## Containers

- Create, run, start, stop, restart, kill, and delete containers.
- Live list with status, image, CPU, memory, IP, and published ports.
- **Running / All filter** with an always-visible count of what is shown.
- Full-container **logs** with follow and tail.
- **Exec** into a running container, and **open a terminal** in it.
- **Live stats** per container (CPU %, memory) sampled every two seconds.
- Context menus for every lifecycle action, with destructive-action
  confirmation.
- **Auto-remove** support and stopped-container prune.

## Images

- Pull images from any registry, pinned to the host platform by default.
- Image list with digests; delete individual images.
- **Registry logins** (docker.io and others) with logout.
- Disk usage reporting via the system `df` view.

## Builds

- Build images from a Dockerfile with build context browser.
- Tags, build args, target platform, and disable-cache options.
- Streaming build output with a toolbar Build action.
- Builder resource defaults (CPUs, memory, Rosetta) configurable in Settings.

## Compose

- Run multi-container projects from a standard `docker-compose.yml`.
- Optional project name; dependency-ordered service startup.
- Start Services / Stop Services with streaming output.
- Per-service status and log links.

## Kubernetes

- **Single-node cluster** on a kindest/node-based Apple Container, bootstrapped
  with kubeadm.
- Create, start, stop, and delete the cluster from one screen with live
  bootstrap output.
- **kubeconfig written automatically** to `~/.keg/kubeconfig` — `kubectl`
  works without setup.
- Cluster name and node image configurable.

## Docker compatibility

- **Docker Engine API served on a Unix socket** (`~/.keg/docker.sock`) — the
  `docker` CLI, Compose, VS Code, and language SDKs work against Keg.
- One-click `export DOCKER_HOST=…` copy.
- Optional auto-start of the API server, and Keg launch-at-login.

## System resources

- **Networks** — list with subnets.
- **Ports** — every published port across running containers, searchable by
  container, port, or URL.
- **Volumes** — create, inspect, and delete named volumes that persist beyond
  a container's lifecycle.
- **Registries** — logged-in registries with login/logout.

## Tools

- **Embedded terminal** — a real terminal inside Keg, pre-configured with
  `DOCKER_HOST` and `KUBECONFIG`; presets for Terminal and iTerm.
- **Dev Containers** — open a project folder with a `.devcontainer/` and run
  it as a container.
- **Health dashboard** — per-container health scores (CPU + memory), an
  overall gauge, and a runtime panel: runtime status, effective data
  location, recent container-CLI activity, and one-click **Copy
  Diagnostics**.

## Cooper — the built-in agent

- **On-device agent** built on Apple's FoundationModels; requests never leave
  the Mac.
- Answers questions about Keg, containers, images, Compose, and the runtime —
  and can act on them.
- **Three permission modes**: Explore (read-only), Ask (confirms every
  change), Execute (autonomous for routine actions). Destructive actions
  always require approval in every mode.
- "Ask Cooper About This…" deep links on containers and images.
- Conversation persists on-device between launches; clear it any time from
  Settings → Cooper.

## App-wide

- **keg companion CLI** — `keg status`, `ps`, `images`, `logs`, `exec`,
  `start/stop/restart/rm`, `env`, `doctor`, and `keg open <section>` deep
  links, installed in one click from Settings.
- **Menu bar popover** — runtime status, running containers, quick actions.
- **Deep links** — `keg://containers`, `keg://logs`, and friends open the app
  on a specific section.
- **Experience levels** — Getting Started, Comfortable, and Full Control
  gradually reveal the full surface.
- **Settings in six tabs** — Keg, Apple Containers, Docker, Kubernetes,
  Cooper, and About; opens centered on the main window.
- **Automatic updates** via Sparkle, with manual check and automatic
  download/install options.
- **Launch at login**.
- **Unresponsive-runtime protection** — bounded operations, an honest
  "unresponsive" state instead of a frozen app, a diagnostics banner, and
  copyable triage reports.
