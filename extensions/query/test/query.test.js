'use strict';
// What the query service keeps, what it answers, and who it answers.

const { tmp } = require('./tmp.js');
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { open, openReading, snapshot, openKept, keep, keepChecked, answer, prune, pruned, sizeOf, MAIN_BUDGET, damage, outOfRoom, ONLY_READS, BYTES, VALUE_BYTES } = require('../store.js');

/** A database in a folder of its own, with what was kept and asked in it. */
async function fresh() {
  const dir = tmp('keg-query-');
  const db = await open(path.join(dir, 'events.duckdb'));
  return { db, dir };
}

const event = (id, type, extra = {}) => ({
  id,
  cursor: '7',
  type,
  subject: 'work/1',
  at: 1795000000,
  actor: { role: 'node', name: 'kegd' },
  payload: { state: 'open' },
  ...extra,
});

test('an event is kept once, however often it is told of', async () => {
  const { db } = await fresh();
  assert.equal(await keep(db, event('a', 'work.changed')), true);
  assert.equal(await keep(db, event('a', 'work.changed')), false);
  assert.equal(await keep(db, event('b', 'changeset.changed', { cursor: '9007199254740993' })), true);
  const said = await answer(
    db,
    'SELECT id, cursor, type, subject, "at", actor_role, actor_name, payload->>\'state\' AS state FROM events ORDER BY id',
  );
  assert.deepEqual(said, {
    columns: ['id', 'cursor', 'type', 'subject', 'at', 'actor_role', 'actor_name', 'state'],
    rows: [
      ['a', 7, 'work.changed', 'work/1', '2026-11-18 11:06:40', 'node', 'kegd', 'open'],
      // Past what a number holds exactly, it is said as a string.
      ['b', '9007199254740993', 'changeset.changed', 'work/1', '2026-11-18 11:06:40', 'node', 'kegd', 'open'],
    ],
  });
});

test('a count is answered as a number', async () => {
  const { db } = await fresh();
  for (const [id, type] of [['1', 'work.changed'], ['2', 'work.changed'], ['3', 'changeset.changed']]) {
    await keep(db, event(id, type));
  }
  assert.deepEqual(await answer(db, 'SELECT type, count(*) AS n FROM events GROUP BY type ORDER BY type'), {
    columns: ['type', 'n'],
    rows: [['changeset.changed', 1], ['work.changed', 2]],
  });
});

test('only one query that reads is answered', async () => {
  const { db } = await fresh();
  await keep(db, event('a', 'work.changed'));
  for (const sql of [
    '',
    '  ;  ',
    'DELETE FROM events',
    'UPDATE events SET type = 1',
    'INSERT INTO events (id) VALUES (\'x\')',
    'DROP TABLE events',
    'SELECT 1; DROP TABLE events',
    'SELECT 1; SELECT 2',
    'CREATE TABLE t (a INT)',
    'INSTALL httpfs',
    'LOAD httpfs',
    "ATTACH '/tmp/other.duckdb' AS other",
    'SET enable_external_access = true',
    'RESET lock_configuration',
    'PRAGMA enable_profiling',
    'CHECKPOINT',
    'VACUUM',
    'EXPLAIN SELECT 1',
    "CALL pragma_version()",
    'BEGIN TRANSACTION',
    "PREPARE p AS DELETE FROM events",
    "COPY events TO '/tmp/out.csv'",
    "EXPORT DATABASE '/tmp/out'",
    'not sql at all',
  ]) {
    await assert.rejects(answer(db, sql), { message: ONLY_READS }, sql);
  }
  assert.deepEqual((await answer(db, 'SELECT count(*) FROM events')).rows, [[1]]);
});

