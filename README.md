# Keg

Run and build your systems anywhere.

Keg runs containers on a Mac or Linux, and lets you build and ship software on them. It is a container runtime of its own: it pulls, builds and runs OCI images, runs Compose files, and answers Docker's API so the tools you already use keep working. There is no Docker underneath. On top of it, Keg lets you build and ship: work given to a coding agent that waits at a gate for a person, releases to environments that wait for approval, apps with a database of their own, and services that Keg runs on the node.

On a Mac it runs in a small Linux machine that boots in about a second and sleeps when nothing is running. On Linux it runs directly.

More at [keg.rahultrikha.com](https://keg.rahultrikha.com).

## Install

**On a Mac** (Apple silicon, macOS 15 or later): download [Keg.dmg](https://github.com/rahult/keg/releases/latest/download/Keg.dmg) and drag Keg to Applications. The app has the `keg` command and the Linux machine inside it; nothing else needs installing. Open it, press **Start Keg**, and in **Settings ▸ General** choose **Install the keg Command** to use it in a terminal. The app updates itself.

**On Linux** (cgroup v2, root, `nsenter`, `ip` from iproute2, and `iptables` or `nft`): download the archive for your processor from the [latest release](https://github.com/rahult/keg/releases/latest), `keg-0.13.0-linux-x86_64.tar.gz` or `keg-0.13.0-linux-aarch64.tar.gz`. It holds `bin/keg`, `bin/kegd` and `bin/keg-agent`:

```sh
tar -xzf keg-0.13.0-linux-x86_64.tar.gz
sudo install -m 755 bin/keg bin/kegd bin/keg-agent /usr/local/bin/
sudo kegd --names 127.0.0.1:7380 --names-tls 127.0.0.1:7443 &
```

[Getting started](docs/GETTING-STARTED.md#install) has a systemd unit that keeps `kegd` running. Upgrading a node from 0.10.0: read [the changelog's notes](docs/CHANGELOG.md) first.

**On Windows**, Keg runs in WSL2, which is Linux: install it there the same way.

## Try it

```sh
keg run -it --rm alpine:3.20                 # a shell in a new container
keg run --name web -p 8080:80 nginx:1.27     # then open http://web.keg.localhost
keg compose up                               # the compose.yaml in this folder
keg docker use                               # point docker and docker compose at Keg
```

And to ship something, with a person approving:

```sh
keg example hello-keg && cd hello-keg        # a small project to try Keg with
keg up                                       # build, release, deploy to `local`
keg env add staging --policy manual
keg up --env staging                         # waits for you
keg needs                                    # what waits for you
keg approve 1 --env staging                  # or Approve in the app
```

## Two modes

The Mac app and the web console (`keg ui`, in any browser) have two modes, and a guide in ten steps through both:

- **Containers**, for what runs on the node: containers with live charts, output, files and a terminal; Compose projects; images with a vulnerability check; builds, volumes, networks, machines, Kubernetes and sharing.
- **Builder**, which has everything and leads with what you build and ship: **Needs you**, **Work** (a brief taken by agents through build, test and ship, with its evidence and diff, and Approve, Send back and Reject at the gate), **Apps**, **Keg services** and **Events**, then changes, services and environments.

## Documentation

- [Getting started](docs/GETTING-STARTED.md): install, the two modes, a first deploy, work and gates.
- [Reference](docs/REFERENCE.md): what Keg does, command by command, and its limits.
- [Events protocol](docs/PROTOCOL.md): what a Keg service may rely on.
- [Changelog](docs/CHANGELOG.md): each release, with how to upgrade and go back.
- [The assistant](docs/ASSISTANT.md): what it reads, what it proposes, what it can never do.
- [The Keg skill for coding agents](docs/AGENT-SKILL.md).
- [Writing a service](docs/WRITE-A-SERVICE.md), with two to read and copy in [`extensions/`](extensions/): NATS and a query service.
- [The vault](docs/VAULT.md) and [Kubernetes](docs/KUBERNETES.md).
- Release notes for [0.13.0](docs/releases/notes-0.13.0.md), [0.12.1](docs/releases/notes-0.12.1.md), [0.12.0](docs/releases/notes-0.12.0.md), [0.11.1](docs/releases/notes-0.11.1.md) and [0.11.0](docs/releases/notes-0.11.0.md).

## This repository

This repository holds Keg's releases, its website (`site/`), its documentation (`docs/`), its Homebrew cask (`Casks/`), the skill for coding agents (`skills/`) and two example services (`extensions/`). Report a problem under [Issues](https://github.com/rahult/keg/issues).

## License

Keg is free to use under the [Keg License](LICENSE.md). There will always be a free version. Software by others inside Keg is listed in [THIRD-PARTY-NOTICES.md](https://github.com/rahult/keg/blob/main/THIRD-PARTY-NOTICES.md), which ships with every download.
