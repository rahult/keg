# An app on Keg's capabilities

An app is a service whose `keg.yaml` names an `app` and the capabilities
it `uses`. Keg gives it a Postgres database of its own in each environment,
in which tenancy is the database's to keep: sign-in, sessions,
organizations and members (`identity`), events (`events`), jobs (`jobs`),
and a gateway that pushes each user what they may read (`realtime`).
Everything below is what is there. If you need something not listed,
check `--help` and the files `keg app new` wrote; if it is not there, say
so rather than invent it.

## Start from what Keg writes

```sh
cd /home/me/work
keg app new notes
```

Run it in the folder that holds the project, naming the project's folder:
it fills `notes/` if that is empty or not there (never a folder inside
it), with `keg.yaml`, `Dockerfile`, `package.json`,
`server.ts`, `migrations/001_init.sql`, and Keg's client in
`vendor/keg-app`, which `package.json` names as
`"@keg/app": "file:./vendor/keg-app"`. Read them before writing.

- `@keg/app` is not on npm (a package of that name there is not Keg's).
  Use the copy in `vendor/keg-app`. An app made without it: make one with
  `keg app new` in a scratch folder and copy its `vendor/keg-app`.
- The app's name is lowercase letters, digits and `-`, at most 30.

## keg.yaml

```yaml
service: notes
app: notes
uses: [data, identity]          # and events, jobs, realtime as needed
build: .
run:
  port: 8080                    # given to the app as PORT
  health: /healthz
checks:
  - { name: e2e, run: "npm install --no-audit --no-fund && npm test", db: true }
```

The app is given `DATABASE_URL` (its own database, where it acts as the
app's role and is held to what its users may see) and `PORT`.

## Migrations

- `migrations/*.sql`, run in name order as the app's owner when a release
  is deployed. Tables are made in the schema `app` (`notes` is `app.notes`).
- **Never edit a migration that has run.** Keg refuses the release
  (`migration 001_init.sql was changed after it was applied; add a new
  migration instead`). Add `002_...sql`. In a piece of work this holds
  from the first time the work reaches its gate: Keg tries the work by
  deploying it, which runs the migrations it added. Sent back, the work
  adds a new migration; it never edits one it committed before.
- A table becomes a tenant table in the same migration that creates it.

## Tenant tables: the rules that cost rounds

```sql
CREATE TABLE notes (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organization_id uuid NOT NULL DEFAULT keg.actor_organization(),
    author_id uuid NOT NULL DEFAULT keg.actor_user(),
    body text NOT NULL
);
SELECT keg.tenant_table('app.notes', update => false);
-- Restrictive, and one command each: FOR ALL would hide rows from reads too.
CREATE POLICY notes_written_as_oneself ON notes AS RESTRICTIVE FOR INSERT
    WITH CHECK (author_id = keg.actor_user());
CREATE POLICY notes_deleted_by_author ON notes AS RESTRICTIVE FOR DELETE
    USING (author_id = keg.actor_user());
```

1. A tenant table shows a row only to an actor of its organization, and
   **lets every member read and write every row of it for every command**
   unless you say otherwise.
2. Turn a command off for everyone (jobs too):
   `keg.tenant_table('app.notes', update => false, delete => false)` (and
   `insert => false`). Called again it keeps what it is not told.
3. Narrow a command with a policy `AS RESTRICTIVE FOR <command>`. A
   permissive policy does nothing (Keg's own already admits every row of
   the organization). A restrictive policy `FOR ALL` covers `SELECT` too
   and hides rows from reads.
4. Policy names beginning `keg_` are Keg's: `keg.tenant_table` drops and
   makes them again. Name yours otherwise.
5. In SQL: `keg.actor_user()` (uuid, null in a job), `keg.actor_organization()`,
   `keg.actor_role()` (`administrator`, a member's role, or `system` in a job).
6. A foreign key between tenant tables is checked **without** row
   security: `supplier_id bigint REFERENCES suppliers (id)` lets one
   organization name another's supplier, and learn whether an id exists.
   After both `keg.tenant_table` calls, make it
   `SELECT keg.tenant_ref('app.orders', 'supplier_id', 'app.suppliers');`:
   it names only a row of the same organization (it replaces the plain key
   and keeps its `ON DELETE`), and another organization's id is refused
   exactly as a missing one (23503).

## Identity and organizations

With `@keg/app` (`import { connect } from "@keg/app"`; `connect()` reads
`DATABASE_URL`):

- `await keg.signUp(name, email, password)` gives the user's id; a
  password is at least 10 characters. `await keg.signIn(email, password)`
  gives a session token; `keg.signOut(token)`.
- `await keg.organizations(token)`: `[{ id, name, role }]`.
- `await keg.tx(token, organizationId, async (db) => ...)`: one transaction
  as that user in that organization; refused if they are not a member.
- An organization is made in SQL by a signed-in user, who becomes its
  administrator: `SELECT keg.create_organization($1, $2) AS id` with the
  token and a name, on a `pg` pool of `DATABASE_URL` (add `pg` to
  `package.json`). `keg app org add <app> <name> --admin <email>` does it
  from the command line, and is a person's.
- Signing up makes no organization and joins none: make them as above.
- Inside a `tx` as an administrator: `SELECT keg.add_member($1, $2)` with
  an email that has signed up and a role (lowercase word, not `system`);
  `SELECT keg.set_role($1, $2)`. `keg.join(token, organization)` joins one
  that is open.
- A member may hold more roles beside that one, their primary role
  (experimental: `member-roles`, off until a person turns it on, and
  refused in the node's words while it is off). An administrator grants
  one with `await db.grantRole(userId, 'agent')` (`SELECT
  keg.grant_role($1, $2)`) and takes it with `db.takeRole` (`SELECT
  keg.take_role($1, $2)`); each returns the member's roles, the primary
  first. The primary is changed with `keg.set_role`, never taken. Who an
  event, a thread or an ask is for, who approves a tool, who replays and
  who uploads an organisation's tools is asked of every role a member
  holds: a supervisor granted `agent` reads what is for agents and still
  answers what is for supervisors. An app that grants none behaves as
  before. `keg app members <app>` lists who holds what.

In a `tx`, `db`:

- `await db.query(sql, params)` returns **the rows** (an array), not a pg
  result: no `.rows`.
- `db.actor`: `{ user, organization, role }`, `role` the primary one;
  `db.roles` is every role the actor holds, the primary first, and
  `db.hasRole('agent')` asks it.
- `await db.emit(type, payload, { to, about })`: `to` is `'organization'`,
  `{ roles: [...] }`, `{ users: [...] }`, or both in one
  (`{ roles: ['agent'], users: [customerId] }`: whoever is in either); left out, every member may
  read it; `to: undefined` or `null` is refused. `about` is like
  `"note/42"`, at most 200 bytes. A type beginning `keg.` is Keg's and
  refused.
- `await db.events({ type, about, limit, before })`: the events this actor
  may read, newest first, and those of one transaction in the order emitted.
- `await db.enqueue(name, payload, { runAt, asUser })`, `await db.once(key)`.

## What of Keg's an app reads

Keg's own tables are not the app's to read. These views are, each for
the member who acts (and empty for anyone else), with these columns and
no others: `SELECT` them by name, and join your tables to them by these.
There is no `organization_id` on `keg.members`: it lists the members of
the organization that acts, which `keg.actor_organization()` names.

  `keg.me`: `user_id`, `name`, `email`, `organization_id`, `role`, `roles`
  `keg.members`: `user_id`, `name`, `email`, `role`, `roles`
  `keg.my_events`: `id`, `type`, `payload`, `at`, `actor`, `about`
  `keg.my_jobs`: `id`, `name`, `state`, `attempts`, `last_error`, `run_at`

An app that uses agents reads more, listed with their columns in
`agents.md`. A row-security policy asks who acts with `keg.actor_user()`,
`keg.actor_organization()` and `keg.actor_role()`, never by reading a
view of Keg's. `role` and `keg.actor_role()` are the primary role; `roles`
is every role held, the primary first. A policy for a role asks
`keg.actor_has_role('agent')`, which a member granted that role passes
too; `keg.actor_role() = 'agent'` asks for the primary role alone.

## Events, jobs, realtime

- In SQL: `keg.emit('note.added', payload, '{"users": ["<id>"]}')` (or
  `'{"roles": [...]}'`, `'{"roles": [...], "users": [...]}'` for whoever
  is in either, `'{"organization": true}'`); the view
  `keg.my_events` gives a member the events meant for them. Give an
  audience whenever an event is not for everyone. To read pages of them
  use `db.events({ type, about, limit, before })` in the server, not SQL
  of your own over `keg.my_events` with `ORDER BY … LIMIT`: it reads
  every page from the feed's index, where your own query may be planned
  as a scan of the whole table.
- Realtime pushes only what may be read, and only the types you say:
  `SELECT keg.expose_events_to(types => '{note.added}', roles => '{member}')`
  or `keg.hide_events_from(types => ..., roles => ...)`.
- A job for each event of a type: `SELECT keg.on('note.added', 'notify')`
  in a migration, and in the server `keg.job('notify', async (payload, db, job) => ...)`
  then `keg.work()`. Such a job's `payload` is the event:
  `{ event, type, payload }`, the event's own payload inside. A job named
  with no handler waits for ever. `SELECT keg.off('note.added', 'notify')` in a
  later migration takes the subscription back and cancels its jobs that
  still wait (failed, saying so); a person removes them with
  `keg app jobs remove <app> --failed`.
- **A job acts as the system**: `keg.actor_user()` is null and the role is
  `system`. A restrictive policy that compares with `keg.actor_user()`
  refuses it: write policies that let the system do what its jobs must
  (`OR keg.actor_role() = 'system'`).
- `keg app show <app>` and `keg app jobs <app>` (with `--failed`) say what
  waits and why; they, `keg app jobs retry` and `keg app jobs remove` are a
  person's to run, so ask for their output.
- `keg app remove <app>` (typing its name, or `--yes <app>`) is a person's
  alone: it stops the app everywhere and takes back the bindings and tokens
  services held for it, keeping its database unless `--with-data`. Never
  suggest it as a fix; say what it would remove and let the person decide.
- A token for a service bound to the app: `serviceToken(name, { org, ttl })`
  from `@keg/app/service`, made on the server, never sent to a browser
  for longer than its `ttl`.

An agent (a thread the app steps, its model, its tools) is in
`references/agents.md`.

## A check that proves the rules

A check with `db: true` runs against an empty database of its own, made
from the app's capabilities and the work's migrations, given as
`DATABASE_URL`. Write tests that act as each kind of user. This one passes
with the migration above, and fails if the author rule is dropped:

```js
// test/tenancy.test.js, run by `npm test` (node --test)
import test from "node:test";
import assert from "node:assert/strict";
import pg from "pg";
import { connect } from "@keg/app";

const keg = connect();
const sql = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const run = Date.now();

async function person(name) {
  const email = `${name}-${run}@example.test`;
  await keg.signUp(name, email, "a long password");
  return { email, token: await keg.signIn(email, "a long password") };
}
async function organization(owner, name) {
  const { rows } = await sql.query("SELECT keg.create_organization($1, $2) AS id", [owner.token, name]);
  return rows[0].id;
}

test("members see only their organization's notes; only the author deletes", async () => {
  const ann = await person("ann"), bob = await person("bob"), cat = await person("cat");
  const acme = await organization(ann, "Acme");
  const other = await organization(cat, "Other");
  await keg.tx(ann.token, acme, (db) => db.query("SELECT keg.add_member($1, 'member')", [bob.email]));

  const [note] = await keg.tx(ann.token, acme, (db) =>
    db.query("INSERT INTO notes (body) VALUES ('plan') RETURNING id"));
  await keg.tx(cat.token, other, (db) => db.query("INSERT INTO notes (body) VALUES ('secret')"));

  const seen = await keg.tx(bob.token, acme, (db) => db.query("SELECT body FROM notes"));
  assert.deepEqual(seen.map((n) => n.body), ["plan"]);

  const notGone = await keg.tx(bob.token, acme, (db) =>
    db.query("DELETE FROM notes WHERE id = $1 RETURNING id", [note.id]));
  assert.equal(notGone.length, 0);
  const gone = await keg.tx(ann.token, acme, (db) =>
    db.query("DELETE FROM notes WHERE id = $1 RETURNING id", [note.id]));
  assert.equal(gone.length, 1);

  await assert.rejects(keg.tx(cat.token, acme, (db) => db.query("SELECT 1")));
});

test.after(async () => { await keg.close(); await sql.end(); });
```

A check may also name services the app's events are bound to:
`{ name: e2e, run: "npm test", db: true, services: [query] }` (it needs
`db: true`). It gets its own throwaway instance of each, fed this check
database's events, with made-up secrets and no internet, and its command
is given `KEG_SERVICE_<NAME>_URL`, `KEG_SERVICE_<NAME>_TOKEN` and
`KEG_APP`: call the service from the test's server side with them. How
to use the service is in `/keg/services/<name>/README.md` in a piece of
work; read it there rather than guess its API.

In a piece of work, run the check itself before you say you are done:

```sh
sh /keg/bin/keg-check          # the checks keg.yaml lists
sh /keg/bin/keg-check e2e      # runs one; exits as it ended
```

Keg runs it as its gate will: on your tree as it is now (what you have
not committed among it, what `.gitignore` leaves out left out), against a
new database made from your migrations, with its services and its
scripted model if it names them. It prints the end of what the check
printed, and for a failed check with agents the threads it left. It
judges nothing: the gate runs every check again on what you commit. A
round may run a number of them (20 unless a person changed it), one at a
time; a check that asks for `model: real` is the gate's alone. A check
you changed is run as you have it, and you are told the gate's rule for
it: the gate judges by the project's own check unless you only gave it
more.

Outside a piece of work you cannot run a `db: true` check yourself. The
node's person can: `keg app check NAME` in the app's folder (the
experimental feature `app-check`) runs it as the gate would, with a
database and a fake model of its own, on a copy of the folder as it is
(uncommitted changes in, `.git` and `node_modules` out), which it reads
and never writes; a check with `services:` or `model: real` runs only in
a piece of work. Ask them to, and say which check. Before you propose
the app, try everything else in a machine for its folder:

```sh
keg machine create notes --image node:22
keg machine shell notes -- npm install --no-audit --no-fund
keg machine shell notes -- sh -c 'for f in test/*.js; do node --check "$f" || exit 1; done'
keg machine shell notes -- npm test
```

Without a database the test fails when it first connects
(`ECONNREFUSED`); any other failure (`Cannot find module`, a syntax error,
a wrong import) is yours to mend first. Make the test script `node --test`
(it finds `test/*.test.js`); `node --test test/` fails on Node 22. Then
say plainly that the database check has not run yet, and how it will.

## An app with a Go server

```sh
keg app new --go ledger
```

writes `keg.yaml`, a `Dockerfile` (a static binary on `FROM scratch`),
`go.mod`, `go.sum`, `main.go`, a migration, and Keg's Go client in
`third_party/keg`, which `go.mod` names with `replace`. Read them, and
`third_party/keg/README.md`, before writing.

- The client is not on any module proxy: use the copy in
  `third_party/keg`. Never put it under `vendor/`: Go takes a folder of
  that name for `go mod vendor`'s and refuses to build.
- `keg.Connect("")` reads `DATABASE_URL`. `k.Tx(ctx, session, org, fn)`
  is `keg.tx`; inside, `tx.QueryRow`, `tx.Query`, `tx.Exec` are pgx's
  (read rows with `pgx.CollectRows`), and `tx.Emit`, `tx.Events`,
  `tx.Enqueue`, `tx.Once` are as above. An audience is
  `keg.To(keg.Roles("agent"))`, `keg.To(keg.Users(id))`, or both at once,
  `keg.To(keg.Roles("agent"), keg.Users(id))`.
- Jobs: `k.Job("notify", func(ctx, payload, tx, job) error {...})`, then
  `k.Work(keg.WorkOptions{})`. Returning an error rolls back what the
  handler wrote and the job is tried again.
- gRPC: require `github.com/rahult/keg/sdk/go/kegrpc` (in
  `third_party/keg/kegrpc`). `kegrpc.ServerOptions(kegrpc.MemberOf(k),
  kegrpc.Options{})` puts the caller's session in the context (metadata
  `authorization: Bearer <session>` and `keg-organization: <id>`), and a
  handler calls `k.As(ctx, fn)`. Serve gRPC and HTTP on the one port with
  `kegrpc.Server(":"+os.Getenv("PORT"), kegrpc.Handler(grpcServer, mux))`:
  Keg asks `run.health` over HTTP, so keep `/healthz` on the mux
  (`kegrpc.HealthHandler(k)`), or ask gRPC's own health service:
  `health: { grpc: "" }` (the whole server, or a service's full name),
  answered by `kegrpc.Health`.
- Say in `keg.yaml` that the port speaks HTTP/2 without TLS:
  `run: { port: 8097, protocol: h2c }`. Then gRPC reaches the app by its
  name, `<app>.keg.localhost` on the names port (prior knowledge, as
  grpc-go dials `passthrough:///<app>.keg.localhost:7381` with insecure
  credentials) and over HTTPS (`h2` by ALPN, trusting `keg trust --print`).
  A connection is for one name: a call on it for another app is refused
  (`421`), so dial each app on its own. Without `protocol: h2c` the names
  speak HTTP/1.1 only (`505` to HTTP/2), and gRPC reaches the app on its
  own port (`http://localhost:<port>`). A page uses Connect or gRPC-Web
  (Connect's Go handlers serve all three), with
  `keg.Sessions(keg.HTTPSession, handler)` to put the session in the
  context.
- Errors: return what the client and pgx give; `kegrpc.Status` (or
  `keg.Public` for HTTP; `publicError` in `@keg/app`) says them without
  Postgres's text, Keg's own refusals in Keg's words with their own kind
  (`keg.KegRefusal(err)`: `no_such_email`, `administrators_only`, ...).
- A check runs in the work's machine, which has Node and no Go unless the
  work's image has it. A project names the image its works run in with
  `work: { image: "<name>@sha256:<digest>" }` in `keg.yaml` (pinned by its
  digest, or the file is refused); it is read where the work begins, so it
  takes effect for works made after a person merges it, never for the work
  that wrote it. Without it, the check fetches Go (see the commented check
  in `keg.yaml`). `cd third_party/keg && go test -v ./...` there runs the
  client's own tests against the check's database too. Run `go test`
  with `-v` in a check: the gate counts tests from the `--- PASS` and
  `--- FAIL` lines it prints only then.

## Run it

```sh
keg up
keg changes --env local
keg logs local-notes
```

A change set's `checked` is about the release (its image, its port), not
the `checks` in `keg.yaml`: those run in a piece of work. Propose once,
when the app is ready, not to try things.

An app has a database, so a release an agent proposes **waits for a
person even in `local`**: `keg up` says `waiting for a person: keg approve
<n> --env local`. That is as far as you go: say the change set number and
that the person approves it (`keg approve <n> --env local`) or runs
`keg dev`. With a person's rights `keg dev` deploys it and follows its
output, and it answers at `http://<app>.keg.localhost` (the address it
prints).