test('a query reaches no file, no network and no extension', async () => {
  const { db, dir } = await fresh();
  await keep(db, event('a', 'work.changed'));
  fs.writeFileSync(path.join(dir, 'beside.csv'), 'a\n1\n');
  for (const sql of [
    "SELECT * FROM read_text('/etc/passwd')",
    "SELECT * FROM read_blob('/etc/hostname')",
    `SELECT * FROM read_csv('${path.join(dir, 'beside.csv')}')`,
    `SELECT * FROM read_csv('${path.join(dir, 'events.duckdb')}')`,
    "SELECT * FROM glob('/*')",
    "SELECT * FROM read_csv('https://example.com/x.csv')",
    "SELECT * FROM read_json('http://127.0.0.1:1/x.json')",
    "SELECT * FROM read_parquet('s3://bucket/x.parquet')",
    `SELECT * FROM '${path.join(dir, 'beside.csv')}'`,
    "SELECT * FROM query('DROP TABLE events')",
    "SELECT * FROM query('ATTACH ''/tmp/x.duckdb''')",
    "SELECT * FROM sqlite_scan('/tmp/x.db', 't')",
    "SELECT * FROM postgres_scan('host=127.0.0.1', 'public', 't')",
    "SELECT current_setting('lock_configuration') AND set_config('enable_external_access', 'true')",
  ]) {
    await assert.rejects(answer(db, sql), (error) => {
      assert.ok(error.refused, `${sql}: ${error.message}`);
      assert.notEqual(error.message, ONLY_READS, sql);
      return true;
    });
  }
  assert.deepEqual(
    (await answer(db, "SELECT current_setting('enable_external_access') AS e, current_setting('lock_configuration') AS l")).rows,
    [[false, true]],
  );
  assert.deepEqual((await answer(db, 'SELECT count(*) FROM events')).rows, [[1]]);
});

test('at most so many rows are answered, said to be cut', async () => {
  const { db } = await fresh();
  const said = await answer(db, 'SELECT * FROM range(25000)', { rows: 10000 });
  assert.equal(said.rows.length, 10000);
  assert.equal(said.cut, true);
  const whole = await answer(db, 'SELECT * FROM range(3)', { rows: 10000 });
  assert.deepEqual(whole, { columns: ['range'], rows: [[0], [1], [2]] });
});

test('a query that takes too long is stopped, and the next is answered', async () => {
  const { db } = await fresh();
  const began = Date.now();
  await assert.rejects(answer(db, 'SELECT sum(hash(i)) FROM range(1000000000000000) t(i)', { ms: 300 }), {
    message: 'the query took more than 0.3 seconds and was stopped',
  });
  assert.ok(Date.now() - began < 5000, `${Date.now() - began} ms`);
  assert.deepEqual((await answer(db, 'SELECT 1 AS one')).rows, [[1]]);
});

test("an app's database reads nothing of the one beside it", async () => {
  const { db, dir } = await fresh();
  await keep(db, event('theirs', 'app.other.note.added', { payload: { said: 'not yours' } }));
  await db.connection.run('CHECKPOINT');
  fs.mkdirSync(path.join(dir, 'apps'));
  const app = await open(path.join(dir, 'apps', 'supportdesk.duckdb'), { memory: '64MB' });
  const beside = path.join(dir, 'events.duckdb');
  for (const sql of [
    `SELECT * FROM read_blob('${beside}')`,
    `SELECT * FROM read_text('${beside}.wal')`,
    `SELECT * FROM '${beside}'`,
    `SELECT * FROM glob('${dir}/*')`,
  ]) {
    await assert.rejects(answer(app, sql), /disabled by configuration|a query may not call|never a file/, sql);
  }
  assert.deepEqual((await answer(app, 'SELECT count(*) FROM events')).rows, [[0]]);
});

test('an answer is held to a size, however few its rows, and so is each value', async () => {
  const { db } = await fresh();
  // A thousand million bytes, were it all answered.
  const big = await answer(db, "SELECT repeat('x', 100000) AS x FROM range(10000)");
  assert.equal(big.cut, true);
  assert.ok(JSON.stringify(big).length <= BYTES + VALUE_BYTES * 2, `${JSON.stringify(big).length}`);
  assert.ok(big.rows.length < 10000 && big.rows.length > 0, `${big.rows.length}`);
  for (const [x] of big.rows) assert.equal(x.length, VALUE_BYTES);
  // One value of many: it is cut, said so.
  const one = await answer(db, "SELECT string_agg(repeat('y', 1000), '') AS s, 1 AS n FROM range(20000)");
  assert.equal(one.cut, true);
  assert.equal(one.rows[0][0].length, VALUE_BYTES);
  assert.equal(one.rows[0][1], 1);
  // A list's or a struct's value is held to its size as its JSON, and
  // given as that much of its JSON.
  const list = await answer(db, 'SELECT list(i) AS l FROM range(100000) t(i)');
  assert.equal(list.cut, true);
  assert.equal(typeof list.rows[0][0], 'string');
  assert.equal(list.rows[0][0].length, VALUE_BYTES);
  // What is small is answered whole, not said to be cut.
  assert.deepEqual(await answer(db, "SELECT repeat('z', 10) AS z"), { columns: ['z'], rows: [['zzzzzzzzzz']] });
});

