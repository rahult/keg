# The vault

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
| Keg's model gateway | `keg assistant setup`, which writes `keg/model/<provider>` | the gateway's key |

`--as` is the name's last part when not said. A use is given what was
granted to it and nothing else: `needs.secrets: [STRIPE_KEY]` in a
`keg.yaml` is met by a grant to that service in that environment giving
`STRIPE_KEY`, whatever its entry is called. A file never grants: a
release that needs a name with no grant is refused, saying the command
that grants it.

A new value reaches a use the next time it starts. `keg vault ls` says
when each use last started with its entry.

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
gateway's keys, `keg/model/openai` and `keg/model/anthropic`, which `keg
assistant setup` writes from a `.env` read once, and which are given to
Keg's own gateway and nothing else. A person may set, replace or remove
them; no one may grant them. See `docs/ASSISTANT.md`.

## What it never does

- A value is never in a log, an event, a process's arguments, evidence, a
  transcript, a tool's result for the assistant, or any answer of the API.
  Each value is sealed with the node's key with its entry's name bound in,
  and has marks (its length and hashes) written with it, so that it is
  hidden from what tools give back without being unsealed.
- Setting, granting, revoking and removing are a person's alone: refused
  to an agent, a piece of work, the assistant, an app and a service, which
  may be told that a name is needed and whether it is set, and nothing
  more. The list is a person's too.
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
