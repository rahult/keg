# Machines: a place to work

A machine is a Linux container made for one project folder and kept until
it is removed. You are root in it. The folder is in it at the same path and
can be written; nothing else of the computer can be.

## Make one, from the project's folder

```sh
cd /path/to/project
keg machine create web --image node:22
```

- The folder you run it from is the machine's folder. There is no flag to
  give it another; `-v` and ports are refused for an agent.
- Pick an image with the tools: `node:22`, `python:3.12`, `rust:1`,
  `golang:1.23`. Without `--image` it is `ubuntu:24.04`.
- `there is already a machine named web`: use it, it is probably yours from
  before (`keg machine ls` shows its folder).
- `outside the directories this node gives to agents`: an agent's machine
  must be for a folder inside the node's agent workspace. Say so; the person
  starts the node with `--agent-workspace <folder>` (on a Mac
  `keg vm start --agent-workspace <folder>`, after `keg vm stop`).
- On a Mac, `the folder cannot be shared`: run it from the project's own
  folder, not a home folder or a disk's top.

MCP: `keg_machine_create` with `name`, `folder` (absolute) and `image`.

## Run commands in it

```sh
keg machine shell web -- npm ci
keg machine shell web -- npm test
keg machine shell web -- sh -c 'apt-get update -q && apt-get install -y -q jq'
```

- It runs in the folder you are in, where the machine has it. Its output
  and exit status are the command's.
- Nobody answers prompts: pass `-y`, `--yes`, `CI=1`.
- As an agent, a command runs to its end (ten minutes at most) and its
  output comes back when it ends. There is no interactive shell.
- Write files in the project folder directly: the machine sees them at once.

MCP: `keg_machine_run` with `name` and `command` as a list
(`["sh", "-c", "npm ci && npm test"]`), optionally `env` and
`timeout_seconds` (up to 3600).

## A server in it

```sh
keg machine shell web -- sh -c 'nohup npm run dev > /tmp/dev.log 2>&1 & echo $! > /tmp/dev.pid'
keg machine shell web -- tail -n 50 /tmp/dev.log
keg machine shell web -- curl -s localhost:3000/
keg machine shell web -- sh -c 'kill $(cat /tmp/dev.pid)'
```

A server listening in the machine answers at `localhost:<port>` inside it
and on the node. A machine has no name of its own under `keg.localhost`;
for a name, run the project as a service (`references/running.md`).

## Keep it, find it, remove it

```sh
keg machine ls
keg machine stop web
keg machine rm web
```

- Stopped, it keeps what was installed; using it again starts it.
- Removing it deletes what was installed in it; the project folder stays.
- Remove only machines you made. `keg machine ls` lists only agents'
  machines to an agent; a piece of work's machine is that work's, even if
  it is listed: leave it.

MCP: `keg_machines`, `keg_machine_remove`.

## Trying something once

```sh
keg sandbox python -- python -c "print(6 * 7)"
keg sandbox node -- node -e "console.log(process.version)"
```

The sandbox is gone when the command ends. A program on standard input is
run by the language: `keg sandbox python < try.py`. With a person's rights
the folder you are in is there to read; an agent's sandbox has nothing of
the computer in it. To work on a project's files, make a machine.
