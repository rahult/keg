'use strict';
// The databases, in a process of their own, which keeps what the service is
// told of and answers no query. For its readers (reader.js) it copies a
// database as it is asked to (`snapshot`): a reader opens the copy, so
// that nothing a query does reaches this process, and a reader killed for
// running past its time costs nothing here.

const path = require('node:path');
const fs = require('node:fs');
const { openKept, keepChecked, eventsOf, pruned, sizeOf, snapshot, freeBytes, Refused, MAIN_BUDGET, APP_BYTES } = require('./store.js');
const { shelf, forEveryMember, ORGS_MAX, IDLE_DAYS, ORG_BYTES } = require('./shelf.js');

/** The most events an organization given a place is filled with from its app's database. */
const REFILL_MAX = 20000;

/** How often what is kept is held to its days and its size. */
const PRUNE_MS = 10 * 60 * 1000;

/**
 * How often, at most, a database that changes is copied again for its
 * readers: a query may be answered from what was kept so long ago.
 */
const SNAPSHOT_MS = 2000;
/** How long a copy nobody asked for is kept. */
const SNAPSHOT_IDLE_MS = 10 * 60 * 1000;
/** What a copy leaves free on the volume, at the least, for what is kept. */
const SNAPSHOT_FLOOR = 64 * 1024 * 1024;

/** What this process is given: its folder, and the apps bound. */
const { dir, apps, budgets, orgsMax, snapshotMs = SNAPSHOT_MS, snapshotPause = null } = JSON.parse(process.argv[2]);
/** The sizes of the main database's parts: its own, or a test's. */
const MAIN = budgets || MAIN_BUDGET;

try {
  // Stopped by the kernel, when the service is out of memory, after its
  // readers (1000) and before the service.
  fs.writeFileSync('/proc/self/oom_score_adj', '500');
} catch {
  // Not Linux, or not allowed.
}

