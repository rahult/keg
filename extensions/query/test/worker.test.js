'use strict';
// The databases in a process of their own, which no query reaches, and the
// readers that answer queries from copies of them: a query that runs past
// its time, or takes more memory than there is, stops its reader alone,
// and what the service keeps goes on.

const { tmp } = require('./tmp.js');
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { startStore } = require('../worker.js');
const { readers, OUT_OF_MEMORY } = require('../readers.js');

const event = (id, type = 'work.changed') => ({
  id,
  cursor: '7',
  type,
  subject: 'work/1',
  at: 1795000000,
  actor: { role: 'node', name: 'kegd' },
  payload: { state: 'open' },
});

function store(t, apps = [], options = {}) {
  const dir = tmp('keg-query-');
  const said = [];
  // Copied for its readers each time it is asked, unless a test says otherwise.
  const s = startStore({ dir, apps, say: (line) => said.push(line), snapshotMs: 0, ...options });
  t.after(() => s.close());
  const r = readers({ most: 4, ...(options.readers || {}) });
  t.after(() => r.close());
  // As the service asks: a copy of what it reads, and a reader of it.
  s.answer = async (app, org, sql, limits) => {
    const copy = await s.snapshot(app, org);
    return r.answer(copy.file, sql, limits);
  };
  return { s, r, said, dir };
}

test('an event is kept while a heavy query runs', async (t) => {
  const { s } = store(t);
  await s.ready();
  await s.keep(event('first'));
  const heavy = s.answer(null, null, 'SELECT sum(hash(i)) FROM range(1000000000000000) t(i)', { ms: 3000 });
  const began = Date.now();
  assert.deepEqual(await s.keep(event('second')), { kept: true });
  assert.ok(Date.now() - began < 1000, `${Date.now() - began} ms`);
  await assert.rejects(heavy, /took more than 3 seconds/);
  assert.deepEqual((await s.answer(null, null, 'SELECT count(*) AS n FROM events')).rows, [[2]]);
});

test("a query whose reader stops is said to have needed more memory, the databases' process goes on, and the next is answered", async (t) => {
  const { s, r, said } = store(t);
  await s.ready();
  await s.keep(event('one'));
  const keeper = s.pid();
  const asked = s.answer(null, null, 'SELECT sum(hash(i)) FROM range(1000000000000000) t(i)');
  while (r.pids().length === 0) await new Promise((resolve) => setTimeout(resolve, 20));
  await new Promise((resolve) => setTimeout(resolve, 200));
  // As the kernel stops it when the service is out of memory.
  process.kill(r.pids()[0], 'SIGKILL');
  await assert.rejects(asked, { message: OUT_OF_MEMORY });
  assert.equal(s.pid(), keeper);
  assert.equal(s.down(), false);
  assert.deepEqual(await s.keep(event('two')), { kept: true });
  assert.deepEqual((await s.answer(null, null, 'SELECT count(*) AS n FROM events')).rows, [[2]]);
  assert.ok(!said.some((line) => /starting it again/.test(line)), said.join('\n'));
});

test("an app's events are kept in its own database too, and its page is answered from that alone", async (t) => {
  const { s } = store(t, ['supportdesk']);
  await s.ready();
  await s.keep(event('w'));
  await s.keep(event('a', 'app.supportdesk.ticket.opened'));
  assert.deepEqual((await s.answer('supportdesk', null, 'SELECT id FROM events')).rows, [['a']]);
  assert.deepEqual((await s.answer(null, null, 'SELECT count(*) FROM events')).rows, [[2]]);
  await assert.rejects(s.snapshot('other', null), { message: 'not bound to that app' });
});

const A = '0b6f7c2e-5d4a-4c1b-9e8f-1a2b3c4d5e6f';
const B = '9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f';
const C = '11111111-2222-4333-8444-555555555555';
/** An event of SupportDesk's, of `org`, as the node tells of it. */
const theirs = (id, org) => ({
  ...event(id, 'app.supportdesk.ticket.opened'),
  subject: `app/supportdesk/${id}`,
  payload: { app: 'supportdesk', env: 'prod', type: 'ticket.opened', id, at: 1795000000, organization: org, payload: { title: `of ${org}` } },
});

