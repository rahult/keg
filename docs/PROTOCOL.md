# Keg's events: one protocol, two stores

Keg keeps events in two places: in each app's own database (the app layer,
`keg.*` in Postgres, `crates/kegd/src/capabilities/003_events_jobs.sql`)
and on the node (`keg.db`, for Keg's own services and the workflow).

The two share a shape, not every word. What is the same in both:

- An event is written in the transaction of the change it tells of, and
  the deliveries it calls for are made in that same transaction.
- A delivery is `waiting`, `running`, `done` or `failed`, and has
  `attempts`, `max_attempts` (5), `run_at`, `held_until`, `last_error`,
  and a token of which only a hash is kept.
- It is retried by the same numbers: a failure puts it back to `waiting`
  with `run_at = now + attempts² × 10 s`, and the 5th failure leaves it
  `failed`. An error is kept to 2000 characters. A hold is 5 to 3600 s.
- Delivery is at least once. A handler must be safe to run twice.

Everything else differs, and is listed below: in the table, and under
"How an app's events differ from the node's".

## On the node

**Event.** `id` (uuid), `type` (dotted, lower case, thing then what
happened: `work.created`, `gate.answered`), `subject` (what it is about,
`kind/name`: `work/7`, `changeset/local/15`), `at` (seconds since 1970),
`actor` (a role and a name), and `payload`: small JSON. The node's own
events carry ids and states only, never a brief, a title, a secret, a
diff, a note or the body of evidence; an event a service writes carries
what it wrote, and an app's event relayed for a binding carries the
app's content (both below). Events have an order, and the place in it is the **cursor**,
which a reader keeps and treats as an opaque string.

**Subscription.** A name, an owner (the service), and the event types it
takes. It is made from what a person allowed of the service's manifest:
each `listens` pattern allowed, and the app events of each binding to an
app's events allowed (below). Nothing else makes or changes one.

**Delivery.**

- **Claim** gives the caller up to 10 of its oldest due deliveries (1 by
  default), marks them `running` and holds them for a lease of 60 s, each
  with a token. A claim waits up to 20 s for one.
- **Extend** lengthens the lease, from now, by 5 to 3600 s. A holder of
  long work extends it while it works.
- **Finish**, with the token, marks one `done`, with a result: a JSON
  object of at most 4096 bytes.
- **Fail**, with the token, or a lease that runs out, puts it back to
  `waiting` with `run_at = now + attempts² × 10 s`. At `max_attempts` it
  is `failed`.
- A **failed** delivery is the dead letter. It stays, it is shown, and a
  person can put it back to `waiting`.
- Each delivery is in an order, and in a subscription one of an order is
  claimed only once every earlier one of it is `done` or `failed`: none
  earlier is `running` or `waiting`, backing off after a failure among
  them. A node's event or a service's is in the order of its subject, so
  what happens to one thing is handled in order, and other subjects are
  not held up by it. An app's event relayed for a binding (its subject
  `app/<app>/<id>`, one each) is in the order of its app and environment,
  `app/<app>/<env>`: a service is told of one app's events in each
  environment in the order the relay read them, which is the order their
  transactions committed, and one that fails holds the app's next back
  until it is done or failed for good (after its 5th try, or when a
  person's retry of it ends); then the next goes. The app's other
  environments, other apps and the node's own events are not held up by
  it. Redelivery still repeats an event: after a hold runs out or a run
  ends, an event may come again although its service did the work, so a
  service is still safe to be told of each twice, keyed by its `id`.
- What a service may rely on is this order within one order key, and no
  more: nothing about the order of two keys, and nothing about a dead
  letter. A failed delivery a person tries again is `waiting` again after
  the events that went on past it, so it arrives after them, out of its
  first place.
- When a person ended a service's run (stopped, removed or installed it
  again), or the node started again, each delivery it held is `waiting`
  again at once, its try not counted, and a claim that was waiting as it
  stopped is given nothing. When its run ended by itself (it exited or
  crashed) while it held one, that was a try: it counts, with the usual
  wait after it. So an event a service dies on every time is `failed`
  after its 5th try, as one it fails is, and its order goes on: a poison
  event ends as a dead letter, never by holding the app's events back for
  ever. A person can end one sooner: `keg events skip <delivery>` (or
  "Skip" on the console's Events page) fails a delivery that waits, at
  once; it is a dead letter like any, which `keg events retry` tries
  again. Installed again from another folder, what it held and what
  waited for it are withdrawn instead, as before.
- How far behind a subscriber may fall on one writer's events (10,000 not
  done) is counted, for an app's relayed events, for each app and
  environment: an app's `local` far behind keeps none of its `prod`.

**Reading without subscribing.** A person may ask for the events after a
cursor, and wait for more: at most 20 s, and at most 64 requests wait at
once. If the cursor is older than what is kept, or newer than anything
ever written, the answer is the error `cursor_expired`, and the reader
reads the state afresh. The log never skips silently.

**Keeping.** The node keeps events seven days, or the newest 100,000,
whichever is fewer, and never removes one while a delivery that is not
`done` points at it. `done` deliveries are removed with their events.
The node's own events and the events services write are counted apart:
the newest 100,000 of each are kept, so a service writing many never
pushes the node's own out. A `failed` delivery of an event a service
wrote does not keep that event: once the event is past what is kept, it
goes, and its failed deliveries with it. A `failed` delivery of one of
the node's own events keeps it until a person tries it again. The node
removes at most 5,000 events at a time, oldest first, and goes on a
second later until what is past keeping is gone.

