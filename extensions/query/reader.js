'use strict';
// A reader: a process of its own that answers one query at a time from a
// copy of a database (`snapshot` in store.js), opened so that it only
// reads, locked as every database is. It keeps nothing. A query that runs
// past its time, however it does, is stopped by the service killing this
// process, which costs that query alone: the events are kept elsewhere,
// by the databases' process, which no query reaches.

const fs = require('node:fs');
const { open, openReading, answer } = require('./store.js');

/** What this reader is given: the memory each query's database has. */
const { memory } = JSON.parse(process.argv[2] || '{}');

try {
  // The first the kernel stops when the service is out of memory: a
  // reader, never the databases' process or the service.
  fs.writeFileSync('/proc/self/oom_score_adj', '1000');
} catch {
  // Not Linux, or not allowed.
}

process.on('message', async ({ id, file, sql, limits }) => {
  let db = null;
  try {
    // An organization with nothing kept yet reads an empty table.
    db = file ? await openReading(file, { memory }) : await open(':memory:', { memory });
    process.send({ id, value: await answer(db, sql, limits) });
  } catch (error) {
    process.send({ id, error: String(error && error.message ? error.message : error), refused: Boolean(error && error.refused) });
  } finally {
    if (db) {
      if (db.insert) db.insert.destroySync();
      if (db.connection) db.connection.closeSync();
      db.instance.closeSync();
    }
  }
});
process.send({ ready: true });
