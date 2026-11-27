# The vault

The vault's uses for what you run by hand (`keg run --secret`, a Compose
file's external secrets, a build's secrets, `keg login`, and `keg vault
show`, `export`, `import`, `stale` and `restart`) are experimental: off
until a person turns them on with `keg settings experimental on vault`. The
vault itself, its entries and grants to services, is not. See
[EXPERIMENTAL.md](EXPERIMENTAL.md).

The vault is one place on a node for passwords and keys: one named entry
for each, set once by a person, and given only where a person granted it.
An app's service, an installed service and Keg's own model gateway all
take what they use from it.

## The commands

```sh
keg vault set shop/stripe --note "the Stripe test key"   # asks for the value, not shown
printf %s "$KEY" | keg vault set shop/stripe              # or from standard input
keg vault set shop/stripe --from-env STRIPE_KEY           # or from your own variable, for scripts
keg vault ls                                               # names, notes, grants and times
keg vault grant shop/stripe --service web --env prod --as STRIPE_KEY
keg vault grant shop/stripe --service web --env staging --as STRIPE_KEY  # once for each
keg vault revoke shop/stripe --service web --env prod --as STRIPE_KEY
keg vault rm shop/stripe                                   # says what uses it, then asks
```

A value is never an argument of a command, which every user of the
machine can read. It is at most 64 KiB, and may be any bytes. A name is
letters, digits, `_`, `-` and `.`, in parts joined by `/`, at most 128
characters. `--env E` on any of these goes to the node of that
environment, as `keg secret set` does.

A grant to an app's service names its one environment: `keg vault grant
NAME --service S` without `--env` is refused, saying to name one. To give
an entry in several environments, grant it once for each. There is no
grant to every environment of a service: one would reach `local`, where a
piece of work's build is deployed, and every environment made later.

The console's Vault page (in Containers and in Builder) does the same:
Set an entry, Replace, Grant, Revoke and Remove. A value is typed into a
password field, sent once and emptied; the page is never sent one.

## What a grant is

A grant names an entry, one use, and the variable the use is given it
as. The uses in this version:

| Use | Written | Given as |
|---|---|---|
| A service of an app in one environment | `keg vault grant NAME --service S --env E [--as VAR]` | a variable, when it next starts |
| A service installed on the node | `keg system secret S NAME`, which writes `service/S/NAME` | its `secret:NAME` binding |
| Keg's model gateway | `keg assistant setup` or `keg assistant provider add`, which write `keg/model/<provider>` | the gateway's key, asked for each call it claimed |

`--as` is the name's last part when not said. A use is given what was
granted to it and nothing else: `needs.secrets: [STRIPE_KEY]` in a
`keg.yaml` is met by a grant to that service in that environment giving
`STRIPE_KEY`, whatever its entry is called. A file never grants: a
release that needs a name with no grant is refused, saying the command
that grants it.

A new value reaches a use the next time it starts. `keg vault ls` says
when each use last started with its entry.

```
keg vault stale            # what holds a value from before its entry was last set
keg vault restart NAME     # restarts the containers that hold NAME's old value
```

`keg vault stale` lists each container that started with an older value
(a container run with `--secret`, a Compose service's) while it runs, and
each service and installed service whose grant last started with one,
with how it takes the new value (its next release; `keg system restart`).
`keg vault restart NAME` restarts the containers, each handed the value
set now, and says what else holds it. Restarting is a person's, at a
terminal, the console or the app; the assistant may read the list
(`keg.vault.stale`), never a value.

What waits for a grant is a Needs-you item, with the command that makes
it: a release refused a secret it needs (none granted, or one an agent's
or a work's release may not be handed until a person grants it again), or
a build refused an entry its `keg.yaml` asks for. It goes once a person
makes the grant. Each container holding an old value is one too, with
`keg vault restart NAME`.

The Mac app's Vault page (in Containers and in Builder) lists the entries
with their notes, when each was last set and what each is granted to, and
what holds an old value, with Restart. Set and Grant are there too: a
value is typed into a password field, sent once and emptied, and the app
is never sent one.

## What an agent's code is handed

A release an agent proposed, or one a piece of work built (whose code and
`keg.yaml` an agent wrote), is handed an entry where no person approved it
only when a person granted that entry to exactly that service in exactly
that environment, and did so after the entry was last set. Approving the
release, or granting the entry again (`keg vault grant` once more), lets
it through; replacing a value means granting it again before a work's
release in `local` is handed the new one. The node checks this each time
such a release starts, a restart after the node's own included, and a
release that would be refused it waits for a person instead of applying
(an agent's that needs secrets or a database always waits, as before). An
image a work built stays the work's when a person proposes it elsewhere.

## `keg secret` and `keg system secret`

`keg secret set NAME --service S --env E` is short for setting the entry
`S/E/NAME` and granting it to S in E as NAME (a person's grant, made with
the value); `keg secret ls` lists the
names granted to S in E; `keg secret rm` takes that grant away and the
entry with it. Each says on standard error the vault commands it stands
for. `keg system secret S NAME` writes `service/S/NAME`, granted to the
installed service S alone.

Both read the value as `keg vault set` does: from the terminal, not
shown, or from standard input (`printf %s "$KEY" | keg secret set NAME
--service S`). A value given as an argument, as scripts written before
this version do, is still taken, with a line on standard error saying
that it can be seen by other programs and how to pass it on standard
input instead; the line never says the value.

## Keg's own entries

Entries under `keg/` are Keg's. In this version they are the model
gateway's keys: `keg/model/openai` and `keg/model/anthropic`, which `keg
assistant setup` writes from a `.env` read once or typed at the terminal,
and `keg/model/<name>` of each provider a person added with `keg assistant
provider add` (with `keg/model-headers/<name>`, the values of the headers
it is sent, if it has any). Each is given to Keg's own gateway and nothing
else, which asks the node for it for each call it has claimed. A person
may set, replace or remove them (`keg vault set keg/model/<name>` replaces
a provider's key); no one may grant them, and an entry under `keg/model/`
for a provider that was never added is refused. Removing a provider
removes its entries. See `docs/ASSISTANT.md`.

## A container you run by hand

```
keg run --name web --secret shop/stripe alpine:3.20 cat /run/secrets/stripe
keg run --name web --secret shop/stripe,env=STRIPE myimage
keg run --name web --secret shop/stripe,file=key.txt myimage
```

Running a container with `--secret` is the grant of that entry to that
container, by its name, kept while the container is there: started again,
it is given the entry again; removed, the grant goes. A file is put in
`/run/secrets`, in a folder of the container's own on the node's
filesystem in memory (`/dev/shm` on Linux), 0400 and owned by the
container's user, mounted read only. A variable is seen by every program
in the container and by anything that reads its environment, so a file is
the better form where a program can read one. `--secret` needs `--name`,
and is a person's at a terminal on the node's own socket: the console, a
request from another machine, the Docker API, an agent, an app and a
service cannot ask for it.

## A Compose project

In Keg's own Compose path (`keg compose up`), a top-level secret marked
`external: true` names an entry of the vault (its `name:`, or its own
name), given as a file in `/run/secrets` to the services that list it:

```yaml
services:
  api:
    image: myapi
    secrets: [stripe]
