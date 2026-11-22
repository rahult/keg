# Keg's events: one protocol, two stores

Keg keeps events in two places: in each app's own database (the app layer,
`keg.*` in Postgres)
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
"Known differences".

## On the node

**Event.** `id` (uuid), `type` (dotted, lower case, thing then what
happened: `work.created`, `gate.answered`), `subject` (what it is about,
`kind/name`: `work/7`, `changeset/local/15`), `at` (seconds since 1970),
`actor` (a role and a name), and `payload`: small JSON, ids and states
only, never a brief, a title, a secret, a diff, a note or the body of
evidence. Events have an order, and the place in it is the **cursor**,
which a reader keeps and treats as an opaque string.

**Subscription.** A name, an owner (the service), and the event types it
takes. It is made from the service's manifest, `listens`.

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
- At most one delivery for the same subject is `running` in a
  subscription at a time, so what happens to one thing is handled in
  order. Deliveries for other subjects are not held up by it.

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
"payload"}`, `at` in seconds, `payload` whatever JSON the app wrote (an
object, a list, a string or a number, as it is). An app payload over 16 KiB
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

`005_relay.sql` reaches an app bound before it at its next deploy, or as
the node begins to follow the app (when the node starts, or the app is
first bound). The node refuses to read from a Postgres older than 13, and
says so in its log. Where the app uses realtime, Postgres tells the node of
each commit, and that is only a reason to read; it asks every minute
besides. It reads at most 500 rows at a time, and writes at most 1200 of an
app's events a minute into its log for each environment; the rest wait,
in order. What an app wrote before a service was first bound to it is not
told of, and a binding added later hears only what began after it was
allowed or committed after the node first read for it. An app's events are
kept, held back and counted as what a service writes is, each app as one
writer, so they never push the node's own out. Nothing but such a binding
brings an app's events to a service, and a service cannot listen to an
`app.` type itself.

**Withdrawing.** The node can withdraw the deliveries for a subject: they
are marked `done` with `last_error` "withdrawn", their tokens stop
working, and no `delivery.done` is written. It does so when a piece of
work is stopped, sent back, retried or rejected, and for a subscription's
deliveries when its service is removed. There is no call for it.

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
| Write an event | `keg.emit(type, payload)`, as the acting user, any payload | the node's emit, in the transaction of its change; nothing else may; ids and states only |
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
`work`.

## What the node writes

| Type | Subject |
|---|---|
| `work.created`, `work.changed` | `work/<id>` |
| `stage.started`, `stage.finished` | `work/<id>` |
| `check.requested` | `work/<id>` |
| `gate.asked`, `gate.answered` | `work/<id>` |
| `gate.withdrawn` | `work/<id>`, with `{gate}`, when a person stops, sends back, retries or rejects work that has an open question |
| `evidence.added` | `work/<id>` |
| `changeset.created`, `changeset.changed` | `changeset/<env>/<id>` |
| `service.installed`, `service.started`, `service.stopped`, `service.removed` | `service/<name>` |
| `service.failed` | `service/<name>`, with `{name, code}`, when a service that kept stopping by itself is left failed for a person |
| `app.bound` | `app/<name>`, once the app's release is recorded as deployed |
| `container.started`, `container.stopped`, `container.removed` | `container/<id>` |
| `delivery.done`, `delivery.failed` | the delivery's subject |

`delivery.done` and `delivery.failed` are written for a service's
deliveries. `delivery.failed` carries no error text; the error is read
from the delivery. For a service from outside, `delivery.done` carries no
result either, only ids and the state: what it returned is read from the
delivery. Its `delivery.done` and `delivery.failed` count with that
service's own events, as the log is kept and as how far behind on it each
subscriber is, so a busy service never pushes out the node's events. Keg's
own services' `delivery.done` carries their result, which the workflow
reads, and counts as the node's.

## Who may do what on the node

- **A person** reads every event, lists subscriptions and deliveries, and
  retries a failed delivery.
- **A service** claims, extends, finishes and fails the deliveries of its
  own subscription, and nothing else of the log. It needs the grant
  `events:take`, which a person allows when installing it. A service
  cannot make a subscription, change what it listens to, emit, read the
  log or set a timer.
- **An agent** has nothing of the log.
- **Nobody** answers a gate or approves a change through the log. Those
  stay the calls they are, for a person alone. No event approves
  anything.

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
- An app's dead letters are shown only by `keg app show`, as a count.
- Only the node has a person's retry, keeping and withdrawing.
