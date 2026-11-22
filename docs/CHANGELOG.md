# Changelog

## [0.10.0] — 2026-11-22

### Added
- **Work and gates.** `keg work new` begins a piece of work in a project, on a branch and in a worktree of its own; agents take it through build, test and ship in a machine of their own, and each stage keeps what it found as evidence. A gate waits for a person: `keg needs` lists what waits, `keg gate approve|reject` answers, and `keg work send-back` sends it back with what is to be changed. Nothing is merged until a person approves. An agent sees none of this and answers no gate.
- **A log of events.** Every change the node makes (work, stages, gates, evidence, change sets, services, apps, containers) is written as an event in the same transaction as the change. `keg events` reads it; `keg events failed`, `keg events retry` and `keg events timers` show what Keg's services have yet to do. The console and the Mac app have an Events page, and refresh when something happens.
- **App capabilities.** A `keg.yaml` with `app:` and `uses: [data, identity, events, jobs, realtime]` gives an app a database of its own in each environment, in which tenancy is the database's to keep: sign-in, sessions, organizations and members; events and jobs, at least once; and a realtime gateway that sends each subscriber what its user may read. `keg dev` runs one, `keg app ls|show|new|stop|org` looks after them, and `@keg/app` is the library.
- **Keg services.** Keg runs services of its own on the node, each in a container with a socket and grants of its own: the console, the checks that the test stage asks for, and the realtime gateway. `keg system ls`, `install`, `start`, `stop` and `rm` look after them.
- **Services from outside.** A folder with a `keg.service.toml` is installed with `keg system install <folder>`: a person is asked about each thing it asks for, in plain words, and it holds only what was allowed. It runs pinned by digest, behind walls: no capability, no network but its socket (or the public internet only, if that was asked and allowed), memory, processes and disk capped, a volume, secrets and ports only through bindings of its own, at most 16 connections and 8 requests at once. It can be told of events, write its own, set timers and hear an app's events. Building one from its folder on the node is off until a person turns it on with `keg system builds on`; off, a service names its image by digest (`image = "…@sha256:…"`). A node needs loop devices and `mkfs.ext4` (e2fsprogs) to run them; one without says so and refuses them alone. [PROTOCOL.md](PROTOCOL.md) is what such a service may rely on.
- **The console has two modes**, Containers and Builder, with a guide through both in ten steps; `keg example hello-keg` makes a small project to try them with.
- **The Mac app** has the same two modes and guide, and new sections: Needs you (pinned, with its count), Work with Approve, Send back and Reject at a gate, Keg services with the question of what each asks, Apps, and Events.
- **The source of the GPL and LGPL software in Keg**, the kernel and the Alpine packages of the Linux machine, is published with each release, as `keg-<version>-gpl-source-kernel.tar.xz` and `keg-<version>-gpl-source-packages.tar`.

