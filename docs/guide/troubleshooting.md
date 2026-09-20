# Troubleshooting

## The runtime looks unresponsive

When the container runtime stops answering, Keg shows an orange
**"Container runtime is unresponsive"** banner with three actions:

1. **Retry** — re-check the runtime now.
2. **Restart Services** — stops and starts the container system.
3. **Copy Diagnostics** — puts a triage bundle on your clipboard: live
   container processes, launchd service states, the configured data location,
   and Keg's recent container-CLI activity.

Paste the bundle into a GitHub issue if you need help.

Keg also stops polling a dead runtime every two seconds; it backs off to once
a minute until the runtime answers again.

## Containers are missing from the list

- Check the **Running / All** filter above the list — it says what is shown
  ("Showing 1 running of 65 containers").
- Check the **Data Location**: Settings → Apple Containers → Data Location
  shows the folder in effect. If a configured folder is missing (for example
  an external volume that isn't mounted), Keg shows a warning and will not
  start the runtime against it.
- If the running runtime uses a *different* root than configured, Keg shows a
  mismatch warning — restart services to apply your choice.

## `docker` CLI doesn't see Keg containers

The Docker API server must be running (**Settings → Docker**) and your shell
needs the socket:

```sh
export DOCKER_HOST=unix://~/.keg/docker.sock
```

Copy the exact command from Settings → Docker.

## A port isn't reachable

- Sidebar → **Ports** lists published ports for running containers.
- The container must be running, and the host port must be free.
- Reach the service on the *host* port from `localhost`.

## Keg says the data folder doesn't exist

The configured data location lives on a volume that isn't currently mounted
(for example an external disk). Mount the volume and press **Start System**,
or pick a different folder. Keg deliberately never starts an empty runtime
against a missing path — that would make your containers look deleted.

## Collecting diagnostics for a bug report

1. Settings → Apple Containers → Health → **Copy Diagnostics**.
2. Include the bundle in your issue alongside the Keg version
   (Settings → About).

## `keg` CLI can't find the app

`keg doctor` checks the installation: the CLI binary on your PATH, the Keg
app, and the socket. Reinstall the CLI from Settings → Keg → **Install** if
doctor reports it missing.