test('DuckDB is held below the memory the service has, with two threads', async () => {
  const { db } = await fresh();
  const said = await answer(db, "SELECT current_setting('memory_limit') AS m, current_setting('threads') AS t");
  assert.deepEqual(said.rows, [['152.5 MiB', 2]]);
});

test('a query spills nothing to disk, and events are kept while two would', async () => {
  const { db } = await fresh();
  const spilling = [
    'SELECT * FROM range(100000000) t(i) ORDER BY random()',
    'SELECT i, count(*) FROM range(60000000) t(i) GROUP BY i',
  ].map((sql) => answer(db, sql, { ms: 8000 }).then(() => 'answered', (error) => error.message));
  let most = 0;
  let n = 0;
  const kept = [];
  const keeping = setInterval(() => {
    kept.push(keep(db, event(`e${(n += 1)}`, 'work.changed')));
    answer(db, 'SELECT coalesce(sum(size), 0) AS s FROM duckdb_temporary_files()').then(
      (said) => (most = Math.max(most, Number(said.rows[0][0]))),
      () => {},
    );
  }, 100);
  const said = await Promise.all(spilling);
  clearInterval(keeping);
  for (const why of said) assert.match(why, /Out of Memory Error|stopped|answered/, why);
  assert.equal(most, 0, `${most} bytes spilled`);
  assert.ok((await Promise.all(kept)).every((k) => k === true));
  assert.equal((await answer(db, 'SELECT count(*) FROM events')).rows[0][0], n);
  const settings = await answer(db, "SELECT current_setting('temp_directory') AS t");
  assert.deepEqual(settings.rows, [['']]);
});

test('a write that fails is tried again here before the delivery is failed', async () => {
  const { db } = await fresh();
  const run = db.insert.run.bind(db.insert);
  let failing = 2;
  db.insert.run = async () => {
    if (failing > 0) {
      failing -= 1;
      throw new Error('IO Error: could not write');
    }
    return run();
  };
  assert.equal(await keep(db, event('a', 'work.changed'), { waitMs: 1 }), true);
  failing = 5;
  await assert.rejects(keep(db, event('b', 'work.changed'), { waitMs: 1 }), /could not write/);
  assert.deepEqual((await answer(db, 'SELECT id FROM events')).rows, [['a']]);
});

test('what is kept is held to its days and its size, the oldest going first', async () => {
  const { db } = await fresh();
  const day = 24 * 60 * 60;
  const now = 1795000000;
  await keep(db, event('old', 'work.changed', { at: now - 31 * day }));
  await keep(db, event('new', 'work.changed', { at: now - day }));
  assert.deepEqual(await prune(db, { days: 30, bytes: 1 << 30, now }), { old: 1, over: 0 });
  assert.deepEqual((await answer(db, 'SELECT id FROM events')).rows, [['new']]);

  // Past its size, the oldest go until it is well within it.
  for (let n = 0; n < 2000; n += 1) {
    await keep(db, event(`e${String(n).padStart(4, '0')}`, 'work.changed', { at: now - 2000 + n, payload: { pad: require('node:crypto').randomBytes(1000).toString('hex') } }));
  }
  const used = () => sizeOf(db);
  const before = await used();
  const bound = Math.floor(before / 2);
  const pruned = await prune(db, { days: 30, bytes: bound, now });
  assert.ok(pruned.over > 0, JSON.stringify(pruned));
  assert.ok((await used()) <= bound, `${await used()} > ${bound}`);
  // The newest are left; 'new', older than all of them, went first.
  const left = (await answer(db, "SELECT min(id), max(id), count(*) FILTER (id = 'new') FROM events")).rows[0];
  assert.equal(left[1], 'e1999');
  assert.ok(left[0] > 'e0000', left[0]);
  assert.equal(left[2], 0);
  // Within it, nothing goes.
  assert.deepEqual(await prune(db, { days: 30, bytes: bound, now }), { old: 0, over: 0 });
});

