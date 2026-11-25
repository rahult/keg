# Keg reference

What Keg does, command by command, and its limits. New to Keg? Start with [Getting started](GETTING-STARTED.md).

Keg builds images, runs containers and moves a service from one machine to another. It pulls and builds OCI images and runs them itself; there is no Docker or containerd underneath. On Linux it runs directly. On a Mac it runs inside a small Linux machine that `keg vm start` boots in about a second.

## Run it

**On Linux** (cgroup v2, root, and `ip` plus `iptables` or `nft` for container networking): put `keg`, `kegd` and `keg-agent` from the release's archive in `/usr/local/bin` and run `kegd`, as a systemd service where there is systemd. [Getting started](GETTING-STARTED.md#install) has the steps and the unit file.

```sh
sudo keg run -a --rm alpine:3.20 echo hello
```

**On Windows**, Keg runs in WSL2, which is Linux: install it there the same way, and use `keg` from the WSL shell. There is no Windows app; `keg ui` in WSL opens the console in your Windows browser. Turn systemd on in `/etc/wsl.conf` (`[boot]` / `systemd=true`) for the daemon to start by itself.

**On a Mac** (Apple silicon, macOS 15 or later): install the Keg app, which has the `keg` command and the VM inside it, and link the command from its settings.

```sh
keg run -it --rm alpine:3.20        # the VM starts by itself, in about a second
keg app                             # the Mac app
```

The VM starts when a command needs it and stays up until `keg vm stop`, which stops its containers and writes everything to disk first. Services that were deployed come back when it starts again. Its disk, logs and sockets are in `~/.keg/runtime`.

- **Ports** a container publishes, and ports services are reached on, are open on the Mac's `localhost`. So is whatever listens in a machine.
- **Names:** anything with a port opens by name, with no port to remember: `http://web.keg.localhost` for a container called `web`, `http://checkout.staging.keg.localhost` for a service in an environment. Over HTTPS too: `keg trust` adds Keg's certificate authority to your keychain, and that authority can vouch only for names ending in `.keg.localhost`.
- **Sleep:** with nothing running for a minute, the VM is paused and uses no processor. Any command, or a connection to one of its ports, wakes it at once. `keg vm start --idle-sleep 0` keeps it awake.
- **Intel images** (`linux/amd64`) run through Rosetta where the Mac has it: `keg run --platform linux/amd64 ...`, or by themselves when an image has no arm64 build. An image name holds one platform at a time: after pulling the Intel one, `keg pull NAME` brings the Mac's own back.
- **Folders:** `/Users` and `/Volumes` are visible to containers at the same paths, read-only. To let containers write to a folder, name it once: `keg vm share ~/Code/myproject`. It takes effect without restarting the VM and stays so when the VM restarts. Settings given to `keg vm start` are remembered; `--fresh` forgets them.

## What it does

**Containers**

```sh
keg run -a --rm alpine:3.20 echo hello
keg run --name web -p 8080:80 -v /srv/site:/usr/share/nginx/html:ro --memory 256m nginx:1.27
keg ps
keg logs -f web
keg exec web cat /etc/os-release
keg exec -it web sh                 # a shell in a running container
keg run -it --rm alpine:3.20        # a shell in a new one
keg ports                           # the ports this node has open, and the names that lead to them
keg stats                           # processor, memory and processes of what is running
keg ls web /etc                     # a running container's files, looked at from outside
keg cat web /etc/hostname
keg run -v data:/var/lib/data ...   # a named volume: storage that outlives the container
keg volume ls
keg volume export data -o data.tar  # and `keg volume import`, which is also how a Docker volume comes over:
docker run --rm -v data:/v -w /v alpine tar cf - . | keg volume import data
keg stop web && keg start web       # a container that has ended is started again
keg restart web
keg pause web && keg resume web     # held still: it keeps its memory and is given no processor
keg vm start --proxy http://localhost:3128   # on a Mac: images are fetched through a proxy (--no-proxy to stop)
keg stop web && keg rm web
```

`keg start` gives a container made through Docker's API the files it had; one made with `keg run` is run again as it was first asked for, under the same name, as a new container.

**Images**

