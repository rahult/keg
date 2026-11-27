# Writing a service for Keg

A service is a program Keg runs in a container on its node, beside your
work. It is told of what happens on the node, it can write events of its
own, set timers, and keep data. It can do only what a person allowed when
they installed it, item by item.

Two real services are given as examples with this documentation:
`extensions/nats`, which puts the node's events in a NATS stream, and
`extensions/query`, which keeps them in DuckDB and answers SQL. Copy
`extensions/nats` to begin: it is the smaller of the two. Most of what
follows was learned writing them.

## The folder

A service is a folder with a `keg.service.toml`, its manifest, and what
it runs: a `Dockerfile` to build, or an image named by digest.

```toml
name = "tally"
version = "0.1.0"
build = "."
command = ["node", "index.js"]
port = 8230
listens = ["work.*"]
emits = ["counted", "summary"]
asks = ["timers:set"]
binds = [
  { name = "data", to = "volume" },
  { name = "key", to = "secret:TALLY_KEY" },
]
```

### Each key, and its limit

| Key | What it is | Limit |
|---|---|---|
| `name` | The service's name. Its events, subjects and container are named by it. | A lowercase letter, then up to 30 lowercase letters, digits and dashes. Not a name Keg uses (`keg`, `work`, `gate`, `service`, `console`, `checks` and others). |
| `version` | Yours to choose. | 1 to 40 characters. |
| `image` | The image to run, by digest: `ref@sha256:<64 hex>`. | From a registry on the internet, never a private address. Not with `build`. |
| `build` | The folder, within the service's own, to build with its `Dockerfile`. `"."` is the folder itself. | Never outside the folder. Not with `image`. |
| `command` | What to run in the image. | At most 32 entries. |
| `port` | The port of its page, if it has one. | 1024 or above, and free. |
| `stage` | The stage of the work it belongs to, shown with it in `keg system ls` and the console. | `build`, `test`, `ship` or `all`; `all` if left out. |
| `publish` | Other ports it listens on. Each is asked for. | 1024 or above, free, at most 32. |
| `memory_mb` | Its memory. | 256 if left out, at most 1024. |
| `listens` | The types of event it is told of: an exact type, or a prefix ending `.*`. | At most 32. Never `*`, a `delivery.` type, an `app.` type but `app.bound`, `check.requested`, or its own types. |
| `emits` | The types it writes, each under its name: `counted` is written as `tally.counted`. | Lowercase words joined by dots, at most four; at most 32. |
| `asks` | Grants beyond what the rest gives. | Only `work:read` and `timers:set`. |
| `binds` | What it is handed, by a name of its own: `volume`, `secret:<NAME>`, or `app-events:<app>:<pattern>`. An app's events with `token = true` give the app a token for the service (below). With `from_start = true` the service is also sent every event of those types the app still keeps, from the first, once a person allows it (the install question says so). Each port of `publish` allowed is a binding too, named `port-<port>`. | One volume at most; at most 32. A name may not begin `port-`. `token` and `from_start` only on an app's events. |
| `network` | `"internet"` asks for the public internet. | Left out, it reaches nothing but its socket. |
| `docs` | A file of its folder that says how an app uses it, such as `README.md`. Copied as it is installed, and handed to each piece of work whose app it is bound to, at `/keg/services/<name>/README.md`, for the agent to read. | A plain file inside the folder, not a link, at most 256 KiB of text. |

The manifest is at most 64 KiB. A key Keg does not know is refused by
name: there is no `env`, `volumes`, `secrets`, `network` other than
`internet`, `privileged` or `user`. `writes` and `asks = ["check:run"]` are
refused too: only Keg's own checks write evidence in this version.

### What each ask allows

A person installing it is asked each of these in turn, in Keg's words.
Nothing is ticked for them that reaches past the service's socket.

