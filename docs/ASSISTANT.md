# Keg's assistant

Keg's assistant answers a person's questions about their node in words,
from what it reads there, and proposes changes that a person confirms.
It is in the console (the command box, and the Command page,
`#/command`) and in the Mac app (Command, and Needs you).

It is off until a person sets it up. Nothing of it runs on a node where
`keg assistant setup` was never run.

## Setting it up

```sh
keg assistant setup --env-file ~/secrets/.env   # reads OPENAI_API_KEY (and ANTHROPIC_API_KEY) and nothing else
keg assistant setup                             # or: asks for each key here, unseen
keg assistant keys                              # which keys are set, never their values
keg assistant model                             # the models offered, their prices, and the one asked by default
keg assistant model <name>                      # sets it
```

Setup is a person's, on their own terminal. It reads the `.env` once,
prints the names it found and never a value, seals the key for Keg's
model gateway (`models`), installs and starts the gateway and the
assistant, and makes one call to check them. After it, nothing reads a
`.env` for a model, pieces of work included (below). The provider is
OpenAI (its Responses API); `ANTHROPIC_API_KEY` is kept for a later
version.

## Pieces of work reach their model through the gateway

Once the gateway is set up, the agent of a piece of work (Pi, in the
work's machine) asks its model through the gateway too, and is given no
key: the project needs no `.env`, and the runner reads none.

```sh
keg assistant model --works openai/gpt-5.6-luna   # the model works ask (none set: the default)
keg assistant model                              # marks the default and the one works ask
keg assistant limits work:12 --usd-per-day 5     # one work's allowance; default:work for all
```

- **The door.** For each round the node opens a socket in the work's own
  `/keg/model`, which only that machine is given, read only; a bridge in
  the machine (`node`, which Pi needs anyway) carries a port of the
  machine's own loopback to it, and Pi is pointed at
  `http://127.0.0.1:<port>/v1` as an OpenAI-compatible provider
  (`POST /v1/chat/completions`, streamed). Nothing else of the node is
  reachable through it, and no other machine, app or service has it.
- **The token.** Each round has a random token of its own, in the agent's
  process environment and no file; the node keeps only its digest, and
  forgets it as the round ends, when the socket goes too. Another work's
  token, an earlier round's, or none is refused (`401`).
- **The model.** A work asks the model a person set for works
  (`keg assistant model --works`), or the node's default if none is set;
  the `model` a request names must be that one, and anything else is
  refused (`400 model_not_allowed`). The project's recipe's provider and
  model are not used then: a recipe is in the repository a work's agent
  writes in.
- **What reaches the provider.** The request is translated into the
  node's own call (instructions, messages, tool definitions, tool calls
  and results, as data) and sent by the gateway's own builder, with its
  own address, organisation and key. No header of the request, no
  address and no field the node does not carry reaches the provider;
  a field it does not know (`base_url`, `n`, `response_format`, …) is
  refused. Images are not carried (a line says one was there).
- **Spend.** Every call is held at its worst case as `work:<N>` against
  the work's daily ceiling ($2 by default) and the node's, at the price of
  the works' model, and settled at what the provider counted; a call cut
  off (the agent gone, the round over) is counted at what the gateway
  reports within a minute, else at its worst. `keg assistant usage`
  shows it as `work:<N>`; the work's page and `keg work show` say, for
  each round, which model it reached this way and what the round spent.
- **A ceiling reached** ends the call with an OpenAI-shaped
  `429 insufficient_quota` (with `x-should-retry: false`), and the round
  ends with the node's own sentence ("Work 12's model allowance for
  today, $2.00, is used … A person raises it with `keg assistant limits
  work:12 --usd-per-day 4`."), which is what the gate shows.