secrets:
  stripe: { external: true, name: shop/stripe }
```

The file only ASKS for it. A person grants it to the project, or to one
service of it, for the folder the project is brought up from, in that
folder:

```
keg vault grant shop/stripe --compose shop [--service api]
```

The node keeps the folder's real path: a Compose file elsewhere that names
itself the same project is given nothing. A service given entries keeps
the container name Keg gives it (`shop-api`). The project is brought up by
a person at the node's own socket; an agent's `compose up` that lists an
entry is refused, and so is the console's or one from another machine. A grant
is read each time a container starts: taken away (`keg vault revoke … --compose
shop`), the next start is not given it, and the revoke says which
containers still hold the value they started with. A `file:` secret stays
what Compose makes it, a file of the project. `docker compose` through
Keg's Docker API is unchanged: the docker client turns its secrets into
mounts before Keg sees them.

## Builds

A Dockerfile step that mounts a secret is handed an entry as a file,
there only while the step runs:

```dockerfile
RUN --mount=type=secret,id=npm npm ci     # /run/secrets/npm
RUN --mount=type=secret,id=key,target=/root/.key,required=true,mode=0440 make
```

```
keg build -t web:dev --secret id=npm,entry=shop/npm .
```

`--secret id=ID` names the entry ID; `id=ID,entry=NAME` another. Naming it
is a person's grant to that one build, at a terminal on the node's own
socket; nothing else may ask, not the console nor a request from another
machine (`--node-url`), since whatever the build runs reads the value.
Each entry handed is written down as `vault.used` (the name, the build and
the id, never the value). A secret the
build is not given is left out, unless `required=true`, which fails the
step saying so. The file is the node's own, in memory, 0400 and root's
unless `mode`, `uid` and `gid` say, mounted read only. It is never in a
layer (the empty file the mount needed is left out too), the image's
config, the build cache (a step is cached by each secret's id and place
and by which entry it was handed at which version, never the value: what a
step made with a secret is taken from the cache only by a build handed that
same entry, unchanged since), the build's log or its
record: what a step prints has the value put as `[hidden]`. What a step
does with it (copying it into the image) is the Dockerfile's.

For a service `keg up` builds, `keg.yaml` asks, and a person grants:

```yaml
build:
  context: .
  secrets: { npm: shop/npm }     # the secret npm is the entry shop/npm