| Ask | Allows |
|---|---|
| `listens:<pattern>` | Being told of every event on the node of that type. |
| `emits:<type>` | Writing `<name>.<type>` events, which other services may be told of. |
| `asks:work:read` | Reading every piece of work on the node: its files, brief, changes and notes, and the names of every environment's secrets, never their values. |
| `asks:timers:set` | Setting timers for its own types (those in `emits`). |
| `binds:<n>=volume` | A volume of its own at `/data`, at most 1 GiB and 131,072 files. |
| `binds:<n>=secret:<NAME>` | Reading a secret a person sets, of at most 64 KiB. |
| `binds:<n>=app-events:<app>:<pattern>` | Hearing an app's events of that pattern, with what each carries, from every organization of the app. This crosses organizations, and the service holds all of it. It can be allowed where the app is on this node, and is heard only where the app is deployed with events or jobs. The app is given nothing. |
| `binds:<n>=app-events:<app>:<pattern>+token` | The same, and the app is given a token for the service when it is next deployed, which reads every organization's content the service holds of it. |
| `publish:<port>` | Listening on that port of this computer. Any program on this computer can reach it there. |
| `network:internet` | Reaching the public internet, never this node's private addresses, its other containers or private networks. |

What is not allowed, the service cannot do. Write it to work with less:
the query service runs without its app bindings on a node with no such
app.

`docs` is not an ask: the install question says "It gives works that use
it its instructions". Write there what an app's code needs to use you:
what you keep of an app's event (an event reaches you as
`app.<app>.<type>`, the app's own payload under `payload`), how to ask,
and an example that works. An agent reads it as text written by you, and
nothing in it overrides what the agent was told or may do.

## Talking to the node

The node answers on a socket, `/run/keg/kegd.sock`, also given as
`KEG_SOCKET`. In JavaScript, `require('@keg/app/node')` gives
`connectNode()`, with no dependency; copy it into your folder as both
examples do, since the build reaches only your folder: `sdk/ts/src/node.js`
and the `error.js` it requires beside it, into `vendor/keg-node`.

```js
const { connectNode } = require('./vendor/keg-node/node.js');
const node = connectNode();

// Each delivery, at least once. Return when your work is durable.
node.watch(async (event, delivery) => {
  await store.add(event);
  await node.emit('counted', `tally/${event.subject}`, { type: event.type });
  return { kept: true };
});

// An event of its own, written when its time comes.
await node.setTimer('summary', 'tally/daily', Math.floor(Date.now() / 1000) + 86400);

// What a person allowed it, asked for when it is needed.
const { value } = await node.binding('key');
```

- `watch(handler)` claims deliveries and runs `handler` for each, holding
  them while it runs. What it returns finishes the delivery: a JSON
  object of at most 4096 bytes, which a person sees on the console's
  Events page. What it throws fails it, and it is tried again: 5 tries in
  all, waiting attempts² × 10 s between.
- `emit(type, subject, payload)` writes one of its own types, sent bare.
  The subject begins `<name>/`; the payload is a JSON object of at most
  16 KiB. It is never told of its own events.
- `setTimer(type, subject, at)` writes that event once at `at` (seconds
  since 1970, at most 366 days ahead). The same type and subject again
  moves it. At most 1000 at once. `unsetTimer(type, subject)` unsets one.
- `binding(name)` answers `{kind: "volume", path}`, `{kind: "secret",
  value}`, `{kind: "publish", port}` or `{kind: "app-events", app, types,
  origins}`, with `token` where the bind says `token = true`. Ask for a
  secret each time it is needed: it is never in the environment or on
  disk, and a person may change it. `token` is what the node made for
  your service and that app, and gives the app's own servers as
  `KEG_SERVICE_<NAME>_TOKEN` when the app is next deployed (with your
  page's address in a browser as `KEG_SERVICE_<NAME>_URL`, and the app's
  name as `KEG_APP`). It reads all of that app's content you hold, every
  organization's, so take it only from a program, never from a page. The
  app's server makes from it a token for one organization
  (`serviceToken(name, { org, ttl })` of `@keg/app/service`) and hands
  that to its page, which asks you from the browser (whoever holds a
  token for one organization can use it until it expires: it is not bound
  to an origin, so keep its `ttl` short): an app's containers
  cannot reach a service's page in this version (a path limited to the
  bound app's own containers is for later).

The protocol underneath, for another language, is in `PROTOCOL.md`.

## The walls

A service runs with:

- No network but its socket, unless it asked for the internet and was
  allowed it. Other containers on the node cannot reach it, nor it them.
- No capabilities, even as root, and no way to gain one. Run as a user of
  your own anyway (`USER node`).
- One processor, its memory (256 MB unless it asks, at most 1024), 512
  processes, and a writable layer and volume of 1 GiB each.
