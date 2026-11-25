# Getting started with Keg

Keg runs containers, and lets you build and ship software on them. This page takes you from installing it to a release that waits for your approval.

## Install

**On a Mac** (Apple silicon, macOS 15 or later): download [Keg.dmg](https://github.com/rahult/keg/releases/latest/download/Keg.dmg) and drag Keg to Applications. The app has the `keg` command and the Linux machine inside it; nothing else needs installing. Open it, press **Start Keg**, and in **Settings ▸ General** choose **Install the keg Command** to use it in a terminal. Or, with Homebrew:

```sh
brew tap rahult/keg https://github.com/rahult/keg
brew install --cask rahult/keg/keg
```

**On Linux** (cgroup v2, root, `nsenter`, `ip` from iproute2, and `iptables` or `nft`): download the archive for your processor from the [latest release](https://github.com/rahult/keg/releases/latest), `keg-VERSION-linux-x86_64.tar.gz` or `keg-VERSION-linux-aarch64.tar.gz`, and put the three programs in it on the PATH:

```sh
tar -xzf keg-0.10.0-linux-x86_64.tar.gz
sudo install -m 755 bin/keg bin/kegd bin/keg-agent /usr/local/bin/
```

Then run the daemon. Where the system uses systemd, as a service that keeps it running:

```ini
# /etc/systemd/system/kegd.service
[Unit]
Description=Keg: containers, services and the changes between them
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/kegd --names 127.0.0.1:7380 --names-tls 127.0.0.1:7443
Restart=always
RestartSec=1
# Restarting the daemon leaves running containers running.
KillMode=process

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload && sudo systemctl enable --now kegd
sudo keg run -a --rm alpine:3.20 echo hello
```

Without systemd, start it yourself: `sudo kegd --names 127.0.0.1:7380 --names-tls 127.0.0.1:7443 &`. To run services from outside (below), a Linux node also needs loop devices and `mkfs.ext4` (the e2fsprogs package).

**On Windows**, Keg runs in WSL2, which is Linux: install it there the same way. Turn systemd on in `/etc/wsl.conf` (`[boot]` then `systemd=true`) for the daemon to start by itself. `keg ui` in WSL opens the console in your Windows browser.

## Run a container

```sh
keg run -it --rm alpine:3.20                 # a shell in a new container
keg run --name web -p 8080:80 nginx:1.27     # then open http://web.keg.localhost
keg logs -f web
keg compose up                               # the compose.yaml in this folder
keg docker use                               # point docker and docker compose at Keg
keg machine create dev && keg machine shell dev   # a Linux system to work in, kept until removed
```

Anything with a port opens by name: `web.keg.localhost` for a container called `web`. On a Mac the Linux machine starts when a command needs it and sleeps when nothing is running.

## Two modes

The Mac app and the web console (`keg ui`, in any browser) have two modes. Switch with the control at the top of the sidebar, or press **M**.

- **Containers** is for running containers: containers, Compose projects, images, builds, volumes, networks, machines, Kubernetes and sharing. Its first page is an overview of what runs.
- **Builder** has everything, and leads with what you build and ship: **Needs you** (what waits for a person), **Work**, **Apps**, **Keg services** and **Events**, then changes, services and environments.

A guide in ten steps goes through both: five in Containers (run a container, open it, read its output, stop and start it), and five in Builder (make an example project, deploy it, send a change for approval, approve it, give an agent a brief). Each step says what to run and ticks itself when it sees it done.

## Deploy, and approve

```sh
keg example hello-keg && cd hello-keg        # a small web service with its keg.yaml, in a new git repository
keg up                                       # build, release, deploy to `local`
keg env add staging --policy manual          # an environment that waits for a person
keg up --env staging                         # a change set for staging, waiting for you
keg needs                                    # what waits for you
keg approve 1 --env staging                  # or Approve in the app or the console
keg rollback hello-keg --env staging         # the release before, if you need it
```

A release is built once and moved between environments as the same image, never rebuilt. A change set shows what would change and the checks it passed. Environments on other nodes (a Linux server you run) are added with `keg node add` and `keg env add NAME --node NODE`.

## Work, given to an agent

A piece of work is a brief taken by agents through build, test and ship, on a branch and in a worktree of its own, in a machine of its own. Each stage keeps what it found as evidence. When it is ready it stops at a gate and waits for a person: nothing is merged until you approve.

```sh
keg work new --title "Add a version route" --brief "GET /version answers the release number."
keg work ls
keg work show 1                              # the brief, the stages, and the evidence each kept
keg needs                                    # what waits for you
keg gate approve 1                           # merged, and deployed if it is a service
keg work send-back 1 --note "..."            # built again, with what is to be changed
keg gate reject 1                            # stopped, and nothing merged
```

In the app and the console, a piece of work shows its evidence and its diff, with Approve, Send back and Reject at the gate. An agent sees none of this and cannot answer a gate.

For a coding agent of your own (Claude Code, Codex, Pi), `keg agents` prints how it gets somewhere to build and run a project, and `keg agents --connect claude` (or `codex`, `pi`) connects it through `keg mcp`. The daemon holds it to what it was given; it can propose a release, never approve one.

## Events

Every change the node makes (work, stages, gates, evidence, change sets, services, apps, containers) is written as an event in the same transaction as the change.

```sh
keg events                                   # what happened, newest last
keg events --follow --type work.changed
keg events failed                            # deliveries to Keg's services that failed for good
keg events retry DELIVERY                    # one of those, tried again
keg events timers
```

The app and the console have an Events page, and refresh when something happens.

## Apps

A `keg.yaml` with `app:` and `uses: [data, identity, events, jobs, realtime]` gives an app a database of its own in each environment: sign-in, sessions, organizations and members; events and jobs, delivered at least once; and a realtime gateway that sends each subscriber what its user may read. `keg app new NAME` makes one to start from, `keg dev` runs it, and `keg app ls`, `show`, `stop` and `org` look after them.

## Keg services

Keg runs services of its own on the node, each in a container with a socket and grants of its own: the console, the checks the test stage asks for, and the realtime gateway.

```sh
keg system ls                                # each service, and how it is on this node
keg system install checks                    # one of Keg's own, by name
keg system stop checks && keg system start checks
```

A service from outside is a folder with a `keg.service.toml`. `keg system install ./folder` asks you about each thing it asks for, in plain words, and it holds only what you allowed. It runs pinned by digest, behind walls: no capabilities, no network but its socket (or the public internet only, if that was asked for and allowed), with memory, processes and disk capped. What such a service may rely on is in [PROTOCOL.md](PROTOCOL.md).

Building a service from its folder on the node is **off** until a person turns it on with `keg system builds on`. While it is off, a service that names its image by digest (`image = "…@sha256:…"`) still installs.

## More

- `keg license` shows the Keg License, under which Keg is free to use.
- [Reference](REFERENCE.md): what Keg does, command by command, and its limits.
- [Events protocol](PROTOCOL.md): what a Keg service may rely on.
- [Changelog](CHANGELOG.md): what changed in each release, and how to upgrade.
- [Release notes for 0.10.0](releases/notes-0.10.0.md).

## A Kubernetes cluster

Keg can run one node of Kubernetes (k3s) beside your containers:

```sh
keg k8s start
export KUBECONFIG=~/.keg/k8s/kubeconfig.yaml
kubectl create namespace keg-guide
kubectl -n keg-guide create deployment web --image=nginx:1.27-alpine --port=80
kubectl -n keg-guide expose deployment web --port=80
kubectl -n keg-guide port-forward service/web 8080:80
```

Open <http://localhost:8080>. `keg k8s start` prints what to do next, and
`keg k8s info` prints how to connect at any time. With no kubectl on your
computer, `keg k8s kubectl ...` runs it in the cluster (all but
`port-forward`). An image you built with `keg build` goes into the cluster
with `keg k8s load IMAGE`. `keg k8s stop` keeps everything in it;
`keg k8s delete` removes it. [KUBERNETES.md](KUBERNETES.md) has the rest.