test("an app's events are kept apart by organization, and one organization's are answered from its own alone", async (t) => {
  const { s, dir } = store(t, ['supportdesk']);
  await s.ready();
  for (const [id, org] of [['a1', A], ['a2', A], ['b1', B], ['x', undefined], ['y', '../../events']]) await s.keep(theirs(id, org));
  const ids = async (org) => (await s.answer('supportdesk', org, 'SELECT id FROM events ORDER BY id')).rows.flat();
  assert.deepEqual(await ids(A), ['a1', 'a2']);
  assert.deepEqual(await ids(B), ['b1']);
  // One with none yet reads an empty table, and makes nothing.
  assert.deepEqual(await ids(C), []);
  // The app's own database has them all; none but an organization's id names a file.
  assert.deepEqual(await ids(null), ['a1', 'a2', 'b1', 'x', 'y']);
  assert.deepEqual(fs.readdirSync(path.join(dir, 'apps', 'supportdesk')).filter((n) => n.endsWith('.duckdb')).sort(), [`${A}.duckdb`, `${B}.duckdb`]);
  // Nothing of another file can be reached from one organization's.
  await assert.rejects(s.answer('supportdesk', A, `SELECT * FROM '${path.join(dir, 'apps', 'supportdesk', B + '.duckdb')}'`), /never a file/);
});

test("an event for some users or roles only is read with the app's token, never with a token for one organization", async (t) => {
  const { s } = store(t, ['supportdesk']);
  await s.ready();
  const told = (id, audience, about) => {
    const e = theirs(id, A);
    return { ...e, payload: { ...e.payload, ...(audience === undefined ? {} : { audience }), about } };
  };
  await s.keep(told('all', null, 'ticket/1'));
  await s.keep(told('before', undefined, null));
  await s.keep(told('users', { users: ['5f0c4a8e-1b2d-4c3e-9f4a-6b7c8d9e0f1a'] }, 'ticket/2'));
  await s.keep(told('roles', { roles: ['agent'] }, 'ticket/3'));
  await s.keep(told('cut', { cut: true }, null));
  // Roles and users at once is for some of the organization, not all.
  await s.keep(told('both', { roles: ['agent'], users: ['5f0c4a8e-1b2d-4c3e-9f4a-6b7c8d9e0f1a'] }, 'ticket/4'));
  const ids = async (org) => (await s.answer('supportdesk', org, 'SELECT id FROM events ORDER BY id')).rows.flat();
  assert.deepEqual(await ids(A), ['all', 'before']);
  assert.deepEqual(await ids(null), ['all', 'before', 'both', 'cut', 'roles', 'users']);
  // Both are kept as the node told of them, and read as any field is.
  const read = await s.answer(
    'supportdesk',
    null,
    "SELECT id, json_extract_string(payload, '$.about'), json_extract(payload, '$.audience.roles')::TEXT FROM events WHERE id IN ('all', 'roles') ORDER BY id",
  );
  assert.deepEqual(read.rows, [['all', 'ticket/1', null], ['roles', 'ticket/3', '["agent"]']]);
});

test("an organization given a place is filled from its app's database with only the events for every member of it", async (t) => {
  const { s, dir } = store(t, ['supportdesk'], { orgsMax: 1 });
  await s.ready();
  await s.keep(theirs('a1', A));
  const aFile = path.join(dir, 'apps', 'supportdesk', `${A}.duckdb`);
  const old = Date.now() / 1000 - 8 * 86400;
  for (const f of [aFile, `${aFile}.wal`]) if (fs.existsSync(f)) fs.utimesSync(f, old, old);
  // B's first is for some users only: in the app's own database alone.
  const some = theirs('b-some', B);
  await s.keep({ ...some, payload: { ...some.payload, audience: { users: ['5f0c4a8e-1b2d-4c3e-9f4a-6b7c8d9e0f1a'] } } });
  // Its next is for every member: it takes A's place, filled from the app's.
  await s.keep(theirs('b-all', B));
  assert.deepEqual((await s.answer('supportdesk', B, 'SELECT id FROM events ORDER BY id')).rows.flat(), ['b-all']);
  assert.deepEqual((await s.answer('supportdesk', null, "SELECT id FROM events WHERE id LIKE 'b-%' ORDER BY id")).rows.flat(), ['b-all', 'b-some']);
});