```

```
keg vault grant shop/npm --build web
```

A build of what a person did not write (a piece of work's, an agent's) is
handed it only by such a grant made since the entry was last set, as a
release is. In `keg compose up`, a service's `build.secrets` names the
file's top-level secrets (`external: true`), handed to its build by the
same grant its container is given them by (`--compose PROJECT [--service
S]`, in its folder).

Through Keg's Docker API, `docker build --secret id=NAME,src=/dev/null`
(the client offers the secret empty) hands the step the vault's entry
NAME, as `keg build --secret id=NAME` does, and the build's output says
`secret NAME: the vault's entry NAME`: the node asks the client for each
secret the Dockerfile mounts, and only one the client offers this build is
handed. A secret the client offers with a value (`src=FILE`, `env=VAR`) is
that value, as Docker has it, cached for that build alone, even where an
entry has its name: a build is never handed an entry you did not ask the
vault for. A Dockerfile that mounts a secret the client does not offer is
handed nothing; Keg's own entries are never handed.

## Registry logins

```
keg login ghcr.io [--username me]
```

keeps the login (a user name, and a password or token read from the
terminal, unseen, or standard input) as the entry `registry/ghcr.io`,
granted to the node's pulls and pushes at that host alone. It is used for
a pull or push a person asks for there (`keg pull`, `docker pull` and
`docker push` through Keg), and for the pull of a release a person makes
(`keg up` of a `keg.yaml` naming an `image:` the node does not have); a
login sent with the request wins. A host's login is only ever sent to that
host. A pull an agent or a piece of work makes (its release's image) uses
it only when a person grants it to them, since it was last set:

```
keg vault grant registry/ghcr.io --registry ghcr.io
```

Logging in again (`keg login ghcr.io`) means granting it again before an
agent's or a work's pull uses the new one.

## Showing, exporting and importing

```
keg vault show NAME
keg vault export --to vault.keg
keg vault import vault.keg [--replace]
```

These are a person's alone, at a terminal on the node's own socket: the
node refuses them to the console, an agent, a service, the assistant, and
any request that reached it from another machine (`--node-url`), which it
marks so when it accepts the connection, whatever the request says. The
node's own socket is trusted, as everything of Keg's local is, by its
mode: 0600 and owned by the node's user.
`show` asks for the entry's name to be typed again, and is written down as
`vault.revealed` (who, which entry, never the value). `export` seals every
entry under a passphrase you type twice, 12 characters or more (Argon2id,
then ChaCha20-Poly1305), never the node's key, into a file only you can
read; without the passphrase nothing in it can be read. `import` opens one
with its passphrase and sets each entry as `keg vault set` does, leaving an
entry that is here already unless `--replace`. Grants are not exported:
grant each entry where it is used on the new machine.

## What it never does

- A value is never in a log, an event, a process's arguments, evidence, a
  transcript, a tool's result for the assistant, or any answer of the API.
  Each value is sealed with the node's key with its entry's name bound in,
  and has marks (its length and hashes) written with it, so that it is
  hidden from what tools give back without being unsealed.
- Setting, granting, revoking and removing are a person's alone: refused
  to an agent, a piece of work, the assistant, an app and a service, which
  may be told that a name is needed and whether it is set, and nothing
  more. The list of names and grants is a person's, and the assistant's
  to read on their behalf (`keg.vault.list`), never a value.
- Show, export and import, and handing an entry by hand (`keg build
  --secret`, `keg run --secret`, a Compose project's entries), are refused
  to anything but a person at the node's own socket.
- One service is never given what was granted to another.
- Merging a file that names an entry is not a grant.

## Upgrading

On its first start after the upgrade, a node takes every secret set
before into the vault, in one transaction, each with the one grant it
had: an environment's as `<service>/<env>/<NAME>`, an installed service's
as `service/<service>/<NAME>`, the model gateway's keys as
`keg/model/<provider>`. Nothing has to be typed again. Each new entry is
read back and compared before the old row is let go. Keg's own internal
secrets (database passwords and the like) stay where they are.

A grant to every environment of a service, which the vault's first
version allowed and a node running it may hold, is replaced at start by
one grant for each environment the service is deployed in now where a
person approves what is deployed: never `local` nor an environment whose
policy is `auto`, where a piece of work's or an agent's release applies by
itself. The node writes a `vault.revoked` event saying what it did and
where it did not grant, and a line in its log with the command that grants
it elsewhere.

Going back to the version before is not supported once the vault has
been written to: that version does not read it.
