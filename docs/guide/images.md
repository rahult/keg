# Images

The **Images** section lists every image on the machine with its reference and
digest.

## Pull an image

Toolbar → **Pull…** (or the **Pull** field in the section header):

- Enter any registry reference — `docker.io/library/alpine:latest`,
  `ghcr.io/owner/image:tag`, …
- Pulls are pinned to the host platform (arm64) by default so unpacked disks
  stay small.

## Delete an image

Right-click an image → **Delete**, or select it and use the context menu.
Deleting removes the image's stored layers and frees disk space.

## Registry logins

Sidebar → **Registries** → **Login…**:

- Hostname (for example `ghcr.io`), username, and password/token.
- Credentials are stored by the container runtime; pull private images after
  logging in.
- Right-click a logged-in registry to copy its URL or log out.

## Disk usage

Sidebar → **Health → system `df`** (or the `keg` CLI) shows how much space
images, containers, and volumes occupy. Deleting unused images and stopped
containers is the fastest way to reclaim space; a stopped-container **prune**
is available in the Containers section.
