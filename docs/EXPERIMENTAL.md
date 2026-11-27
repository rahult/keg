# Experimental features

Some of what a Keg node has is still being tried. Each such feature is off
until a person turns it on, and off means off everywhere: the node refuses
its requests, whoever sends them, leaves its tools out of what the
assistant and a connected chat app are offered, runs none of its doors or
loops, and `keg --help`, the console and the Mac app leave out its
commands and pages.

```sh
keg settings experimental              # each feature, whether it is on, what is rough about it
keg settings experimental on mail      # turn one on: a person's to do
keg settings experimental off mail     # turn it off: what it made is kept
```

The console has them on its Keg services page, under Experimental
features; the Mac app in Settings, under Experimental. An agent can read
which are on (`keg agents` says which are off) but cannot turn one on.

A refusal of one that is off says so, the same everywhere:

```
mail is experimental and off on this node: a person turns it on with `keg settings experimental on mail` or in Settings › Experimental
```

## The features

| Name | What it is | Needs |
| --- | --- | --- |
| `workspaces` | Workspaces: lasting, walled machines to build in | |
| `door` | The connector door, for ChatGPT, Claude or Grok | `workspaces` |
| `previews` | Previews of what a workspace serves | `workspaces` |
| `workspace-git` | Git remotes, pushes and a project in a workspace | `workspaces` |
| `ssh-door` | The SSH door to a workspace | `workspaces` |
| `setup-server` | `keg setup server`'s checklist | |
| `model-gateway` | Model providers of your own, OpenAI- and Anthropic-shaped endpoints at an app's and a work's door, and the model for a workspace | |
| `vault` | The vault's uses for what you run by hand: `keg run --secret`, a Compose file's external secrets, a build's secrets, `keg login`, and `keg vault show`, `export`, `import`, `stale` and `restart` | |
| `mail` | Mail in, to an app's addresses | |
| `mail-verdict` | A verdict on each mailed message's sender (SPF, DKIM, DMARC), written with its event | `mail` |
| `hooks` | Webhooks in, to an app | |
| `org-tools` | An organisation's own tools, run walled for it | |
| `member-roles` | A member of an app's organisation holds more than one role, as an administrator grants them | |
| `app-check` | `keg app check`: a person runs a project's check, with a database and a fake model of its own, outside a piece of work | |

Not experimental, and always on: the vault itself (entries, and grants to
an app's or a work's service, since 0.13.0), Keg's own model gateway that
the assistant, works and apps use, and Chat Completions at a work's door.

`keg settings experimental` says what is known to be rough about each,
and the release it came in.

## Turning one on and off

- A feature that needs another is turned on only once that one is:
  `previews` needs `workspaces`. Turning `workspaces` off turns off what
  needs it too, and says so.
- Turned off, a feature stops and keeps what it made. Running workspaces
  are stopped (their folders kept); the doors stop answering; mail lets go
  of its port; a webhook's address leads nowhere; a preview's readers are
  cut off. Turned on again, each is as it was.
- A node upgraded from 0.14.0 that already used workspaces, or had named
  its connector door, has those turned on as it starts, so nothing anyone
  set up goes; the node says so once in its log and in
  `keg settings experimental`.

## How a feature stops being experimental

Every new feature is experimental from its first commit, and graduates in
the release after the one it came in, once it has had real use and has no
flaky tests: it is taken out of the list in `crates/kegd/src/experimental.rs`
(and its commands and pages out of the lists in `crates/keg/src/experimental.rs`,
the console and the Mac app). A feature that is not fully tested, or has a
flaky test, stays experimental whatever its age. Each release's notes say
what is experimental and what graduated.
