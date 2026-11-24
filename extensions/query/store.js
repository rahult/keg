'use strict';
// The events this service heard, kept in DuckDB, and the SQL it answers.
//
// A database is opened locked: DuckDB reaches no file but its own, no
// network and no extension, and nothing asked of it can change that. Of
// what it is asked, one statement that reads is run, in a transaction
// that is always rolled back, on a connection of its own, for so long and
// for so many rows.

const fs = require('node:fs');
const { DuckDBInstance, StatementType, DuckDBTypeId, JsonDuckDBValueConverter } = require('@duckdb/node-api');

/** What anything but one statement that reads is told. */
const ONLY_READS = 'only one query that reads is answered';
/**
 * What a PIVOT that names none of its values is told: DuckDB runs it as
 * more than one statement, finding the values first.
 */
const PIVOT_NAMED =
  "a PIVOT is answered when it names the values it makes columns of: PIVOT events ON type IN ('work.changed', 'changeset.changed') USING count(*)";

/**
 * The most rows answered, and the longest a query runs, by default; the
 * most an answer holds, as JSON, however few its rows; and the most of
 * any one value, a longer one being cut there.
 */
const ROWS = 10000;
const MS = 10000;
const BYTES = 8 * 1024 * 1024;
const VALUE_BYTES = 4 * 1024;
/** The most columns an answer has. */
const COLUMNS = 100;

const TABLE = `CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  cursor BIGINT,
  type TEXT,
  subject TEXT,
  "at" TIMESTAMP,
  actor_role TEXT,
  actor_name TEXT,
  payload JSON
)`;

/**
 * The table functions a query may call: what makes rows of what it was
 * given, and what tells of DuckDB itself. Any other, such as one that
 * reads a file (its own database's among them), checkpoints, logs, or
 * runs SQL given as text, is refused.
 */
const TABLE_FUNCTIONS = new Set([
  'range',
  'generate_series',
  'unnest',
  'json_each',
  'json_tree',
  'duckdb_settings',
  'duckdb_functions',
  'duckdb_keywords',
  'duckdb_types',
  'duckdb_tables',
  'duckdb_columns',
  'duckdb_views',
  'duckdb_schemas',
  'duckdb_constraints',
  'duckdb_indexes',
  'duckdb_temporary_files',
  'pragma_table_info',
  'pragma_database_size',
]);

/** Each table function a parsed query calls, wherever it is in it. */
function tableFunctions(tree, found = new Set()) {
  if (Array.isArray(tree)) {
    for (const item of tree) tableFunctions(item, found);
  } else if (tree && typeof tree === 'object') {
    if (tree.type === 'TABLE_FUNCTION' && tree.function && typeof tree.function.function_name === 'string') {
      found.add(tree.function.function_name.toLowerCase());
    }
    for (const value of Object.values(tree)) tableFunctions(value, found);
  }
  return found;
}

/**
 * Each table a parsed query names that is a file's name, wherever it is
 * in it: DuckDB reads `FROM 'x.csv'` as the file, and `FROM
 * '<its own database>'` as an attempt to attach it.
 */
function filesNamed(tree, found = new Set()) {
  if (Array.isArray(tree)) {
    for (const item of tree) filesNamed(item, found);
  } else if (tree && typeof tree === 'object') {
    if (tree.type === 'BASE_TABLE' && typeof tree.table_name === 'string' && /[/\\.]/.test(tree.table_name)) {
      found.add(tree.table_name);
    }
    for (const value of Object.values(tree)) filesNamed(value, found);
  }
  return found;
}

/**
 * What a query may call, checked as DuckDB parses it: no table function
 * but those of `TABLE_FUNCTIONS`, and no file named as a table. Kept on an
 * object, so a test can see each query it is asked of.
 */
const checks = {
  async calls(connection, sql) {
    const parsed = await connection.runAndReadAll('SELECT json_serialize_sql($1::VARCHAR)', [sql]);
    const tree = JSON.parse(String(parsed.getRows()[0][0]));
    if (tree.error) throw new Refused(ONLY_READS);
    for (const name of tableFunctions(tree.statements)) {
      if (!TABLE_FUNCTIONS.has(name)) throw new Refused(`a query may not call ${name}()`);
    }
    for (const name of filesNamed(tree.statements)) {
      throw new Refused(`a query reads the table events, never a file: ${name}`);
    }
  },
};

