# Keg

**Somewhere for a coding agent to work, and a way to ship what it builds.** Keg gives an agent (Claude Code, Codex, Pi) Linux containers to build, run and test in, so nothing is installed on your computer, and lets it propose a release that waits for a person. Underneath it is a container runtime built for speed and delivery: it builds images, runs containers and Compose files, answers Docker's API so the tools you already use keep working, and moves a tested image from your laptop to a server you run. There is no Docker underneath: Keg pulls, builds and runs OCI images itself.

On a Mac it runs in a small Linux machine that boots in about a second and sleeps when nothing is running. On Linux it runs directly.

More at [keg.rahultrikha.com](https://keg.rahultrikha.com).

## Install

**On a Mac** (Apple silicon, macOS 15 or later): download [Keg.dmg](https://github.com/rahult/keg/releases/latest/download/Keg.dmg) and drag Keg to Applications. The app has the `keg` command and the Linux machine inside it; nothing else needs installing. Open it, press **Start Keg**, and in **Settings ▸ General** choose **Install the keg Command** to use it in a terminal.

**On Linux**: download the archive for your processor from the [latest release](https://github.com/rahult/keg/releases/latest) (`linux-x86_64` or `linux-aarch64`) and unpack it.

**On Windows**, Keg runs in WSL2, which is Linux: install it there the same way.

## Try it

```sh
keg run -it --rm alpine:3.20                 # a shell in a new container
keg run --name web -p 8080:80 nginx:1.27     # then open http://web.keg.localhost
keg compose up                               # the compose.yaml in this folder
keg docker use                               # point docker and docker compose at Keg
```

## This repository

This repository holds Keg's releases, its website and its Homebrew cask. Report a problem under [Issues](https://github.com/rahult/keg/issues).