test('no function is refused by its name: what holds a query to its time is its reader, killed past it', async () => {
  // levenshtein can run on past an interrupt (README, "Limits"); a reader
  // running it past its time is killed (worker.test.js), so it is not
  // refused here as a name, nor is any other.
  const { db } = await fresh();
  assert.deepEqual((await answer(db, "SELECT levenshtein('kitten', 'sitting') AS d, damerau_levenshtein('ab', 'ba') AS e")).rows, [[3, 1]]);
});

test("a copy for readers is the database as kept, opened to read alone, and locked as every database is", async () => {
  const { db, dir } = await fresh();
  await keep(db, event('one', 'work.changed'));
  const to = path.join(dir, 'copies', 'events.duckdb');
  assert.equal(await snapshot(db, to), 'made');
  assert.equal(await snapshot(db, to), 'same');
  // Not copied where the volume has no room for it.
  await keep(db, event('two', 'work.changed'));
  assert.equal(await snapshot(db, to, { room: () => false }), 'no-room');
  const reading = await openReading(to);
  assert.deepEqual((await answer(reading, 'SELECT id FROM events')).rows, [['one']]);
  await assert.rejects(answer(reading, "SELECT * FROM read_text('/etc/passwd')"), /may not call read_text/);
  assert.deepEqual((await answer(reading, "SELECT current_setting('enable_external_access') AS x, current_setting('lock_configuration') AS y")).rows, [[false, true]]);
  // It only reads: nothing a connection of its own does writes to it.
  const c = await reading.instance.connect();
  await assert.rejects(c.run("INSERT INTO events (id) VALUES ('x')"), /read-only/i);
  c.closeSync();
  reading.instance.closeSync();
  assert.equal(await snapshot(db, to), 'made');
  const after = await openReading(to);
  assert.deepEqual((await answer(after, 'SELECT id FROM events ORDER BY id')).rows, [['one'], ['two']]);
  after.instance.closeSync();
});

test('an event that cannot be kept is refused, and nothing kept goes for it', async () => {
  const { db } = await fresh();
  for (let n = 0; n < 50; n += 1) await keep(db, event(`k${n}`, 'work.changed'));
  const big = 'x'.repeat(2 * 1024 * 1024);
  for (const bad of [
    event('far', 'work.changed', { at: 1e300 }),
    event('before', 'work.changed', { at: -1 }),
    event('nan', 'work.changed', { at: Number.NaN }),
    event('huge', 'work.changed', { payload: { big } }),
    event('', 'work.changed'),
    event('t', ''),
    { ...event('nobig', 'work.changed'), payload: { n: 10n } },
  ]) {
    const said = await keepChecked(db, bad, { bytes: 1 });
    assert.equal(said.kept, false, bad.id);
    assert.match(said.refused, /./, bad.id);
  }
  assert.equal((await answer(db, 'SELECT count(*) FROM events')).rows[0][0], 50);
});

test('a write that fails for any reason but room is thrown, and nothing goes', async () => {
  const { db } = await fresh();
  for (let n = 0; n < 50; n += 1) await keep(db, event(`k${n}`, 'work.changed'));
  db.insert.run = async () => {
    throw new Error('Constraint Error: something else');
  };
  await assert.rejects(keepChecked(db, event('x', 'work.changed'), { bytes: 1, waitMs: 1, free: () => 1 << 30 }), /something else/);
  assert.equal((await answer(db, 'SELECT count(*) FROM events')).rows[0][0], 50);
});

test('a write that fails for want of room makes room by the rule, and is kept', async () => {
  const { db } = await fresh();
  const now = Math.trunc(Date.now() / 1000);
  for (let n = 0; n < 50; n += 1) await keep(db, event(`k${n}`, 'work.changed', { at: now - 100 + n }));
  const run = db.insert.run.bind(db.insert);
  let full = true;
  db.insert.run = async () => {
    if (full) throw new Error('IO Error: Could not write file "events.duckdb.wal": No space left on device');
    return run();
  };
  // Within its size: nothing goes, and it is tried again later.
  await assert.rejects(keepChecked(db, event('x', 'work.changed', { at: now }), { bytes: 1 << 30, waitMs: 1 }), /No space left/);
  assert.equal((await answer(db, 'SELECT count(*) FROM events')).rows[0][0], 50);
  // Past it: the oldest go as the rule says, and then it is kept.
  const size = await sizeOf(db);
  const pruning = keepChecked(db, event('y', 'work.changed', { at: now }), { bytes: Math.floor(size / 2), waitMs: 1 });
  setTimeout(() => (full = false), 5);
  assert.deepEqual(await pruning, { kept: true });
  const left = Number((await answer(db, 'SELECT count(*) FROM events')).rows[0][0]);
  assert.ok(left > 1 && left < 50, `${left}`);
  assert.deepEqual((await answer(db, "SELECT count(*) FROM events WHERE id = 'k49'")).rows, [[1]]);
});

