'use strict';
// Each bound app's events, kept apart by organization: one database for
// each (app, organization), `/data/apps/<app>/<organization>.duckdb`, of
// that organization's events alone. A token for one organization is
// answered from its database and nothing else.
//
// They are opened as they are needed, and at most `open` at once, each
// with a small memory: an app with many organizations does not take the
// service's memory. An app has at most `most` of them, so an app that
// writes events of organizations without end cannot fill the volume with
// databases. The places go by recent use: an organization whose database
// has had nothing written to it for `IDLE_DAYS` gives its place up to one
// that needs it. An event of an organization with no place is kept in the
// app's own database alone, which only the service's key reads.

const fs = require('node:fs');
const path = require('node:path');
const { ORG } = require('./who.js');

/**
 * How many organizations' databases one app may have. 64 of at most 4 MiB
 * each is 256 MiB of the volume, what 16 of 16 MiB took before.
 */
const ORGS_MAX = 64;
/** How long an organization writes nothing before it gives its place up. */
const IDLE_DAYS = 7;
/** How many are open at once. */
const OPEN_MAX = 4;
/** How much each holds, as `prune` counts it, and DuckDB's memory for each. */
const ORG_BYTES = 4 * 1024 * 1024;
const ORG_MEMORY = '24MB';

/**
 * The organizations' databases under `dir/apps`, opened with `opened`
 * (`file, options` to a database). `use(app, org, make, work)` runs
 * `work(db)` on that organization's database, made first if `make`; it
 * gives `{ none: true }` where there is none, `{ full: true }` where there
 * is none and the app has its most, none of which has been idle for
 * `IDLE_DAYS`, and else `{ value }`. `work` is given, second, whether the
 * database was made for it just now.
 */
function shelf({ dir, opened, most = ORGS_MAX, open = OPEN_MAX }) {
  /** Each database open, by its file: `{ db, users, used }`. */
  const held = new Map();
  /** Each being opened, by its file. */
  const opening = new Map();
  /** Each being closed, by its file: not opened again until it is. */
  const closing = new Map();
  let clock = 0;

  const folder = (app) => path.join(dir, 'apps', app);
  const fileOf = (app, org) => path.join(folder(app), `${org}.duckdb`);
  /** The organizations an app has a database of. */
  const orgs = (app) => {
    try {
      return fs
        .readdirSync(folder(app))
        .map((name) => /^(.*)\.duckdb$/.exec(name))
        .filter((m) => m && ORG.test(m[1]))
        .map((m) => m[1]);
    } catch {
      return [];
    }
  };

  const close = (file) => {
    const one = held.get(file);
    if (!one) return closing.get(file) || Promise.resolve();
    held.delete(file);
    const done = (async () => {
      // What was asked of it is done first.
      await (one.db.turn || Promise.resolve());
      one.db.insert.destroySync();
      one.db.connection.closeSync();
      one.db.instance.closeSync();
    })().finally(() => closing.delete(file));
    closing.set(file, done);
    return done;
  };

  /** Closes the least lately used that nobody is using, past `open`. */
  const trim = async () => {
    while (held.size > open) {
      const idle = [...held].filter(([, one]) => one.users === 0).sort((a, b) => a[1].used - b[1].used);
      if (idle.length === 0) return;
      await close(idle[0][0]);
    }
  };

  const take = async (file) => {
    if (held.has(file)) return held.get(file);
    if (!opening.has(file)) {
      opening.set(
        file,
        (async () => {
          try {
            await (closing.get(file) || Promise.resolve());
            const db = await opened(file, { memory: ORG_MEMORY });
            const one = { db, users: 0, used: 0 };
            held.set(file, one);
            return one;
          } finally {
            opening.delete(file);
          }
        })(),
      );
    }
    return opening.get(file);
  };

  /** When an organization's database was last written to, in ms. */
  const writtenAt = (app, org) => {
    const file = fileOf(app, org);
    let at = 0;
    for (const f of [file, `${file}.wal`]) {
      try {
        at = Math.max(at, fs.statSync(f).mtimeMs);
      } catch {
        // Not there.
      }
    }
    return at;
  };

  /** Gives the place of the app's organization idle longest up, if one has been idle long enough. */
  const giveUp = async (app) => {
    const idle = Date.now() - IDLE_DAYS * 86400 * 1000;
    const oldest = orgs(app)
      .map((org) => [org, writtenAt(app, org)])
      .filter(([org, at]) => at < idle && !((held.get(fileOf(app, org)) || {}).users > 0))
      .sort((a, b) => a[1] - b[1])[0];
    if (!oldest) return false;
    return api.remove(app, oldest[0]);
  };

  const api = {
    orgs,
    full: (app) => orgs(app).length >= most,
    async use(app, org, make, work) {
      if (!ORG.test(String(org))) return { none: true };
      const file = fileOf(app, org);
      let made = false;
      if (!held.has(file) && !opening.has(file) && !fs.existsSync(file)) {
        if (!make) return orgs(app).length >= most ? { full: true } : { none: true };
        if (orgs(app).length >= most && !(await giveUp(app))) return { full: true };
        fs.mkdirSync(folder(app), { recursive: true });
        made = true;
      }
      // Counted as used before anything else runs, so nothing closes it
      // under its work.
      let one = held.get(file);
      while (!one) {
        await take(file);
        one = held.get(file);
      }
      one.users += 1;
      one.used = (clock += 1);
      try {
        return { value: await work(one.db, made) };
      } finally {
        one.users -= 1;
        await trim();
      }
    },
    /** Removes an organization's database, once nobody is using it. */
    async remove(app, org) {
      const file = fileOf(app, org);
      const one = held.get(file);
      if (one && one.users > 0) return false;
      await close(file);
      for (const f of [file, `${file}.wal`]) fs.rmSync(f, { force: true });
      return true;
    },
    async closeAll() {
      for (const file of [...held.keys()]) await close(file);
    },
  };
  return api;
}

/**
 * Whether an app's event is for every member of its organization: its
 * audience, as the node told of it from the event's row, is absent or
 * null. One for some users or roles only, or with an audience this does
 * not understand, is not: a token for one organization never shows it.
 */
function forEveryMember(event) {
  const told = event && event.payload;
  return Boolean(told) && (told.audience === undefined || told.audience === null);
}

module.exports = { shelf, forEveryMember, ORGS_MAX, IDLE_DAYS, OPEN_MAX, ORG_BYTES, ORG_MEMORY };