/** A refusal of what was asked, said to whoever asked. */
class Refused extends Error {
  constructor(message) {
    super(message);
    this.refused = true;
  }
}

/**
 * Opens (or makes) the database at `file`, with its table, locked. Set as
 * it is opened, so nothing is ever run on it unlocked.
 * @param {string} file
 * @param {{ memory?: string }} [options]
 */
async function open(file, options = {}) {
  const instance = await DuckDBInstance.create(file, locked(options));
  const connection = await instance.connect();
  await connection.run(TABLE);
  const insert = await connection.prepare(
    `INSERT INTO events VALUES ($1, $2, $3, $4, make_timestamp($5::BIGINT * 1000000), $6, $7, $8::JSON)
     ON CONFLICT DO NOTHING`,
  );
  // Each database is taken to have changed since it was last copied for
  // its readers (`snapshot`) when it is opened.
  return { instance, connection, insert, file, changed: true };
}

/**
 * Opens a copy of a database (`snapshot`) that only reads, locked as
 * `open` locks one: what a reader answers a query from.
 */
async function openReading(file, options = {}) {
  const instance = await DuckDBInstance.create(file, { access_mode: 'READ_ONLY', ...locked(options) });
  return { instance, file };
}

/** The settings a database is opened with, so nothing is ever run on it unlocked. */
function locked(options) {
  return {
    // Nothing is spilled to disk: a query past its memory is refused. A
    // spill would go to the volume the events are kept on, and DuckDB
    // 1.5.6 does not hold it to max_temp_directory_size (a GROUP BY was
    // seen to spill 1.3 GB past a limit of 64 MB). Set first: it cannot be
    // once external access is off.
    temp_directory: '',
    // No file but its own, no network, no extension, no secret.
    enable_external_access: 'false',
    autoinstall_known_extensions: 'false',
    autoload_known_extensions: 'false',
    allow_community_extensions: 'false',
    allow_unsigned_extensions: 'false',
    allow_persistent_secrets: 'false',
    // Within the service's memory, beside the programs of Node that run it
    // and the other databases (README): DuckDB refuses what
    // would take more.
    memory_limit: options.memory || '160MB',
    threads: '2',
    // And none of the above can be set again.
    lock_configuration: 'true',
  };
}

/**
 * Whether DuckDB said a database's file is damaged: not a database of its
 * own, or a block whose checksum is wrong. DuckDB's binding for Node gives
 * an error's message alone, which begins with DuckDB's own type of it
 * (`IO Error: `, `Serialization Error: `, ...); no field says the type. So
 * the type is read from that start, and the damage from what DuckDB says
 * of it there.
 */
function damage(error) {
  const said = String(error && error.message);
  // Not a `Serialization Error` alone: DuckDB says that of a file a newer
  // DuckDB wrote too, which is to be left as it is, not set aside.
  return /^IO Error: .*(not a valid DuckDB database file|Corrupt database file|checksum .* does not match)/s.test(said);
}

/** What the service is stopped with: a database it cannot open, and why. */
class CannotOpen extends Error {
  constructor(file, error) {
    super(`${file} cannot be opened, and is left as it is: ${String(error && error.message)}`);
    this.fatal = true;
  }
}

/**
 * Opens the database at `file` as `open` does. One DuckDB says is damaged
 * is moved aside, with its WAL, to `<file>.corrupt-<when>`, in place of
 * any set aside before, and begun again empty. One that cannot be opened
 * for any other reason (no room, no memory, a file it may not read) is
 * left as it is, and a `CannotOpen` thrown: the service stops, saying
 * why, and nothing is lost. Where it was set aside, or null.
 */
async function openKept(file, options = {}, now = () => new Date(), opening = open) {
  try {
    return { db: await opening(file, options), setAside: null };
  } catch (error) {
    if (!fs.existsSync(file) || !damage(error)) throw new CannotOpen(file, error);
    const dir = require('node:path').dirname(file);
    const base = require('node:path').basename(file);
    for (const name of fs.readdirSync(dir)) {
      if (name.startsWith(`${base}.corrupt-`)) fs.rmSync(require('node:path').join(dir, name), { force: true });
    }
    const setAside = `${file}.corrupt-${now().toISOString().replace(/\.\d+Z$/, 'Z').replace(/:/g, '-')}`;
    fs.renameSync(file, setAside);
    if (fs.existsSync(`${file}.wal`)) fs.renameSync(`${file}.wal`, `${setAside}.wal`);
    return { db: await open(file, options), setAside };
  }
}