test('a query calls only table functions that read what it was given, and nothing of its files', async () => {
  const { db, dir } = await fresh();
  await keep(db, event('a', 'work.changed'));
  await db.connection.run('CHECKPOINT');
  const own = path.join(dir, 'events.duckdb');
  for (const sql of [
    'SELECT * FROM checkpoint()',
    'SELECT * FROM force_checkpoint()',
    'SELECT * FROM enable_logging()',
    `SELECT size FROM read_blob('${own}')`,
    `SELECT * FROM read_text('${own}.wal')`,
    `SELECT * FROM read_csv('${own}')`,
    `SELECT * FROM (SELECT * FROM (SELECT size FROM read_blob('${own}')))`,
    `WITH x AS (SELECT * FROM read_blob('${own}')) SELECT count(*) FROM x`,
    `SELECT (SELECT size FROM read_blob('${own}'))`,
    "SELECT * FROM query('SELECT 1')",
    "SELECT * FROM query_table('events')",
  ]) {
    await assert.rejects(answer(db, sql), (error) => {
      assert.ok(error.refused, sql);
      assert.match(error.message, /^a query may not call /, `${sql}: ${error.message}`);
      return true;
    });
  }
  for (const sql of [
    'SELECT count(*) FROM range(10)',
    'SELECT count(*) FROM generate_series(1, 3)',
    'SELECT unnest([1, 2])',
    "SELECT count(*) FROM duckdb_settings() WHERE name = 'memory_limit'",
    'SELECT count(*) FROM duckdb_temporary_files()',
    "SELECT key FROM json_each('{\"a\": 1}')",
  ]) {
    await answer(db, sql);
  }
  assert.deepEqual((await answer(db, 'SELECT count(*) FROM events')).rows, [[1]]);
});

test('a database that cannot be opened is set aside, said so, and begun again', async () => {
  const dir = tmp('keg-query-');
  const file = path.join(dir, 'events.duckdb');
  fs.writeFileSync(file, 'not a database at all, '.repeat(1000));
  fs.writeFileSync(`${file}.wal`, 'nor this');
  const { db, setAside } = await openKept(file, {}, () => new Date('2026-11-23T01:02:03Z'));
  assert.equal(setAside, `${file}.corrupt-2026-11-23T01-02-03Z`);
  assert.ok(fs.readFileSync(setAside, 'utf8').startsWith('not a database at all'));
  assert.equal(fs.readFileSync(`${setAside}.wal`, 'utf8'), 'nor this');
  assert.equal(await keep(db, event('a', 'work.changed')), true);
  // One that opens is not set aside.
  const again = await openKept(path.join(dir, 'other.duckdb'));
  assert.equal(again.setAside, null);
});

test('only a damaged database is set aside, and only the last one set aside is kept', async () => {
  const dir = tmp('keg-query-');
  const file = path.join(dir, 'events.duckdb');
  const damaged = () => fs.writeFileSync(file, 'not a database at all, '.repeat(1000));
  damaged();
  const first = await openKept(file, {}, () => new Date('2026-11-23T01:02:03Z'));
  first.db.connection.closeSync();
  first.db.instance.closeSync();
  damaged();
  const second = await openKept(file, {}, () => new Date('2026-11-23T02:02:03Z'));
  assert.equal(second.setAside, `${file}.corrupt-2026-11-23T02-02-03Z`);
  assert.deepEqual(
    fs.readdirSync(dir).filter((n) => n.includes('.corrupt-')).sort(),
    ['events.duckdb.corrupt-2026-11-23T02-02-03Z'],
  );
});