```sh
keg build -t myapp:dev .            # from a Dockerfile, with a layer cache
keg pull redis:7
keg images                          # with what each takes to store
```

Images move as files in the standard archive format, which is also how one comes over from Docker:

```sh
docker save myapp:dev | keg load
keg save myapp:dev -o myapp.tar
keg search postgres                 # find images on Docker Hub
keg scan myapp:dev                  # known vulnerabilities in its Alpine, Debian or Ubuntu packages
```

`keg pull` and `keg run` show each layer arriving. `keg scan` sends the image's package names and versions to osv.dev, the open vulnerability database, and nothing else.

If Docker Hub limits your pulls, `KEG_DOCKER_MIRROR=mirror.gcr.io` in kegd's environment pulls its images from a mirror instead.

**Machines.** A Linux system to work in, kept until you remove it. What you install stays, across restarts too; your folders are in it at the same paths; a shell opens in the folder you are in; and what you start in it is on `localhost`.

```sh
keg machine create dev              # ubuntu:24.04 unless --image says otherwise
keg machine shell dev               # or: keg machine shell dev make test
keg machine ls
```

**Sharing.** Something running here, opened on another of your nodes, over the encrypted link the two already have. No service in between: the node that shows your work is one you run.

```sh
keg share web --via server          # prints server's address and the port it opened
keg share ls
keg share stop web
```