/** A cursor as a number to keep, or nothing if it is not one. */
function cursorOf(cursor) {
  return /^\d{1,19}$/.test(String(cursor)) ? BigInt(cursor) : null;
}

/** How many times a write is tried here before its delivery is failed. */
const TRIES = 3;

/**
 * Keeps an event once, by its id. Whether it was new. A write that fails
 * is tried again, `TRIES` in all, a little later each time, before what
 * it failed with is thrown.
 * @param {{ insert: import('@duckdb/node-api').DuckDBPreparedStatement }} db
 */
async function keep(db, event, { waitMs = 200 } = {}) {
  for (let tried = 1; ; tried += 1) {
    try {
      return await keepOnce(db, event);
    } catch (error) {
      if (tried >= TRIES) throw error;
      await new Promise((resolve) => setTimeout(resolve, waitMs * tried));
    }
  }
}

async function keepOnce(db, event) {
  const actor = event.actor || {};
  const at = Number.isFinite(event.at) ? Math.trunc(event.at) : 0;
  const values = [
    String(event.id),
    cursorOf(event.cursor),
    String(event.type),
    String(event.subject),
    BigInt(at),
    actor.role == null ? null : String(actor.role),
    actor.name == null ? null : String(actor.name),
    JSON.stringify(event.payload ?? null),
  ];
  db.insert.clearBindings();
  db.insert.bind(values);
  const done = await db.insert.run();
  if (done.rowsChanged === 1) db.changed = true;
  return done.rowsChanged === 1;
}

/** How long an event is kept, in days, and how much a database holds. */
const DAYS = 30;
const MAIN_BYTES = 384 * 1024 * 1024;
const APP_BYTES = 128 * 1024 * 1024;
/**
 * The database of all it heard holds the node's own events and the apps'
 * to sizes of their own, so apps that write much never push out the
 * node's work and change sets.
 */
const MAIN_BUDGET = { node: 256 * 1024 * 1024, app: 128 * 1024 * 1024 };
/** Which events each part of a budget holds. */
const PARTS = { node: "type NOT LIKE 'app.%'", app: "type LIKE 'app.%'" };

/** What one event takes, as DuckDB is asked it: its text and a little more. */
const SIZE = `(strlen(id) + strlen(type) + strlen(subject)
  + strlen(coalesce(actor_role, '')) + strlen(coalesce(actor_name, ''))
  + strlen(coalesce(payload::VARCHAR, '')) + 48)`;

/** What a database's events take, as SIZE counts it: those `where` says. */
async function sizeOf(db, where = 'true') {
  const reader = await db.connection.runAndReadAll(`SELECT coalesce(sum(${SIZE}), 0) FROM events WHERE ${where}`);
  return Number(reader.getRows()[0][0]);
}

/** How many rows one DELETE of a prune takes, a checkpoint after each. */
const BATCH = 10000;

/**
 * Deletes the events `where` says, at most `BATCH` at a time, with a
 * checkpoint after each batch: DuckDB holds what a delete touches of the
 * table's index on `id` in memory until the next checkpoint, and a
 * database of a million events, deleted at once, takes more than a small
 * memory limit (measured: 45 MB of index after 45,000 rows, under 48 MB).
 * How many went.
 */
async function deleteBatched(c, where, params) {
  let went = 0;
  for (;;) {
    const done = await c.run(`DELETE FROM events WHERE rowid IN (SELECT rowid FROM events WHERE ${where} LIMIT ${BATCH})`, params);
    if (done.rowsChanged === 0) return went;
    went += done.rowsChanged;
    await c.run('CHECKPOINT');
  }
}

/** A time in seconds since 1970, as DuckDB compares it with "at". */
const AT = (n) => `make_timestamp($${n}::BIGINT * 1000000)`;