test("an app makes at most so many organizations' databases; past that, its own holds the rest and a token for one of them reads nothing", async (t) => {
  const { s, dir } = store(t, ['supportdesk'], { orgsMax: 2 });
  await s.ready();
  for (const [id, org] of [['a1', A], ['b1', B], ['c1', C]]) await s.keep(theirs(id, org));
  assert.deepEqual(fs.readdirSync(path.join(dir, 'apps', 'supportdesk')).filter((n) => n.endsWith('.duckdb')).length, 2);
  await assert.rejects(s.answer('supportdesk', C, 'SELECT 1'), /keeps 2 organizations apart, the most it does/);
  assert.deepEqual((await s.answer('supportdesk', null, 'SELECT count(*) FROM events')).rows, [[3]]);
  assert.ok(s.notices().some((n) => /supportdesk has events of more than 2 organizations/.test(n)), s.notices().join('\n'));
  // Nothing it says names a way in that this version does not have.
  for (const said of [...s.notices(), String(await s.answer('supportdesk', C, 'SELECT 1').catch((e) => e.message))]) {
    assert.doesNotMatch(said, /from its server/, said);
  }
});

test("a place goes to an organization by recent use: one that wrote nothing for a week gives its place up, and one given a place is filled from the app's own database", async (t) => {
  const { s, dir } = store(t, ['supportdesk'], { orgsMax: 2 });
  await s.ready();
  for (const [id, org] of [['a1', A], ['b1', B], ['c1', C]]) await s.keep(theirs(id, org));
  // C has no place: A and B have written lately.
  await assert.rejects(s.answer('supportdesk', C, 'SELECT 1'), /keeps 2 organizations apart/);
  // A has written nothing for eight days.
  const aFile = path.join(dir, 'apps', 'supportdesk', `${A}.duckdb`);
  const old = Date.now() / 1000 - 8 * 86400;
  for (const f of [aFile, `${aFile}.wal`]) if (fs.existsSync(f)) fs.utimesSync(f, old, old);
  await s.keep(theirs('c2', C));
  // C has A's place, with what it had before in the app's own database.
  assert.deepEqual((await s.answer('supportdesk', C, 'SELECT id FROM events ORDER BY id')).rows.flat(), ['c1', 'c2']);
  assert.ok(!fs.existsSync(aFile));
  // A, back, waits for a place; its events are still in the app's own.
  await s.keep(theirs('a2', A));
  await assert.rejects(s.answer('supportdesk', A, 'SELECT 1'), /keeps 2 organizations apart/);
  assert.deepEqual((await s.answer('supportdesk', null, "SELECT count(*) FROM events WHERE id LIKE 'a%'")).rows, [[2]]);
});

test("more organizations' databases than are kept open at once are each kept and answered", async (t) => {
  const { s } = store(t, ['supportdesk']);
  await s.ready();
  const orgs = Array.from({ length: 7 }, (_, n) => `00000000-0000-4000-8000-00000000000${n}`);
  for (const org of orgs) await s.keep(theirs(`e${org.slice(-1)}`, org));
  for (const org of orgs) assert.deepEqual((await s.answer('supportdesk', org, 'SELECT id FROM events')).rows, [[`e${org.slice(-1)}`]]);
});

test("an event asked to be kept while the databases' process is down is kept once it is back, and its delivery does not fail", async (t) => {
  const { s } = store(t, [], { backoffMs: () => 200 });
  await s.ready();
  process.kill(s.pid(), 'SIGKILL');
  while (!s.down()) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(await s.keep(event('while-down')), { kept: true });
  assert.deepEqual((await s.answer(null, null, 'SELECT count(*) FROM events')).rows, [[1]]);
});