test('a database that cannot be opened for any reason but damage is not set aside: the service stops, saying why', async () => {
  const dir = tmp('keg-query-');
  const file = path.join(dir, 'events.duckdb');
  const made = await open(file);
  await keep(made, event('a', 'work.changed'));
  made.connection.closeSync();
  made.instance.closeSync();
  for (const said of [
    'IO Error: Cannot open file "/data/events.duckdb": Permission denied',
    'IO Error: Could not write file "/data/events.duckdb.wal": No space left on device',
    'Out of Memory Error: could not allocate block of size 256.0 KiB',
  ]) {
    const failing = async () => {
      throw new Error(said);
    };
    await assert.rejects(openKept(file, {}, () => new Date(), failing), (error) => error.fatal === true && error.message.includes(said));
    assert.deepEqual(fs.readdirSync(dir).filter((n) => n.includes('.corrupt-')), []);
  }
  for (const said of [
    'IO Error: The file "/data/events.duckdb" exists, but it is not a valid DuckDB database file!',
    'IO Error: Corrupt database file: computed checksum 1 does not match stored checksum 2 in block at location 12288',
  ]) {
    assert.equal(damage(new Error(said)), true, said);
  }
  assert.equal(damage(new Error('IO Error: Cannot open file "x": Permission denied')), false);
  // A database a newer DuckDB wrote is not damaged: the service stops,
  // saying so, and it is left as it is.
  for (const said of [
    'Serialization Error: Failed to deserialize: field id mismatch, expected: 103, got: 104',
    'IO Error: Trying to read a database file with version number 99, but we can only read versions up to 67.',
  ]) {
    assert.equal(damage(new Error(said)), false, said);
  }
});

test('room is made only for an error of writing for want of room, or a write that failed with the volume nearly full', async () => {
  const error = (m) => new Error(m);
  assert.equal(outOfRoom(error('IO Error: Could not write file "x.wal": No space left on device'), 1 << 30), true);
  assert.equal(outOfRoom(error('IO Error: Could not write file "x.wal": Input/output error'), 1024), true);
  // Not an error of writing, however full the volume.
  assert.equal(outOfRoom(error('Constraint Error: Duplicate key'), 1024), false);
  assert.equal(outOfRoom(error('Conversion Error: Malformed JSON'), 0), false);
  assert.equal(outOfRoom(error('IO Error: Could not write file "x.wal": Input/output error'), 1 << 30), false);
});

test('every value that is not of a fixed width is cut in bytes, and what DuckDB makes is held to the answer by its columns', async () => {
  const { db } = await fresh();
  const bytes = (s) => Buffer.byteLength(s);
  // As the review ran them: a list of a large text, ten thousand times.
  const listed = await answer(db, "SELECT [repeat('x',100000)] FROM range(10000)");
  assert.equal(listed.cut, true);
  assert.ok(bytes(JSON.stringify(listed)) <= BYTES, `${bytes(JSON.stringify(listed))}`);
  for (const [l] of listed.rows) assert.ok(bytes(l) <= VALUE_BYTES, `${bytes(l)}`);
  // DuckDB is asked for no more rows than the answer's size could hold.
  assert.ok(listed.rows.length * (VALUE_BYTES + 1) <= BYTES, `${listed.rows.length}`);
  // A struct, a map, a blob and a bit string alike.
  for (const sql of [
    "SELECT {'a': repeat('x', 100000)} FROM range(3)",
    "SELECT map(['k'], [repeat('x', 100000)]) FROM range(3)",
    "SELECT encode(repeat('x', 100000)) FROM range(3)",
    "SELECT repeat('1', 100000)::BIT FROM range(3)",
  ]) {
    const said = await answer(db, sql);
    assert.equal(said.cut, true, sql);
    for (const [v] of said.rows) assert.ok(bytes(String(v)) <= VALUE_BYTES, `${sql}: ${bytes(String(v))}`);
  }
  // Counted in bytes: a character of four is never cut through.
  const wide = await answer(db, "SELECT repeat('😀', 5000) AS w");
  assert.equal(wide.cut, true);
  assert.ok(bytes(wide.rows[0][0]) <= VALUE_BYTES && bytes(wide.rows[0][0]) > VALUE_BYTES - 4);
  assert.ok(!wide.rows[0][0].includes('�'));
  // Two wide columns: fewer rows, held to the answer's size.
  const two = await answer(db, "SELECT repeat('x', 8000) a, repeat('y', 8000) b FROM range(10000)");
  assert.equal(two.cut, true);
  assert.ok(two.rows.length * 2 * VALUE_BYTES <= BYTES, `${two.rows.length}`);
  // What is small is whole, a list as DuckDB writes it.
  assert.deepEqual(await answer(db, "SELECT [1, 2] AS l, 7 AS n, {'a': 'b'} AS s"), { columns: ['l', 'n', 's'], rows: [['[1, 2]', 7, "{'a': b}"]] });
});