/**
 * The second before which a part's events go so that what is left takes
 * at most `target`: the newest kept whole. Read from sums of the part by
 * day, then by hour, minute and second within the newest one past it,
 * each a few hundred groups whatever the table holds: no sort of all of
 * it, and nothing held but the groups. Null when it all fits.
 */
async function cutoff(c, where, target) {
  let newer = 0;
  let within = null;
  for (const step of [86400, 3600, 60, 1]) {
    const range = within ? ` AND "at" >= ${AT(2)} AND "at" < ${AT(3)}` : '';
    const params = [BigInt(step), ...(within ? [BigInt(within[0]), BigInt(within[1])] : [])];
    const reader = await c.runAndReadAll(
      `SELECT floor(epoch("at"))::BIGINT // $1 AS b, sum(${SIZE})::BIGINT FROM events
       WHERE (${where})${range} GROUP BY b ORDER BY b DESC`,
      params,
    );
    const buckets = reader.getRows().map(([b, s]) => [Number(b), Number(s)]);
    let refine = null;
    for (const [b, size] of buckets) {
      if (newer + size <= target) {
        newer += size;
        continue;
      }
      // Past it in this one, whichever it is: looked at more finely, so
      // that what fits of it stays, but for a second, which goes with
      // everything before it.
      if (step > 1) {
        refine = [b * step, (b + 1) * step];
        break;
      }
      return (b + 1) * step;
    }
    if (!refine) return null;
    within = refine;
  }
  return null;
}

/**
 * Holds what a database keeps to `days` and to `bytes`: what is older
 * goes, and past its size the oldest go, until the newest that fit in
 * four fifths of it are left. `bytes` is one size for all, or a size for
 * each part of `PARTS` (`{ node, app }`), each held apart. How many went
 * for each. Each goes by a cut-off in time, in batches (`deleteBatched`):
 * DuckDB finds what is older than a time by each row group's least and
 * most "at", which it keeps for every column, and the rows are kept in
 * the order they came, so it reads little more than what goes. An index
 * of "at" of its own would be held in DuckDB's memory, as the one of `id`
 * is. The file is given back what went at each checkpoint.
 */
async function prune(db, { days = DAYS, bytes = MAIN_BUDGET, now = Date.now() / 1000 } = {}) {
  const c = db.connection;
  const before = BigInt(Math.trunc(now - days * 24 * 60 * 60));
  const old = await deleteBatched(c, `"at" < ${AT(1)}`, [before]);
  let over = 0;
  for (const [where, most] of partsOf(bytes)) {
    if ((await sizeOf(db, where)) <= most) continue;
    const cut = await cutoff(c, where, Math.floor(most * 0.8));
    if (cut !== null) over += await deleteBatched(c, `(${where}) AND "at" < ${AT(1)}`, [BigInt(cut)]);
  }
  if (old + over > 0) db.changed = true;
  return { old, over };
}

/** Each part of a budget, as `[where, most, name]`. */
function partsOf(bytes) {
  return typeof bytes === 'number' ? [['true', bytes, 'all']] : Object.entries(bytes).map(([part, most]) => [PARTS[part], most, part]);
}

/** Which part of a budget an event is in. */
function partOf(bytes, event) {
  if (typeof bytes === 'number') return 'all';
  return /^app\./.test(String(event.type)) ? 'app' : 'node';
}

/** The latest moment kept, 9999-12-31, in seconds since 1970. */
const LATEST = 253402300799;
/** The most of an event's payload kept, as JSON. */
const PAYLOAD_BYTES = 1024 * 1024;

/**
 * Why an event cannot be kept, or null. What the node tells of is always
 * kept; this is for what no write could keep, which would fail as often
 * as it was tried.
 */
