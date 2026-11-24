'use strict';
// The databases' process, from the service's side: it is started, asked to
// keep events and to copy a database for readers, and started again when
// it stops. No query runs in it.

const { fork } = require('node:child_process');
const path = require('node:path');
const { Refused } = require('./store.js');

/** What is asked while the process is being started again. */
const DOWN = "the databases' process is being started again; ask again soon";
/** How long a keep may take before it is given up, and its delivery failed. */
const ASK_MS = 30000;
/**
 * How long a keep asked while the process is down, or cut short by its
 * stopping, waits for it to be back and is asked again: within a
 * delivery's hold (60 s), so that the node does not count a try that the
 * process's stopping, not the event, failed.
 */
const KEEP_WITHIN_MS = 45000;
/** How many starts in a row may fail before the service stops. */
const STARTS = 5;
/**
 * How many events may wait to be kept at once: the node's deliveries are
 * claimed one at a time, so more is something stuck, refused at once
 * rather than queued.
 */
const KEEPS = 8;

/**
 * Starts the databases in `dir` for `apps`, in a process of their own.
 * `keep` and `snapshot` ask it: each fails at once while it is being
 * started again, and fails if it is not answered in time (`askMs`). One
 * that stops is started again, and what was asked of it then fails. One that fails to start `starts` times
 * running, or that cannot open a database but for damage, stops the
 * service, saying why (`onFatal`), so the node sees it stopped. A keep is
 * the exception: one asked while it is down, or cut short as it stops, is
 * asked again once it is back, for up to `keepWithinMs`.
 */
function startStore({
  dir,
  apps,
  budgets,
  orgsMax,
  snapshotMs,
  snapshotPause,
  script = path.join(__dirname, 'db.js'),
  say = console.error,
  askMs = ASK_MS,
  keepWithinMs = KEEP_WITHIN_MS,
  starts = STARTS,
  backoffMs = (restarts) => Math.min(30000, 250 * 2 ** Math.min(restarts, 7)),
  onFatal = (why) => {
    say(`query: ${why}; the service stops`);
    process.exit(1);
  },
}) {
  let child = null;
  let alive = false;
  let next = 0;
  let stopping = false;
  let fatal = false;
  let restarts = 0;
  /** Starts in a row that ended before the process was ready. */
  let failedStarts = 0;
  /** What is waiting for an answer, by id. */
  const waiting = new Map();
  /** What the databases' process said a person should know. */
  const notices = [];
  /** Resolved once the process is first ready. */
  let first;
  const firstReady = new Promise((resolve) => {
    first = resolve;
  });

  const stop = (why) => {
    if (fatal) return;
    fatal = true;
    onFatal(why);
  };

  const start = () => {
    if (stopping || fatal) return;
    let ready = false;
    const made = fork(script, [JSON.stringify({ dir, apps, budgets, orgsMax, snapshotMs, snapshotPause })], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
    child = made;
    made.on('message', (message) => {
      if (message.fatal) {
        stop(String(message.fatal));
        return;
      }
      if (message.notice) {
        if (!notices.includes(message.notice)) notices.push(message.notice);
        return;
      }
      if (message.ready) {
        for (const said of message.notices || []) if (!notices.includes(said)) notices.push(said);
        ready = true;
        alive = true;
        first();
        restarts = 0;
        failedStarts = 0;
        return;
      }
      const asked = waiting.get(message.id);
      if (!asked) return;
      waiting.delete(message.id);
      clearTimeout(asked.timer);
      if ('error' in message) asked.reject(message.refused ? new Refused(message.error) : new Error(message.error));
      else asked.resolve(message.value);
    });
    made.on('exit', (code, signal) => {
      alive = false;
      const why = `the databases' process stopped (${signal || code})`;
      for (const [id, asked] of waiting) {
        waiting.delete(id);
        clearTimeout(asked.timer);
        asked.reject(Object.assign(asked.op === 'snapshot' ? new Refused(DOWN) : new Error(why), { down: true }));
      }
      if (stopping || fatal) return;
      if (!ready) {
        failedStarts += 1;
        if (failedStarts >= starts) {
          stop(`the databases' process did not start, ${failedStarts} times running (${signal || code})`);
          return;
        }
      }
      say(`query: ${why}; starting it again`);
      restarts += 1;
      setTimeout(start, backoffMs(restarts)).unref();
    });
  };

  const ask = (op, asked, ms) => {
    if (stopping) return Promise.reject(new Error('the service is stopping'));
    // While it is down, what is asked fails now: a delivery is tried
    // again by the node, a query asked again by whoever asked it.
    if (!alive) return Promise.reject(Object.assign(op === 'snapshot' ? new Refused(DOWN) : new Error(DOWN), { down: true }));
    if (op === 'keep' && [...waiting.values()].filter((w) => w.op === 'keep').length >= KEEPS) {
      return Promise.reject(new Error(`${KEEPS} events are being kept already; this one is tried again later`));
    }
    const id = (next += 1);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!waiting.has(id)) return;
        waiting.delete(id);
        reject(new Error(`the databases' process did not answer within ${ms / 1000} seconds`));
        // What it was doing is stopped with it, and it is started again:
        // a keep stuck goes on no longer, and nothing more queues behind it.
        if (child && child.exitCode === null && child.signalCode === null) {
          say(`query: the databases' process did not answer in time, and is stopped`);
          child.kill('SIGKILL');
        }
      }, ms);
      timer.unref();
      waiting.set(id, { op, resolve, reject, timer });
      child.send({ id, op, ...asked }, (error) => {
        if (!error || !waiting.has(id)) return;
        waiting.delete(id);
        clearTimeout(timer);
        reject(error);
      });
    });
  };

  /** A keep, asked again while the process is being started again. */
  const keep = async (event) => {
    const until = Date.now() + keepWithinMs;
    for (;;) {
      try {
        return await ask('keep', { event }, askMs);
      } catch (error) {
        if (!(error && error.down) || stopping || fatal || Date.now() >= until) throw error;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
  };

  start();
  return {
    keep,
    /** A copy to read of what `app` and `org` read, `{ file, asOf }` (`file` null for an empty table). */
    snapshot: (app, org) => ask('snapshot', { app, org }, askMs),
    /** Resolves once the databases are first open. */
    ready: () => firstReady,
    /** Whether the process is being started again. */
    down: () => !alive && !stopping && !fatal,
    pid: () => child && child.pid,
    notices: () => notices.slice(),
    async close() {
      stopping = true;
      if (child && child.exitCode === null && child.signalCode === null) {
        child.kill('SIGTERM');
        await new Promise((resolve) => child.once('exit', resolve));
      }
    },
  };
}

module.exports = { startStore, DOWN };