### Changed
- What a request names as a number (a CPU limit, a timeout, a duration, a recipe's minutes) is refused or held at its most when it is too large to hold, never a panic; a release build checks every sum for overflow.
- A panic while the control database is held fails that request alone: the node goes on.
- **An app's own transactions left idle are ended.** The roles an app connects to its database as have `idle_in_transaction_session_timeout` set to 10 minutes: a connection left idle inside a transaction for that long is ended by Postgres, and its transaction rolled back. One left open would hold back that app's events.
- **A Dockerfile or `.dockerignore` larger than 1 MiB is refused**, before more of it is read, by every build: a service's, and a person's own `keg build`, `keg up` and `docker build` alike.
- **What a request sends is held to a size.** A request to the Keg API, the console or the Docker API whose body is JSON is read to 1 MiB (evidence, whose body is kept to 1 MiB and cut past that, to 8 MiB). A blob or a volume's contents sent to the node is written to disk as it arrives, up to 64 GiB; a build context or an archive sent into a container through the Docker API, up to 16 GiB. A request past its limit, whether it says so or turns out so, is answered 413 with a sentence that says the limit, and its connection is closed as soon as that answer is sent, so nothing more it sent is read, as a body or as a request.

### Fixed
- One request could make kegd, or `keg ui` and `keg files mount`, end: the HTTP library they use read what was left of a body it did not need into one buffer as large as the request said it was. It is changed so that it reads what is left a few KiB at a time, and closes the connection instead when more than 1 MiB is left.
- An app's events waited, and the relay that reads them dropped its connection and tried again, whenever two transactions that write were open at once past the last one to end.
- A container whose image names a user other than root could hang as its first process changed to that user, on a busy node, and then could not be stopped: it held the container's lock for ever. It now changes user by system calls of its own, and one that does not reach its command in 30 seconds is ended. This is in the agent that runs containers, and takes effect when the agent is started again (see below).

### Upgrading from 0.9.0
- **The agent that runs containers stays the old one** after an upgrade on a Linux node. The new kegd runs once kegd is restarted: after `keg update`, that is `sudo systemctl restart kegd`. The containers keep running in the old agent. Until it is started again, `keg ps` and `keg vm status` say so, and services from outside, kept volumes and walled containers are refused. `sudo systemctl kill kegd` starts it again (systemd starts kegd, with a new agent): every running container stops; Keg's services and machines start again, other containers do not. On a Mac, the app updates itself, but the Linux machine goes on running 0.9.0 until it is stopped: Stop Keg and then Start Keg in the app (or `keg vm stop` and `keg vm start`) runs 0.10.0 and its new agent. That stops every running container.
- **Walled containers** (a service from outside, and its build) are on a bridge of their own, `kegw0`, and the node keeps them from itself with rules that match only what comes in on that bridge. Nothing of it is made until the first walled container. Their range is 10.89.0.0/16, unless an address or route of the node's own overlaps it (a Podman network, say): then the first free of 10.90, 10.91 and 10.92.0.0/16, kept from then on in the agent's folder (`walled-range`). A node whose networks cover all four runs everything but walled containers.
- Building a service from its folder is off on every node, upgraded or new: `keg system builds on` turns it on where a person develops services.
- After an upgrade, `keg system ls` says the realtime service "asks for listens:app.bound too: keg system install realtime": it goes on running as before without it, `keg system install realtime` gives it (so that it is told when an app is bound), and it is safe to leave.

### Going back to 0.9.0
- First remove each service from outside with `keg system rm <name> --data`: its container, its volume, its filesystems and what its install brought to the image store go with it. 0.9.0 does not know them, and would leave them.
- Then, with kegd stopped, `sudo sh remove-walls.sh` takes away the walled bridge `kegw0`, its rules (IPv4, IPv6 and nft), the walled range's way out and the note of which range was chosen. The script is a file of the release. If kegd's `--root` is not `/var/lib/keg`, give that folder to the script: `sudo sh remove-walls.sh /srv/keg`.
- An app's database keeps the tables and functions its capabilities made (the `keg`, `keg_crypto` and `keg_horizon` schemas); 0.9.0 reads none of them, and they do no harm. The node's own database keeps the new tables beside the old, which 0.9.0 leaves alone.

## [0.9.0] — 2026-11-20

Keg is rewritten. The app that wrapped Apple's `container` tool is gone, and with it what was unreleased in it (managed agents, traces, Cooper, the app catalogue). In its place:

### Added
- **A runtime of Keg's own, in Rust.** It pulls, builds and runs OCI images itself, on Linux directly and on a Mac in a small Linux machine that boots in about a second and sleeps when idle. There is no Docker and no Apple `container` tool underneath.
- **The `keg` command**: containers, images, volumes, Compose files, machines (a Linux system to work in), a sandbox for trying code, `keg init` for setting a project up, `keg k8s` (one node of k3s), `keg migrate` from Docker Desktop, OrbStack or Colima, `keg files mount`, `keg update`.
- **Docker's API**, on a socket of its own: `docker`, `docker compose`, `docker build` with BuildKit on, `docker cp`, `docker push`, restart policies, UDP ports.
- **Services that move.** A `keg.yaml`, environments, releases and change sets with checks and approval, promotion of the exact image between nodes over mutual TLS, rollback, deploys with no gap, a shared Postgres, secrets.
- **Names and HTTPS.** `NAME.keg.localhost` for anything with a port; sharing through a server you run, with a Let's Encrypt certificate for each name.
- **For agents.** `keg agents`, `keg mcp`, and `keg agents --connect claude|codex|pi`; an agent's rights are held by the daemon.
- **A new Mac app**, in SwiftUI: changes to approve, services with rollback, containers with output, files, usage and a terminal, machines, images with a vulnerability check and a search of Docker Hub, volumes, environments and nodes, a menu bar item, settings for the Linux machine. It has the `keg` command and the Linux machine inside it, links the command onto the PATH, and follows the Mac's language, in fifteen.
- **The app, section by section.** An overview; containers that are filtered, searched, sorted, started again, restarted and removed several at a time, each with live charts, how it was made, output with a search and a level filter, files saved to Downloads and a command run in it; images with sizes, how each was built and the progress of a download; volumes made from the app; Kubernetes with its pods and services; sharing; a menu bar that lists what is running; a notification when a change starts to wait for approval; settings that point `docker` at Keg and import from another engine; and `keg://` links.
- **The web console, rebuilt** to the same breadth, with a command palette, keyboard shortcuts and a layout for any width.
- `keg start`, `keg restart`, `keg pause` and `keg resume`; `keg images` says each image's size.
- **Compose projects, builds and networks** in the app and the console: a project is started and stopped as one and its file changed and run again; each build is kept with what it said; networks are listed and removed.
- **A terminal in the app's window**, in a container's pane; a container's ports and variables changed from there; light or dark; a report to copy when something is wrong.
- **Twenty-three more languages** in the app: thirty-eight in all.
- `keg env rm` forgets an environment that has nothing in it, as do the app and the console. Its change sets stay on record.
- One service of a Compose project is started again and restarted by itself, and is still that service of the project.
- A build that fails is kept with the steps it got through.
- **Disk and network, charted** for each container beside processor and memory, and its own address told, in the app and the console.
- **Go to… (⌘K)** in the app: type part of a section's, container's, service's or image's name and go there.
- **The app's language, accent colour, lettering and text size chosen in its settings**, where they are not to be the Mac's. The size is followed by the sidebar, the lists, output and the terminal; small labels keep theirs.
- In the app: back and forward between sections (⌘[ and ⌘]), start, stop, restart and remove on each container's row, and each image marked by its letter and colour.
- **A running container's ports are changed without stopping it**, from the app and the console, where ports are all that change and it already has one open: it is the same container, with everything it has written.
- **A proxy for fetching images**: `keg vm start --proxy http://HOST:PORT`, or the app's Linux Machine settings. One that listens on the Mac itself is reached from the Linux machine too. On a Linux node, `KEG_PROXY` or `HTTPS_PROXY` in kegd's environment does the same. A password in the address is kept from containers and from other programs on the Mac.
- **The console, laid out as the Mac app is**: the same sidebar and sections, a toolbar with back and forward, the container list with the chosen container's charts, output, files and terminal below it, and Kubernetes pods and services.
- **The console as a service of the node.** `keg ui` now has Keg run its own console in a container (`keg-console`), made from the keg command itself with nothing fetched, and opens it at `console.keg.localhost` with a link that is the person's alone. It stays up until `keg ui --stop`. `keg ui --local` serves it from the command as before, as does a node that cannot run it.

### Changed
- **Requires macOS 15 or later** on Apple silicon (0.8 required macOS 26).
- The app updates itself as before, through the same feed; an installed 0.8 is offered 0.9. Containers, images and settings of 0.8 are not carried over: they belonged to Apple's `container` tool, which 0.9 does not use.

### Fixed
- A node with a public name did not answer at that name itself, only at the names under it, so whatever else held the port answered with a certificate of its own and browsers warned. The node now has a certificate for its own name and says there what it is.
- A certificate that could not be got for a share was not asked for again for six hours. It is now asked for after two minutes, then ten, then thirty.
- Asked plainly over HTTP, a node sent the visitor on to HTTPS at whatever host the request named. It now does so only for its own names.
- Two kegd on one machine that started their first containers at the same moment could both try to make the bridge, and one container failed with "File exists".
- `keg pause` returned before the kernel had stopped every process of the container.
- On a Mac, a build run within a second of a file being replaced (as an editor saves one) failed with "No such file or directory": the folder shared with the Linux machine went on naming the file that had been there. The build now waits that out.
- After Keg was restarted, sharing the same thing again through a node was refused: the node still held the name for the daemon that had gone. A share whose node has gone now gives its name up at once.

### Removed
- The 0.8 app and everything particular to it: Cooper, managed agents and traces, the app catalogue, Dev Containers, the health score, the embedded terminal, the `keg://` links and its own command-line client.