function unstorable(event) {
  if (!event || typeof event !== 'object') return 'it is not an event';
  const text = (v, most) => typeof v === 'string' && v.length > 0 && v.length <= most;
  if (!text(event.id, 200)) return 'its id is not 1 to 200 characters';
  if (!text(event.type, 200)) return 'its type is not 1 to 200 characters';
  if (!text(event.subject, 1000)) return 'its subject is not 1 to 1000 characters';
  if (!Number.isFinite(event.at) || event.at < 0 || event.at > LATEST) return 'its time is not one between 1970 and 9999';
  // DuckDB takes no JSON with a lone surrogate in it, nor should a text
  // column hold one. Neither the node nor an app's database writes one;
  // were one told of, it would fail every try.
  const unwell = 'its text is not well-formed Unicode (a lone surrogate)';
  if (![event.id, event.type, event.subject].every((t) => t.isWellFormed())) return unwell;
  let payload;
  try {
    payload = JSON.stringify(event.payload ?? null, (key, value) => {
      if (!key.isWellFormed() || (typeof value === 'string' && !value.isWellFormed())) throw new SyntaxError(unwell);
      return value;
    });
  } catch (error) {
    return error instanceof SyntaxError && error.message === unwell ? unwell : 'its payload is not JSON';
  }
  if (payload.length > PAYLOAD_BYTES) return `its payload is more than ${PAYLOAD_BYTES} bytes`;
  return null;
}

/** Free bytes on the volume `db` is on, or Infinity if that cannot be told. */
function freeBytes(db) {
  try {
    const { bavail, bsize } = fs.statfsSync(require('node:path').dirname(db.file));
    return bavail * bsize;
  } catch {
    return Infinity;
  }
}

/** Below this, a failed write is taken to be for want of room. */
const FREE_FLOOR = 16 * 1024 * 1024;

/**
 * Whether a write failed for want of room: an error of writing (DuckDB's
 * type `IO Error`, read from the start of its message, the binding giving
 * no other) that says the disk is full, or any error of writing while the
 * volume has less than `FREE_FLOOR` free. Nothing else makes room.
 */
function outOfRoom(error, free) {
  const said = String(error && error.message);
  if (!/^IO Error: /.test(said)) return false;
  return /No space left on device|disk is full|out of disk space/i.test(said) || free < FREE_FLOOR;
}

/**
 * Runs `work` on `db`'s one connection when what was asked of it before is
 * done. DuckDB's connection runs one thing at a time: two at once, a keep
 * and a prune, can bring its process down (measured: 500 keeps at once on
 * one connection stopped it with SIGSEGV).
 */
function turn(db, work) {
  const run = (db.turn || Promise.resolve()).then(work, work);
  db.turn = run.catch(() => {});
  return run;
}

/**
 * The newest `limit` events of `db` of one organization, oldest first, as
 * `keep` takes them: what an organization given a place is filled from.
 */
function eventsOf(db, org, limit) {
  return turn(db, async () => {
    const reader = await db.connection.runAndReadAll(
      `SELECT id, cursor, type, subject, epoch("at")::BIGINT, actor_role, actor_name, payload::VARCHAR FROM events
       WHERE json_extract_string(payload, '$.organization') = $1 ORDER BY cursor DESC LIMIT ${Math.trunc(limit)}`,
      [String(org)],
    );
    return reader
      .getRows()
      .reverse()
      .map(([id, cursor, type, subject, at, role, name, payload]) => ({
        id,
        cursor: String(cursor),
        type,
        subject,
        at: Number(at),
        actor: { role, name },
        payload: JSON.parse(payload),
      }));
  });
}

/** What the events of each part of a budget are said to be, by name. */
const PART_SAID = { all: 'events', node: "the node's events", app: "apps' events" };

/**
 * `prune`, in its turn on the database's connection. One that fails is
 * thrown, and each part then past its size is marked (`db.stuck`), so
 * that nothing more is kept in it until a prune succeeds: the size bound
 * never stops working unseen while the volume fills.
 */
function pruned(db, options = {}) {
  return turn(db, async () => {
    try {
      const went = await prune(db, options);
      db.stuck = null;
      db.pruneFailed = null;
      return went;
    } catch (error) {
      const why = String(error && error.message ? error.message : error).split('\n')[0];
      db.pruneFailed = { why, at: Date.now() };
      const stuck = {};
      for (const [where, most, part] of partsOf(options.bytes ?? MAIN_BUDGET)) {
        let size = Infinity;
        try {
          size = await sizeOf(db, where);
        } catch {
          // Not told: taken to be past it.
        }
        if (size > most) stuck[part] = why;
      }
      db.stuck = stuck;
      throw error;
    }
  });
}