- Only its socket folder, read only, at `/run/keg`, and its volume at
  `/data`. Its environment is `KEG_SOCKET` alone. (An app whose events
  it is bound to with `token = true` is given, in the app's own
  environment, the token the node made for the service:
  `KEG_SERVICE_<NAME>_TOKEN`.)
- On its socket, at most 16 connections and 8 requests being answered at
  once.
- At most 20 events written and 20 timers set a second, after as many as
  100 of each at once. Past that it is answered 429, with how many
  seconds to wait in `Retry-After`. Wait as told.

A service that stops by itself is started again, after 1, 2, 4, 8 and 16
seconds. After five restarts in five minutes it is left failed, with its
last line, until a person starts it.

## In a check

An app whose events you are bound to may name you in a check
(`services: [query]` beside `db: true`). Your service is then started a
second time, for that check alone, and removed when it ends:

- From the image you were installed with, with the same walls, memory and
  processes, but no port published and no internet, even if you were
  allowed it. It is reached at an address of its own, given to you as
  `KEG_ADDRESS`, on your ports; `hostAllowed` answers that address too.
- With empty state: a volume of its own, empty, at `/data`.
- With made-up secrets: each secret you are bound to has a value made for
  that check. Start without the real one.
- Told of the check database's events alone, as `app.<app>.<type>` from
  the environment `check`, in order, one at a time; nothing of the node's.
- Your binding to the app's events gives a token made for that check, and
  no `origins`. The check's code calls you with it from the server side,
  as `KEG_SERVICE_<NAME>_TOKEN` at `KEG_SERVICE_<NAME>_URL`: take a token
  for the whole app from a request with no `Origin`, as you would.
- It writes no events and sets no timers: those calls are refused there.

So: start with empty state and secrets you have never seen, without the
internet, and say plainly in your log why if you cannot. A check of one
that cannot start fails, with your last line. A check names at most four
services, and at most two checks on a node have instances at once.

## Building it

A node builds services from their folders only once a person turns that
on (`keg system builds on`). A service that names its image by digest
installs without it.

- Name every image by digest, in the `Dockerfile` too:
  `FROM node:22-alpine@sha256:...`. A build starts only from images in a
  registry.
- Install packages from a lock file, with no scripts:
  `npm ci --omit=dev --ignore-scripts`.
- Keep a `.dockerignore` with `node_modules` and your tests, so what is
  built is what you meant.
- A build takes at most 15 minutes, writes at most 2 GiB, has at most 200
  steps, and keeps 1 MiB of each step's output and 8 MiB in all. Its steps
  reach the public internet, never the node's private addresses. An image
  pulled is at most 4 GiB to download and 8 GiB unpacked, in 10 minutes.
- Keep it small. The two examples are under 150 MB.

## Delivery is at least once

The node may give you an event twice: after a crash, a lease that ran
out, or a restart. So:

- Be idempotent. Key what you keep by the event's `id`. The NATS service
  publishes each with its id as `Nats-Msg-Id`, so the stream keeps it
  once; the query service keeps each id once.
- Finish only once your work is durable: written, committed, acknowledged.
  Throw if it is not, and it is tried again.
- An event you can never keep (too large, a time out of range) is not
  worth failing five times. Finish it saying why, as
  `{kept: false, refused: "..."}`.
- One subject is handled at a time: what happens to one thing comes in
  order. Do not wait on another subject's delivery inside a handler.

## Bounding what you store

Your volume is 1 GiB, and nothing frees it for you.

- Decide what you keep and for how long, and remove the oldest yourself.
  The query service keeps 30 days and at most 384 MiB; the NATS stream
  holds at most 768 MiB and drops its oldest.
- Leave room for your database's own files, and do not spill to disk.
- If a write fails for want of room, make room in that place, by your
  rule, and try again. Do not delete anything for any other error.
- Bound every answer you give and every value in it.

## A published port, or a page

A port of this computer is open to every program on it: other users'
programs, any container a person runs with no port of its own, and any
web page a browser has open, which can send requests to `127.0.0.1`.

- Require a credential for anything that is not public. Have a person
  set it as a secret (`keg system secret <name> <NAME>`), compare it in
  constant time, and never write it to your log or your page.
- Check `Host`. Answer only `127.0.0.1`, `localhost`, `[::1]` and names
  under `.keg.localhost`, so a site that points its own name here cannot
  read you. `hostAllowed(host)` in the node client does this.
