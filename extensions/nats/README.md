# nats

A service for Keg, installed from outside as anyone's would be. It runs a
NATS server with JetStream on this computer's port 4222, and is told of the
node's events: each piece of work's (`work.*`) and each change set's
(`changeset.changed`). It puts each in the stream `KEG`, on the subject
`keg.<type>`, for example `keg.work.changed`, as the event's JSON. A
character of a type that is not a letter, a digit, `_`, `.` or `-` is
written `_`.

Each event is published with its id as `Nats-Msg-Id`, so one the node gives
it twice is kept once. A delivery is finished only once JetStream has the
event, with `{ "seq": N }`, its place in the stream; if JetStream does not
take it, the delivery fails and the node tries it again.

The service's stream holds at most 64 MiB. Readers read a stream of their
own, also `KEG`, in an account of their own, which keeps each event as it
is published and holds at most 704 MiB; together they leave room on the
service's 1 GiB volume for JetStream's own files. When either is full,
its oldest events are dropped to take the newest, so it never refuses
one for want of room. Neither is bounded by age. The readers' stream
holds what was published while it was there: if it is ever gone, the
service makes it again within 30 seconds, empty.

Its page, on port 8222, lists the last 50 events it published, and how
many. It is answered only for a name of this computer (`127.0.0.1`,
`localhost`, or a name under `.keg.localhost`), so a site that points a
name of its own here cannot read it from a browser. What it lists is had
only with the reader password: the page asks for it, keeps it in the page
alone while it is open, and asks `POST /published` with it as a bearer
token and the header `X-Keg-Nats: 1`. Anything on the node's network,
a coding agent's machine among them, can reach the port; the password is
what keeps it out.

## Who may do what

A reader connects to `127.0.0.1:4222` as the user `reader`, with the
password a person sets for the service:

```sh
openssl rand -hex 24 | keg system secret nats READER_PASSWORD
```

The password is a person's, an operator's: whoever has it reads every
event the service has, and of an app's events every organization's. It
is never for an app's users, and the app is given nothing for the
service (its bindings ask for no token).

It is at least 32 characters, of letters, digits and `. _ ~ + / = -`.
Until one is set, or while what is set cannot be one, every reader is
refused, and the page says so; the service asks for it every 10 seconds,
so a new one is used within that. It is never in the service's log or on
its page. A client then connects with
`nats://reader:<password>@127.0.0.1:4222`.

A reader may subscribe to `keg.>`, read the readers' stream `KEG`, and
make, read, acknowledge and remove consumers of it. Readers are in an
account of their own, `READERS`, which has its own stream and the events
as they are published, and nothing else of the service's: a consumer a
reader makes, and wherever it delivers, are in that account, so nothing
a reader does can reach the service's own stream, its API, or where the
service is answered. At worst someone with the reader password can
damage the readers' copy (a consumer whose deliveries name a subject of
that account's API); the service's own stream and what it publishes
cannot be touched from there. Only the service publishes: it connects
as `keg`, in the account `KEG`, with a password made at random each time
it starts, kept in the server's configuration and nowhere else. A reader
cannot publish to `keg.>`, so nothing can pass for the node's events, and
cannot make, change, purge or remove a stream. Every reader is the one
user, so one can remove another's consumer.

What readers hold is bounded, so they cannot take the volume's files or
the service's memory: at most 32 consumers of their stream, each with at
most 1000 delivered and not yet acknowledged; at most 64 connections and
1000 subscriptions among them all; and 64 KiB in one message they publish
(a request, never an event). The server takes at most 128 connections in
all. The service makes its own connections before any reader is let in
and keeps them while it runs; should it lose one, it stops, and the node
starts it again. An event is published as one message of at most 1 MiB,
NATS's own limit, which is past anything the node tells of (an app's
payload is cut at 16 KiB); one larger would be finished
`{"published": false, "refused": "not published: it is N bytes, ..."}`,
never failed for it.

## Install

Building a service from its folder is off on a node until a person turns
it on:

```sh
keg system builds on
keg system install extensions/nats
keg system start nats
```

The install asks, item by item, for what its manifest names: to be told of
those events, a volume for JetStream's data (at `/data`), the secret
`READER_PASSWORD`, which a person then sets, and port 4222.
On a node where the app SupportDesk is, it also asks to hear SupportDesk's
`ticket.*` events, which carry what each ticket says, from every
organization; they go to `keg.app.supportdesk.ticket.<what>`, where
whoever has the reader password reads them all, each with who it is for
(`audience`: `null` for every member, else `{"roles": [...]}`,
`{"users": [...]}` or both in one) and what it is about (`about`), as the node told of
them from the event's row, beside `organization`. NATS holds none of them
to an audience: a reader that shows events to people must. The question says so,
and that the app is given nothing for the service. Where there
is no SupportDesk, that one cannot be allowed, and the rest can.

It reaches nothing but its socket to the node: NATS clients reach it on
`127.0.0.1:4222`. Another container on the node, a person's or another
service's, cannot reach it at its own address: the node lets in only what
comes through the ports it publishes.

## What it is made of

- The NATS server 2.10 (`nats:2.10-alpine`, Apache-2.0), its program only.
- Node 22 (`node:22-alpine`, MIT; on Alpine Linux).
- The `nats` client for Node 2.29.3 (Apache-2.0), with `nkeys.js`
  (Apache-2.0) and `tweetnacl` (Unlicense), pinned in `package-lock.json`.
- `vendor/keg-node`: Keg's client for the node, as Keg ships it.

Both images are named by digest in the `Dockerfile`. The image is built on
the node that installs it; nothing of it is shipped with Keg.