async function main() {
  fs.mkdirSync(path.join(dir, 'apps'), { recursive: true });
  // The copies for readers are made anew as they are asked for: any from
  // before, one half made among them, go.
  const copies = path.join(dir, 'snapshots');
  fs.rmSync(copies, { recursive: true, force: true });
  /** What a person should know: a database that was damaged, and set aside. */
  const notices = [];
  const opened = async (file, options) => {
    const { db, setAside } = await openKept(file, options);
    if (setAside) {
      const said = `${file} could not be opened, and was moved to ${setAside}; it was begun again, empty`;
      console.error(`query: ${said}`);
      notices.push(said);
    }
    return db;
  };
  const everything = await opened(path.join(dir, 'events.duckdb'));
  /** Each bound app's own database, by its name. */
  const theirs = new Map();
  for (const app of apps) theirs.set(app, await opened(path.join(dir, 'apps', `${app}.duckdb`), { memory: '48MB' }));
  /** Each app's events, by organization, opened as they are needed. */
  const most = orgsMax || ORGS_MAX;
  const orgs = shelf({ dir, opened, most });
  /** Apps said to have more organizations than are kept apart. */
  const full = new Set();
  const say = (said) => {
    console.error(`query: ${said}`);
    notices.push(said);
    if (ready) process.send({ notice: said });
  };
  /**
   * Each database held to its days and its size. One that cannot be is
   * said, on the page and in the log, and the rest are held still; past
   * its size, nothing more is kept in it until it can be (`keepChecked`).
   */
  const failing = new Map();
  let ready = false;
  const holdOne = async (name, db, bytes) => {
    try {
      const went = await pruned(db, { bytes });
      failing.delete(name);
      if (went.old || went.over) console.error(`query: ${name}: ${went.old} older than kept and ${went.over} past its size went`);
    } catch (error) {
      const said = `${name}: what it keeps could not be held to its days and size: ${String(error && error.message).split('\n')[0]}`;
      if (!failing.has(name)) say(said);
      else console.error(`query: ${said}`);
      failing.set(name, said);
    }
  };
  const pruneAll = async () => {
    for (const [name, db, bytes] of [['events', everything, MAIN], ...[...theirs].map(([app, db]) => [app, db, APP_BYTES])]) {
      await holdOne(name, db, bytes);
    }
    // Each organization's, one at a time; one left empty goes, and its
    // place with it.
    for (const app of theirs.keys()) {
      for (const org of orgs.orgs(app)) {
        const left = await orgs
          .use(app, org, false, async (db) => {
            await holdOne(`${app}/${org}`, db, ORG_BYTES);
            return sizeOf(db);
          })
          .catch((error) => {
            say(`${app}/${org}: could not be opened: ${String(error && error.message).split('\n')[0]}`);
            return { value: 1 };
          });
        if (left.value === 0) await orgs.remove(app, org);
      }
    }
  };
  /** Each copy made for readers, by its file: when it was made, and last asked for. */
  const made = new Map();
  let copiesMade = 0;
  /** Copies nobody asked for lately go. */
  const tidy = () => {
    for (const [to, one] of made) {
      if (Date.now() - one.asked < SNAPSHOT_IDLE_MS) continue;
      made.delete(to);
      fs.rmSync(to, { force: true });
    }
  };
  /**
   * A copy of `db` at `to` to read, `{ file, asOf }`, `asOf` the time
   * (ms) what was kept then is all of what it holds: copied again when it
   * changed, at most every `snapshotMs`; meanwhile, the one before.
   */
  const copyOf = async (db, to) => {
    const had = made.get(to);
    const there = had !== undefined && fs.existsSync(to);
    if (there) had.asked = Date.now();
    if (there && db.changed && Date.now() - had.at < snapshotMs) return { file: to, asOf: had.at };
    const at = Date.now();
    copiesMade += 1;
    const pause = snapshotPause && copiesMade >= snapshotPause.from ? () => new Promise((resolve) => setTimeout(resolve, snapshotPause.ms)) : null;
    const done = await snapshot(db, to, { room: (bytes) => freeBytes(db) - bytes >= SNAPSHOT_FLOOR, pause, chunk: pause ? snapshotPause.chunk : undefined });
    if (done === 'no-room') {
      if (there) return { file: to, asOf: had.at };
      throw new Refused('the volume has no room for a copy of these events to read them from, beside what is kept; ask again once it has');
    }
    if (done === 'made' || !there) made.set(to, { at, asked: at });
    // Unchanged: what it holds is all that is kept now.
    else had.at = at;
    return { file: to, asOf: at };
  };
  setInterval(() => {
    tidy();
    pruneAll().catch((error) => console.error(`query: could not hold what is kept: ${error.message}`));
  }, PRUNE_MS).unref();
  const does = {
    // What cannot be kept is said so, and its delivery finished: it would
    // fail as often as it was tried. Only want of room makes room, in the
    // database that wanted it, by its rule; anything else is thrown, and
    // the delivery is tried again later.
    async keep({ event }) {
      const said = await keepChecked(everything, event, { bytes: MAIN });
      if (said.refused) return said;
      const of = /^app\.([a-z][a-z0-9-]*)\./.exec(String(event.type));
      const app = of && theirs.get(of[1]);
      if (!app) return said;
      await keepChecked(app, event, { bytes: APP_BYTES });
      // And in its organization's, by the organization the node told of,
      // which is the app's row's, never what the app wrote. One with none
      // is in the app's own database alone, and so is one for some of the
      // organization's users or roles only: what a token for one
      // organization reads is what every member of it may read.
      const org = event.payload && event.payload.organization;
      if (!forEveryMember(event)) return said;
      const put = await orgs.use(of[1], org, true, async (db, made) => {
        // Given a place just now: what the app's own database still has of
        // it comes first, the newest that fit, and of them, as of any
        // event, only those for every member of it.
        if (made) {
          for (const before of await eventsOf(app, org, REFILL_MAX)) {
            if (forEveryMember(before)) await keepChecked(db, before, { bytes: ORG_BYTES });
          }
        }
        return keepChecked(db, event, { bytes: ORG_BYTES });
      });
      if (put.full && !full.has(of[1])) {
        full.add(of[1]);
        say(
          `${of[1]} has events of more than ${most} organizations that wrote in the last ${IDLE_DAYS} days, the most kept apart: the others' are kept in ${of[1]}'s own database alone, which only the query key reads, and a token for one of them reads nothing until one of the ${most} has written nothing for ${IDLE_DAYS} days and gives its place up`,
        );
      }
      return said;
    },
    // A copy to read: of all it holds (no app), of an app's own database
    // (no organization), or of one organization's.
    async snapshot({ app, org }) {
      const db = app ? theirs.get(app) : everything;
      if (!db) throw new Refused('not bound to that app');
      if (!app) return copyOf(db, path.join(copies, 'events.duckdb'));
      if (!org) return copyOf(db, path.join(copies, 'apps', `${app}.duckdb`));
      const to = path.join(copies, 'apps', app, `${org}.duckdb`);
      const got = await orgs.use(app, org, false, (one) => copyOf(one, to));
      // One with no place now has no copy either: what was copied of it
      // before is never read.
      if (got.none || got.full) {
        made.delete(to);
        fs.rmSync(to, { force: true });
      }
      if (got.full) {
        throw Object.assign(
          new Error(`${app} keeps ${most} organizations apart, the most it does, and this one is not among them now: its events are kept with every organization's, where only the query key reads them, and it is given a place once one of the ${most} has written nothing for ${IDLE_DAYS} days`),
          { refused: true },
        );
      }
      // One with nothing kept yet reads an empty table.
      return got.none ? { file: null, asOf: Date.now() } : got.value;
    },
  };
  process.on('message', async ({ id, op, ...asked }) => {
    try {
      process.send({ id, value: await does[op](asked) });
    } catch (error) {
      process.send({ id, error: String(error && error.message ? error.message : error), refused: Boolean(error && error.refused) });
    }
  });
  ready = true;
  process.send({ ready: true, notices });
  // Held to their days and sizes once ready, so that a long prune never
  // holds up the start: what is kept meanwhile waits its turn on each
  // database's connection, after the prune (`keepChecked`).
  pruneAll().catch((error) => console.error(`query: could not hold what is kept: ${error.message}`));
}

main().catch((error) => {
  console.error(`query: the databases could not be opened: ${error.message}`);
  // One that cannot be opened but for damage stops the service: started
  // again, it would fail the same way.
  if (error && error.fatal && process.send) process.send({ fatal: error.message }, () => process.exit(2));
  else process.exit(1);
});
