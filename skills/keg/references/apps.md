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
  migration instead`). Add `002_...sql`.
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

In a `tx`, `db`:

- `await db.query(sql, params)` returns **the rows** (an array), not a pg
  result: no `.rows`.
- `db.actor`: `{ user, organization, role }`.
- `await db.emit(type, payload, { to, about })`: `to` is `'organization'`,
  `{ roles: [...] }`, `{ users: [...] }`, or both in one
  (`{ roles: ['agent'], users: [customerId] }`: whoever is in either); left out, every member may
  read it; `to: undefined` or `null` is refused. `about` is like
  `"note/42"`, at most 200 bytes.
- `await db.events({ type, about, limit, before })`: the events this actor
  may read, newest first, and those of one transaction in the order emitted.
- `await db.enqueue(name, payload, { runAt, asUser })`, `await db.once(key)`.

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
- A token for a service bound to the app: `serviceToken(name, { org, ttl })`
  from `@keg/app/service`, made on the server, never sent to a browser
  for longer than its `ttl`.

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

You cannot run a `db: true` check yourself: it runs in a piece of work's
test stage, or a person runs the tests against a deployed app. Before you
propose the app, try everything else in a machine for its folder:

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
  `keg.To(keg.Roles("agent"))` or `keg.To(keg.Users(id))`.
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
  (`kegrpc.HealthHandler(k)`).
- gRPC reaches the app only on its own port (`http://localhost:<port>`,
  HTTP/2 without TLS). Keg's names (`http://<app>.keg.localhost`, and
  over HTTPS) speak HTTP/1.1 only: a page there uses Connect or gRPC-Web
  over HTTP/1.1 (Connect's Go handlers serve all three), with
  `keg.Sessions(keg.HTTPSession, handler)` to put the session in the
  context.
- Errors: return what the client and pgx give; `kegrpc.Status` (or
  `keg.Public` for HTTP) says them without Postgres's text.
- A check runs in the work's machine, which has Node and no Go unless the
  work's image has it: the check fetches Go (see the commented check in
  `keg.yaml`). `cd third_party/keg && go test ./...` there runs the
  client's own tests against the check's database too.

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