**Updating.** The Mac app updates itself, and the `keg` command inside it with it (Keg ▸ Check for Updates…). A `keg` installed by itself is updated by `keg update`, which replaces it with the latest release if there is a later one (`--check` only says). A release is an archive for each kind of computer and a `manifest.json` naming them and their SHA-256, published together (by default, looked for on the project's GitHub releases; `--from URL` or `KEG_UPDATE_URL` names another place). What arrives is checked against the manifest before anything is changed, and what is running is left running until its next start. Releases are not signed beyond that.

**Containers' files as a folder.** `keg files mount` shows the files of every running container in `~/Keg` on a Mac (or in a folder you name), in Finder and to every other program, for reading: each container is a folder. `keg files unmount` ends it. Nothing is copied; what is looked at is asked of the node then. Links show as empty files, and volumes are seen only through a container that has them mounted. It is served on this computer alone, under an address a web page cannot guess; other accounts on the same computer can find that address among the system's mounts while it is shown. On Linux it says the WebDAV address to mount instead.

**Kubernetes.** One node of k3s, in a privileged container, with the cluster's state in a volume:

```sh
keg k8s start                       # ready in seconds once the image is here; prints what to do next
keg k8s info                        # how to connect, at any time (--json for tools)
export KUBECONFIG=~/.keg/k8s/kubeconfig.yaml
kubectl get nodes                   # or, with no kubectl: keg k8s kubectl get nodes
kubectl port-forward service/web 8080:80      # a Service, at http://localhost:8080
keg k8s load app:1                  # an image Keg has, into the cluster's own store
keg k8s stop                        # what is in it is kept
keg k8s start --publish 8088        # from stopped: a LoadBalancer Service on 8088 at localhost:8088
keg k8s delete                      # the cluster and everything in it
```

The kubeconfig's context, cluster and user are all `keg`, so it sits beside other clusters (`KUBECONFIG=~/.kube/config:~/.keg/k8s/kubeconfig.yaml`, then `--context keg`); it is cluster-admin, written for you alone. The API is published on the node's loopback, on 6443 or, where something here already has that port, the next free one, which the kubeconfig and `keg k8s info` name. `keg k8s kubectl` runs kubectl in the cluster's container: at a terminal it is connected to it (`exec -it`, `logs -f`), a manifest on this computer is sent (`-f app.yaml`, or `-f -`), and `port-forward` is refused, since it would listen where nothing here reaches it. There is no ingress (ports 80 and 443 are for names here) and NodePorts are not published, so a Service is reached with `kubectl port-forward`, or with `--publish`. An image built or pulled by Keg is not in the cluster until `keg k8s load` puts it there; one tagged `latest` needs `imagePullPolicy: IfNotPresent`. `keg run --privileged` is what it rests on: a container with every capability and cgroups of its own, which only a person can ask for, and which can do to the node what root can; every `keg k8s` command is a person's. [KUBERNETES.md](KUBERNETES.md) is the full guide: connecting, running something, reaching it, images, storage, security and what is not there.

**Coming from Docker Desktop, OrbStack or Colima.** `keg migrate --from <docker context>` brings that engine's images and named volumes over, by asking it for them with the `docker` command (`--dry-run` says what would come; names after it bring only those). Nothing there is changed, and containers are not brought: start them again here from their Compose file.

**The Mac's SSH agent, in a container.** Off unless asked for: `keg vm start --ssh-agent` (after `keg vm stop`) lets a container that is given the socket use the agent of whoever started the VM. The keys stay on the Mac; `--no-ssh-agent` ends it.

```sh
docker run --rm -v /run/host-services/ssh-auth.sock:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent alpine/git ls-remote git@github.com:you/private.git
```

**HTTPS, here and for the world.** What `keg up` deploys answers on this computer at `https://SERVICE.keg.localhost` (in `local`; `SERVICE.ENV.keg.localhost` elsewhere), with a certificate from the node's own authority, which vouches for names under `keg.localhost` and nothing else; `keg trust` has this computer's browsers accept it. For the world, give a node you run a public name:

```sh
# on the server: *.apps.example.com points at it, ports 80 and 443 reach it
sudo kegd --listen 0.0.0.0:7480 --public-domain apps.example.com --acme-contact you@example.com
# on your computer, once: keg node add server https://server.example.com:7480 --invitation ...
keg share web --via server          # web is open at https://web.apps.example.com
```

Where something already has ports 80 and 443 on the server (a Kubernetes ingress, a load balancer), Keg listens elsewhere and is passed what arrives for its names: kegd's `--public-tls` and `--public-http` say where it listens, and `--public-port 443` the port the world uses. In front of it, route HTTP for its names to Keg and pass TLS through untouched, so the certificate is still Keg's own.

The node gets a certificate for each name from Let's Encrypt the first time it is shared (`--acme` names another authority, `--acme off` none), keeps it, and renews it while the name is in use. Until one arrives the node answers with a certificate of its own, which browsers will not accept. Plain HTTP is sent on to HTTPS. The share's port on the node is then closed to everyone but the node itself.

**Compose files**, run as written:

```sh
keg compose up                      # compose.yaml or docker-compose.yml here
keg compose down
```

**Tools made for Docker.** Keg answers Docker's API on a socket of its own, so `docker`, `docker compose` and whatever else speaks to Docker (editors, test libraries) can be pointed at Keg and left as they are. There is still no Docker underneath: the containers, images and volumes are Keg's, and show in `keg ps` and the console like any others.

```sh
keg docker use                      # docker talks to Keg from now on (a Docker context named keg)
eval "$(keg docker env)"            # or just in this shell
docker run --rm -p 8080:80 nginx
docker compose up -d                # health checks, depends_on, service names, volumes
docker exec -it web sh
```

The socket is `~/.keg/runtime/docker.sock` on a Mac and `docker.sock` in the data directory on Linux (`kegd --docker-socket PATH` puts it elsewhere). It is as good as root on the node, and only its owner can open it.

**Services that move.** A `keg.yaml` describes a service without anything specific to one environment:

```yaml
service: checkout
build: .
run:
  port: 8080
  health: /healthz
release:
  migrate: ["./bin/migrate", "up"]
needs:
  secrets: [STRIPE_KEY]
  db: { service: postgres, requires: ">=16" }
```

```sh
keg secret set STRIPE_KEY sk_test_... --service checkout
keg up                              # build, release, deploy to `local`

# On the server: kegd --listen 0.0.0.0:7340
#                keg env add staging          (waits for a person by default)
#                keg node invite laptop       (prints an invitation)
keg node add server https://server.example:7340 --invitation @invite.txt
keg env add staging --node server
keg env rm staging                  # forgets one that has nothing in it
keg secret set STRIPE_KEY sk_test_... --env staging --service checkout
keg promote checkout --from local --to staging
keg approve 1 --env staging         # or approve it in `keg ui`
keg rollback checkout --env staging
keg rm -f staging-checkout          # take the service out of staging altogether
```

**Deploys have no gap.** A service that declares `run.port` is reached through a proxy on that port. A new release starts beside the old one, must pass its health check, and only then takes the traffic; the old one finishes what it has and stops. A release that fails never takes the port, and the old one carries on.

`promote` sends the exact image the source environment runs and never rebuilds; a release runs only the digest that was approved. Only the blobs the target lacks are transferred. Nodes talk over mutual TLS: each listening node is its own certificate authority and an invitation is a certificate it signed.

**Shared services.** `needs.db` gives the service its own database and role in the node's one Postgres server, per environment, and a `DATABASE_URL`. Secrets are per environment and encrypted with the node's key. Data never moves with a release; a person moves it:

```sh
keg data copy checkout --from production --to local
```

**The app and the console.** On a Mac, `keg app` opens the Keg app. The app and the console have two modes: **Containers**, with the sections below that run things, and **Builder**, which has everything and leads with Needs you, Work, Apps, Keg services and Events; a guide in ten steps goes through both, and **M** switches. In Containers it opens on an overview: what is waiting for approval, what is running, and what the Linux machine is using. Its sections are changes, with what would change and the checks they passed, and Approve and Reject; services, opened by name, with a rollback to the release before; containers, filtered, searched and sorted, started, stopped, paused, restarted and removed one or many at a time, each with live charts of what it is using, how it was made, its output (searched, and filtered by level), its files (saved to Downloads), a terminal in the window, and its ports and variables changed by running it again; Compose projects, started and stopped as one, with the file each was run from; builds, each kept with what it said; networks; machines; images, with their sizes, how each was built, a check for known vulnerabilities, and a search of Docker Hub with the download's progress; volumes; Kubernetes, started and stopped, with its pods and services; environments and the other nodes; and what is shared. It sits in the menu bar with what is running and the number of changes waiting, and says so as a notification when a change starts to wait. Its settings set the VM's processors, memory and writable folders, point `docker` at Keg and import from another engine, link the `keg` command onto the PATH, and say how it updates itself. A link such as `keg://containers/web/output` opens it on a section or a container. It follows the Mac's language, in thirty-eight: English, Simplified and Traditional Chinese, Japanese, Korean, German, French, Spanish, Italian, Brazilian and European Portuguese, Polish, Russian, Ukrainian, Bulgarian, Czech, Slovak, Croatian, Hungarian, Romanian, Greek, Turkish, Dutch, Swedish, Danish, Norwegian, Finnish, Catalan, Arabic, Hebrew, Persian, Hindi, Bengali, Tamil, Thai, Indonesian, Malay and Vietnamese. The translations were machine-made and are checked for completeness and for their blanks; they have not been read by native speakers, so corrections are welcome; messages that come from the node, and the `keg` command, are in English. `keg ui` opens a web console with the same things in it, on any machine: changes to approve, services, containers with their output, files and usage, machines, images with the vulnerability check and the search, volumes and environments.

**Writable folders on a Mac.** Each folder shared for writing has a device of its own in the VM, twelve in one run of it; the six most lately shared are given when the VM starts, and the rest when they are next asked for. When all twelve are taken, a new folder takes the device of one that has since been deleted. A published port also listens on the IPv6 address that goes with its IPv4 one, since `localhost` means the IPv6 loopback first to many programs.

**Looking after images.** `keg rmi NAME` forgets an image by name; a name a release or a machine is held to is refused, there and through the Docker API. `keg pull --fresh IMAGE` fetches and unpacks again an image whose files read back wrong. The VM looks its data disk over each time it starts. An image that lists the same layer twice runs. A Compose file's `build.target` and `build.labels` are honoured.

**Trying some code.** `keg sandbox python -- python -c "print(6 * 7)"` runs a command in a container made for it and removed after; the first word is a language (python, node, ruby, bun, go, rust), a system or any image, and a program on standard input is run by that language. The folder it is started in is there to read and cannot be changed.

**Setting a project up.** `keg init` writes a `keg.yaml`, a `Dockerfile` for the kind of project it finds (Node.js, Bun, Deno, Python, Ruby, PHP, Go, Rust, Java with Maven or Gradle, .NET, or a static site; the Python one is built and run by the tests, and each of the others was built, deployed and fetched from by hand on 2026-11-18) and a `.dockerignore`, where they are missing, and says where each of the twelve factors stands: settings and `PORT` from the environment, a database as `DATABASE_URL` (`--db`), releases that are never changed, logs to standard output.

**Agents.** `keg agents` prints how an agent gets somewhere to build and run a project: a machine for the project's folder (`keg machine create`, `keg machine shell NAME -- command`), with that folder writable in it and nothing else of the computer; servers started in it answer on localhost. It is short enough to be read at the start of every piece of work, or kept in a project's AGENTS.md; `keg agents --skill` prints it as a skill, and `keg agents --setup` says how to connect Claude Code, Codex, Pi and others, and `keg agents --connect claude|codex|pi` does it in that agent's own settings. Through `keg mcp` an agent has the same as tools (`keg_sandbox`; `keg_machine_create`, `keg_machine_run`, `keg_machines`, `keg_machine_remove`; `keg_backing_start`, `keg_backing_list`, `keg_backing_logs`, `keg_backing_stop` for a database or cache beside a machine; `keg_init`), held by the daemon to machines of its own, each in a folder under a directory given to agents with `--agent-workspace`; a person's machines it can neither see nor use. **Agents.** `keg mcp` is a Model Context Protocol server. It connects to a second socket (beside the data directory: `/var/lib/keg-agent.sock`) on which the daemon gives every caller an agent's rights: read state; build and deploy a service from a directory the node has given to agents (`kegd --agent-workspace DIR`, or `keg vm start --agent-workspace DIR` on a Mac); read the logs of services that hold no secrets, in environments that apply automatically; and propose releases on that node. A release that needs secrets or a database always waits for a person, even in `local`. There is no way to approve, set or read a secret, run an arbitrary container, name an image, or copy data from it. For an agent on another machine, `keg node invite NAME --agent` issues an invitation with the same limits.

```json
{ "mcpServers": { "keg": { "command": "keg", "args": ["mcp"] } } }
```

**Work and gates.** `keg work new --title ... --brief ...` begins a piece of work in a project (a git repository), on a branch and in a worktree of its own; agents take it through build, test and ship in a machine of their own, and each stage keeps what it found as evidence. A gate waits for a person: `keg needs` lists what waits, `keg gate approve|reject ID` answers, and `keg work send-back ID --note ...` sends it back with what is to be changed. Nothing is merged until a person approves. `keg work ls`, `show`, `stop` and `retry` follow it. An agent sees none of this and answers no gate.

**Events.** Every change the node makes is written as an event in the same transaction as the change. `keg events` reads them (`--follow`, `--type work.changed`); `keg events failed`, `keg events retry DELIVERY` and `keg events timers` show what Keg's services have yet to do. [PROTOCOL.md](PROTOCOL.md) is the shape of an event and a delivery.

**Apps.** A `keg.yaml` with `app:` and `uses: [data, identity, events, jobs, realtime]` gives an app a database of its own in each environment, in which tenancy is the database's to keep: sign-in, sessions, organizations and members; events and jobs, at least once; and a realtime gateway that sends each subscriber what its user may read. `keg app new NAME` makes one to start from, `keg dev` runs it, and `keg app ls|show|stop|org` look after them. The roles an app connects as end a transaction left idle for 10 minutes.

**Keg services.** Keg runs services of its own on the node, each in a container with a socket and grants of its own: the console, the checks the test stage asks for, and the realtime gateway. `keg system ls`, `install`, `start`, `stop` and `rm` look after them. A folder with a `keg.service.toml` is a service from outside: `keg system install <folder>` asks a person about each thing it asks for, in plain words, and it holds only what was allowed. It runs pinned by digest, behind walls: no capability, no network but its socket (or the public internet only, if that was asked and allowed), memory, processes and disk capped, a volume, secrets (`keg system secret`) and ports only through bindings of its own, at most 16 connections and 8 requests at once. It can be told of events, write its own, set timers and hear an app's events. Building one from its folder on the node is off until a person turns it on with `keg system builds on`; off, a service names its image by digest (`image = "…@sha256:…"`). A Linux node needs loop devices and `mkfs.ext4` (e2fsprogs) to run them; one without says so and refuses them alone.

## How fast

Measured on an Apple silicon Mac, through the `keg` command, VM included:

| | |
|---|---|
| Start a container (`keg run alpine true`) | about 4 ms |
| Run one, wait for it, remove it (`keg run -a --rm alpine true`) | about 5 ms |
| The same with its own address and a published port | about 6 ms |
| From nothing: boot the VM and run the first container | about 0.9 s |
| Wake a sleeping VM and run a container | about 45 ms |

Against Docker (29.2 on Colima, the same Mac, both warm), with the same `docker` client talking to each, so that what differs is the engine. Medians:

| | Keg | Docker | |
|---|---|---|---|
| Run a container to its end (`docker run --rm alpine true`) | 21 ms | 174 ms | 8 times faster |
| Start one in the background (`run -d`) | 13 ms | 94 ms | 7 times |
| Stop and remove it (`rm -f`) | 11 ms | 92 ms | 8 times |
| Start a web server until it answers on a port | 30 to 120 ms | 146 ms | the higher figure is for a port the Mac has not forwarded before |
| Run a command in a running container (`exec`) | 12 ms | 29 ms | 2.4 times |
| List containers (`ps -a`) | 10 ms | 22 ms | 2 times |
| Compose up: Postgres, wait until healthy, then a web server | 1.9 s | 1.9 s | the same: the database's own start is the time |
| Compose down | 135 ms | 370 ms | 2.7 times |
| Build an image, nothing cached (2000 files, a 32 MB context) | 1.0 s | 1.8 s | 1.9 times |
| Build it again, everything cached | 171 ms | 220 ms | 1.3 times |

About 10 ms of every Keg figure there is the `docker` client itself; Keg's own command does the first row in 5 ms. The memory each VM held on the Mac when this was measured was 110 MB for Keg's and 3 GB for Colima's, but Colima's had been up for hours of builds and Keg's for minutes, so that pair says little.

Most of this is the `keg` command itself starting; the node's part of a run is under a millisecond. A container that is thrown away does not have its changes forced to disk as it ends, which is where the time used to go. A container that keeps its changes (a machine, a build step) does.

## Limits to know about

- **A container made through the Docker API has its changes written to disk when it stops, not each time it asks.** That is what lets a database in one start in a second or two. If the node goes down while such a container is running, what it had changed is discarded and it starts again from its image; a named volume, and a machine, are written through as they ask. On a Mac the VM's disk is forced all the way to the drive on every sync; a lighter mode was tried for a day and given up when files in the VM read back wrong under it.
- **Containers are hardened, not a sandbox for hostile code.** A container's root has a reduced capability set, a system-call filter that refuses mounts, namespaces, kernel modules, ptrace, BPF and the like, and read-only kernel settings. There is no user namespace: root inside is still root's uid outside. For code you do not trust at all, the answer would be `isolation: vm`, which is not built.
- **Two environments on one node cannot give the same service the same port.** The port in `run.port` is the port on the node. A service with no `run.port` that listens on a port itself does not own that port; while it is down, another service that names the port can be given it.
- **Names** are served on ports 80 and 443 of the Mac when those are free, and on 7380 and 7443 always. On a Linux node they are served where `kegd --names 127.0.0.1:PORT` and `--names-tls` say. Until `keg trust` has been run, browsers warn about the HTTPS ones.
- **Scans** cover the system's own packages on Alpine, Debian and Ubuntu, not what an application installs with its language's package manager, and list advisories without ranking them. An image whose package list cannot be found is reported as not checkable, never as clean.
- **HTTPS names** go through a relay that closes a connection with nothing passing for a minute, and any connection after fifteen; long-lived ones such as WebSockets are better opened over plain `http://`.
- **Files** of a container can be looked at only while it is running, and not changed.
- **Machines** run as root, share the node's network, and are not yet a way to run another init system: services inside one are started by hand.
- **Sharing** through a node with no public name opens a plain TCP port on it: anyone who can reach that port reaches what is shared, unencrypted from them to the node. Through a node with a public name it is HTTPS by name, but still open to anyone who knows the name: there is no sign-in in front of a share. A name is proved to the certificate authority over port 80 only (no DNS proof, so no one certificate for every name). A connection lasts at most 15 minutes, and one with nothing passing for a minute is closed. Shares are forgotten when kegd restarts.
- **Sessions:** a session nobody reads from for 90 seconds is ended, with its command. If `keg` is killed during `keg run -it`, the container it started is left running; remove it with `keg rm -f`.
- **Withdrawing an invitation** (`keg node revoke NAME`) refuses its holder from the next connection on; a connection already open carries on until it closes. Certificates do not expire.
- **Dockerfiles:** `RUN --mount=type=cache`, `RUN` heredocs and `COPY --chmod` work. Other `RUN --mount` types, `COPY` heredocs, `ADD` from URLs or of archives, and `ONBUILD` are refused by name. Builds are for this machine's CPU only.
- **Ports** are TCP, or UDP where it says so (`-p 5353:53/udp`); nothing else. On a Mac a UDP port is carried into the VM over a stream, so it is on `localhost` only, and a caller quiet for a minute is forgotten.
- **Compose:** `restart`, `networks` and some other keys are accepted with a warning and have no effect; `privileged`, `secrets`, `configs` and external volumes are refused.
- **On a Mac,** a port below 1024 is opened on every address of the Mac, with callers from other machines turned away, because macOS allows nothing narrower; folders are read-only to containers unless shared with `keg vm share`; a restarted VM brings back deployed services, but not containers started by hand with `keg run` or Compose. The VM uses the Linux kernel that Apple's `container` tool uses, which is Kata Containers'.
- **The shared database** is one Postgres 16 per node, with no backups of its own and no scrub step on `data copy`.
- `keg run -it` needs a shell (`/bin/sh`) in the image, and the session keeps the terminal's size up to date about five times a second. `logs -f` polls.
- **Docker's API** covers what `docker` and `docker compose` use day to day: containers (run, start, stop, wait, logs, attach, exec, inspect, stats, files copied in and out, restart policies), images (pull, build, tag, remove), volumes and networks. `docker build` and Compose's `build:` work as they come, with BuildKit on: Keg answers the client in BuildKit's terms, fetches the files over the client's session and builds with its own builder, so nothing of BuildKit runs. That covers a Dockerfile in a directory, with build arguments, labels, a target stage and an ignore file. It does not cover building for another processor, pushing as part of the build, output to anything but an image, named extra contexts, secrets, or a context given as an address; each is refused in words. A build of a directory built before is sent only the files that have changed since. At most four builds fetch and build at once; a build has at most a million files and 16 GiB. `docker push` sends an image to the registry its name says, as whoever `docker login` signed in (and `docker pull` fetches as them). Not there: `commit`, `save` and `load`; pausing; UDP ports; privileged containers. A filter Keg does not apply to a list (for example `before` on images) is refused, never ignored: a tool that removes what it lists must not be handed everything. A folder of the Mac given to a container can be read but not written to unless it has been shared for writing: `keg vm share <folder>` does that while the VM runs, and `keg machine create` does it for the folder the machine is made in, and only folders under /Users and /Volumes can be given at all; both are said when the container is made. `docker cp` works on a running container only, and copies out trees up to 200 directories deep. A container that is started again, by a person or by its restart policy, finds its files as it left them, but its earlier output is not kept; if its image's name has come to mean another image, it starts afresh from that one. Events tell of containers being made, started, ended and removed, and of nothing else, and only from when they are listened for. `docker kill` with a signal other than KILL, TERM, INT or QUIT is sent by the `kill` command in the container's own image, to its first process. A Docker network is a list of containers that know each other by name, kept in each one's hosts file; they are not kept apart from containers on other networks. Output is one stream: what a container writes to its error stream arrives as ordinary output. After the machine restarts, containers that were running are listed as ended (code 255) and can be started; those with a restart policy of `always` or `unless-stopped` are started. A container with a terminal (`-t`) or open input (`-i`) needs `/bin/sh` in its image, and `/dev/tty` cannot be opened in it.
- Not built: the evals service, hosted agents, Apple containers (`isolation: vm`), WASM and Keg Cloud.
