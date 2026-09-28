---
name: keg
description: Run any local codebase as containers on macOS with Keg (Apple container microVMs). Use when the user wants to containerize, run, test, or serve a local repo — write a keg.yaml, `keg project up`, verify with status/logs/curl, iterate, then `keg project down`. Also use for databases (`keg db ensure postgres --database <app>` → connection URL for code running on the Mac), questions about the keg CLI, Keg the macOS app, or Apple's `container` runtime.
---

# Keg — container infra for local repos

Keg is a macOS app wrapping Apple's `container` runtime: **one lightweight
microVM per container**, Apple Silicon only, images must be `linux/arm64` or
multi-arch (amd64 runs under Rosetta where available). A repo declares its
infra in a `keg.yaml`; the `keg` CLI turns it into running containers — no
Docker Desktop, no daemon of its own.

## Prerequisites (check first)

- `keg status` — Keg app running + Docker-compatible socket answering. If it
  says "Keg is not running", run `keg open` and retry after a few seconds.
- `keg doctor` — deeper diagnostics when something feels off.
- Everything goes through Keg's socket (`~/.keg/docker.sock`). The `docker`
  CLI also works against it (`eval "$(keg env)"`) but is NOT required.

## The workflow

1. **Survey the repo**: entrypoint, framework, listen port, external
   services (database, cache), any existing Dockerfile.
2. **Write `keg.yaml`** in the repo root (`keg project init` scaffolds one
   pre-detected for node/python/go/rust/swift/Dockerfile repos — then edit
   the TODOs it marks).
3. **`keg project up`** — builds (`build:`) or pulls (`image:`) each service,
   recreates + starts containers in `depends_on` order, waits until each is
   running, prints URLs. A container that exits during startup fails the `up`
   **with its log tail attached** — read it, fix the config or the command.
4. **Verify**: `keg project status` (add `--json` when scripting), then
   `curl http://127.0.0.1:<hostPort>/…`. `keg exec <container> <cmd>` runs
   commands inside a container.
5. **Iterate**: `keg project logs <service> [-f]`. Config changes need
   `keg project down && keg project up` (up recreates containers, so plain
   `up` re-applies config too — data in bind mounts/named volumes survives).
6. **Done**: `keg project down` — stops and removes the project's containers.
   Data always survives unless something deleted the bind-mount directory.

## keg.yaml reference

```yaml
name: my-project          # optional; defaults to the directory name
services:
  web:
    image: nginx:1.27     # EITHER image (pulled on demand)…
    build: .              # …OR build (Dockerfile context dir, built once,
    #   dockerfile: Containerfile   # tagged <name>-web:local, cached)
    #   args:
    #     FLAVOR: dev
    ports:
      - "8080:80"         # host:container (host port must be >1024)
      - "127.0.0.1:5432:5432"   # optional host-IP prefix
      - "5353:53/udp"     # protocols: tcp (default) or udp
    environment:
      - DATABASE_URL=${SUPABASE_URL}      # from shell env or repo .env
      - LOG_LEVEL=${LOG_LEVEL:-info}      # ${VAR:-fallback} supported
    env_file: ./secrets.env     # extra KEY=VALUE file → container env
    volumes:
      - ./data:/var/lib/app     # bind mount, anchored to the keg.yaml dir
      - cache:/var/cache        # named volume
    command: ["npm", "start"]   # runs via non-login `sh -c` with `exec`
    entrypoint: ["/app/entrypoint.sh"]  # override the image entrypoint
    workdir: /app
    platform: linux/arm64       # default; linux/amd64 uses Rosetta
    restart: unless-stopped     # always | unless-stopped | on-failure
    depends_on: [db]            # start ordering only — see "multi-service"
    labels:                     # free-form; Keg adds project/service labels
      team: platform
  db:
    image: postgres:17
    ports: ["5432:5432"]        # publish it so peers can reach it (below)
    environment:
      - POSTGRES_PASSWORD=${DB_PASSWORD:?is required}   # not supported —
      # provide a fallback or set the var; missing vars are hard errors
```

Rules that bite:

- Every service needs `image:` or `build:` (not both).
- Port strings must specify a **host port**; bare `"80"` is rejected.
- Host ports must be **>1024** (unprivileged).
- Missing `${VAR}` with no fallback is a hard error naming the field —
  put a `.env` in the repo (not committed) or export before running.
- Validation runs before anything starts: `keg project validate` checks the
  file standalone (also catches depends_on cycles).

## Multi-service reality (important)

Apple's runtime has **no inter-container DNS**: a container's `/etc/hosts`
resolves only itself, service names do NOT resolve, and published ports
listen on the **Mac's loopback only** — a container cannot reach another
container's published port, not even via `192.168.64.1` (verified live
2026-09-27). Practical consequences:

