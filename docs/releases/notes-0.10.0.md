Keg 0.10.0 lets agents do work that a person approves, and runs services of Keg's own and from outside, each behind walls.

## New

- **Two modes and a guide.** The console and the Mac app have two modes, Containers and Builder, and a guide through both in ten steps. `keg example hello-keg` makes a small project to try them with.
- **Work, gates and Needs you.** `keg work new` begins a piece of work on a branch and in a worktree of its own. Agents take it through build, test and ship in a machine of their own, and each stage keeps what it found as evidence. A gate waits for a person: `keg needs` lists what waits, `keg gate approve` or `reject` answers it, and `keg work send-back` sends it back with what is to change. Nothing is merged until a person approves, and no agent can answer a gate.
- **Events.** Every change the node makes is written as an event, in the same transaction as the change. `keg events` reads them; `keg events failed`, `retry` and `timers` show what is left to do. The console and the app have an Events page and refresh when something happens.
- **App capabilities.** A `keg.yaml` with `app:` and `uses: [data, identity, events, jobs, realtime]` gives an app its own database in each environment: sign-in, sessions, organizations and members, events and jobs, and a realtime gateway that sends each user only what they may read. `keg dev` runs one, `keg app` looks after them, and `@keg/app` is the library.
- **Keg services.** Keg runs services of its own on the node, each in its own container with only what it is granted: the console, the checks the test stage asks for, and the realtime gateway. `keg system ls`, `install`, `start`, `stop` and `rm` look after them.
- **Services from outside.** `keg system install <folder>` installs a service that has a `keg.service.toml`. You are asked about each thing it wants, in plain words, and it gets only what you allow. It runs pinned by digest, behind walls: no network but its socket unless you allow the internet, and capped memory, processes, disk and connections. Building a service from its folder on the node is off until you turn it on with `keg system builds on`; until then a service names its image by digest. A Linux node needs loop devices and `mkfs.ext4` (e2fsprogs) to run them, and says so if it has none.
- **In the Mac app**: the two modes and the guide, and new sections: Needs you (pinned, with its count), Work with Approve, Send back and Reject, Keg services with what each asks for, Apps, and Events.
- **The source of the GPL software in Keg** (the Linux kernel and the Alpine packages in the Linux machine it runs on a Mac) is published with the release, in `keg-0.10.0-gpl-source-kernel.tar.xz` and `keg-0.10.0-gpl-source-packages.tar`.

## Fixed

- **A container could hang at start and then could not be stopped.** When an image runs its first process as a user other than root, the change to that user could hang on a busy node, and the container's lock was held for ever. Keg now changes user itself, and a container that does not reach its command in 30 seconds is ended. The fix is in the agent that runs containers, so it takes effect when the agent starts again. On Linux: `sudo systemctl kill kegd`. systemd starts kegd again with a new agent. Every running container stops; Keg's services and machines start again, other containers do not. On a Mac: Stop Keg, then Start Keg, in the app (or `keg vm stop` and `keg vm start`), which also stops every running container.
- **A request with an absurd declared length could stop the daemon.** The HTTP library Keg uses tried to read the rest of a body into one buffer as large as the request said. It now reads a few KiB at a time, and closes the connection when more than 1 MiB is left. Request bodies have limits now too, and a request over its limit gets a 413 that says the limit.

## Upgrading from 0.9.0

- **Linux.** After `keg update`, run `sudo systemctl restart kegd` to start the new daemon. Running containers keep running, in the old agent. Until that agent is started again (`sudo systemctl kill kegd`, above), `keg ps` and `keg vm status` say so, and services from outside, kept volumes and walled containers are refused.
- **Mac.** The app updates itself, but the Linux machine goes on running 0.9.0 until you stop it: Stop Keg, then Start Keg, runs 0.10.0.
- **Walled containers** (a service from outside, and its build) use a bridge of their own, `kegw0`, made only for the first one. Their range is 10.89.0.0/16, or the first free of 10.90, 10.91 and 10.92.0.0/16 if one of your own networks overlaps it. A node whose networks cover all four runs everything but walled containers.
- Building a service from its folder is off on every node, upgraded or new.
- `keg system ls` may say the realtime service "asks for listens:app.bound too": it runs as before without it; `keg system install realtime` gives it, and it is safe to leave.
- A connection an app leaves idle inside a transaction for 10 minutes is ended, and the transaction rolled back.
- A Dockerfile or `.dockerignore` over 1 MiB is refused.

## Going back to 0.9.0

1. Remove each service from outside: `keg system rm <name> --data`. 0.9.0 does not know them and would leave them behind.
2. On Linux, with kegd stopped, run `sudo sh remove-walls.sh` (attached to this release). It removes the bridge `kegw0` and its rules. If kegd's `--root` is not `/var/lib/keg`, give that folder: `sudo sh remove-walls.sh /srv/keg`.
3. Install 0.9.0 again. The tables 0.10.0 added are left in place and do no harm.

See [keg.rahultrikha.com](https://keg.rahultrikha.com) for more.
