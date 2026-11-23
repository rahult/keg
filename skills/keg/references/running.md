# Running what a project needs

What is yours and what is the person's (`keg whoami` must say `agent`):

| | an agent | a person |
|---|---|---|
| machines, sandbox | yes | yes |
| backing services (`keg backing ...`), your own | yes | all |
| `keg up` to `local`, `keg services`, `keg logs local-<service>` | yes | yes |
| `keg run`, `keg exec`, `keg compose`, `keg build`, volumes | refused | yes |
| `keg ports`, `keg stats`, `keg app show`, `keg needs`, secrets | refused | yes |

A refusal says `an agent credential cannot call ...`: do it the agent's way
below, or tell the person the command they can run. Do not look for
another way in.

## Databases and caches beside the project (backing services)

```sh
keg backing start db postgres:16 --port 5432 -e POSTGRES_PASSWORD=dev
keg backing start cache redis:7 --port 6379
keg backing logs db
keg backing ls
```

- Each answers at `localhost:<port>` from your machines and from the node,
  and nowhere else. Give the project its address as settings:
  `DATABASE_URL=postgres://postgres:dev@localhost:5432/postgres`,
  `REDIS_URL=redis://localhost:6379`.
- Give Postgres a few seconds: `keg backing logs db` says
  `ready to accept connections` when it is.
- What one holds goes when it is stopped (`keg backing stop db`).
- Keg keeps who started each. An agent sees, reads and stops only its
  own; a person's are not listed to it and are refused. A name someone
  else holds is refused: choose another.
- MCP: `keg_backing_start` (`name`, `image`, `port`, `env`),
  `keg_backing_logs`, `keg_backing_list`, `keg_backing_stop`.

Then run the project in its machine, with those settings:

```sh
keg machine shell web -- sh -c 'npm ci && DATABASE_URL=postgres://postgres:dev@localhost:5432/postgres REDIS_URL=redis://localhost:6379 nohup npm start > /tmp/app.log 2>&1 &'
keg machine shell web -- curl -s localhost:3000/
```

It answers at `localhost:3000` on the node. That is the address to show.

## A Compose file

`keg compose` is a person's. Do what the file says by hand: each database
or cache in it as a backing service on its own port, the app in a machine
with the settings pointed at `localhost`. Say that this is what you did,
and that the person can run the file itself with `keg compose up` in the
project's folder (and `keg compose down`). Then each service with a
published port gets a name, `<project>-<service>.keg.localhost`
(`visits-app.keg.localhost`); `depends_on` does not wait for a database to
be ready, so an app that exited is started again with `keg start <project>-<service>`.

## Names and ports

- A name is `http://<name>.keg.localhost` on the port the node serves names
  on. On a Mac that is normally 7380 (`keg vm status` says which it really
  got: another Keg or program may hold 7380); on a Linux node, the port
  kegd was started with `--names` on. Read the address Keg prints; never
  assume it.
- `<container>.keg.localhost`: the first port a container publishes.
  `<service>.keg.localhost`: a service in `local`.
  `<service>.<env>.keg.localhost`: a service in another environment.
- A machine has no name: its servers are at `localhost:<port>`.
- `keg services` shows each service's port, and `keg ps` says when a port
  does not reach this computer. `keg ports` (a person's) lists every port
  the node has open.
- `address already in use`: another program holds that port. Use another
  port; do not stop what holds it unless you made it.

## A service, with a name (keg up)

```sh
keg init
keg up
keg services
keg logs local-<service>
```

`keg init` writes a `keg.yaml`, `Dockerfile` and `.dockerignore` where
they are missing; check its `run.port` and `run.health`. `keg up` builds and
runs it in `local`, where it answers at `http://<service>.keg.localhost`
and on its port. A service runs in a container of its own: `localhost`
there is the service itself, so it cannot reach your backing services. A
database for it is `needs.db` in `keg.yaml`, and a release with a database
or secrets that an agent proposes waits for a person, even in `local`
(`references/release.md`).

## Containers, images, volumes: a person's

These are refused to an agent. When one is what the project needs, say so
and give the person the command:

- A container: `keg run --name app-db -p 127.0.0.1:5432:5432 -e POSTGRES_PASSWORD=dev postgres:16`.
  A port given without an address (`-p 5432:5432`) is open on every
  address of the node, to the network it is on; `127.0.0.1:` keeps it to
  the node. Then `keg logs app-db`, `keg exec app-db -- psql -U postgres`,
  `keg stop app-db`, `keg rm app-db`.
- An image: `keg build -t app .`; one that reads back wrong
  (`Bad message`, `I/O error`): `keg pull --fresh <image>`.
- Volumes: `keg volume ls`. Never ask for `keg volume rm` of a volume the
  person did not name.
- `docker` and `docker compose` work against Keg too (`keg docker env`
  prints the setting); never change the person's default Docker context.

## What runs, what it costs, cleaning up

```sh
keg machine ls
keg backing ls
keg services
keg ps
```

`keg stats` (a person's) shows processor and memory. Clean up what you made
when the task is done or the person asks: `keg machine rm`,
`keg backing stop`. Leave the rest. Freeing the node's disk (removing images, old releases,
build layers) is a person's to do: tell them what you saw.
