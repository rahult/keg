# Settings

Settings opens centered on the main window (⌘,) and is organised into six
tabs. Sections and fields that need the runtime show honest states — running,
stopped, or unresponsive — rather than blank values.

## Keg

- **Experience** — Getting Started, Comfortable, or Full Control; controls
  how much of the app is visible.
- **Terminal** — which terminal app one-click container shells open in.
- **Keg CLI** — install or remove the `keg` companion CLI.
- **Startup** — launch Keg at login (the Docker socket comes up with it).
- **Agents API** — cloud-agent credentials, when the agents surface is
  enabled.
- **Software Update** — automatic checks, frequency, automatic download and
  install.

## Apple Containers

Everything about the container runtime:

- **Container CLI** — install status and path of the `container` binary.
- **Container System** — runtime status with Start / Stop / Restart, plus
  runtime version.
### Data Location

Where containers, images, volumes, and snapshots live.
  Opens a folder browser; shows the resolved default
  (`/Users/you/.container (default)`) when nothing is set. Keg refuses to
  start against a folder that doesn't exist, and warns if the running runtime
  is using a different root.
- **Platform defaults** — grouped sliders and fields for new containers
  (CPUs, memory), builds (CPUs, memory, Rosetta, builder image), machines
  (CPUs, memory, home-mount policy, virtualization), and the registry domain.
  Slider ranges come from your hardware. **Changes save automatically** and
  apply to new containers, builds, and machines; **Revert** re-reads the
  saved configuration.
- **Storage Locations** — the resolved containers / volumes / images paths,
  each with a copy button.
- **Advanced (read-only)** — the pinned kernel and vminit images.
- **DNS Domains** — locally registered DNS domains.

## Docker

- Docker API compatibility server: status, socket path with copy buttons,
  Start/Stop, and auto-start.

## Kubernetes

Cluster status ("Not created", "Running", "Stopped"), Start/Stop shortcuts,
and pointers to the full Kubernetes section — create and delete live there,
where bootstrap output is visible.

## Cooper

- **Permission mode** — Explore / Ask / Execute, with a caption explaining
  what Cooper may do in each. Destructive actions always require approval.
- **Clear Conversation** — erases the on-device transcript.

## About

Version, runtime, requirements, and license.