test('at most 100 columns are answered', async () => {
  const { db } = await fresh();
  const cols = Array.from({ length: 400 }, (_, i) => `repeat('x',8000) AS c${i}`).join(', ');
  await assert.rejects(answer(db, `SELECT ${cols} FROM range(10001)`), /at most 100 columns are answered; this query has 400/);
  const hundred = Array.from({ length: 100 }, (_, i) => `${i} AS c${i}`).join(', ');
  assert.equal((await answer(db, `SELECT ${hundred}`)).columns.length, 100);
});

test('DESCRIBE, SUMMARIZE and SHOW TABLES are answered, and a PIVOT that names no values is told how to', async () => {
  const { db } = await fresh();
  await keep(db, event('a', 'work.changed'));
  assert.equal((await answer(db, 'DESCRIBE events')).rows.length, 8);
  assert.equal((await answer(db, 'SUMMARIZE events')).rows.length, 8);
  assert.deepEqual((await answer(db, 'SHOW TABLES')).rows, [['events']]);
  await assert.rejects(
    answer(db, 'PIVOT events ON type'),
    {
      message:
        "a PIVOT is answered when it names the values it makes columns of: PIVOT events ON type IN ('work.changed', 'changeset.changed') USING count(*)",
    },
  );
  const named = await answer(db, "PIVOT (SELECT type FROM events) ON type IN ('work.changed') USING count(*)");
  assert.deepEqual(named.rows, [[1]]);
});

test('a query that names a file as its table is refused, saying so', async () => {
  const { db, dir } = await fresh();
  for (const name of ['/data/events.duckdb', '/data/events.duckdb.wal', `${dir}/events.duckdb`, 'events.csv', '../x.parquet']) {
    await assert.rejects(answer(db, `SELECT * FROM '${name}'`), { message: `a query reads the table events, never a file: ${name}` });
    await assert.rejects(answer(db, `SELECT * FROM "${name}"`), { message: `a query reads the table events, never a file: ${name}` });
  }
  assert.deepEqual((await answer(db, 'SELECT count(*) FROM main.events')).rows, [[0]]);
});

test('an event whose text is not well formed is finished saying so, not failed on every try', async () => {
  const { db } = await fresh();
  for (const extra of [{ payload: '\ud800' }, { payload: { a: ['x\udc00'] } }, { subject: 'work/\ud800' }]) {
    assert.deepEqual(await keepChecked(db, event('s', 'work.changed', extra), { waitMs: 1 }), {
      kept: false,
      refused: 'not kept: its text is not well-formed Unicode (a lone surrogate)',
    });
  }
  assert.deepEqual(await keepChecked(db, event('ok', 'work.changed', { payload: '😀' }), { waitMs: 1 }), { kept: true });
});

test('what is asked of one database is done one at a time, so a prune beside many keeps is safe', async () => {
  const { db } = await fresh();
  for (let n = 0; n < 2000; n += 1) await keep(db, event(`x${n}`, 'work.changed', { at: 1795000000 + n, payload: { b: 'y'.repeat(200) } }));
  // Many at once, as two callers could ask, with a prune among them: one
  // connection that runs two at once can bring its process down.
  const asked = Array.from({ length: 200 }, (_, n) => keepChecked(db, event(`n${n}`, 'work.changed', { at: 1795100000 + n }), { waitMs: 1 }));
  asked.push(pruned(db, { bytes: 64 * 1024 }));
  await Promise.all(asked);
  assert.deepEqual((await answer(db, "SELECT count(*) FROM events WHERE id LIKE 'n%'")).rows, [[200]]);
});