- **Bounds.** A request is at most 4 MiB and its head 16 KiB; at most 4
  calls of a work are open at once (a fifth is told `429` to ask again in
  a second); a call's answer is at most 1 MiB and 5 minutes, as every
  call through the gateway; output asked past 32,000 tokens is held to
  that. A request has 30 seconds to arrive, head and body, and its answer
  5½ minutes to be read; a request is read as typed parts, counted as
  they come (1,000 messages, 128 tools, 256 parts a message, 50,000 values
  in all the tools' schemas). The door closes when the round ends, or at
  the recipe's time and a minute, whichever is first: every connection
  still open is cut off then, its call ended, and nothing more is held.
- **What is kept.** Nothing of what was asked or answered is written to
  the node's log or its events: `model.used` carries the caller
  (`work:<N>`), the model and the counts, as for every caller. What the
  agent said and did is kept in the round's transcript, as before, with
  the token hidden.
- **Installed, and stopped or without its key.** Once the gateway
  (`models`) is installed, a round never falls back to a `.env`: with the
  provider's key not set it fails with "… the key for openai is not set …
  `keg assistant setup --env-file <path to a .env>`", and with the gateway
  not running with "Keg's model gateway is set up and not running … `keg
  system start models`".
- **No gateway.** On a node where the gateway was never installed, the
  runner gives the agent the provider's key from the project's `.env`, as
  before, and the round says so.

The gateway is the one thing on the node that holds a model's key and
reaches a provider. It runs walled, with the public internet only. The
assistant runs walled with no network at all and nothing but its socket.

## What it may spend

Every model call is held at its worst case against its caller's
allowance and the node's before it is sent, and settled at what the
provider counted. By default a day (UTC) allows:

| Who | Default |
|---|---|
| the assistant | $5 |
| each piece of work | $2 |
| each app environment | $2 |
| a person's own calls (as setup's check) | $1 |
| the node, in all | $20 |

```sh
keg assistant limits                                   # every limit
keg assistant limits default:assistant --usd-per-day 10
keg assistant limits node --usd-per-day 50 --per-minute 30 --tokens-per-day 2000000
keg assistant limits service:assistant --resume        # after a call cost more than was held
keg assistant usage [--day YYYY-MM-DD] [--json]       # what each caller spent and has held
```

Over a limit a call is refused (429 `over_limit`), saying which limit and
when it resets. At most 16 calls run at once on a node, 4 kept for the
assistant.

## What it reads

What a person reads, through 28 tools whose requests the node builds
itself from the tool's arguments: containers (state, ports, how each is
made, the last lines each printed), volumes, images, networks, machines,
builds, events and deliveries, pieces of work with their evidence and
diffs, the services of an environment, Keg's own services, apps and their
jobs, environments, change sets, backing services, what waits for a
person, what the node uses, and what takes space on its disk. It can open
the console's pages.

- It never reads a variable's or a secret's value. Every result has each
  secret the node holds hidden, before it is cut to 64 KiB, and a
  container's command line is left out.
- **What it reads is sent to the model's provider.** Log lines, what a
  build printed and what a service or an app wrote are among it.
- What a program wrote is given to the model as a tool's result, never as
  the person's words, and is marked so wherever it is shown.

## What it may change, and how

The assistant changes nothing by itself. It may propose 16 kinds of
change: start, stop, restart, pause, resume or remove a container; start
or stop a machine; retry or skip a delivery; fetch or remove an image;
remove a volume; take a Compose project down; promote a release to an
environment, or roll one back.

A proposal is a card in the node's own words. It names each thing by the
node's name for it, says whether the change can be undone, what the
person asked, and, in a box of its own, what a program wrote that the
assistant read first ("A program wrote that, and it may be wrong or
written to mislead."). Every value on it is one line, its line breaks and
invisible characters shown escaped. The model's own words never reach a
card.

The rules:

- **Nothing is done until a person clicks Confirm** on the card, in the
  console (Command, or Needs you) or the Mac app. `keg needs` lists a
  waiting proposal and says to confirm it in the console.
- The node carries out exactly the request it stored when the change was
  proposed, as the person who clicked, **once**, and only **within ten
  minutes**. Decline it, or let ten minutes pass, and nothing is done.
- At the click each thing the card named is looked at again by its
  identity: a container by its id, a volume by its folder, an image by its
  digest, a service by the release it runs, an environment by where it is
  and its policy. If any changed, the card is withdrawn and nothing is
  done.
- One change at a time in a turn, and five in a turn at most.
- **Removing a container that a service is deployed as undeploys that
  service** until it is deployed again; the card says which service and
  environment.
- **A promotion or rollback is carried out as the person who clicked.**
  Into an environment that applies releases without approval it is
  deployed at once; into one that needs approval it waits there for a
  person to approve it; to an environment on another node it is sent with
  the person's invitation, and that node decides. The card says which.
- The containers of services Keg runs (the console, the gateway, the
  assistant, and services installed from folders) are never proposed: a
  person starts and stops those on the System page (`#/system`).
- If the node stops between a click and knowing how the change went, the
  change is never carried out again; when the node starts, the turn is
  told so and goes on.

## What it can never do

Whatever it reads or is asked: approve or reject a gate or a change set;
install, replace or remove a service, or change what one is allowed; read
or set a secret; set a model's key, limits or allowances; change what
this computer reaches; run a cleanup or change what is kept; share or
expose anything; begin a piece of work or hand it files; confirm or
decline a proposal, its own or any. None of these is a tool, even as a
proposal; a test fails if one becomes one. An agent that works on the
node (Claude Code, Codex) is refused `keg assistant` altogether.

## Who can see it

**Anyone with the console's link can read the conversations and confirm
the changes the assistant proposes.** The link holds the console's
token: treat it as the node's key. The console and the Command page say
so.

Conversations are kept on the node: at most 200, for 30 days, and 256 MiB
of steps, the oldest going first; a person can delete one. A run is held
to 200 steps, 50 tool calls and 30 minutes.

## For apps that read `keg.my_events`

The assistant does not read an app's own events. An app that does should
read pages of them with `@keg/app`'s `db.events({ type, about, limit,
before })` rather than SQL of its own over `keg.my_events` with
`ORDER BY … LIMIT`: `db.events()` reads every page, the first or one far
back, from the feed's index whatever Postgres's statistics say, where a
query of one's own may be planned as a scan of the whole table.