/** How long after a prune failed one is tried again, as an event waits. */
const PRUNE_AGAIN_MS = 60000;

/**
 * Why `event` is not kept in `db` now, or null: the part it is in is past
 * its size, and could not be made smaller. Tried again, once a minute at
 * most, as events are refused.
 */
async function stuckFor(db, event, options) {
  const part = partOf(options.bytes ?? MAIN_BUDGET, event);
  if (!db.stuck || !db.stuck[part]) return null;
  if (Date.now() - db.pruneFailed.at >= PRUNE_AGAIN_MS) {
    await pruned(db, options).catch(() => {});
    if (!db.stuck || !db.stuck[part]) return null;
  }
  const name = require('node:path').basename(db.file, '.duckdb');
  return `${name} holds more of ${PART_SAID[part]} than it may, and could not be made smaller (${db.stuck[part]}): nothing more of them is kept in it until it can be`;
}

/**
 * Keeps an event, as `keep`, or says why it cannot be kept. Only a write
 * that failed for want of room makes room, and only in this database, by
 * its rule (`prune` to `bytes`); then it is tried once more. Anything
 * else is thrown, and the delivery is tried again later.
 */
async function keepChecked(db, event, options = {}) {
  const why = unstorable(event);
  if (why) return { kept: false, refused: `not kept: ${why}` };
  // After what was asked of it before, a prune among it: whether it is
  // past its size is known only then.
  await (db.turn || Promise.resolve());
  const stuck = await stuckFor(db, event, options);
  if (stuck) throw new Error(stuck);
  return turn(db, () => keepNow(db, event, options));
}

async function keepNow(db, event, { bytes = MAIN_BUDGET, waitMs, free = freeBytes } = {}) {
  try {
    return { kept: await keep(db, event, { waitMs }) };
  } catch (error) {
    if (!outOfRoom(error, free(db))) throw error;
    const went = await prune(db, { bytes });
    if (went.old + went.over === 0) throw error;
    return { kept: await keep(db, event, { waitMs }) };
  }
}

/** The column types whose values come back as strings but are numbers. */
const WHOLE = new Set([DuckDBTypeId.BIGINT, DuckDBTypeId.UBIGINT, DuckDBTypeId.HUGEINT, DuckDBTypeId.UHUGEINT]);

/**
 * The column types whose values are of a width of their own, small and
 * fixed: answered as they are. Every other type (text, blob, bit string,
 * list, array, struct, map, union, enum and any DuckDB adds) is cut.
 */
const FIXED = new Set(
  [
    'BOOLEAN', 'TINYINT', 'SMALLINT', 'INTEGER', 'BIGINT', 'UTINYINT', 'USMALLINT', 'UINTEGER', 'UBIGINT',
    'HUGEINT', 'UHUGEINT', 'FLOAT', 'DOUBLE', 'DECIMAL', 'DATE', 'TIME', 'TIME_TZ', 'TIMESTAMP',
    'TIMESTAMP_S', 'TIMESTAMP_MS', 'TIMESTAMP_NS', 'TIMESTAMP_TZ', 'INTERVAL', 'UUID', 'SQLNULL',
  ]
    .map((name) => DuckDBTypeId[name])
    .filter((id) => id !== undefined),
);
/** What one fixed value may take, at most, as it is answered. */
const FIXED_BYTES = 64;

/** A whole number said as a string: a number when it is exactly one. */
function whole(value) {
  if (typeof value !== 'string') return value;
  const n = Number(value);
  return Number.isSafeInteger(n) ? n : value;
}

/**
 * The text of `bytes`, cut to at most `most` bytes, never within a
 * character. Whether it was cut.
 */
function cutText(bytes, most) {
  const buffer = Buffer.from(bytes);
  if (buffer.length <= most) return { text: buffer.toString('utf8'), cut: false };
  let end = most;
  // Back to the start of the character the cut falls in.
  while (end > 0 && (buffer[end] & 0xc0) === 0x80) end -= 1;
  return { text: buffer.subarray(0, end).toString('utf8'), cut: true };
}