test("in the database of all it heard, apps' events and the node's are held to sizes of their own", async () => {
  const { db } = await fresh();
  const now = 1795000000;
  for (let n = 0; n < 50; n += 1) await keep(db, event(`w${n}`, 'work.changed', { at: now - 5000 + n }));
  // Many more of an app's, newer: they push out only their own.
  for (let n = 0; n < 1000; n += 1) {
    await keep(db, event(`a${n}`, 'app.desk.note.added', { at: now - 1000 + n, payload: { pad: 'p'.repeat(1000) } }));
  }
  const went = await prune(db, { days: 30, bytes: { node: 1 << 20, app: 200 * 1024 }, now });
  assert.ok(went.over > 0, JSON.stringify(went));
  const [[work, apps]] = (await answer(db, "SELECT count(*) FILTER (type = 'work.changed'), count(*) FILTER (type LIKE 'app.%') FROM events")).rows;
  assert.equal(work, 50);
  assert.ok(apps > 0 && apps < 1000, `${apps}`);
  assert.deepEqual(MAIN_BUDGET, { node: 256 * 1024 * 1024, app: 128 * 1024 * 1024 });
});

test('past its size it keeps close to as much as fits, whichever day holds the most', async () => {
  // Little today, much the day before: what goes is cut within that day,
  // not all of it.
  const { db } = await fresh();
  const now = 1795000000;
  const today = 100;
  const before = 50000;
  await db.connection.run(
    `INSERT INTO events SELECT 't-' || i::VARCHAR, i, 'work.changed', 'work/t' || i::VARCHAR,
       make_timestamp((${now} - ${today} + i) * 1000000), 'node', 'kegd', '{}'::JSON
     FROM range(${today}) t(i)`,
  );
  await db.connection.run(
    `INSERT INTO events SELECT 'y-' || i::VARCHAR, ${today} + i, 'work.changed', 'work/y' || i::VARCHAR,
       make_timestamp((${now} - 86400 - ${before} + i) * 1000000), 'node', 'kegd', ('{"pad":"' || repeat('x', 100) || '"}')::JSON
     FROM range(${before}) t(i)`,
  );
  const bound = 1 << 20;
  const target = Math.floor(bound * 0.8);
  assert.ok((await sizeOf(db)) > 2 * bound);
  await prune(db, { days: 30, bytes: bound, now });
  const left = await sizeOf(db);
  assert.ok(left <= bound, `${left} > ${bound}`);
  assert.ok(left >= 0.7 * target, `only ${left} of ${target} was left`);
  const [[todays]] = (await answer(db, "SELECT count(*) FROM events WHERE id LIKE 't-%'")).rows;
  assert.equal(todays, today);
});

test('a database of many rows is held to its size within a small memory, a batch at a time', async () => {
  // Made with room to spare, then opened as the service opens a small one:
  // a prune that sorts the whole table, or deletes it all at once, runs
  // out of DuckDB's memory here.
  const dir = tmp('keg-query-');
  const file = path.join(dir, 'many.duckdb');
  const rows = 100000;
  const now = 1795000000;
  const made = await open(file, { memory: '1GB' });
  await made.connection.run(
    `INSERT INTO events SELECT 'e-' || i::VARCHAR || '-' || md5(i::VARCHAR), i, 'work.changed', 'work/' || i::VARCHAR,
       make_timestamp((${now} - ${rows} + i) * 1000000), 'node', 'kegd', ('{"pad":"' || repeat('x', 100) || '"}')::JSON
     FROM range(${rows}) t(i)`,
  );
  await made.connection.run('CHECKPOINT');
  made.insert.destroySync();
  made.connection.closeSync();
  made.instance.closeSync();
  const db = await open(file, { memory: '16MB' });
  const bound = 1 << 20;
  const went = await prune(db, { days: 30, bytes: bound, now });
  assert.ok(went.over > rows / 2, JSON.stringify(went));
  assert.ok((await sizeOf(db)) <= bound, `${await sizeOf(db)} > ${bound}`);
  // The newest are what is left.
  const [[newest, n]] = (await answer(db, 'SELECT max(cursor), count(*) FROM events')).rows;
  assert.equal(newest, rows - 1);
  assert.equal(n, rows - went.over);
  // And so are the old by their days, as many.
  const old = await prune(db, { days: 1, bytes: bound, now: now + 86400 + rows / 2 });
  assert.ok(old.old > 0, JSON.stringify(old));
});
