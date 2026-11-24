'use strict';
// The readers, from the service's side: at most so many processes, each
// answering one query at a time from a copy of a database. One whose query
// runs past its time is killed (SIGKILL) and another started when one is
// next needed: whatever the query called, it goes on no longer, and
// nothing but that query is lost.

const { fork } = require('node:child_process');
const path = require('node:path');
const { Refused, MS } = require('./store.js');

/** What a query is told when its reader stopped under it, not by the service. */
const OUT_OF_MEMORY = 'the query needed more memory than the service has, and was stopped';
/** How long past its own time a query is let run before its reader is killed. */
const GRACE_MS = 2000;
/** What each query's database has of memory in a reader (README). */
const READER_MEMORY = '64MB';

/**
 * At most `most` readers. `answer(file, sql, limits)` answers `sql` from
 * the database copied to `file` (an empty table where `file` is null), as
 * `answer` of store.js does: past `limits.ms` and `graceMs` more, its
 * reader is killed and it is refused as a query that took too long.
 */
function readers({ most, script = path.join(__dirname, 'reader.js'), memory = READER_MEMORY, graceMs = GRACE_MS }) {
  /** Readers waiting for a query. */
  const idle = [];
  /** Every reader running, busy or not. */
  const all = new Set();
  let next = 0;
  let closing = false;

  const started = () =>
    new Promise((resolve, reject) => {
      const child = fork(script, [JSON.stringify({ memory })], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
      const reader = { child, asked: null };
      all.add(reader);
      child.on('message', (message) => {
        if (message.ready) {
          resolve(reader);
          return;
        }
        const asked = reader.asked;
        if (!asked || message.id !== asked.id) return;
        reader.asked = null;
        clearTimeout(asked.timer);
        if ('error' in message) asked.reject(message.refused ? new Refused(message.error) : new Error(message.error));
        else asked.resolve(message.value);
        // Free for the next.
        if (!closing) idle.push(reader);
      });
      child.on('exit', (code, signal) => {
        all.delete(reader);
        const at = idle.indexOf(reader);
        if (at >= 0) idle.splice(at, 1);
        reject(new Error(`a reader did not start (${signal || code})`));
        const asked = reader.asked;
        if (!asked) return;
        reader.asked = null;
        clearTimeout(asked.timer);
        asked.reject(asked.late ? new Refused(`the query took more than ${asked.ms / 1000} seconds and was stopped`) : new Refused(OUT_OF_MEMORY));
      });
    });

  const take = async () => {
    if (closing) throw new Error('the service is stopping');
    if (idle.length) return idle.pop();
    if (all.size >= most) throw new Refused(`${most} queries are running; ask again soon`);
    return started();
  };

  return {
    async answer(file, sql, limits = {}) {
      const reader = await take();
      const ms = limits.ms ?? MS;
      const id = (next += 1);
      return new Promise((resolve, reject) => {
        const asked = { id, ms, resolve, reject, late: false, timer: null };
        // Its own time, then a little more for it to stop of itself; then
        // it is stopped from outside, whatever it is doing.
        asked.timer = setTimeout(() => {
          asked.late = true;
          reader.child.kill('SIGKILL');
        }, ms + graceMs);
        asked.timer.unref();
        reader.asked = asked;
        reader.child.send({ id, file, sql, limits }, (error) => {
          if (!error || reader.asked !== asked) return;
          reader.asked = null;
          clearTimeout(asked.timer);
          reader.child.kill('SIGKILL');
          reject(error);
        });
      });
    },
    /** The process id of each reader running. */
    pids: () => [...all].map((r) => r.child.pid),
    async close() {
      closing = true;
      await Promise.all(
        [...all].map(
          (r) =>
            new Promise((resolve) => {
              if (r.child.exitCode !== null || r.child.signalCode !== null) return resolve();
              r.child.once('exit', resolve);
              r.child.kill('SIGKILL');
            }),
        ),
      );
    },
  };
}

module.exports = { readers, OUT_OF_MEMORY, GRACE_MS, READER_MEMORY };