/**
 * Answers `sql`, one statement that reads, as columns and rows of JSON:
 * at most `rows` rows, `bytes` in all and `valueBytes` of any one value,
 * for at most `ms`. What is past those is left out, and the answer says
 * `cut`. Throws a `Refused` for anything else, for what DuckDB refused,
 * and for a query stopped for taking too long.
 * @param {{ instance: import('@duckdb/node-api').DuckDBInstance }} db
 * @param {string} sql
 * @param {{ rows?: number, ms?: number, bytes?: number, valueBytes?: number }} [limits]
 */
async function answer(db, sql, limits = {}) {
  const most = limits.rows ?? ROWS;
  const ms = limits.ms ?? MS;
  const bytes = limits.bytes ?? BYTES;
  const valueBytes = limits.valueBytes ?? VALUE_BYTES;
  if (typeof sql !== 'string' || !sql.trim().replace(/;/g, '').trim()) throw new Refused(ONLY_READS);
  const connection = await db.instance.connect();
  const deadline = Date.now() + ms;
  let stopped = false;
  const stop = () => {
    stopped = true;
    connection.interrupt();
  };
  const timer = setTimeout(stop, ms);
  try {
    let extracted;
    try {
      extracted = await connection.extractStatements(sql);
    } catch {
      // What DuckDB cannot read as statements is not one that reads.
      throw new Refused(ONLY_READS);
    }
    if (extracted.count !== 1) throw new Refused(ONLY_READS);
    // What it calls, as DuckDB parses it, before anything of it is bound:
    // binding a function that reads a file reads it.
    await checks.calls(connection, sql);
    // Preparing it runs nothing; what it names that it may not reach is
    // refused here, by DuckDB, as is what is not there.
    const asked = await extracted.prepare(0);
    if (asked.statementType !== StatementType.SELECT) throw new Refused(ONLY_READS);
    const columns = Array.from({ length: asked.columnCount }, (_, i) => asked.columnName(i));
    if (columns.length > COLUMNS) {
      throw new Refused(`at most ${COLUMNS} columns are answered; this query has ${columns.length}`);
    }
    // Asked again within one that makes each value that is not of a fixed
    // width the bytes of its text, cut one byte
    // past the most, as DuckDB makes it; and stops at the rows the
    // answer's size could hold of so many columns that wide: DuckDB may
    // make all of an answer before the first of it is read.
    const capped = Array.from({ length: asked.columnCount }, (_, i) => !FIXED.has(asked.columnTypeId(i)));
    const within = Array.from({ length: asked.columnCount }, (_, i) => {
      const at = `#${i + 1}`;
      if (!capped[i]) return `${at} AS "c${i}"`;
      // A nested value's text is DuckDB's: its JSON would be made whole
      // first, and DuckDB counts that against its memory.
      const text = `CAST(${at} AS VARCHAR)`;
      // Cut to so many characters first, so no more is copied than that,
      // then to the bytes.
      return `CASE WHEN ${at} IS NULL THEN NULL ELSE encode(left(${text}, ${valueBytes + 1}))[1:${valueBytes + 1}] END AS "c${i}"`;
    });
    asked.destroySync();
    const wide = capped.reduce((sum, c) => sum + (c ? valueBytes + 1 : FIXED_BYTES), 0);
    const fits = Math.max(1, Math.floor(bytes / Math.max(1, wide)));
    const limit = Math.min(most, fits);
    const inner = sql.replace(/[\s;]+$/, '');
    const around = `SELECT ${within.join(', ')} FROM (\n${inner}\n) AS answered LIMIT ${limit + 1}`;
    // Checked again as it is asked: what it is part of could be read
    // otherwise than it was alone.
    await checks.calls(connection, around);
    const wrapped = await connection.extractStatements(around);
    if (wrapped.count !== 1) throw new Refused(ONLY_READS);
    const statement = await wrapped.prepare(0);
    if (statement.statementType !== StatementType.SELECT) throw new Refused(ONLY_READS);
    // Whatever it does, nothing of it stays.
    await connection.run('BEGIN TRANSACTION');
    try {
      const result = await statement.stream();
      const types = result.columnTypes().map((type) => WHOLE.has(type.typeId));
      const rows = [];
      // As JSON: the answer around its rows, each row's brackets and comma,
      // and each value's own and its comma.
      let size = Buffer.byteLength(JSON.stringify({ columns, rows: [], cut: true }));
      let cut = false;
      let full = false;
      while (!full) {
        const chunk = await result.fetchChunk();
        if (!chunk || chunk.rowCount === 0) break;
        for (let n = 0; n < chunk.rowCount; n += 1) {
          // What it turns into JSON counts against its time too.
          if (Date.now() > deadline) stop();
          if (stopped) throw new Refused('stopped');
          if (rows.length === limit || size >= bytes) {
            cut = true;
            full = true;
            break;
          }
          const raw = chunk.getRowValues(n);
          const converted = chunk.convertRowValues(n, JsonDuckDBValueConverter);
          size += 3;
          const row = converted.map((value, i) => {
            let kept = types[i] ? whole(value) : value;
            if (capped[i] && raw[i] !== null && raw[i] !== undefined) {
              const said = cutText(raw[i].bytes, valueBytes);
              if (said.cut) cut = true;
              kept = said.text;
            }
            size += Buffer.byteLength(JSON.stringify(kept) ?? 'null') + 1;
            return kept;
          });
          if (size > bytes) {
            cut = true;
            full = true;
            break;
          }
          rows.push(row);
        }
      }
      result.closeSync();
      return cut ? { columns, rows, cut } : { columns, rows };
    } finally {
      await connection.run('ROLLBACK').catch(() => {});
    }
  } catch (error) {
    if (stopped) throw new Refused(`the query took more than ${ms / 1000} seconds and was stopped`);
    if (error instanceof Refused && error.message === ONLY_READS && /\bPIVOT\b/i.test(sql)) throw new Refused(PIVOT_NAMED);
    if (error instanceof Refused) throw error;
    throw new Refused(String(error && error.message ? error.message : error));
  } finally {
    clearTimeout(timer);
    connection.closeSync();
  }
}

