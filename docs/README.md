# Keg Documentation

User documentation for Keg — a native macOS app for running containers with
Apple's Containerization framework.

These pages are the source of truth for the website and in-app help. They are
plain Markdown on purpose: copy a page as-is, or point the site generator at
this folder.

## Pages

| Page | Contents |
|------|----------|
| [Getting started](guide/getting-started.md) | Install, first launch, your first container |
| [Containers](guide/containers.md) | Run, start/stop, logs, exec, live stats, filters |
| [Images](guide/images.md) | Pull, inspect, delete, registry logins |
| [Building images](guide/builds.md) | Build from a Dockerfile, tags, platforms, cache |
| [Compose](guide/compose.md) | Run multi-container `docker-compose.yml` projects |
| [Kubernetes](guide/kubernetes.md) | Single-node cluster, kubeconfig, kubectl |
| [Docker compatibility](guide/docker-compatibility.md) | Point the `docker` CLI at Keg's socket |
| [Volumes, networks & ports](guide/volumes-networks-ports.md) | Persistent data, networks, published ports |
| [Cooper (on-device agent)](guide/cooper.md) | Ask/Execute modes, privacy model |
| [keg CLI](guide/keg-cli.md) | Companion command-line tool |
| [Settings](guide/settings.md) | Every tab and field explained |
| [Troubleshooting](guide/troubleshooting.md) | Runtime problems, diagnostics, recovery |

## Feature list

The canonical product feature inventory lives in
[FEATURES.md](FEATURES.md). Update it whenever a user-visible feature ships;
the website's feature grid is generated from it.

## Keeping this up to date

- User-visible feature shipped? Add a bullet to `FEATURES.md` and, if it
  needs explanation, a short section in the matching guide page.
- A control moved or was renamed? Update the Settings page — it documents
  every tab and field.
- Screenshots live with the website, not here; keep image references out of
  these pages so they stay reusable.
- `AGENTS.md` in the repository root is the *internal* architecture notes for
  contributors and coding agents — user-facing claims belong here, not there.
- The user-facing set is exactly: `README.md` (this file), `FEATURES.md`, and
  `guide/`. Other files in this folder (ARCHITECTURE, GTM-PLAN, WASM-*, …)
  are internal planning documents, not website content.
