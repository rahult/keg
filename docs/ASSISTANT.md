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
keg assistant keys                              # which keys the vault holds for the gateway, never their values
keg assistant model                             # the models offered, their prices, and the one asked by default
keg assistant model <name>                      # sets it
```

Setup is a person's, on their own terminal, and it is the one way any
node gets a model key: the owner's Mac, a Linux server and a stranger's
laptop alike. It reads the `.env` once, prints the names it found and
never a value, and puts each key in the vault (`docs/VAULT.md`) as the
entry `keg/model/<provider>` (`keg/model/openai`, `keg/model/anthropic`),
given to Keg's model gateway (`models`) alone. It installs and starts the
gateway and the assistant, and makes one call to check them. The file is
never read again and may be deleted. No part of Keg reads a project's
`.env` by itself: not the assistant, not a piece of work (below), not an
app's `model` binding. Each reaches models through the gateway, holds no
key, and on a node with no key says the one command above.

`keg assistant keys` is a view of those entries: which is set, the
provider it serves, and when the gateway last used it. `keg vault ls`
lists them too. A key is replaced by running setup again (or `keg vault
set keg/model/openai`) and removed with `keg vault rm keg/model/openai`.
Nothing but Keg's own gateway may be granted an entry under `keg/`.

A node upgraded from 0.12 carries the keys it had into the vault at its
first start, with nothing typed again.

The provider is OpenAI (its Responses API); `ANTHROPIC_API_KEY` is kept
for a later version.

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
- **Installed, and stopped or without its key.** A round never reads a
  `.env`: with the provider's key not set it fails with "… the key for openai is not set …
  `keg assistant setup --env-file <path to a .env>`", and with the gateway
  not running with "Keg's model gateway is set up and not running … `keg
  system start models`".
- **No gateway.** On a node with no model key at all the round is
  refused before anything runs: "This node has no model key … `keg
  assistant setup --env-file <path to a .env>`; the project's own .env is
  never read." (Before the vault, the runner read the key from the
  project's `.env`; that is gone.)

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

### Input the provider read from its cache

A call is HELD, before it is sent, at the model's full input price: that
is an upper bound and stays one. It is SETTLED at what the provider
counted, and the input tokens the provider says it read from its cache
are counted at the model's cached price, when it has one:

```sh
keg assistant model                                               # each model and its prices
keg assistant model openai/gpt-5.6-luna --cached-input-usd-per-mtok 0.02
```

A cached price is above nothing and at most the input price. A model
with none counts cached input at the input price, as before. The models
Keg ships with have OpenAI's published cached prices (standard tier,
short context, 2026-11-25): gpt-5.6-luna $0.02, gpt-6-luna $0.01,
gpt-5.6-terra $0.20, gpt-5.6-sol $0.40 a million tokens. A provider that
says it read more from its cache than it was sent is believed for the
input and no more. `keg assistant usage` says how many input tokens were
read from the cache.

A node that kept its own table of models before cached prices were known
(one upgraded from 0.13.0, where a person had set a model) has the
shipped cached price for each model whose prices in and out are still
the shipped ones. A model a person priced otherwise is left as it is, and
`keg assistant model` says so under the list, with the command that sets
its cached price. A cached price a person set is never replaced; to be
charged in full for cached input, set it to the input price.

Not counted: a provider's prices for a context past 272K input tokens,
and for writing to a cache it keeps 30 minutes or 12 hours.

### Each organization of an app

A call an app's agent makes as a step of a thread carries a claim, signed
by Keg's SQL in the app's database with a key the node put there for
Keg's role alone, of which thread and organization it is for. The node
checks it (403 if it is forged, stale, or contradicted by the call's own
headers) and counts the call under that organization, always: `keg
assistant usage` lists each organization under its app. An organization
the app only names, with no claim, is counted under none.

```sh
keg assistant limits app:desk/local --per-organization-usd-per-day 1
```

holds EACH organization of that app's environment to that much a day. A
call past it is refused (429 `over_limit`) in words the app can show that
organization's administrator, which name no command of the node's; the
app's other organizations are answered. `keg assistant limits` lists the
ceiling beside the app's own, and `keg assistant usage` shows each
organization's spend against it.

A call is held, before it is sent, for the most it may cost, and the hold
counts toward the ceiling. So a ceiling below what the least call is held
for would refuse every organization: it is refused when set, saying the
least that lets a call through. One above that and below what a call is
held for when it does not say how much it may answer (4,000 tokens of
output) is taken, and `keg assistant limits` says under it that such
calls are refused.
A call outside any thread (`keg.model()`) carries no claim and is for no
organization: it is held to the app's ceiling alone, and `keg assistant
usage` shows such calls on a line of their own under the app whenever a
ceiling for organizations is set. A call that names a thread and carries
no claim is refused (403) while such a ceiling is set: the app's copy of
the client predates claims, and `keg app client` brings it up to date. What an app's
dry replays of its threads spent is said as evaluations.

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