**Falling behind.** A subscription with 10,000 deliveries waiting or
running of what one service wrote is behind on that service. While it
is, new events that service writes are not delivered to it: they are
written, and others are told of them, but it misses them. It is still
given what the node writes, and what every other service writes; a
`failed` delivery is a dead letter, and does not count. Beside that, a
subscription with 100,000 deliveries waiting or running in all, of
anyone's events, the node's own among them, is given nothing more until
it has fewer: that is the store's guard against a service that never
claims. Both are counted as missed, and shown the same way. It is never given what it missed later. How many it
missed is shown with it (`missed` in `GET /v1/subscriptions`, `keg
events`, the console's Events page) until a person installs the service
again; a person fixes the service or removes it.

**Writing.** A service from outside writes at most 20 events a second
and sets at most 20 timers a second, after as many as 100 of each at
once. It writes no evidence and runs no checks in this version: a
manifest from outside that names `writes` or asks `check:run` is refused,
since only Keg's own checks are told of checks. A service from outside
allowed `work:read` reads every piece of work on the node: its files, its
brief, its changes and notes, and the names of every environment's
secrets, never their values; the install question says so. Past that it is refused with HTTP 429,
`rate_limited`. The answer says how many seconds to wait, in a
`Retry-After` header and as `retry_after` in the error; every 429 the
node gives says it. A request refused for what it asks, such as a
subject not its own or a timer too far ahead, spends nothing of the
allowance. Keg's own services (checks, console, realtime) are not held
to it: whether a caller is one of them is read from the service the node
stored, not from the name it gives. Keg's checks write a record for each
check; answered 429 all the same, they wait as told and try again, for
at most a minute in all, while the hold is kept.

**An app's events.** A service bound to `app-events:<app>:<pattern>` is
told of that app's events whose own type the pattern matches, from every
organization of the app and every environment it is deployed in with events
or jobs. The node reads the app's `keg.events` as `<db>_keg`, on a connection
that only reads, and writes each app event into its log once, however often
it reads it: as `app.<app>.<type>`, about `app/<app>/<id>`, by the actor
`{"role": "app", "name": "app.<app>"}`, never by the node. Its payload is the
app's content: `{"app", "env", "type", "id", "at", "organization",
"audience", "about", "payload"}`, `at` in seconds, `payload` whatever JSON
the app wrote (an object, a list, a string or a number, as it is). Every
field but `payload` is the node's, read from the event's row:
`organization` is the row's `organization_id`, which the app's capability
layer sets from the acting user's (or job's) organization in `keg.emit`,
never anything the app wrote in its payload. `audience` is who the event
is for as the row keeps it: `null` for the whole organization, else
`{"roles": [...]}`, `{"users": [...]}`, or both in one, `{"roles": [...],
"users": [...]}`, for whoever is in either; one longer than 8 KiB is
`{"cut": true}`, which is for no one in particular, never for everyone.
`about` is what the event is about (`ticket/42`), or `null`. A service that
shows events to people treats any audience it does not understand as not
theirs. A service that keeps each organization's events apart
relies on it. More fields of the row may be added beside these; a service
ignores any it does not know. An app payload over 16 KiB
as text is not fetched from the app's database at all: it is told of with
`"payload": null`, `"cut": true` and `"size"`, its size in bytes; so is one
nested deeper than the node reads (128 levels).

The node reads an app's events in the order their transactions were given
ids, not by time: `005_relay.sql` gives each `keg.events` row the id of the
transaction that wrote it (`xid`, an `xid8`, 64 bits, which never wraps;
rows from before that file have 0, and come first). Each read takes only
rows of transactions below the app's database's horizon: the oldest
transaction id held by a backend connected to that database, or by a
transaction prepared in it, and never past the next id to be given as it
is read (a transaction with no id yet is given one at least that). The
server's own superuser makes `keg_horizon.oldest()` in each app's
database for this, with a search path of its own; only Keg's role of the
app may call it. Every transaction below the horizon has ended, and the
rows are read in a snapshot taken after it, so nothing can appear behind
the node's place later, whenever it commits and however long the node was
stopped. The consequences:

- An event is late, never lost. One whose transaction is open is told of
  once it commits, and everything after it in that app's database waits
  behind it.
- What holds an app's events back is a transaction in that app's own
  database, and nothing else: another app's, on the same Postgres, holds
  back only its own. When one has held an app's events for 10 minutes with
  newer ones waiting, its bindings say "waiting on a long transaction in
  <database>, the database of <app> in <env>", in `keg system ls` and the
  console.
- A transaction an app leaves open and idle is ended by Postgres after 10
  minutes (`idle_in_transaction_session_timeout` on the roles the app
  connects as), so it cannot hold its own app's events for ever. One that
  is busy all that time, as a long `keg.run` job is, holds them while it
  runs.
- A database made again, or put back from a copy so that its transaction
  ids went back, is noticed (`keg.instance`, written once by
  `005_relay.sql`, says another, or the next transaction id is not past the
  node's place). The node says so in its log and reads again from the
  start of what is there, as far back as an hour; what it wrote in that
  hour is remembered by id, and is not written twice.

**An app's pages.** A service asks for such a binding at
`GET /v1/bind/<name>` and is answered `{"kind": "app-events", "app",
"types", "origins"}`, and `"token"` where its manifest asks for one
(`token = true` on the bind; false unless said). `token` is 256 bits the
node made at random for that service and that app (64 hex digits), the
same each time it is asked; the node gives it to the app's own services in
each environment the app is deployed in, as the environment value
`KEG_SERVICE_<NAME>_TOKEN` (`<NAME>` the service's name in capitals, `-`
written `_`), with `KEG_APP`, the app's name, and, for a service with a
page, the address a person's browser opens it on, `KEG_SERVICE_<NAME>_URL`
(`http://127.0.0.1:<port>`, on the port that leads to this node from the
computer a person uses; not given at all where none does), set when the app is next deployed: the node
starts no app's containers again by itself. Until then the service's row
in `keg system ls` and the console says so ("supportdesk in local is given
its token for query when it is next deployed: keg up"), as do the answers
to installing it and removing it (`DELETE /v1/system/services/<name>`
answers `{"waiting": [...]}`, and an app keeps a removed service's token,
which reads nothing, until it is next deployed). It is made
anew when the service is removed or replaced from another folder, and it
is never in an event, a log, `keg system ls` or anything an agent reads
(but code an agent deploys as the app runs with it, as it runs with the
app's database). A service with no token asked for gives the app nothing:
NATS's readers, say, read with a password a person sets, which is for a
person who may see every organization, never for the app's users.

The app's token reads every organization's content the service holds of
the app, so it never goes to a browser. It is for the app's server; a
service takes it only from a request no browser made (no `Origin`, and no
`Sec-Fetch-Site` but `none`). For a page, the app's server makes a token
for one organization, the signed-in user's, for at most 15 minutes:

    v1.<payload>.<mac>
    payload = base64url(JSON {"app": "<app>", "org": "<organization id>", "exp": <seconds since 1970>})
    mac     = base64url(HMAC-SHA256(key = the app's token as text, message = the payload's base64url text))

base64url without padding. In JavaScript, `serviceToken(name, { org, ttl })`
of `@keg/app/service` makes one (`ttl` in seconds, 300 unless said, at most
900). A service checks the mac in a time that does not depend on how much
of it is right, that `exp` is not past (30 seconds are allowed for the
clocks) nor more than 15 minutes and 30 seconds ahead, and that `app` is
one it is bound to with a token, and answers that organization's content
alone. A token of an app it is not bound to is refused in the same words
as one whose mac is wrong, so that a refusal says nothing of which apps
are bound, and the mac is taken in its one base64url spelling alone. Such
a token is a bearer token: whoever holds it, from wherever, reads that
organization's content with it until it expires, up to its 15 minutes. It
is not bound to a page's origin or to a connection, so an app hands it
only to its own signed-in user's page, and keeps its `ttl` short. A page
whose origin the node vouched for (below) is answered only with such a
token of that app. Not built in this version: an app's
containers cannot reach a service's page, so the app's server cannot ask
the service itself; a path limited to the bound app's own containers is
for later.
`origins` are the exact origins, scheme, name and
port, of the pages the node serves for that app: for each environment
the app is deployed in, the name of the service it is made of there that
has a port (`<service>.<env>.keg.localhost`, and in `local`
`<service>.keg.localhost` too), on the ports that lead to the node's names from the computer a person
uses (below, "Where a node is reached"; on a node reached directly,
`http` on `--names` and `https` on `--names-tls`, with no port when that
is 80 or 443). It is empty when the node serves no names, or does not yet
know where it is reached. A service that
answers a browser trusts a page as the app's only by these, never by a
name that looks like the app's: anything on this computer may listen on
another port, and a browser sends every `*.localhost` name here. So that
nothing else is served by those names, a name in `local` that is an
app's service is that service's, and never a person's container of the
same name: while the service has no port there, between one release and
the next, the name leads nowhere, and a container of that name is not
listed as leading anywhere by it. A name that is no app's goes to a
container of that name first, as it always has. The origins change as the app is deployed and
removed, so a service asks again from time to time (the query service
every minute, and at once, at most once in five seconds, when a page's
origin or a token is not one it was told of). A program that is not a browser can send any `Origin` it
likes: an origin tells a browser's page apart, not a program, so it is
never a credential. Anything that carries an app's content asks for a
credential, of a browser's page and a program alike: a token for one
organization from a page, with the origin besides.

`005_relay.sql` reaches an app bound before it at its next deploy, or as
the node begins to follow the app (when the node starts, or the app is
first bound). The node refuses to read from a Postgres older than 13, and
says so in its log. Where the app uses realtime, Postgres tells the node of
each commit, and that is only a reason to read; it asks every minute
besides. It reads at most 500 rows at a time, and writes at most 1200 of an
app's events a minute into its log for each environment; the rest wait,
in order: by transaction, and a transaction's events in the order they were
emitted (`011_events_order.sql`; before it, in the order of their random
ids). What an app wrote before a service was first bound to it is not
told of, and a binding added later hears only what began after it was
allowed or committed after the node first read for it, unless it asks for
the past: `from_start = true` on the bind, which the person installing it
is asked about ("It is sent every event of <app> that is still kept, from
the first, not only those after it is allowed."; its id ends
`+from-start`). Such a binding, allowed, is also sent each event of its
types still in the app's `keg.events` that it was not told of as it came,
from the first, in order, to it alone (each delivery as the live one is,
in the app's queue beside what comes now, each with its own `at`). That
past is read for each environment as far as what had committed when the
node first read for the binding, a batch of 500 at a time, only while
fewer than 500 of the app's events wait for the service (far below the
10,000 at which it would miss what comes) and within the 1200 a minute;
`keg system ls` and the console's System page say how far it got ("sending
the past events of desk in local from the first, as query takes them: 340
so far", then "sent every past event of desk in local from the first:
1234"). Installed again, or the app's database made again, it is sent the
past afresh. An app's events are
kept, held back and counted as what a service writes is, each app as one
writer, so they never push the node's own out. Nothing but such a binding
brings an app's events to a service, and a service cannot listen to an
`app.` type itself.

**A service in a check.** A check that names services (`services:
[query]` with `db: true`) is given an instance of each, made for it and
removed when it ends, at most two checks' at once (a third waits, in
order, for ten minutes, and is then given back to be run again). Its
socket is a door of its own: its claims are answered from the check's own
Postgres, read as above (as `<db>_keg`, read only, below the horizon, in
the order of the transactions), each as a delivery of
`app.<app>.<type>` about `app/<app>/<id>`, with `env` `check`, one at a
time; a hold, an extend, a finish and a fail work as they do on the node,
and one tried five times is let go. Nothing of it is written into the
node's log, and nothing of the node's reaches it. Its bindings are what
the check gives it: a volume of its own, empty; a value made for each
secret; for the app's events, a token made for this instance and no
`origins`. It cannot write events or set timers. The check's command is
given `KEG_SERVICE_<NAME>_TOKEN` and `KEG_SERVICE_<NAME>_URL`
(`http://<its walled address>:<port>`) and `KEG_APP`; the instance has
`KEG_ADDRESS`, that address. The instance is walled as a check's Postgres
is: no port on the node and no internet; the node and what shares its
network (work machines among them) reach its ports, and the token, 256
random bits given to that check alone, is what keeps another work out.
One whose image is not here, or that the node cannot run, is the verdict
`error`; one that stops or is not ready in 60 seconds fails the check.
What a node that stopped left is removed as it starts.

**Withdrawing.** The node can withdraw the deliveries for a subject: they
are marked `done` with `last_error` "withdrawn", their tokens stop
working, and no `delivery.done` is written. It does so when a piece of
work is stopped, sent back, retried or rejected, and for a subscription's
deliveries when its service is removed. There is no call for it.

## A service's own events

A service allowed `emits:<type>` writes events of `<service>.<type>`, and
no other type: `POST /v1/events` `{"type": "<type>", "subject":
"<service>/...", "payload": {}}`, the type sent bare, which needs the grant
`events:emit:<service>.<type>` that allowing it gives. The subject is one of
its own, beginning `<service>/`, 1 to 200 of `A-Z a-z 0-9 . _ : / -`; the
payload a JSON object of at most 16384 bytes (left out, `{}`); the type
lowercase words joined by dots, at most four. It is written by the actor
`{"role": "service", "name": "<service>"}`, never by the node, and the
answer is the event as written. A name the node writes events under
(`work`, `gate`, `service` and the like) is no service's.

Such an event is delivered to every subscription that takes it, but never
to the service that wrote it: no service listens to its own namespace. Its
payload is what the service wrote; the node does not read it, and it is
for the services that listen to it, and the person who allowed them, to
trust it as far as they do. It counts with that service's own events as
the log is kept and as how far behind on it each subscriber is.

## Timers

A timer is an event written when its time comes, once. A service allowed
`asks:timers:set`, and `emits:<type>`, sets one for that type:
`PUT /v1/timers` `{"type": "<type>", "subject": "<service>/...", "at":
<seconds since 1970>}`, the type sent bare. Setting the same type and
subject again moves it. `at` is at most 366 days ahead; left out, or past,
it fires at once. A service has at most 1000 set; `GET /v1/timers` lists
its own, and `DELETE /v1/timers?subject=S&type=T` unsets one, answering
`{"removed": true}` or `false`. A person's `GET /v1/timers` lists every
timer on the node (`keg events timers`, the console's Events page).

When it fires, the event is written as the service's own (above), with
the payload `{}`, and the timer goes, in one transaction: a node that was
down fires what fell due as it starts. It fires only if the service may
still write that type then; one removed takes its timers with it.

The node sets one timer itself: `gate.waiting`, a day (86400 s) after
`gate.asked`, for a question nobody has answered. It is told of once, and
unset when the question is answered or withdrawn.

## Bindings

A binding is something a person allowed a service to be handed, by a
name of its manifest's own (`binds = [{ name = "data", to = "volume" }]`).
Its kinds:

- `volume`: a volume of its own, mounted at `/data`, of at most 1 GiB
  and 131,072 files. A service has one at most. It is kept when the
  service is removed, unless a person removes it with its data, and given
  back if it is installed from the same folder again.
- `secret:<NAME>`: a secret a person sets with `keg system secret
  <service> <NAME>`, of at most 64 KiB. Its value is never in the
  service's environment or on its disk, and no person reads it back.
- `app-events:<app>:<pattern>`: the events of an app whose own type the
  pattern matches, relayed into the node's log (above, "An app's events")
  as `app.<app>.<type>` and delivered through the service's subscription.
  This crosses organizations: such a binding hears every organization of
  the app, not one, with the content each event carries, and the service
  holds all of it; the install question says so, and, with `token =
  true`, that the app is given a token for the service (above, "An app's
  pages"). It can be allowed where the app is on this
  node, and is heard only where the app is deployed with events or
  jobs.
- `publish`: each port of `publish` allowed is a binding `port-<port>`.

A service lists its own with `GET /v1/bind` (`[{"name", "kind"}]`) and
asks for one with `GET /v1/bind/<name>`, answered only for its own:
`{"kind": "volume", "path": "/data"}`, `{"kind": "secret", "value"}`
(asked again each time it is needed; a secret not set is `not_found`,
saying how a person sets it), `{"kind": "publish", "port"}`, or
`{"kind": "app-events", "app", "types", "origins"}`, with `"token"` where
the manifest asks for one (above, "An app's pages").

## In an app

**Event.** A row of `keg.events`: `id` (uuid), `organization_id`, `type`
(any text that is not empty), `payload` (any JSON the app writes),
`actor_user` (the acting user's uuid, or none), and `at` (a
`timestamptz`). It has no subject, no actor role or name, and no cursor.

**Subscription.** A row of `keg.subscriptions`: `(type, job)`, written by
the app's migrations with `keg.on(type, job)`. It has no name and no
owner.

**Delivery.** A row of `keg.jobs`, made for each subscription by the
`event_jobs` trigger in the event's transaction. Its `payload` is
`{"event": id, "type": type, "payload": payload}`. A job can also be made
without an event, with `keg.enqueue`. Its `run_at` and `held_until` are
`timestamptz`.

- **Claim**: `keg.claim(names, seconds)` gives one job, the oldest that is
  ready among the names asked for, in any organization. The caller
  chooses the hold, 5 to 3600 s (60 by default), and is given a token.
- **Run and finish**: `keg.run(id, token)` checks the token and the hold,
  keeps the job's row locked and sets the job's actor for the transaction
  the handler runs in. `keg.finish(id)` takes no token, since `keg.run`
  checked it, and keeps no result.
- **Fail**: `keg.fail(id, token, why)`, after the handler's transaction
  was rolled back, in one of its own.
- **A hold that runs out**: the job is ready again at once, unless that
  was its last attempt, when the next claim marks it `failed`.

## The same act in both stores

| Act | In an app (SQL) | On the node (HTTP on the socket) |
|---|---|---|
| Write an event | `keg.emit(type, payload)`, as the acting user, any payload | the node's emit, in the transaction of its change, ids and states only; a service's own types with `POST /v1/events`, its payload what it wrote |
| When it happened | `at`, a `timestamptz` | `at`, seconds since 1970 |
| Who did it | `actor_user` (a uuid, or none) and `organization_id` | `actor`: a role and a name |
| Its place in the order | none | `cursor` |
| Listen for a type | `keg.on(type, job)`: a `(type, job)` row, no name, no owner | the service's manifest: `listens = ["app.bound"]`; a subscription with a name and an owner |
| Make a delivery with its event | the `event_jobs` trigger makes a `keg.jobs` row | a `deliveries` row, in the event's transaction |
| Claim | `keg.claim(names, seconds)`: one job, the caller chooses the hold | `POST /v1/deliveries/claim` `{"max": 1, "wait": 20000}`: 1 to 10, held 60 s |
| Extend | none | `POST /v1/deliveries/ID/extend` `{"token": "...", "seconds": 60}` |
| Finish | `keg.run(id, token)` checks the token; `keg.finish(id)` takes none and keeps no result | `POST /v1/deliveries/ID/finish` `{"token": "...", "result": {}}`, a result of at most 4096 bytes |
| Fail | `keg.fail(id, token, why)` | `POST /v1/deliveries/ID/fail` `{"token": "...", "error": "..."}` |
| A hold that runs out | ready again at once | waits attempts² × 10 s, as a failure does |
| See what failed | `keg app show`: how many failed | `keg events failed`, `GET /v1/deliveries?state=failed`, the console's Events page |
| Try a failed one again | none | `keg events retry ID`, `POST /v1/deliveries/ID/retry` |
| Read the log | none | `keg events [--follow] [--type T]`, `GET /v1/events?after=C&type=T&limit=100&wait=20000` |

`GET /v1/subscriptions` lists each of the node's subscriptions, with how
many of its deliveries are waiting, running and failed, and how many
events it missed while it was behind. In JavaScript,
`require('@keg/app/node')` gives `connectNode()` with `claim`, `extend`,
`finish`, `fail` and `watch`, shaped like the app client's `job` and
`work`, and `emit`, `setTimer`, `unsetTimer` and `binding` for a
service's own events, its timers and what it was allowed;
`require('@keg/app/service')` gives an app's servers `serviceFor(name)`,
the token and address of a service bound to the app's events, and
`serviceToken(name, { org, ttl })`, a token for one organization for its
page.

## What the node writes

| Type | Subject |
|---|---|
| `work.created`, `work.changed` | `work/<id>` |
| `stage.started`, `stage.finished` | `work/<id>` |
| `check.requested` | `work/<id>` |
| `gate.asked`, `gate.answered` | `work/<id>` |
| `gate.withdrawn` | `work/<id>`, with `{gate}`, when a person stops, sends back, retries or rejects work that has an open question |
| `gate.waiting` | `work/<id>`, with `{gate}`, a day after `gate.asked` when the question is still open; once |
| `evidence.added` | `work/<id>` |
| `changeset.created`, `changeset.changed` | `changeset/<env>/<id>` |
| `service.installed`, `service.started`, `service.stopped`, `service.removed` | `service/<name>` |
| `service.failed` | `service/<name>`, with `{name, code}`, when a service that kept stopping by itself is left failed for a person |
| `app.bound` | `app/<name>`, once the app's release is recorded as deployed |
| `container.started`, `container.stopped`, `container.removed` | `container/<id>` |
| `delivery.done`, `delivery.failed` | the delivery's subject |
| `vault.set`, `vault.granted`, `vault.revoked`, `vault.removed`, `vault.used` | `vault/<name>`, with the entry's name and the use; never a value (`docs/VAULT.md`) |

Beside the node's own, the log holds what others write, never by the node:

| Type | Subject |
|---|---|
| `app.<app>.<type>` | `app/<app>/<id>`, an app's event relayed for a binding, by the actor `{"role": "app", "name": "app.<app>"}`, with the app's payload, which is content |
| `<service>.<type>` | `<service>/...`, a service's own event, or one of its timers, by that service |

`delivery.done` and `delivery.failed` are written for a service's
deliveries. `delivery.failed` carries no error text; the error is read
from the delivery. For a service from outside, `delivery.done` carries no
result either, only ids and the state: what it returned is read from the
delivery, as its `result` in `GET /v1/deliveries`, by a person. Its `delivery.done` and `delivery.failed` count with that
service's own events, as the log is kept and as how far behind on it each
subscriber is, so a busy service never pushes out the node's events. Keg's
own services' `delivery.done` carries their result, which the workflow
reads, and counts as the node's.

## Who may do what on the node

- **A person** reads every event, lists subscriptions and deliveries, and
  retries a failed delivery.
- **A service** claims, extends, finishes and fails the deliveries of its
  own subscription, and nothing else of the log. It needs the grant
  `events:take`, which follows from what a person allowed it to listen to
  when installing it. It writes events of its own types only with
  `events:emit:<service>.<type>`, from each `emits` allowed, and sets
  timers for them only with `timers:set`, from `asks:timers:set` allowed.
  It is handed only its own bindings, those a person allowed. A service
  cannot make a subscription, change what it listens to, read the log,
  write the node's events or another service's, or be told of its own.
- **An agent** has nothing of the log.
- **Handing a piece of work files** (`POST /v1/work/<id>/attach`, its
  `attach-inspect`, `POST /v1/work-attach-inspect`, `/v1/work-allow-from`),
  what it was handed (`GET /v1/work/<id>/attached`) and the node's
  `@keg/app` (`GET /v1/app-client`) and Go client (`GET /v1/app-client/go`)
  are a person's: an agent and a service
  are refused them. A work's agent reads what it was handed, read only, at
  `/keg` in its machine. What a round may run of its project's checks
  itself (`GET` and `POST /v1/work-self-checks`) is a person's to set.
- **A work's own run of a check** is asked for at the round's door, the
  socket at `/keg/model/door.sock` in the work's machine, with the round's
  token as a Bearer token: `GET /keg/checks` lists the checks the work's
  `keg.yaml` has, and `POST /keg/check`, its body the check's name as
  plain text and nothing else, runs one. The answer is plain text, with
  `Keg-Exit` the code `keg-check` ends with. The node takes its own
  snapshot of the work's tree, into a store that is removed when the run
  ends and never into the project's repository, and reads the check from
  it; the run is the
  gate's own, waits at most 30 s for a database, gives way to the gate's
  checks, and judges nothing. It reaches nothing of the node's API.
- `GET /v1/work/<id>/base-tests` (`work:read`, as its evidence): what the
  branch the work merges into was last checked with, `{base, work, tests:
  [{check, passed, failed}]}`, the checks service's last count of each
  check in the latest work merged (`done`) into the same branch of the same
  project, or null. A first round's gate is said against it.
- **What a project names for its works' machine** (`POST
  /v1/work-project-inspect` with `{"folder": "..."}`) is a person's, as
  beginning a work is: `{image, default_image}`, `image` being the
  `work.image` the folder's keg.yaml names as it is now, or null. The
  console's and the Mac app's New work ask for a machine's image only when
  it is null. An image a work is begun with (`image` in `POST /v1/work`,
  `keg work new --image`) is refused (`invalid_reference`) before anything
  of the work is made when it is not an image's name.
- **Nobody** answers a gate or approves a change through the log. Those
  stay the calls they are, for a person alone. No event approves
  anything.
- A work is approved only when what was checked and built is what would be
  merged. While the branch it merges into has commits it does not, its
  gate in `GET /v1/needs` carries `behind` ("main has 1 commit this work
  does not have, so what was checked and built is not what would be
  merged. Bring it up to date first (`keg work update 1`) ...") and
  `POST /v1/gates/<id>/answer` with `approve` is refused (409) with that
  sentence; whether it is behind is read again, from the project's own
  repository, as the answer is acted on, and one that cannot be read
  refuses too. `POST /v1/work/<id>/update` (`keg work update <id>`, Bring
  up to date in the console and the Mac app; a person's alone) merges the
  base into the work's branch in Keg's machine for the work, where nothing
  of the person's is checked out (`git merge-tree`, then `commit-tree` and
  `update-ref` from the commit it was at). The work then runs again from
  its test stage: its checks run on the combined code, it is built and run
  in `local`, and a new question is asked; approving it merges that commit
  and deploys that release, so `local` and the environment approved into
  run what was merged. Where the two conflict, the merge is begun in a
  fresh copy of the work, the base's commits handed to it in a bundle, and
  the work goes back to its agent for a round with a note naming the files
  in conflict. The answer is `{item, merged}` or `{item, conflicts}`.

## How an app's events differ from the node's

Step B built the relay above: an app's events reach the node's log, as
`app.<app>.<type>` events written by the app, and from there reach the
services bound to them like any other event. In the app's own database
they stay as the app writes them, and these differences remain:

- An app's `at` is a `timestamptz`, not seconds since 1970; the relay
  carries it in seconds.
- An app event's actor is `actor_user` (a uuid) and `organization_id`,
  with no role and no name.
- In the app's database, events have no subject and no cursor, and the
  log of an app cannot be read after a cursor or waited on. On the node a
  relayed event's subject is `app/<app>/<id>`, and it is read after a
  cursor and waited on like any other.
- An app's subscription is `(type, job)`, with no name and no owner.
- An app's payload is whatever the app writes; on the node it is ids and
  states only, but for an app's events told of on the node, which carry
  the app's payload. An app's type is any text that is not empty; one that
  is not words of letters, digits, `_` and `-` joined by dots, at most 100,
  is not told of on the node.
- `keg.finish(id)` takes no token (`keg.run` checks it) and keeps no
  result, so the 4096-byte limit on a result is the node's alone.
- An app's claim returns one job, and the caller chooses the hold. The
  node claims up to 10, and holds each 60 s.
- Apps have no extend. A job's hold is what was asked for at the claim.
- In an app, a hold that runs out makes the job ready at once. On the
  node it waits attempts² × 10 s, as a failure does.
- The node runs one delivery at a time per subject. An app does not.
- An app's dead letters are counted by `keg app show` and listed, with
  their last errors, by `keg app jobs`.
- A person retries a failed delivery on the node with `keg events retry`
  (and fails a waiting one sooner with `keg events skip`), and a failed job of an app with `keg app jobs retry`; only the node has
  keeping and withdrawing.

## An app's threads, for a person

The threads of an app's agents, of every organization, are a person's to
read, start, stop and wake; an agent, a service and the assistant are
refused each route.

- `GET /v1/apps/<app>/threads?env=&state=&agent=&before=` lists them,
  newest first, at most 100 an environment. `stranded: true` marks one
  that is `ready` with nothing to wake it (its step ended without a next,
  a wait or an end).
- `GET /v1/apps/<app>/threads/<id>?env=&after=&wait=` is one thread, its
  events and its model calls' requests, every secret the node holds hidden.
- `POST /v1/apps/<app>/threads?env=` starts one; `.../<id>/stop` stops it
  and its children.
- `POST /v1/apps/<app>/threads/<id>/wake?env=` wakes one that has not
  ended: `{id, was}`. One that waits is woken whatever it waits for, and
  its next step reads `wake {why: "person"}`. An app deployed before
  threads could wait is told to be deployed again (400); an ended thread
  is `wrong_state`.

## An app's jobs, for a person

A person, or the console, reads and retries an app's jobs; an agent and a
service are refused both, as they are `GET /v1/apps/<app>`.

- `GET /v1/apps/<app>/jobs?env=<env>&failed=true|false`: the jobs that are
  not done, newest first, at most 500 an environment (`env` left out: every
  environment the app is in). Each is `{env, id, name, state, attempts,
  max_attempts, next, last_error}`: `next` is when it runs next, in seconds
  since 1970, or null once it has failed; `name` is at most 200 characters
  and `last_error` at most 500, each one line with no control character.
- `POST /v1/apps/<app>/jobs/retry?env=<env>` with `{"ids": [...]}` or
  `{"failed": true}`: failed jobs back to waiting, attempts 0, to be taken
  at once. An id of a job that has not failed is refused (409) and nothing
  is put back. Answers `{"retried": n}`.
- `POST /v1/apps/<app>/jobs/remove?env=<env>` with `{"failed": true}`,
  `{"orphaned": true}` (both may be given) or `{"ids": [...]}`: removes for
  good every failed job, every orphaned one (made by a subscription since
  taken back with `keg.off`, still waiting), or the failed jobs named.
  Answers `{"removed": n}`. A person's alone, as `keg app jobs remove`.
- `POST /v1/apps/<app>/remove` with `{"confirm": "<app>", "with_data":
  false}`: a person's alone (`keg app remove <app>`, which asks for the
  name to be typed, or `--yes <app>`; Remove… on the console's Apps page),
  refused to agents, services and the assistant, which has no tool for it.
  `confirm` must be the app's name. In each environment on this node its
  container is stopped and removed, it is no longer deployed there (so
  nothing starts it again, its ports are given up and its images are left
  for cleanup), and its row goes; every service's binding to its events,
  and the tokens given for them, go too. Its database in each environment
  is kept, and deploying it again uses it, unless `with_data`, when the
  database is dropped with its roles and the passwords Keg kept for them.
  An environment's row goes only once its database has been dropped (or
  kept), so a removal that fails part way is finished by asking again;
  each drop can be made again. With `with_data`, an app already removed
  whose data was kept (or left) is found by its name, and its data in each
  environment here is dropped. `"look": true` (no `confirm` needed) says
  what would be stopped, kept and removed, and does nothing. Answers `{app, envs, bound, kept, removed, elsewhere}`: `bound` the
  services that were bound to it, `kept` or `removed` the databases,
  `elsewhere` environments on other nodes, where it is removed there.
- `keg.tenant_ref(child, column, parent, on_delete => null)` (capability
  file 013, `data`): Postgres checks a foreign key without row security, so
  a plain `REFERENCES parent (id)` from one tenant table to another lets an
  organization name another's row and tells it whether an id exists. This
  makes the reference `(organization_id, column)` to the parent's
  `(organization_id, id)`: a unique index on the parent's pair if it has
  none (built in the migration's transaction, so a large existing parent's
  writes wait while it is built), and a key `keg_ref_<column>` in place of
  the column's own keys to the parent, doing on delete what they did (or
  `'no action'`, `'restrict'`, `'cascade'`, `'set null'`, which nulls the
  column alone). A row naming another organization's id is refused as one
  naming no row: the same error (23503) from the same constraint after the
  same one look in the same index. Both must be tenant tables, the parent
  needs `id`, and the column must be of its type; the owner calls it.
- `keg.off(type, job)` (capability file 012) also cancels the jobs its
  subscription made that still wait: each is `failed`, its `last_error`
  `cancelled: keg.off('<type>', '<job>') took back the subscription that
  made it`. One running finishes as it would.
- `GET /v1/apps/<app>` gives, for each environment, `waiting`, `failed`,
  `retrying` (of those waiting, how many failed before), `last_error` (of
  one being retried) and `unclaimed` (at most 20 names of jobs ready for
  five minutes and never taken).
- `GET /v1/apps/<app>/jobs/summary?env=<env>`, the one of these the
  assistant reads, as the tool `keg.apps.jobs` (an agent is refused it):
  for each environment, `{env, counts: [{name, state, count}], failed:
  [{id, name, attempts, error}]}`, the 20 latest failed jobs, each `error`
  at most 300 characters on one line, with every secret the node holds
  hidden as in any tool's result. It never carries what a job was given.

## Where a node is reached

A node's ports are not always on the same numbers on the computer a
person uses. On a Mac, Keg's VM serves names on 7380 and 7443 inside it,
and `keg vm forward` opens them on the Mac's `localhost`. Two nodes on one
Mac (each with its own `HOME`) cannot both have 7380 there. So:

- The forwarder opens each port of Keg's own (the names, and the ports of
  Keg's own services, listed as `own` in `GET /v1/ports`) on its usual
  number when that is free, and otherwise on the first free one after it,
  up to 99 further on. Where it was put is kept in `~/.keg/runtime/mac-ports.json`
  and tried first the next time, so links stay the same from one start to
  the next.
- A port someone asked for by number (a container's `-p`, a service's
  `publish`, a deployed service's port) is never moved. If another program
  holds it on the Mac, it is not reachable from the Mac.
- The forwarder tells the node what it got: `PUT /v1/reach` with
  `{"names", "names_tls", "web", "web_tls", "ports": [{"port", "here",
  "why"}]}`, again whenever it changes and whenever the node has forgotten
  (it starts again knowing nothing). Only a person's socket may say it:
  an agent, a service, even the console, is refused (403), since what is
  said here decides where a person's browser is sent, with what it carries.
  A node reached directly (Linux) refuses it (400): its ports are its own.
- `GET /v1/ports` gives `here`, what the node was told (on a node reached
  directly, `{"direct": true, ...}` from its own ports), or `null` while a
  node in the VM has not been told. Until then the node hands out no
  address: `KEG_REALTIME_URL` and `KEG_SERVICE_<NAME>_URL` are left out of
  what an app is given, `origins` is empty, and there is no `page_url`,
  console address or link in the console or the Mac app.
- Everything the node hands out uses `here`: an app's `KEG_REALTIME_URL`,
  `origins`, `page_url`, the console's address, the links of `keg ports`,
  `keg app show`, `keg up`, the console and the Mac app. An app keeps what
  it was given until it is next deployed; `keg app show` and the console's
  Apps page say so ("ledger in local keeps the realtime address ...,
  which no longer leads to this node, until it is next deployed: keg up").
- `keg vm status` says which ports this node got, and why any is not the
  usual one ("7380 is in use by another program, so names are on 7381").
  `keg ps`, `keg ports` and the console's rows say of a published port the
  Mac does not reach: "4222 is not reachable from this Mac: another
  program holds it".

On Linux kegd binds `--names` and `--names-tls` itself. A port that is
taken there is said in kegd's log ("names are not served: ..."), and the
node goes on without names, handing out none.

### HTTP/1.1 through the names

One connection to the names is for one name: the first request's `Host`
(over `--names-tls`, the name the caller asked a certificate for, which
the first request must match, else `421`). Every request on the connection
is read as far as its head and the framing of its body before it is sent
on, and:

- One whose `Host` is another name, even another name of the same service
  (`web.local.keg.localhost` after `web.keg.localhost`), is answered
  `421 Misdirected Request` once the answers to the requests before it
  have been sent, and the connection is closed; it reaches nothing. A
  client opens a new connection for it.
- One that two readers could frame differently is refused, not guessed at:
  `Content-Length` and `Transfer-Encoding` together, `Content-Length` twice
  or not plain digits, `Transfer-Encoding` twice, or other than `chunked`
  (`501`), or on HTTP/1.0, a line ended by a bare LF or CR, a header folded
  onto the next line, a space before a header's colon, a control character
  in a value, no `Host` on HTTP/1.1 or two, a request line not of three
  parts one space apart, a target in absolute form naming another host
  than `Host` (all `400`), a head over 32 KiB (`431`). `CONNECT` is `405`.
  A chunked body whose chunk lines are not as HTTP says ends the connection
  where it goes wrong.
- `Upgrade: h2c` (and its `HTTP2-Settings`) is taken out of the request,
  which is answered over HTTP/1.1: HTTP/2 is reached with prior knowledge,
  where each request is checked (below).
- Any other upgrade (a websocket) is carried once the service answers
  `101`: from then on both sides are the service's own protocol. If the
  service answers otherwise, the requests after it are checked as before.
- Pipelined requests, chunked and streamed answers, answers to `HEAD`, and
  `Expect: 100-continue` are carried as they are. An answer whose end
  cannot be told (no length and not chunked, or two lengths that differ)
  is passed on to the end of the connection, and no request after it is
  sent on.

### HTTP/2 and gRPC through the names

A service whose `keg.yaml` says `run.protocol: h2c` (its port speaks
HTTP/2 without TLS, as gRPC servers do, beside or instead of HTTP/1.1) is
reached with HTTP/2 by its names: with prior knowledge on `--names`, and
on `--names-tls` by ALPN `h2`. Nothing else is: a service that has not
said so, a container run by hand, the console and Keg's own services
(`*.svc`) answer HTTP/2 with `505` and are reached over HTTP/1.1 only, and
over TLS are offered only `http/1.1`, since a browser offered `h2` would
use it with any name.

Keg ends the caller's HTTP/2 and opens its own to the service, checking
every request before it is sent on:

- The first request's `:authority` chooses the service, by the rules
  `Host` follows over HTTP/1.1. Over TLS it must be the name the caller's
  certificate was asked for (SNI). Each certificate names one name, so a
  browser never shares one connection between two apps.
- Every later request on the connection must be for the same name. One for
  another app is answered `421 Misdirected Request` and sent nowhere, so
  one connection reaches one service, whatever a caller writes. A `host`
  header that disagrees with `:authority` is refused (`400`).
- `CONNECT`, plain or extended (a websocket over HTTP/2), is refused
  (`405`), as over HTTP/1.1: what a tunnel carries could not be checked.
- The caller has 30 seconds for its preface and first request's headers,
  however slowly they come; a connection is closed once nothing has been
  open on it for 5 minutes, counted from when its last request ended;
  headers are held to 32 KiB, as an HTTP/1.1 head is; a connection may have
  100 requests open and carry 10,000 in all (then `GOAWAY`, and the caller
  opens another); one request lives at most 15 minutes, as a TLS
  connection does, and is then reset; the node holds at most 256 such
  connections (one more is sent `GOAWAY` with `ENHANCE_YOUR_CALM`), of
  which one name may have 64; once it holds 192, only a name with fewer
  than 8 is let in. A connection past its name's share has its first
  request answered `503`. Every caller reaches the names from the node's
  loopback, so there is no cap by the caller's address. Over TLS
  the handshake has 15 seconds, and the TLS relay's own bounds hold (60
  seconds with nothing sent either way, 15 minutes in all), so a gRPC
  stream that is quiet for a minute is cut there; a client that sends
  keepalive pings keeps it.

A gRPC client dials `<app>.keg.localhost:<names port>` (grpc-go:
`passthrough:///` and insecure credentials, or TLS trusting
`keg trust --print`). The app's own port (`localhost:<port>`) reaches it
as before.

Cookies are not kept apart by port: a cookie a page by
`desk.keg.localhost` sets on one node is sent to `desk.keg.localhost` on
every port of the computer, and so to another node's app of the same name.
Keg itself sets no cookie: the console keeps what opens it in the page's
`sessionStorage`, which is kept apart by port, and the realtime gateway
takes a session only as `Authorization: Bearer`. An app that keeps a
session in a cookie should not count on its name being its own when two
nodes run on one computer.

## The app door's claim (`Keg-Claim`)

`POST {KEG_DOOR_URL}/v1/model/calls` takes an optional `Keg-Claim` header:
`v1.<thread>.<organization>.<0|1>.<expires>.<mac>`, as
`keg.thread_door_claim(thread, token)` returns it to the worker that holds
the thread (capability 021). `<0|1>` is whether the thread is a dry run,
`<expires>` seconds since 1970 (five minutes from when it was made), and
`<mac>` the HMAC-SHA256, in hex, of `keg-door-claim|<database>|` followed
by everything before the last dot, under a key the node puts in the app's
database (`keg.door_key`, readable by `<db>_keg` alone). The key is made
anew at each deploy; the door takes a claim signed with the key before it
for six minutes after, which is as long as such a claim can still be
good, so a step under way across a deploy is not refused. The node gives
the key to `psql` in the Postgres container as a setting of the
connection, in that process's environment, as it gives the role's
password: Keg's driver runs a command with arguments and an environment
and no input.

The door refuses with 403 `forbidden` a claim that is not of that shape,
whose MAC does not check for that app and environment's database, whose
time has passed or is more than six minutes off, or that is for another
thread or organization than the call's `Keg-Thread` or `Keg-Organization`
names. A call with a claim is counted for the claim's organization and
held to its ceiling where one is set; a dry run's is counted as an
evaluation. A call with no claim is counted under no organization:
`Keg-Organization` alone is never counted.

The `done` line's `usage` may carry `cached_input_tokens`: how many of
`input_tokens` the provider read from its cache.