test('an event the databases cannot take for longer than its hold fails as it did, to be tried again', async (t) => {
  const { s } = store(t, [], { backoffMs: () => 2000, keepWithinMs: 300 });
  await s.ready();
  process.kill(s.pid(), 'SIGKILL');
  while (!s.down()) await new Promise((resolve) => setTimeout(resolve, 10));
  await assert.rejects(s.keep(event('too-long')), /being started again/);
});

test('an event that cannot be kept finishes its delivery saying why', async (t) => {
  const { s } = store(t);
  await s.ready();
  await s.keep(event('one'));
  assert.deepEqual(await s.keep({ ...event('far'), at: 1e300 }), {
    kept: false,
    refused: 'not kept: its time is not one between 1970 and 9999',
  });
  assert.deepEqual((await s.answer(null, null, 'SELECT count(*) AS n FROM events')).rows, [[1]]);
});

/** A databases' process of the test's own, from `code`. */
function script(code) {
  const file = path.join(tmp('keg-query-child-'), 'child.js');
  fs.writeFileSync(file, code);
  return file;
}

test('a database that cannot be opened stops the service, saying why, and is not started again', async (t) => {
  const said = [];
  let stopped = null;
  const s = startStore({
    dir: os.tmpdir(),
    apps: [],
    say: (line) => said.push(line),
    script: script("process.send({ fatal: '/data/events.duckdb cannot be opened, and is left as it is: IO Error: No space left on device' }, () => process.exit(2));"),
    onFatal: (why) => {
      stopped = why;
    },
  });
  t.after(() => s.close());
  await new Promise((resolve) => setTimeout(resolve, 1500));
  assert.match(stopped, /cannot be opened, and is left as it is: IO Error: No space left on device/);
  assert.ok(!said.some((line) => /starting it again/.test(line)), said.join('\n'));
});

test('while the databases are down a query fails at once, and what is asked of one that never answers fails in time', async (t) => {
  const said = [];
  // A process that is ready, and then answers nothing.
  const s = startStore({
    dir: os.tmpdir(),
    apps: [],
    say: (line) => said.push(line),
    script: script("process.send({ ready: true, notices: [] }); process.on('message', () => {}); setInterval(() => {}, 1000);"),
    askMs: 300,
    onFatal: () => {},
  });
  t.after(() => s.close());
  await new Promise((resolve) => setTimeout(resolve, 500));
  const began = Date.now();
  await assert.rejects(s.keep(event('one')), /did not answer within 0.3 seconds/);
  assert.ok(Date.now() - began < 1500);
  process.kill(s.pid(), 'SIGKILL');
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(s.down(), true);
  const now = Date.now();
  await assert.rejects(s.snapshot(null, null), /being started again/);
  assert.ok(Date.now() - now < 200);
});

