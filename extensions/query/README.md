# query

A service for Keg, installed from outside as anyone's would be. It is told
of the node's events: each piece of work's (`work.*`) and each change
set's (`changeset.changed`). It keeps each, once, in DuckDB, in the table
`events` of `/data/events.duckdb` on its volume:

| column | what |
| --- | --- |
| `id` | the event's id; an event told of twice is kept once |
| `cursor` | its place in the node's log |
| `type` | `work.changed`, `app.supportdesk.ticket.opened`, ... |
| `subject` | what it is about: `work/7` |
| `"at"` | when, in UTC (`at` is a word of DuckDB's: write it in quotes) |
| `actor_role`, `actor_name` | who did it |
| `payload` | the event's payload, kept as DuckDB's JSON and answered as its text (`json_extract_string(payload, '$.organization')` reads into it); an app's event has the app, its environment, `organization`, `audience` (who it is for: `null` for every member, else `{"roles": [...]}` or `{"users": [...]}`, or both in one, `{"roles": [...], "users": [...]}`, for whoever is in either) and `about` (`ticket/42`, or `null`) in it, each from the event's row |

It keeps 30 days of events, and at most 384 MiB of them, as their text
is counted: 256 MiB of the node's own and 128 MiB of apps', each held
apart, so apps that write much never push out the node's work and change
sets (each app's own database, 128 MiB); past either, the oldest go
first, every ten minutes and as it starts. What goes goes by a cut-off in
time, found from sums by day, hour, minute and second, and is deleted
10,000 rows at a time with a checkpoint after each, so a database of
millions of events is held within DuckDB's memory limit. A prune that
fails all the same is said on the page and in the log, and the service
starts and goes on; but while a database is past its size and could not
be made smaller, nothing more of that part is kept in it: each delivery
fails, saying why, and the node tries it again later, while a prune is
tried again at most once a minute. So the size bound never stops working
unseen while the volume fills. That leaves room on its 1 GiB volume for
DuckDB's own files. Should a write fail for want of room, that
database is held to its size at once and the write is tried again; a
write that fails for anything else is tried again later, and nothing
kept goes for it. An event that could never be kept (a time past 9999, a
payload over 1 MiB, text with a lone surrogate in it) is not: its delivery is finished saying why, so it
is not tried for ever.

It answers SQL that only reads, on this computer's port 8224:

```sh
curl http://127.0.0.1:8224/query -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -H 'X-Keg-Query: 1' \
  -d '{"sql": "SELECT type, count(*) AS n FROM events GROUP BY type ORDER BY type"}'
# {"columns":["type","n"],"rows":[["changeset.changed",1],["work.changed",3]]}
```

A query is a POST of JSON, `{"sql": "..."}` of at most 64 KiB, with the
header `X-Keg-Query: 1`. A page of another site cannot send that without
asking the browser first, and only a bound app's page is let past that
(below). A request whose `Sec-Fetch-Site` says another site's page made
it is answered 403, whether or not it has an `Origin`: a browser sends
none for an image, a script, a link or a frame.

All it holds is read with a key, which a person sets, and which the
service reads through its binding `key` (an app's own events are read
with that app's token too, below):

```sh
openssl rand -hex 24 | keg system secret query QUERY_KEY
```

It is at least 32 characters; one shorter reads nothing, and a request
is told so. A request without it, or with another, is answered 401. Its page asks
for the key and keeps it on the page alone, until the page is closed;
the service never writes it to its log.

A whole number is a JSON number when it is exactly one, and a string when
it is too large. A value of a fixed width (a number, a time, a
boolean, a uuid) is answered as it is; any other (a text, a blob, a bit
string, a list, a struct, a map, ...) is answered as its text, a nested
one as DuckDB writes it (`[1, 2]`, `{'a': b}`), cut at 4 KiB, counted in
bytes and never within a character. At most 100 columns are answered (a
query with more is answered 400), at most 10,000 rows, and at most 8 MiB
in all; DuckDB is asked for no more rows than so many columns that wide
could fit in 8 MiB, so what it makes is held to that too: a query of 8
texts is answered at most about 250 rows, one text and a count about
2,000. When anything was left out, the answer says `"cut": true`.

A query is answered from a copy of the database it reads, and the answer
says as of when, `"as_of"` (an ISO time): what was kept up to then is all
in it, and a page's numbers may be a few seconds behind. The databases'
process, which keeps the events, makes the copy as a query asks for it,
after a checkpoint, to a file of its own that is renamed into place once
it is whole, so a query reads the copy before or the one after, never one
half made; a database that changed is copied again at most every 2
seconds, and meanwhile the copy before is read. A query runs in a reader,
a process of its own that opens the copy so that it only reads, locked as
every database is, and keeps nothing.

A query is stopped after 10 seconds, counting the time to turn its answer
into JSON: DuckDB is told to stop it then, and its reader is killed
(SIGKILL) 2 seconds later if it has not stopped, whatever it calls.
DuckDB looks at whether to stop only between calls of a function, and one
call can run on past it (`levenshtein` of two strings of 60,000
characters ran 5 seconds past); no function is refused by its name for
that. Either way it is answered 400, `the query took more than 10 seconds
and was stopped`, and only that query is lost: the events are kept by the
databases' process, which no query reaches, and the other readers go on.
Four run at once in all, each in a reader of its own, and of those one
for each organization of each app (one for the key, one for each app's
own token too); one more is answered 429, with `Retry-After: 1`, so one
organization's users cannot take every place. A token for one
organization may ask at most 20 queries a minute; past that it is
answered 429 with a `Retry-After` of when it may ask again. Its page, at
`/`, takes a query and shows the answer as a table.

The copies take room on the volume. Each database has one copy at most,
made only when a query asks for it, and one being made; a copy nobody
asked for in 10 minutes goes, and all go when the databases' process
starts. As the service counts what it keeps (a file may be a little
larger), the main database holds at most 384 MiB, an app's own 128 MiB
and its organizations' 64 × 4 MiB = 256 MiB: 768 MiB in all with
SupportDesk's. Their copies take at most as much again, and the one being
made at most 384 MiB more: about 1.9 GiB at the very most, and as much as
the databases that are read, as they are now, otherwise. A copy is not
made where it would leave less than 64 MiB of the volume free: the copy
before is read, said as of when it was made, or, with none, the query is
answered 400 saying there is no room.

The service has 1024 MB, the most a service may. The databases' process
answers no query: DuckDB is held there to 160 MB for the main database,
48 MB for an app's and 24 MB for each of the four organizations' open at
once, about 350 MB with its Node (measured idle, 84 MB). Each of the four
readers holds a query's database to 64 MB, with two threads, about 145
MB with its Node (measured idle, 80 MB), 580 MB for the four; the
service's own program takes about 60 MB: about 990 MB of the 1024 in all.
DuckDB refuses a query that would take more of what it counts: nothing
is spilled to disk, where it would take the room the events are kept in.
A value of hundreds of MB made at once is not counted by DuckDB (a reader
was measured at 940 MB for one of 400 MB): the kernel stops a reader
first when the service is out of memory, then the databases' process,
so such a query is answered 400, `the query needed more memory than the
service has, and was stopped`, and nothing else stops. A write of an event
that fails is tried three times before its delivery is failed.

Should the databases' process stop, it is started again. Meanwhile a
query is answered 503, `the databases' process is being started again;
ask again soon`, with `Retry-After: 2`, as its copy is made by that
process. An event to be kept meanwhile, or one cut short as the process
stopped, waits for it to be back and is kept then, for up to 45 seconds,
within its delivery's hold, so the node counts no try that the process's
stopping, not the event, failed; past that its delivery fails, to be
tried again later. Anything asked of the process that is not answered in
30 seconds fails too, and the process is stopped and started again.
Should it fail to start five times running, the service stops, saying
why, so the node shows it stopped.

## What a query can do

One statement that reads (DuckDB's type `SELECT`), calling no table
function but those that make rows of what it was given or tell of DuckDB
itself (`range`, `generate_series`, `unnest`, `json_each`, `json_tree`,
`duckdb_settings` and DuckDB's other lists of itself), and nothing else.
`DESCRIBE events`, `SUMMARIZE events` and `SHOW TABLES` are answered. A
`PIVOT` is answered when it names the values it makes columns of
(`PIVOT events ON type IN ('work.changed', 'changeset.changed') USING
count(*)`); one that does not is answered 400, saying so, since DuckDB
finds its values with a statement of its own first. What is not one
statement that reads is answered 400, `only one query that reads is
answered`; one that calls another table function, 400, `a
query may not call read_blob()`, and nothing of it is run; one that names
a file as a table (`FROM '/data/events.duckdb'`, which DuckDB would read
or attach), 400, `a query reads the table events, never a file: ...`. So no query
reads a file, its own database's and WAL among them, checkpoints, turns
on logging, or runs SQL given as text. It runs in a transaction that is
always rolled back.

The database is opened locked as well: DuckDB reaches no file but its
own, no network and no extension, and no query can change that
(`enable_external_access`, extension loading and installing off, then
`lock_configuration`). `ATTACH`, `COPY`, `INSTALL` and `LOAD` are
refused. The service itself reaches nothing but its socket to the node,
and runs as the user `node`, not root.

## Who it answers

Nothing it holds is read without a credential, by a program or by a
browser's page, and no request without one reaches its databases:

- Its key, which a person sets (above), reads all it holds.
- An app's token reads all of that app's events, every organization's,
  and is taken only from a program: a request with an `Origin`, or a
  `Sec-Fetch-Site` but `none`, is refused it, so it never works from a
  page. For each app the service is bound to (its manifest asks for a
  token on those bindings), the node makes a token (256 bits, at random)
  and gives it to the service with the binding, and to that app's own
  servers as `KEG_SERVICE_QUERY_TOKEN`, beside `KEG_SERVICE_QUERY_URL`,
  the address a person's browser opens the service on
  (`http://127.0.0.1:8224`), and `KEG_APP`, the app's name, when the app
  is next deployed (until then `keg system ls` says so; a token from
  before the service was installed again is answered 401, saying it may
  be that). An app's containers do not reach the service in
  this version. It is made anew when the service is removed or replaced
  from another folder, and it is never in an event, a log, `keg system
  ls`, or anything an agent can read (but code an agent deploys as the
  app runs with it, as it runs with the app's database).
- A token for one organization reads that organization's events alone,
  and of them only those for every member of it: an event the app sent
  to some users or roles only (its `audience`), or to roles and users at
  once, is not shown to a page through this service in this version,
  whoever the page is signed in as.
  The app's own token, which stays on its server, reads them all.
  The app's server makes it with the app's token, for the signed-in
  user's organization, for at most 15 minutes, and hands it to its page:
  `require('@keg/app/service').serviceToken('query', { org, ttl })`. Its
  form is `v1.<payload>.<mac>` (`docs/PROTOCOL.md`). The service checks
  its mac in constant time, that it has not expired (30 seconds are
  allowed for the clocks) and lasts no more than 15 minutes, and that its
  app is one it is bound to; one that fails any is answered 401, saying
  which, except that one of an app it is not bound to is refused in the
  words of one whose mac is wrong, so that nobody learns which apps are.
  It is a bearer token: whoever holds it reads that organization's events
  with it, from anywhere on this computer, until it expires, up to its 15
  minutes. It is not bound to a page's origin.

Anything on this computer may ask, on 127.0.0.1:8224, with one of those.
Another container on the node, a person's or another service's, cannot
reach it at its own address: the node lets in only what comes through the
port it publishes.

It is reached on this computer only. It answers a request whose `Host`
is this computer's (`127.0.0.1`, `localhost`, or a name under
`.keg.localhost`), so a site that points a name of its own here is not
answered.

A page of an app it is bound to may read it, with a token for one of
that app's organizations, which the app's server hands to its page: its
origin is let past the browser's asking first, and echoed in
`Access-Control-Allow-Origin`. Which pages are the app's the node says,
with the binding: the exact origins of the names it serves for the
app's services, on the ports it serves names on (for SupportDesk made of
the service `desk-web`, `http://desk-web.keg.localhost:<names port>`). A
page named like the app, or by the app's name on another port, is not
the app's and is answered 403. A page of the app with no token, with the
key, with the app's own token, or with another app's is answered 401.

## Kept apart

Each app's events are kept in a database of that app's alone,
`/data/apps/<app>.duckdb`, which the app's token reads, and again, by
organization, in one database for each of its organizations,
`/data/apps/<app>/<organization>.duckdb`, which a token for that
organization reads, and nothing else. Which organization an event is of
is what the node says (`organization`), which the node reads from the
event's row in the app's database, never from what the app wrote. An
event with no organization is in the app's database alone, and so is
one for some of its users or roles only, or with an audience the
service does not understand. So a page of
SupportDesk's, signed in to one organization, reads that organization's
tickets and ratings, and nothing of another's, of the node's or of
another app's. A token for an organization with nothing kept yet reads
an empty table.

**How many organizations are kept apart: 64 for each app.** Each
organization's database keeps 30 days and at most 4 MiB of events, as
the others are held (64 of 4 MiB is 256 MiB of the volume); one emptied
by its days goes, and its place with it. They are opened as they are
needed, at most 4 at once, each with 24 MB of DuckDB's memory. The places
go by recent use, not to the first to come: an organization whose
database has had nothing written for 7 days gives its place up to one
that needs a place. An organization given a place is filled first with
what the app's own database still has of it (its newest 20,000 events,
then held to its 4 MiB): so one that comes back within the 30 days finds
its events again. Past 64 organizations that all wrote in the last 7
days, an event of another is kept in the main database and the app's own
alone, where only the query key reads it; the page and the log say so
once, and a token for that organization is answered 400, `supportdesk
keeps 64 organizations apart, the most it does, and this one is not
among them now: ...`, until a place comes free. The bound is the
service's own and is not a setting: Keg has no setting a person gives a
service but its secrets. A storage design without a file for each
organization would need no such bound.

## When a database cannot be opened

A database DuckDB says is damaged (not a DuckDB file, or a block whose
checksum is wrong) is not opened again and again: it is moved aside, with
its WAL, to `<file>.corrupt-<when>` on the volume, in place of any set
aside before (one is kept, so a database damaged again and again cannot
fill the volume), a new one is begun empty, and the page and the log say
so. What was in it is still there, for a person to look at with DuckDB,
or to put back while the service is stopped (`keg system stop query`,
then the file renamed back over the new one). Removing the service with
its data removes them.

A database that cannot be opened for any other reason (the volume full,
too little memory, a file it may not read) is left as it is, and the
service stops, its last line saying why, so the node shows it stopped
and a person can make room and start it again. Nothing of it is set
aside.

DuckDB's binding for Node gives an error's message alone, which begins
with DuckDB's type of it (`IO Error: `, `Serialization Error: `, ...): the
service reads the type there. Room is made only after an `IO Error` that
says the disk is full, or any `IO Error` while the volume has less than
16 MiB free.

## Install

Building a service from its folder is off on a node until a person turns
it on:

```sh
keg system builds on
keg system install extensions/query
keg system start query
```

The install asks, item by item, for what its manifest names: to be told of
those events, a volume for its databases (at `/data`), and the secret
`QUERY_KEY`, its key, which a person then sets. On a node where
the app SupportDesk is, it also asks to hear SupportDesk's `ticket.*` and
`rating.*` events, which carry what each ticket and rating says, from
every organization. Where there is no SupportDesk, those cannot be
allowed, and the rest can.

## What it is made of

- DuckDB 1.5.6 (MIT), as `@duckdb/node-api` and `@duckdb/node-bindings`
  1.5.6-r.2 (MIT), with the prebuilt library for this computer's Linux
  (`@duckdb/node-bindings-linux-arm64` or `-linux-x64`, MIT), and
  `detect-libc` 2.1.2 (Apache-2.0), pinned in `package-lock.json`.
- Node 22 (`node:22-bookworm-slim`, MIT; on Debian 12), named by digest
  in the `Dockerfile`.
- `vendor/keg-node`: Keg's client for the node, as Keg ships it.

The image is built on the node that installs it; nothing of it is shipped
with Keg.

## Tests

```sh
npm ci && node --test
```