- `depends_on` only sequences starts; it creates no connectivity.
- Published ports are for processes on the Mac (your browser, curl,
  tests) — plain `127.0.0.1:<hostPort>`.
- Keep multi-service keg.yaml files to **independent services** (an app
  plus a tool, parallel workers). A server + database stack in one
  keg.yaml cannot connect over the network today — run the database as a
  separate project or on a host already reachable to you, and point the
  app at a host-side address.

## Databases: shared servers, many databases (preferred)

One container per engine — `kegdb-postgres`, `kegdb-mysql`, `kegdb-redis`
— hosts **many logical databases**, one per app. This is the default
pattern: you pay one microVM per engine, not one per project, and every
app still gets an isolated database. (`keg db remove` is the explicit
escape hatch; a `db:` service inside keg.yaml is for when a project
genuinely needs a dedicated container.)

```sh
keg db ensure postgres --database todo_app --user todoapp
# → creates the shared server on first call, the database and a
#   per-database login role inside it, then prints:
#   export DATABASE_URL='postgresql://todoapp:<pw>@127.0.0.1:5432/todo_app'

keg db list                     # servers, ports, and their databases
keg db url postgres todo_app    # reprint a connection URL
keg db run postgres -- psql -U keg -d todo_app -c '\dt'   # admin shell
keg db drop postgres todo_app   # evict clients + drop the database
```

- **`ensure` is idempotent** — safe to run at the start of every agent
  session; it creates only what's missing and reprints the URL.
- URLs are loopback (`127.0.0.1:<port>`): app code and migration tools
  run **on the Mac** (where agents work anyway) and reach the database
  directly. Do not try to reach a keg container from another container.
- Role passwords are generated (or `--password`) and printed once with
  the URL; the superuser record lives in `~/.keg/db/registry.json` and
  server data in the runtime volume `kegdb-<engine>-data` (survives
  `remove` unless `--delete-data`).
- Redis: no databases to create — `keg db ensure redis` starts the
  server; use URL path `/0`…`/15` for keyspaces.

Typical full-stack agent flow (e.g. a todo app):

1. `keg db ensure postgres --database todo_app --user todoapp` → URL.
2. Run the backend on the Mac with `DATABASE_URL` from step 1
   (`cd backend && npm run dev`) — hot reload works, DB is one hop away.
3. Frontend dev server likewise on the Mac; browsers hit both at their
   `127.0.0.1` ports.
4. Only services that need no peers (a CI worker, a one-off tool) go
   into `keg.yaml` as containers.

## Command quick reference

    keg project init [--force]      scaffold keg.yaml (stack-detected)
    keg project validate            parse + validate without starting
    keg project up [--build]        build/pull, recreate, start, print URLs
    keg project status [--json]     per-service state/ports/URLs
    keg project logs <svc> [-f]     service logs (stream with -f)
    keg project down                stop + remove this project's containers
    keg up / keg down / keg init    short aliases of the above
    keg db ensure <e> [--database]  shared DB server + database, idempotent
    keg db list | url | drop        inspect / reprint / remove databases
    keg db run <engine> -- <cmd…>   run a command in the server container
    keg db remove <engine>          remove the shared server (data kept)
    keg ps [-a] / keg images        raw container/image lists
    keg logs <container> [-f]       any container's logs (by name)
    keg exec <container> <cmd…>     run a command inside a container
    keg open [section]              open the Keg app at a section

Containers are named `<project>-<service>-1` and labeled
`com.docker.compose.project=<name>` — they appear grouped under the
project's name in the Keg app's Compose screen, where humans can watch logs
and stats for the same infra the CLI drives.

## Troubleshooting

- **"Keg is not running"** → `keg open`, wait, retry.
- **Container exits at startup** → the `up` failure includes a log tail;
  typical causes: wrong command for the image, missing env var, app
  crashes on missing config. `keg project logs <svc>` shows full logs.
- **Image pull fails / wrong arch** → pin `platform: linux/arm64` and use
  arm64 or multi-arch tags; x86-only images need Rosetta (`linux/amd64`).
- **"failed to find target executable X"** → the runtime resolves the
  process target before any PATH setup: the image's CMD/ENTRYPOINT must
  be an absolute path that exists (or override with `command:`/`
  entrypoint:` using absolute paths). Alpine busybox also lacks many
  applets (no httpd) — pick an image that actually ships the server.
- **Port already in use** → macOS owns the port; pick another host port.
- **Build fails** → builds run `container build` (linux/arm64). The
  `.dockerignore` is honored (approximated); huge contexts upload slowly —
  ignore `node_modules`, `.git`, build output.
- **First `up` is slow** → first-time image pulls and first-start image
  unpacking are one-time costs; later ups are fast.