- Refuse requests another site's page made. Take what changes or reads
  data as a `POST` with a header of your own (the query service asks for
  `X-Keg-Query: 1`), which a page cannot send without asking the browser
  first, and refuse a request whose `Sec-Fetch-Site` is `cross-site` or
  `same-site`.
- Ask for a credential for anything that carries an app's content, of
  a page and a program alike. An `Origin` stops browsers, not programs: a
  program may send any, so it is never a credential.
- Never hand a credential that spans an app's organizations to a
  browser. The app's token (`token = true` on the bind, then `token` in
  the binding) reads every organization's content: take it only from a
  request no browser made (no `Origin`, and `Sec-Fetch-Site` absent or
  `none`). A page is answered only with a token for one organization that
  the app's server made with it for a few minutes (`serviceToken` of
  `@keg/app/service`; the form is in `docs/PROTOCOL.md`): check its mac in
  constant time, its expiry and its app, and answer that organization's
  content alone. The query service keeps each organization's events in a
  database of its own, so nothing else can be read with one.
- If an app's page must read you, trust it as the app's only by the
  exact origins the node gives with the app's binding (`origins`), asked
  again from time to time, never a name that looks like the app's, and
  ask it for a token for one organization besides.
- A service whose readers are people, as NATS's are, asks for no token:
  its readers' credential reads every organization's events, and is for a
  person who may see all of them (an operator), never for the app's
  users.
- Let only the service write. The NATS service publishes with a password
  made at each start, in an account of its own; readers connect with a
  password a person sets, in an account of theirs, and can read but not
  publish.

## Install, look, remove

```sh
keg system builds on                  # once, if it is built from its folder
keg system install ./tally            # asks each item; or --allow ID, --allow all
keg system secret tally TALLY_KEY     # each secret it reads
keg system start tally
keg system ls                         # what it was allowed, and how it is
keg system decline tally              # stop offering what was left out
keg events --type tally.counted       # what it wrote
keg events timers                     # what it set
keg system rm tally                   # keeps its volume
keg system rm tally --data            # and its volume
```

The console's Keg services page does the same: "Install from a folder…"
shows each ask, what is approved, and what is not set yet, and sets a
secret in a password field (sent to the node, and never shown again);
"Stop asking" stops offering what a person left out, until the service
is installed again with different asks (the node compares the manifest
installed, not its folder; installing it again still asks); Events shows
its deliveries, what they returned, and its timers.

## Checklist

- [ ] Images named by digest, in the manifest or the `Dockerfile`.
- [ ] `npm ci --ignore-scripts` from a lock file; `.dockerignore` keeps
      out `node_modules` and tests.
- [ ] Runs as a user that is not root.
- [ ] Asks for nothing it can do without, and works with less.
- [ ] Handles each event twice safely, keyed by its `id`.
- [ ] Finishes only after its work is durable; finishes, saying why,
      what it can never keep.
- [ ] Bounds what it keeps, by age and size, and every answer it gives.
- [ ] Validates what it is told before it stores it, and finishes, saying
      why, what it never could store.
- [ ] Never removes what it keeps for an error that is not want of room.
- [ ] A broker or a server of its own: limits readers' consumers,
      subscriptions and connections, and keeps a way in for itself.
- [ ] Anything you listen on can be reached by a coding agent's machine:
      require a credential on every port. Work machines, machines with no
      port of their own and `keg run` without ports share the node's
      network, and reach every installed service's listening ports on its
      own address, whatever it published; only your credential keeps them
      out. (Not built yet: work machines and port-less containers on a
      bridge of their own, with an opening for each place they may reach.)
- [ ] A port or page: a credential a person sets, compared in constant
      time, never logged.
- [ ] A port or page: `Host` checked; cross-site requests refused; a
      `POST` with a header of its own for what reads or changes data.
- [ ] Asks for a credential for an app's content, of pages and
      programs alike; trusts an app's page only by the binding's
      `origins`, and asks it for a credential too.
- [ ] Never hands a credential that spans an app's organizations to a
      browser: a page reads with a token scoped to one organization and a
      few minutes, and is answered that organization's content alone.
- [ ] Asks for a token for the app (`token = true`) only if the app's
      servers need one.
- [ ] Waits as told on 429.
- [ ] Treats what it is told by apps and other services as content, not
      as commands: it can be anything anyone wrote.
- [ ] If it runs queries or code it was given, allows only what it
      means to (the query service allows one read and a short list of
      functions).