/** How much of a file is copied at a time. */
const CHUNK = 1024 * 1024;

/**
 * Copies `db` to `to` for its readers: after a checkpoint, in its turn on
 * the database's connection, so that its file holds all it keeps and
 * nothing is written to it while it is copied; to `<to>.tmp-<pid>` first,
 * then renamed to `to`, so that a reader opens the copy before or the copy
 * after, never one half made. One not changed since it was last copied is
 * left as it is (`'same'`). `room(bytes)` says whether the volume has room
 * for a copy of so many bytes; without it, nothing is copied (`'no-room'`).
 * Else `'made'`. `pause(copied)`, for a test, is waited for after each
 * part copied, of `chunk` bytes.
 */
function snapshot(db, to, { room = () => true, pause = null, chunk = CHUNK } = {}) {
  return turn(db, async () => {
    if (!db.changed && fs.existsSync(to)) return 'same';
    await db.connection.run('CHECKPOINT');
    let wal = 0;
    try {
      wal = fs.statSync(`${db.file}.wal`).size;
    } catch {
      // None: all it keeps is in its file.
    }
    if (wal > 0) throw new Error(`${db.file} was not all in its file after a checkpoint, and was not copied`);
    const size = fs.statSync(db.file).size;
    if (!room(size)) return 'no-room';
    const path = require('node:path');
    fs.mkdirSync(path.dirname(to), { recursive: true });
    const part = `${to}.tmp-${process.pid}`;
    const from = fs.openSync(db.file, 'r');
    const into = fs.openSync(part, 'w', 0o600);
    try {
      const buffer = Buffer.alloc(chunk);
      for (let at = 0; ; ) {
        const read = fs.readSync(from, buffer, 0, chunk, at);
        if (read === 0) break;
        fs.writeSync(into, buffer, 0, read);
        at += read;
        if (pause) await pause(at);
      }
      fs.fsyncSync(into);
    } finally {
      fs.closeSync(from);
      fs.closeSync(into);
    }
    fs.renameSync(part, to);
    db.changed = false;
    return 'made';
  });
}

module.exports = { checks, open, openReading, snapshot, freeBytes, FREE_FLOOR, openKept, damage, outOfRoom, CannotOpen, keep, keepChecked, eventsOf, unstorable, answer, prune, pruned, sizeOf, Refused, DAYS, MAIN_BYTES, MAIN_BUDGET, APP_BYTES, ONLY_READS, ROWS, MS, BYTES, VALUE_BYTES, COLUMNS };
