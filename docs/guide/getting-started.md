# Getting started

## Requirements

- Mac with Apple Silicon
- macOS 26 or later
- The Apple `container` CLI (Keg can install it for you)

## Install

1. Download `Keg.dmg` from the website (or the GitHub releases page) and drag
   **Keg** to **Applications**.
2. Launch Keg. The welcome sheet offers one-click quick starts.
3. If the Apple `container` CLI is not installed, Keg offers to install it —
   no admin rights needed for the default install.

## First launch

Keg starts the container runtime automatically and the sidebar shows the full
surface if you chose **Full Control** during the welcome. Choose a different
experience level any time:

- **Getting Started** — the essentials only.
- **Comfortable** — everyday sections.
- **Full Control** — every section and field.

You can change this in Settings → Keg → Experience, or replay the welcome
with **Show Welcome…**.

## Run your first container

1. Sidebar → **Containers** → **Run…** in the toolbar.
2. Pick an image (for example `docker.io/library/alpine:latest`), set ports or
   environment if you need them.
3. Press **Run**. The container appears in the list with a green *running*
   status.

## Where your data lives

Containers, images, volumes, and snapshots live under a single data folder —
`~/.container` by default. See [Settings](settings.md#data-location) to point
it at a different disk or volume.

## Next steps

- Point the `docker` CLI at Keg: [Docker compatibility](docker-compatibility.md)
- Run a Compose project: [Compose](compose.md)
- Ask the built-in agent: [Cooper](cooper.md)
