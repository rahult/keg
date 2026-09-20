# Containers

The **Containers** section is the main workbench: every container on the
machine, its state, and its controls.

## The list

Each row shows the container's name, image, status, IP address, and published
ports. Rows refresh automatically every couple of seconds while containers
are running.

- **Running / All** — the toolbar segmented control limits the list to
  currently running containers. The subtitle always tells you how much of the
  dataset is on screen ("Showing 1 running of 65 containers").
- **Search** — filters by container name or image.

## Lifecycle

Select a container (or right-click it) for the full action set:

- **Start / Stop / Restart / Kill**
- **Delete** — with confirmation; enable auto-remove at run time to skip this
- **Open Terminal** — a shell inside the container
- **Logs** — follow the container's output
- **Exec** — run a one-off command inside it

## Run a container

Toolbar → **Run…** (or ⌘⇧N):

- **Image** — any registry reference, e.g. `docker.io/library/nginx:latest`
- **Name** — optional; Keg generates one when empty
- **Ports** — `host:container` pairs, e.g. `8080:80`
- **Environment** — `KEY=value` pairs
- **Remove on exit** — delete the container automatically when it stops
- **Resources** — CPU and memory overrides for this container

## Stats

While a container is running, Keg samples CPU and memory every two seconds.
Open a container's detail view for the live numbers.

## CLI equivalents

```sh
keg ps                # list containers
keg start <name>      # start
keg stop <name>       # stop
keg restart <name>    # stop + start
keg rm <name>         # delete
keg logs <name>       # stream logs
keg exec <name> sh    # run a command inside
```
