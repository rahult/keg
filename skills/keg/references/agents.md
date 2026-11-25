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
the piece of work, and is refused on a node with no model key.

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
- A tool declared with `changes => true` does not run at all yet: a
  person's approval of that very call is a later part of Keg.
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
  started with `to`. Members read `keg.my_threads`, `keg.my_thread_events`
  and `keg.my_thread_blobs`; nobody writes them but Keg's functions.
- A tool runs as the organization's system actor, with
  `keg.actor_thread()` set to the thread: a policy can admit what the
  agent writes, e.g. `WITH CHECK (keg.actor_thread() IS NOT NULL)`.

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
  `next()`, `done(result)`, `fail(why)`, `release(why)`.
- A handler that returns without `next`, `done` or `fail` leaves the
  thread `ready` and **nothing wakes it**; one that throws, the same, with
  a note of what it threw.
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

## Do not

- Emit a type beginning `keg.`: `keg.thread.started` and
  `keg.thread.finished` are Keg's, and `keg.emit` refuses every `keg.` type.
- Put in a prompt what the thread's organization may not read: read it in
  the step that sends it, as the thread's actor.
- Hold a transaction open across `thread.model`, or call the door
  yourself to skip the thread's budget: the app's own ceiling still holds.
- Write a loop that calls the model until it is done inside one step:
  end the step with `thread.next()` and let the next wake take it.
