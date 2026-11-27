# An agent in an app on Keg

Read `references/apps.md` first: an agent is part of an app, in its own
database, under the same tenant rules.

Keg is the substrate, not a framework. It keeps a **thread** (an agent's
run, as a list of typed events in the app's database), wakes it, lends it
to one worker at a time, holds it to its agent's bounds, and carries model
calls to Keg's gateway with no key in the app. **Keg runs no loop, builds
no prompt and picks no next step.** You write the prompt, how the thread
becomes the model's input, and what each step does. If something here is
not in the client or the SQL, say so; do not invent it.

## keg.yaml

```yaml
app: desk
uses: [data, identity, events, jobs, model, agents]
checks:
  - { name: e2e, run: "npm install --no-audit --no-fund && npm test", db: true, model: fake }
```

`agents` needs `jobs` and `model`. A check with `model: fake` is given
`KEG_DOOR_URL` and `KEG_DOOR_TOKEN` to a fake model that answers from the
script `KEG_MODEL_SCRIPT` names (in `run.env`; default
`test/model-script.json`), and spends nothing. `model: real` spends as
the piece of work, and is refused on a node with no model key. A work
that adds `model:`, `db:` or a service to a check, its `run` unchanged,
is judged by the check as the work has it.

The script is a list; for each call the first entry whose
`when_input_contains` is in the input (or that names none) answers:

```json
[
  {"when_input_contains": "invoice", "then": [
    {"type": "tool_call", "call": "c1", "name": "ticket.set_priority", "arguments": {"priority": "high"}},
    {"type": "done", "usage": {"input_tokens": 40, "output_tokens": 6}}]},
  {"echo": true}
]
```

`echo` answers with the request as text. A test reads what the fake was
sent with `GET $KEG_DOOR_URL/v1/model/sent` (`Authorization: Bearer
$KEG_DOOR_TOKEN`): `{"sent": [{"request", "thread", "organization"}]}`.

## The migration

```sql
SELECT keg.agent('triage', max_steps => 12, max_tool_calls => 12,
    max_minutes => 1440, max_usd => 0.10, max_errors_in_a_row => 3);
SELECT keg.tool('ticket.set_priority', 'Set ticket {ticket} to {priority}',
    '{"type":"object","properties":{"ticket":{"type":"string","format":"uuid"},"priority":{"enum":["low","normal","high","urgent"]}},"required":["ticket","priority"],"additionalProperties":false}');
SELECT keg.start_on('ticket.created', 'triage');   -- one thread per such event
```

- A **step** is one `model.call`. Past `max_steps`, `max_tool_calls`,
  `max_minutes` or the thread's budget (dollars, at most `max_usd`), or
  1,000 events, the thread is `failed` in the node's words. Past
  `max_errors_in_a_row` errors (a `tool.error`, or a `model.output` with
  an error), its next model call is refused; a `tool.result` resets the
  count. A failed model call is spent too, and on the thread.
- A tool declared with `changes => true` runs only on a person's
  approval of that very call (same tool, same arguments), once, as that
  person: see "Asking people" below. Its `says` is what the person is
  shown, each `{name}` filled from the call's arguments; `confirm_roles`
  (administrators unless said) are who may approve.
- `keg.start_on` makes the thread in the event's transaction; its input
  is `{event, type, payload, about}`, or, for a payload too large for it
  (64 KiB), `{event, type, about, payload_bytes}`: read the event by its id
  in a tool. The thread is read by the event's audience narrowed by
  `keg.start_on(type, agent, "to" => '{"roles": [...]}')`, by default its
  administrators; `'{"organization": true}'` keeps the event's audience as
  it is. `keg.start_off(type, agent)` stops it.
- A thread started from inside a thread (by a tool's `thread_start`, or by
  an event a tool emits that `start_on` takes) is its child: `parent` is
  set, its budget is carved from what the parent has left, a tree is at
  most 5 threads deep (4 below its root; past it a start is refused, and
  an event starts nothing). A thread outlives none of its own: when it
  ends, however it ends, every thread below it is stopped, and its parent
  is given back only what neither it nor they spent.
- A thread's audience is its organization's administrators unless
  started with `to`. Members read three views, with these columns and no
  others (`SELECT` them by name; nobody writes them but Keg's functions):
  `keg.my_threads`: `id`, `agent`, `state`, `input`, `parent`, `started_by`, `trigger`, `seq`, `steps`, `tool_calls`, `errors_in_a_row`, `spend_micro`, `budget_micro`, `deadline`, `result`, `why`, `dry`, `forked_from`, `forked_at`, `made`, `updated`
  `keg.my_thread_events`: `thread`, `seq`, `type`, `data`, `actor_user`, `input_tokens`, `output_tokens`, `spend_micro`, `request`, `at`
  `keg.my_thread_blobs`: `digest`, `body`
  Three more are read the same way, by any member and the app's own
  role: what a migration declared, and the asks a member may read.
  `keg.agents`: `name`, `max_steps`, `max_tool_calls`, `max_minutes`, `max_usd_micro`, `max_errors_in_a_row`, `replay_roles`
  `keg.tools`: `name`, `says`, `schema`, `changes`, `undoable`, `confirm_roles`, `source`
  `keg.my_asks`: `id`, `thread`, `agent`, `kind`, `question`, `says`, `choices`, `tool`, `arguments`, `state`, `answer`, `answered_by`, `answered_at`, `expires`, `made`, `mine`
  A thread's `state` is `ready`, `running`, `waiting`, `done`, `failed` or
  `stopped`. Its first event is Keg's `start`; the app writes `model.call`,
  `model.output`, `tool.call`, `tool.result`, `tool.error`, `note`, and
  types of its own beginning `app.`. Keg writes `wake` (`why`: time,
  event, person, child, missed), `message`, `ask`, `answer`,
  `ask.expired`, `spawn`, and the thread's end. On a `tool.call`, `ask`
  and `approved_by` are Keg's: written by you, they are dropped.
- A tool runs as the organization's system actor, with
  `keg.actor_thread()` set to the thread: a policy can admit what the
  agent writes, e.g. `WITH CHECK (keg.actor_thread() IS NOT NULL)`.
  `keg.actor_thread_input()` is that thread's input and
  `keg.actor_thread_about()` its input's `about` (a thread an event began
  has the event's), both null when no thread acts: a policy holds a
  tool's read to what its thread is about with, e.g.,
  `USING (keg.actor_thread() IS NULL OR 'ticket/' || id = keg.actor_thread_about())`.
  A policy never reads `keg.my_threads`: that view answers for a member,
  and `keg.tenant_table` and `keg.tenant_ref` fail on a policy that does
  ("permission denied for view my_threads").

## The worker

```js
const { connect } = require('@keg/app');
const keg = connect();
const PROMPT = require('fs').readFileSync('prompts/triage.md', 'utf8');
const render = (events) => events.map((e) => `<${e.type}>${JSON.stringify(e.data)}</${e.type}>`).join('\n');

keg.agent('triage', async (thread) => {            // one wake, one step
  const ticket = thread.input.payload.ticket;
  if (thread.seq === 1) {                          // read before the model: recorded
    await thread.tool({ name: 'ticket.read', arguments: { ticket } }, (db) =>
      db.query('SELECT subject, body FROM tickets WHERE id = $1', [ticket]));
    return thread.next();
  }
  const tools = await keg.tools(['ticket.set_priority']);
  tools.push({ name: 'done', description: 'Triage is finished', schema: { type: 'object' } });
  const out = await thread.model({ instructions: PROMPT, input: render(await thread.events()), tools, toolChoice: 'required' });
  const call = out.toolCalls[0];
  if (!call || call.name === 'done') return thread.done(call?.arguments ?? null);
  await thread.tool(call, (db) =>                  // the change and its tool.result: one transaction
    db.query('UPDATE tickets SET priority = $1 WHERE id = $2', [call.arguments.priority, call.arguments.ticket]));
  return thread.next();                            // a tool.error is on the thread; the next step sees it
});
keg.work();
```

- `thread`: `id`, `input`, `organization`, `seq`, `errorsInARow`;
  `events()`, `state()`, `model(request, { onFrame, signal, retries })`,
  `tool(call, fn)`, `key(call)`, `note(data)`, `record('app.<type>', data)`,
  `next()`, `done(result)`, `fail(why)`, `release(why)`; and, below,
  `sleepUntil`, `waitFor`, `listen`, `ask`, `asks`, `spawn`.
- A handler that returns without `next`, `done`, `fail` or a wait leaves
  the thread `ready` and **nothing wakes it** (`keg app threads` calls it
  stranded); one that throws, the same, with a note of what it threw.
  One that throws `over_limit` (the day's allowance is spent) is put to
  sleep until the allowance resets instead.
- `thread.model` writes `model.call` (the request kept by its digest),
  calls the model with no transaction open, and writes `model.output`
  with tokens and spend. A bound throws `KegError` `bound`; too many
  errors in a row, `errors_in_a_row`.
- `thread.tool(call, fn)` holds the arguments to the tool's schema when it
  is in `keg.tools`, commits `tool.call`, then runs `fn(db, { key })` and
  writes `tool.result` in one transaction. If `fn` throws, nothing it did
  is kept and `tool.error` holds its words; it returns `{ error }`, not a
  throw. A result is at most 64 KiB. A tool's `db` runs one statement a
  call, given as text (no query objects), and refuses `COMMIT`,
  `ROLLBACK`, `BEGIN` and the like (`SAVEPOINT` and `ROLLBACK TO` are
  fine); a raw `tool.result` is written only in the transaction
  `keg.thread_act` began. The tool's transaction ends at its
  step's lease (60 s by default): the database ends a statement or a wait
  past it, and nothing is kept. Do slow work outside the database
  before `thread.tool`, or `thread.extend()` first.
- After a crash, a `tool.call` with no result is closed as `tool.error
  {code: 'begun_unknown'}` and never run again. For a tool outside the
  database (a payment, a mail), pass `key` as its idempotency key.
- `keg.model(request, options)` is the same call outside a thread.
  Errors are `KegModelError`: `over_limit` (`resetsAt`), `rate_limited`
  (`retryAfter`), `lost`, `model_not_allowed`, `secret_in_prompt`,
  `output_invalid`. Nothing is retried unless you pass `retries`, and
  then only `rate_limited` and `lost`.
- `db.startThread(agent, input, { to, budget })` starts one inside
  `keg.tx`, as the signed-in user.

## Waiting

Each of these ends the step; the thread is `waiting`, and what woke it
is its last events at the next step. Nothing waits past the agent's
`max_minutes`, which counts from the thread's start through every wait:
size it for the whole life of a thread, its longest waits included. An
agent that asks a person and may wait three days needs
`max_minutes => 4320` or more (a week is 10080; 43200, 30 days, is the
most); with the default, 1440, every wait and every ask ends within a
day of the thread's start.

- `thread.sleepUntil(time)`: woken then, with `wake {why: 'time'}`.
- `thread.waitFor({ until, event, about, message: true })`: until the
  time, an event of that type (about that, if said), or a message,
  whichever comes first; two at once make one step that reads both.
- An event wakes a thread only if everyone who may read the thread may
  read the event (an event for the whole organization wakes any). The
  wake says its id, type and `about`, never its payload: read the event
  in a tool. To hear an event your own step may cause, call
  `thread.listen(event, about)` before causing it.
- A member who may read the thread sends it a message, an object:
  `db.query('SELECT keg.thread_message($1, $2::jsonb)', [thread, '{"text": "..."}'])`.
  It is a `message` event at the thread's next step, and wakes only a
  thread that waits for messages. A thread keeps 50 unread and takes 20
  within a minute from one sender; past either the sender is refused,
  in words to show them. Messages never keep out an answer, an event, a
  child's end or a person's wake.
- If more events a thread waits for come than it keeps unread (100), the
  rest are not kept and its next step also reads
  `wake {why: 'missed', what: 'event'}`: read what changed in a tool
  rather than counting wakes.

## Asking people

```js
const call = out.toolCalls[0];                      // { name: 'refund.issue', arguments: { cents: 500 } }
const ran = await thread.tool(call, refund);        // a `changes` tool
if (ran.error?.code === 'needs_approval') return thread.ask({ kind: 'approve', call });
// next step: the last event is `answer` {ask, kind, answer: {approve: true|false}}, or `ask.expired`
```

- `thread.ask({ kind: 'approve', call, to?, expiresIn? })`: one exact
  call. The person is shown the tool's `says` and the arguments, never a
  text of yours or the model's. The arguments must be the tool's own: one
  its schema's `properties` do not name, or the lack of one it requires,
  is refused. Approved, `thread.tool(call, fn)` with the
  same name and arguments runs `fn` once as that person (`db.actor` is
  them, so a policy can require `keg.actor_user() IS NOT NULL`); a second
  run, other arguments, an expired approval or an approver who lost the
  role is `needs_approval` or refused.
- `thread.ask({ kind: 'choose', question, choices, to })` and
  `thread.ask({ kind: 'answer', question, to })`: `to` is `{ roles }`,
  `{ users }` or both, of the thread's organization. Answers are
  `{ choice }` and `{ text }`. An ask expires in three days unless
  `expiresIn` (seconds, 60 to 30 days) says, and never later than the
  thread's own time runs out (`max_minutes`, above): the `ask` event's
  `expires` is the time kept. At most 10 wait at once.
- With `wait: false` the step goes on; `thread.waitFor({ ask })` waits
  later, and for an ask already answered or expired returns `ready` at
  once. `thread.asks()` lists the thread's asks as they stand.
- **On the page where a person approves, show `says` and every argument
  in full beside it**, as text. `says` is the tool author's sentence: it
  names the arguments its author chose to, cuts each at 200 characters
  (a cut ends with `…`), and writes characters that turn or hide text as
  `\u{202E}`. `arguments` is the whole call, and what is approved.
- The app's pages, as the signed-in member, inside `keg.tx`:
  `db.asks({ state: 'open', mine: true })` (rows of `keg.my_asks`: `id`,
  `thread`, `agent`, `kind`, `question`, `says`, `choices`, `tool`,
  `arguments`, `state`, `answer`, `answered_by`, `answered_at`, `expires`,
  `made`, `mine`) and `db.answer(ask, { approve: true })`. Only a person
  signed in answers: a job, a tool and a worker are refused, whoever they
  run as. Keg tells those asked with `keg.ask.asked`, `keg.ask.answered`
  and `keg.ask.expired` (about `ask/<id>`, ids only).

## A child agent

`thread.spawn(agent, input, { budget })` starts a thread of another agent
as this one's child and ends the step until the child ends; the next step
reads `wake {why: 'child', child, agent, state, result, reason,
spend_micro}`: `result` is what the child gave `done()`, as it gave it
(a field it set to null is there, null); `reason` is there only when the
child failed or was stopped. The budget (dollars) is carved from what this thread has
left; the child is read by those who read this thread, counts as one of
its tool calls, and is stopped if it ends. With `wait: false`, go on and
`thread.waitFor()` later. A thread that started several is told of each
once, as each ends and in any order, one `wake` for each: call
`thread.waitFor()` again while some have not ended (with none left it is
refused, as a wait for nothing).

## A tool's arguments

A tool's schema names each argument and its kind: `string`, `integer`,
`number`, `boolean`, one of a few (`enum`), an `array` of those (say
`items`, and `maxItems` up to 1000; 100 when not said) or an `object` of
those (say `properties`), no more than four lists or objects inside one
another. `keg.tool` refuses any other schema when the migration runs, in
a sentence that names the argument; the client refuses a call that does
not fit before anything runs. For a tool that changes things the
database checks too, whole, when its approval is asked and again when
its call is written (kinds, a list's length and items, an object's
fields; a text's length and a number's range are the client's check
alone).

In the sentence a person approves, `{cites}` of a list reads "3 items"
and `{meta}` of an object "2 fields": show `ask.arguments` in full beside
`ask.says`, since the sentence is one line. The approval is of those very
items, in that order.

## An organisation's own tools

An organisation can write tools of its own, and the app's agent can call
them as it calls any other. A signed-in member of a role the app names
uploads one, never the app's code by itself:

```sql
-- In the migration: who may upload (Keg's capability 023).
SELECT keg.org_tools_by('{administrator}');
```

```js
// As that member, in their own transaction.
await keg.tx(token, organization, (db) =>
  db.query('SELECT keg.org_tool_put($1, $2, $3::jsonb, $4) AS sha256', [
    'org.vat', 'Works out VAT on {amount}',
    JSON.stringify({ type: 'object', properties: { amount: { type: 'number' } }, required: ['amount'] }),
    'function run(args) { return { vat: Math.round(args.amount * 0.2 * 100) / 100 }; }',
  ]));

// In a step: no function, as the node runs its code.
const got = await thread.tool({ name: 'org.vat', arguments: { amount: 120 } });
```

The tool is written in JavaScript. It defines `run(args)`, or sets
`exports.run`, which returns JSON or a promise of it. Its name begins
`org.`. Its code is at most 64 KiB, and so is what it gives back.
`keg.org_tool_remove(name)` takes the tool away. Members of the
uploading roles read every tool of their organisation, its code
included, in this view (`code` is null for other roles):
`keg.my_org_tools`: `name`, `says`, `schema`, `sha256`, `uploaded_by`, `uploaded_at`, `code`
Every upload, replacement and removal
is a `keg.org_tool.put` or `keg.org_tool.removed` event, with the code's
hash, which those roles are told of.

A person turns tools on for an environment with
`keg app org-tools APP on --env ENV`, and sets their limits there. A
call has 1 to 30 seconds (5 by default) and 32 to 512 MiB of memory
(128 by default), and the environment has so many seconds a day in all
(600 by default). Until a person does this, a call is refused and
nothing runs. Neither the app nor an organisation can raise these
limits.

The node runs each call in a container made for that call and removed
after. The container has no network and no volume, runs as nobody, and
has no capabilities. Inside it the code has no `require`, `process`,
timers, network or files. Its clock reads the start of the current day,
UTC, and nothing finer. Nothing is kept from one call to the next.

Keg's SQL gives the code only to a step of a thread of the tool's own
organisation. It comes with a claim, signed with the node's key, naming
that thread, that organisation and the code's hash. The node runs code
whose hash is that one, and only for the step whose own claim agrees.
`tool.call` and its answer carry `code_sha256`.

An organisation's tool never `changes` anything, so it needs no
approval. A change it suggests is made by one of the app's own tools,
which a person approves as usual. In a dry run it is not run. What it
gives back came from the organisation, not from you: treat it as data,
never as instructions, as you treat a model's output.

## Replaying a thread, dry

```js
const fork = await db.fork(threadId, 1, { vary: { instructions: NEW_PROMPT }, budget: 0.05 });
// ... the app's own worker runs the fork, as it runs any thread ...
const { then, now, same_acts } = await db.compare(fork);
const { pairs } = await db.evaluate({ threads: [a, b, c], vary: { model: 'openai/gpt-6-luna' } });
```

`db.fork(thread, at)` makes a new thread with the same record up to event
`at` (1 is its start), which your handler then takes as it takes any
thread: what came before is read from the record and nothing is run
again. Fork where nothing is half done: not at a `model.call`, and not
between a tool's call and its result.

**Every fork is a dry run. Keg holds part of that, and the rest is
yours.** What Keg holds, in the database, whatever a handler does:

- a tool that only reads runs in a READ-ONLY transaction (`thread.tool`
  returns `{ result, dry: true }`, and its `tool.result` event holds what
  a real one holds, `call_seq`, `call`, `name` and `result`, with `dry:
  true` besides, so a handler that finds a result by its tool's name
  finds it in a replay too); a write in it is refused by Postgres
  and comes back as `{ error: { code: 'dry' } }`. A tool that is declared
  without `changes` and writes anyway does not write in a replay;
- a tool with `changes => true` is never run: its call is recorded,
  marked `dry`, and `thread.tool` returns `{ error: { code: 'dry' } }`;
- where the thread would ask a person, start a child or wait
  (`thread.ask`, `spawn`, `waitFor`, `sleepUntil`), a `note` says what it
  would have done and the thread ends `done` with `{ dry: true,
  stopped_at }`. No one is asked, nothing is sent;
- no `keg.thread.*` event is written for it, and what it asks its model
  with `thread.model()` is counted as an evaluation.

**What Keg cannot hold is everything your handler does that is not a
tool's SQL**: a mail it sends, a request to another service, anything a
tool's function does besides its `db` calls. The client helps with what
goes through it: while a dry step runs, `keg.tx()` in that handler is
read only, so `db.emit`, `db.enqueue` and any write there are refused
with a `KegError` of code `dry`, and `keg.job()` is refused; another
thread's real step in the same worker is not affected. Nothing can refuse
the rest but you. So: **make every effect in `thread.tool`, or guard it
with `if (!thread.dry)`.** A handler that mails a customer after the model
answers will mail them again in every replay unless it does one or the
other; replay nothing until you have looked.

`thread.dry` says a handler is in one; `thread.vary` is what the replay
changes. `vary.model` and `vary.instructions` are applied to
`thread.model()` by the client, so a prompt change is tried with no change
to the handler; anything else in `vary` is yours to read. A model the app
may not ask ends the replay `failed`, saying so.

`db.compare(fork)` gives `then` and `now` from where they part: what each
said, the tools it called or would have (`dry: true`), who it asked or
would have, how it ended, what it spent; `same_acts` is whether the fork
called the same tools with the same arguments and asked the same, as far
as it went.

Who may: the roles a migration names with `SELECT keg.agent_replay('triage',
'{administrator,agent}')`, administrators alone by default, signed in.
Anyone else is told there is no such thread. A fork is read only by one
who may read the original AND holds such a role: never more widely than
the original, and never by a reader of the original who may not replay.
Do not show a replay's output to the customer whose ticket it was. Bounds: a fork's budget is its own,
$0.05 unless you say (`budget`), at most its agent's `max_usd`, and it
has 30 minutes at most, however long its agent's threads may run; a thread
has at most 100 forks, forks of forks among them; an organization runs 10
replays at once, and those begun for it in a day may spend $2 in all. The
node counts what replays spend as evaluations (`keg assistant usage`).

The node's person replays any thread: `keg app threads replay APP ID --at
N [--model M] [--instructions-file F] [--max-usd N]`, then `keg app
threads compare APP FORK`.

## What each organization spends

Each call of `thread.model()` carries a claim Keg's own SQL signs for the
worker holding the thread (you do nothing: the client asks for it), so
the node counts the call for that thread's organization and nothing an
app says by itself is believed. The node's person may set a ceiling for
each organization (`keg assistant limits app:APP/ENV
--per-organization-usd-per-day N`); a call past it is refused with
`over_limit` and a message written for that organization's own
administrator ("Your organization's allowance for this app's assistant
today, $1.00, is used ... other organizations are not affected ... The
person who runs this app's Keg node can raise it"): show it to them as
it is; it names no command. `keg.model()` outside a thread is counted under the app
alone, for no organization. With such a ceiling set, a call that names a
thread and carries no claim (a copy of the client from before claims) is
refused: `keg app client` brings the app's copy up to date.

## An SDK or a framework instead

The door also speaks OpenAI's and Anthropic's shapes: `POST
/v1/chat/completions`, `/v1/responses` and `/v1/messages`, and `GET
/v1/models`, at `KEG_DOOR_URL` with `KEG_DOOR_TOKEN` as the SDK's key. A
call through them is held and limited as `keg.model()` is, but is not a
thread's step: no claim, so it counts for the app and no organization.
An agent's step may use an SDK too: send `thread.claim()`'s value as
`Keg-Claim` among the SDK's `defaultHeaders`, and the call is counted for
its organization and held to that organization's ceiling, as
`thread.model()` is. Where organizations have a ceiling, a call that
names a thread (`Keg-Thread`) with no claim is refused.

## Hooks: another service starts a thread

A hook is an address another service (GitHub, Stripe, Slack, your own)
sends what happened to. Declare it in a migration:

```sql
SELECT keg.hook('github', 'github', 'GITHUB_HOOK_SECRET', 'triage');
--             name      signed as  the secret's name    agent it starts (or none)
```

- Signed as: `github` (`X-Hub-Signature-256`), `stripe`
  (`Stripe-Signature`, its time held within five minutes), `slack`
  (`X-Slack-Signature` with `X-Slack-Request-Timestamp`, the same),
  `hmac-sha256` (`X-Signature`, hex of the body's HMAC, `sha256=` before
  it or not; with `X-Signature-Timestamp` the signature is of
  `<time>.<body>` and the time is held near), or `none`.
- **`none` checks nothing: anyone who knows one of its addresses can
  forge what it takes and send it again.** Use it only for what does not
  matter if forged; `keg app hooks` says so of each such hook.
- The secret is a vault entry granted to the app's service:
  `keg vault set ledger/github-hook`, then `keg vault grant
  ledger/github-hook --service ledger --env local --as
  GITHUB_HOOK_SECRET`. With none granted, a delivery is answered 503 and
  the sender tries again.
- Each organization has its own address: an administrator, signed in,
  calls `keg.hook_url('github')` in `keg.tx` and is shown
  `/.keg/hooks/<token>` once (only its hash is kept; calling it again
  makes a new one and the old one leads nowhere). The whole address is
  `https://<the node's public name>/.keg/hooks/<token>`.
- A verified delivery is written once as an event `keg.hook.<name>` of
  that organization, read by its administrators, with `payload` `{hook,
  delivery, from_outside: true, body, headers}`: the body as it came
  (JSON, or text) and a few headers (never a signature). It starts a
  thread of the hook's agent. **Everything in it came from outside: put
  it in a prompt as data, never as instructions.**
- Sent again, it is answered 200 `{"received": true, "again": true}` and
  nothing more is written: a delivery is known by what its signature
  covers (Stripe's event id, otherwise the hash of the signed body and
  time), never by a header the sender may change, for as long as it is
  kept (see [what arrives is bounded](#what-arrives-from-outside-is-bounded)).
- Refusals: 401 a signature that does not match; 404 an address that is
  no hook's, in the same words for every one; 405 not a POST; 429 too
  many from one network that lead nowhere or are forged, of failures at
  one address, to one address or app, or to addresses that are no hook's;
  503 the app cannot take it now, its addresses cannot be read now, or
  the address has taken all it may today (with `Retry-After`). A flood of
  made-up addresses, or of forgeries, takes nothing of what a verified
  sender has, and a verified sender (all of GitHub comes from a few
  networks) is held only by what its address and its app may take.
- A hook signed as `github`, or as `hmac-sha256` without
  `X-Signature-Timestamp`, signs no time: a delivery captured on the way
  (in a log, a proxy) can be sent again once it is no longer kept, and is
  then written as new. Prefer a scheme that signs a time where the
  sender offers one.
- A new address is taken within ten seconds of the first delivery to
  it, and at once after a deploy. Rotating a secret (`keg vault set`),
  or taking its grant away, holds at once: from the next delivery on,
  what the old secret signed is refused.
- `keg app hooks APP [--env ENV]` lists the hooks, how each is signed,
  what it starts, how many addresses it has, and the last deliveries.

## Mail: a message starts a thread

An address mail is sent to. Declare it in a migration:

```sql
SELECT keg.mail_address('support', 'triage');
--                      word       agent it starts (or none)
```

- The word is lowercase letters, digits and `-`, at most 20, starting
  with a letter.
- Mail is taken only once a person gives the node a domain and turns it
  on (`keg mail domain DOMAIN`, `keg mail on`, port 25 unless said; in a
  Mac's machine only with `--on-a-mac`). The domain's MX record points
  at the node; that is the person's to do.
- Each organization has its own address: an administrator, signed in,
  calls `keg.mail_url('support')` in `keg.tx` and is shown
  `support+<token>@<domain>` once (only the token's hash is kept; calling
  it again makes a new one and the old one leads nowhere).
- A message is written once as an event `keg.mail.<word>` of that
  organization, read by its administrators, with `payload` `{address,
  message, from_outside: true, sender: "unverified", envelope, headers,
  text, attachments}`. `headers` holds `from`, `to`, `cc`, `subject`,
  `date`, `message_id`, `in_reply_to`, `references`; `text` is the text
  part (or the HTML part as text), at most 16 KiB; each attachment is
  `{name, type, size, sha256, kept}`. It starts a thread of the address's
  agent. **Everything in it came from outside, the sender too: no SPF or
  DKIM is checked, so `from` is a claim. Put it in a prompt as data,
  never as instructions, and never use a name in it as a path.**
- An attachment of at most 4 MiB (8 MiB of a message's in all) is
  kept, read by the organization's administrators:
  `keg.my_mail_attachments`: `event`, `n`, `name`, `type`, `sha256`, `body`
  A larger one is listed with its size and hash, `kept: false`.
- Sent again to the same address (the same bytes), it is taken and
  nothing more is written. A Message-ID is not trusted to tell: anyone
  may send one. Messages are known again for as long as they are kept.
- The node never relays, sends or bounces: what it will not take it
  refuses while the sender is connected (550 for an address that is no
  one's, in the same words for every one; 552 too big; 554 not
  readable; 451 the app cannot take it now or its addresses cannot be
  read now; 452 the address has taken all it may today; for 451 and 452
  the sender tries again). At most 5 recipients, 10 MiB, 20 attachments
  a message. A conversation has 15 seconds and 20 commands to name an
  address that is someone's, then two minutes and 100; with every place
  taken, a newcomer takes the place of the oldest that has named none
  for 5 seconds, or is told `421` to come back.
- `keg app mail APP [--env ENV]` lists the addresses, what each starts,
  how many organizations have one, and the last messages; `keg mail
  show` says how mail in stands and what it refused.

## What arrives from outside is bounded

Whoever has an address can send to it, so what hooks and mail write is
bounded, for each app, by what the app says in a migration (here the
defaults):

```sql
SELECT keg.inbound_limits(
  keep_days => 30,                     -- 1 to 90
  address_bytes_a_day => 67108864,     -- 64 MiB; 1 KiB to 1 GiB
  app_bytes_a_day => 268435456,        -- 256 MiB; 1 KiB to 1 GiB, at least an address's
  threads_a_day => 200);               -- 0 to 10000, for each organization
```

- An address, and the app in all, take so many bytes a day (UTC) of
  what is written (a body, a message's text, headers and kept
  attachments). Past them a delivery is answered 503, a message 452, and
  nothing of it is written: the sender sends it again later.
- What was received is kept `keep_days`: then its record, its event and
  a message's attachments go, a little at each delivery or message to
  any of the app's addresses. A delivery or message sent again is known
  only while it is kept.
- The deliveries and messages of one organization start at most
  `threads_a_day` threads a day; past that, each is written as ever and
  starts no thread.
- What is not said stays as it was.

## The worker in Go

The Go client (`github.com/rahult/keg/sdk/go`) runs agents as `@keg/app`
does, against the same SQL:

```go
import kegsdk "github.com/rahult/keg/sdk/go"

k, _ := kegsdk.Connect("")                // DATABASE_URL, KEG_DOOR_URL, KEG_DOOR_TOKEN
k.Agent("triage", func(ctx context.Context, t *kegsdk.Thread) error {
    events, err := t.Events(ctx)
    if err != nil { return err }
    out, err := t.Model(ctx, kegsdk.ModelRequest{Instructions: prompt, Input: render(events), Tools: tools})
    if err != nil { return err }
    if len(out.ToolCalls) == 0 { return t.Done(ctx, out.Text) }
    r, err := t.Tool(ctx, out.ToolCalls[0], func(ctx context.Context, tx *kegsdk.Tx, key string) (any, error) {
        _, err := tx.Exec(ctx, "UPDATE tickets SET priority = $1 WHERE id = $2", p, id)
        return map[string]any{"ok": true}, err
    })
    if err != nil { return err }
    _ = r                              // r.Error is a tool.error, on the thread for the next step
    return t.Next(ctx)
})
k.Work(ctx)                            // jobs and agents' wakes alike
```

- `Thread`: `ID`, `Agent`, `Organization`, `Input`, `Dry`, `Vary`,
  `Seq()`, `Ended()`; `Events`, `Extend`, `Claim`, `Model`, `Tool`,
  `Note`, `Next`, `Done`, `Fail`, `Release`, `Ask`, `Asks`, `WaitFor`,
  `SleepUntil`, `Spawn`. Refusals are `*kegsdk.Error` with `Code` (`bound`,
  `lease_lost`, `errors_in_a_row`, `ended`, `needs_approval`, `dry`, and
  the model's: `over_limit` with `RetryAfter`, `rate_limited`, `lost`, …).
- A tool declared with `changes => true` runs only on a person's approval
  of that very call: `Tool` returns `Error.Code == "needs_approval"` and
  writes nothing; ask with `Ask(ctx, kegsdk.AskOptions{Kind: "approve",
  Call: &call})`.
- `ModelBaseURL()` is the address to give an SDK of OpenAI's or
  Anthropic's as its base URL (with `KEG_DOOR_TOKEN` as its key); send
  `t.Claim(ctx)` as the header `Keg-Claim` so the call is counted for the
  thread's organization.

## Do not

- Let an organisation's tool decide what the app does: what it gives back
  is data the organisation wrote.
- Emit a type beginning `keg.`: `keg.thread.started`,
  `keg.thread.finished`, `keg.hook.<name>` and `keg.mail.<word>` are Keg's, and `keg.emit` refuses every `keg.` type.
- Put in a prompt what the thread's organization may not read: read it in
  the step that sends it, as the thread's actor.
- Hold a transaction open across `thread.model`, or call the door
  yourself to skip the thread's budget: the app's own ceiling still holds.
- Write a loop that calls the model until it is done inside one step:
  end the step with `thread.next()` and let the next wake take it.