test('a databases process that keeps failing to start stops the service, saying why', async (t) => {
  let stopped = null;
  const s = startStore({
    dir: os.tmpdir(),
    apps: [],
    say: () => {},
    script: script('process.exit(3);'),
    starts: 3,
    backoffMs: () => 10,
    onFatal: (why) => {
      stopped = why;
    },
  });
  t.after(() => s.close());
  await new Promise((resolve) => setTimeout(resolve, 1500));
  assert.match(stopped, /the databases' process did not start, 3 times running \(3\)/);
});

test('the databases are ready before their prune at start, one that fails is said, and past its size nothing more is kept until it can be held', async (t) => {
  const dir = tmp('keg-query-');
  // A database whose times DuckDB cannot read as times: every prune of it
  // fails, as one that ran out of memory would.
  const { DuckDBInstance } = require('@duckdb/node-api');
  const made = await DuckDBInstance.create(path.join(dir, 'events.duckdb'));
  const c = await made.connect();
  await c.run(`CREATE TABLE events (id TEXT PRIMARY KEY, cursor BIGINT, type TEXT, subject TEXT, "at" TEXT,
    actor_role TEXT, actor_name TEXT, payload JSON)`);
  await c.run(`INSERT INTO events VALUES ('w0', 1, 'work.changed', 'work/1', 'not a time', 'node', 'kegd', '{}')`);
  c.closeSync();
  made.closeSync();
  const said = [];
  const s = startStore({ dir, apps: [], say: (line) => said.push(line), budgets: { node: 1, app: 1 << 20 } });
  t.after(() => s.close());
  await s.ready();
  // Ready before the prune at start is done: it holds nothing up.
  const failedPrune = (n) => /^events: what it keeps could not be held to its days and size: /.test(n);
  assert.ok(!s.notices().some(failedPrune), s.notices().join('\n'));
  const deadline = Date.now() + 10000;
  while (!s.notices().some(failedPrune)) {
    assert.ok(Date.now() < deadline, s.notices().join('\n'));
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  // Its node's part is past its size: an event of the node's is not kept,
  // and its delivery fails, saying why, to be tried again later.
  await assert.rejects(s.keep(event('w1')), /^Error: events holds more of the node's events than it may, and could not be made smaller \(/);
  // An app's, within its own part, is.
  assert.deepEqual(await s.keep(event('a1', 'app.desk.note.added')), { kept: true });
});

test("an organization's database is held to its days as the others are, and goes when nothing is left in it", async (t) => {
  const { s, dir } = store(t, ['supportdesk']);
  await s.ready();
  const old = { ...theirs('old', C), at: Math.floor(Date.now() / 1000) - 40 * 86400 };
  await s.keep(old);
  await s.keep(theirs('a1', A));
  await s.close();
  const again = startStore({ dir, apps: ['supportdesk'], say: () => {} });
  t.after(() => again.close());
  await again.ready();
  // Held to its days once ready, not before: it goes soon after.
  const kept = () => fs.readdirSync(path.join(dir, 'apps', 'supportdesk')).filter((n) => n.endsWith('.duckdb'));
  const deadline = Date.now() + 10000;
  while (kept().length > 1) {
    assert.ok(Date.now() < deadline, kept().join(' '));
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  // Gone, it reads an empty table.
  assert.equal((await again.snapshot('supportdesk', C)).file, null);
  assert.deepEqual(kept(), [`${A}.duckdb`]);
});

test('what is asked and not answered in time is stopped with its process, and no more than so many keeps wait', async (t) => {
  const said = [];
  const s = startStore({
    dir: os.tmpdir(),
    apps: [],
    say: (line) => said.push(line),
    script: script("process.send({ ready: true, notices: [] }); process.on('message', () => {}); setInterval(() => {}, 1000);"),
    askMs: 300,
    backoffMs: () => 50,
    onFatal: () => {},
  });
  t.after(() => s.close());
  await s.ready();
  const first = s.pid();
  await assert.rejects(s.snapshot(null, null), /did not answer within/);
  // The process that held it is stopped: nothing it was doing goes on.
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.throws(() => process.kill(first, 0), /ESRCH/);
  assert.ok(said.some((line) => /did not answer in time, and is stopped/.test(line)), said.join('\n'));
  while (s.down()) await new Promise((resolve) => setTimeout(resolve, 20));
  // Keeps wait at most so many at once; one more is refused at once.
  const waiting = Array.from({ length: 8 }, (_, n) => s.keep(event(`k${n}`)).catch((e) => e));
  const began = Date.now();
  await assert.rejects(s.keep(event('k9')), /8 events are being kept already/);
  assert.ok(Date.now() - began < 100);
  await Promise.all(waiting);
});

test('what a query calls is checked again as it is asked, inside the query that holds it to its size', async () => {
  const store = require('../store.js');
  const db = await store.open(path.join(tmp('keg-query-'), 'e.duckdb'));
  const seen = [];
  const was = store.checks.calls;
  store.checks.calls = async (connection, sql) => {
    seen.push(sql);
    return was(connection, sql);
  };
  try {
    await store.answer(db, 'SELECT 1 AS one');
  } finally {
    store.checks.calls = was;
  }
  assert.equal(seen.length, 2, seen.join('\n'));
  assert.match(seen[1], /\) AS answered LIMIT/);
});

// Measured with DuckDB 1.5: one call of levenshtein of two strings of
// 60,000 runs some seconds past an interrupt, which DuckDB checks between
// calls alone; and nothing refuses it by name.
const SPINS = "SELECT levenshtein(repeat('a', 60000), repeat('b', 60000))";

test('a query that runs on past its time, however it does, is stopped with its reader, and costs nothing else', async (t) => {
  const { s, r } = store(t, ['supportdesk'], { readers: { graceMs: 300 } });
  await s.ready();
  await s.keep(theirs('a1', A));
  await s.keep(theirs('b1', B));
  // Warm: a reader for each, started.
  await s.answer('supportdesk', B, 'SELECT 1');
  const began = Date.now();
  const spinning = s.answer('supportdesk', A, SPINS, { ms: 500 });
  const pid = await (async () => {
    for (;;) {
      if (r.pids().length) return r.pids()[0];
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  })();
  // While it spins: events are kept at once, and another organization's
  // query is answered.
  await new Promise((resolve) => setTimeout(resolve, 100));
  const keptAt = Date.now();
  assert.deepEqual(await s.keep(theirs('b2', B)), { kept: true });
  assert.ok(Date.now() - keptAt < 1000, `${Date.now() - keptAt} ms`);
  const other = await s.answer('supportdesk', B, 'SELECT count(*) FROM events');
  assert.ok(other.rows[0][0] >= 1, JSON.stringify(other));
  await assert.rejects(spinning, { message: 'the query took more than 0.5 seconds and was stopped' });
  const took = Date.now() - began;
  assert.ok(took < 2500, `${took} ms`);
  // Its reader was killed; another answers the next.
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.ok(!r.pids().includes(pid) || (() => { try { process.kill(pid, 0); return false; } catch { return true; } })());
  assert.deepEqual((await s.answer('supportdesk', A, 'SELECT id FROM events')).rows, [['a1']]);
});

test("what a reader reads is a copy made at most every so often, said as of when, and never one half made", async (t) => {
  const { s, r, said } = store(t, [], { snapshotMs: 300, snapshotPause: { from: 3, ms: 3000, chunk: 4096 } });
  await s.ready();
  await s.keep(event('one'));
  const first = await s.snapshot(null, null);
  assert.ok(Math.abs(first.asOf - Date.now()) < 2000, String(first.asOf));
  // Changed within its time: the copy before, said as of then.
  await s.keep(event('two'));
  const again = await s.snapshot(null, null);
  assert.equal(again.asOf, first.asOf);
  assert.deepEqual((await r.answer(again.file, 'SELECT count(*) FROM events')).rows, [[1]]);
  // Past it: copied again.
  await new Promise((resolve) => setTimeout(resolve, 350));
  const second = await s.snapshot(null, null);
  assert.ok(second.asOf > first.asOf);
  assert.deepEqual((await r.answer(second.file, 'SELECT count(*) FROM events')).rows, [[2]]);
  // The databases' process is killed in the middle of the next copy.
  await s.keep(event('three'));
  await new Promise((resolve) => setTimeout(resolve, 350));
  const whole = fs.statSync(second.file).size;
  const copying = s.snapshot(null, null).catch((error) => error);
  const folder = path.dirname(second.file);
  // Until a part of the next copy is written, wherever it is written.
  const begun = () =>
    fs.statSync(second.file).size !== whole ||
    fs.readdirSync(folder).some((n) => n.includes('.tmp-') && fs.statSync(path.join(folder, n)).size > 0);
  for (const until = Date.now() + 2000; !begun(); ) {
    assert.ok(Date.now() < until, 'the copy did not begin');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  process.kill(s.pid(), 'SIGKILL');
  assert.match(String((await copying).message), /stopped|started again/);
  // What a reader opens is the copy before, whole.
  assert.deepEqual((await r.answer(second.file, 'SELECT count(*) FROM events')).rows, [[2]]);
  assert.ok(said.some((line) => /starting it again/.test(line)), said.join('\n'));
});
