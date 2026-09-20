# Compose

The **Compose** section runs multi-container projects from a standard
`docker-compose.yml` — no Docker daemon required.

## Run a project

1. Sidebar → **Compose**.
2. **Compose File** — point at your `docker-compose.yml` (**Browse…**).
3. **Project** — optional name; it prefixes container names so multiple
   projects don't collide.
4. Toolbar → **Start Services**. Services start in dependency order and each
   one appears as a container in the Containers section.

## Stop a project

Toolbar → **Stop Services**. Containers for the project are stopped and
removed per the compose file's semantics.

## Reading the output

- **Services** — per-service state once the project is up.
- **Output** — the raw stream from Start/Stop; errors appear here first.

## Notes and limits

- The file must be a valid `docker-compose.yml`; parse errors are reported
  with the file and line where possible.
- Bind mounts resolve against the paths in the file, exactly like `docker
  compose`.
- Compose files that reference images not yet pulled will pull them on start.
