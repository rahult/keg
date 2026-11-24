'use strict';
// The streams every event is put in, and what bounds them.
//
// The service publishes to the stream KEG of its own account, and readers
// read a stream of their own, also KEG, in theirs, which keeps what
// arrives on the events' subjects (server.js says why). The readers'
// stream holds what arrived while it was there: one made again, because
// it was gone, begins empty. The volume is 1 GiB. Unbounded, a full
// stream would refuse every publish, and every delivery would fail until
// it was a dead letter. So the service's stream holds at most 64 MiB and
// the readers' at most 704 MiB, which leaves room for JetStream's own
// files; when either is full it drops its oldest to take the newest.
// Neither is bounded by age: what fits is kept, however old, for a
// reader that has been away.

const STREAM = 'KEG';
const SUBJECTS = 'keg.>';
const LIMITS = { max_bytes: 64 * 1024 * 1024, discard: 'old' };
/** The readers' stream: 32 consumers at most (server.js holds the rest). */
const READER_LIMITS = { max_bytes: 704 * 1024 * 1024, discard: 'old', max_consumers: 32 };

/** Whether JetStream said there is no such stream. */
function notThere(error) {
  return Boolean(error && error.api_error && error.api_error.err_code === 10059);
}

/**
 * Makes the stream if it is not there, and gives it `limits` if it is
 * there without them. What it did: `made`, `updated` or `found`.
 */
async function ensureStream(jsm, limits = LIMITS) {
  let info = null;
  try {
    info = await jsm.streams.info(STREAM);
  } catch (error) {
    if (!notThere(error)) throw error;
  }
  if (!info) {
    await jsm.streams.add({ name: STREAM, subjects: [SUBJECTS], ...limits });
    return 'made';
  }
  const config = info.config;
  if (Object.entries(limits).every(([key, value]) => config[key] === value)) return 'found';
  await jsm.streams.update(STREAM, { ...config, ...limits });
  return 'updated';
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Connects with `connect(options)` once the server answers, and makes the
 * service's stream if it is not there; then with `connect(reading)`, and
 * makes the readers'. A try that fails closes what it opened.
 */
async function ready(connect, options, reading, { waitMs = 500, say = console.error } = {}) {
  for (;;) {
    let nc = null;
    let rc = null;
    try {
      nc = await connect(options);
      const jsm = await nc.jetstreamManager();
      const did = await ensureStream(jsm);
      rc = await connect(reading);
      const readers = await rc.jetstreamManager();
      const theirs = await ensureStream(readers, READER_LIMITS);
      say(`nats: the stream ${STREAM} was ${did}, and the readers' ${theirs}`);
      return { nc, rc, js: nc.jetstream(), jsm, readers };
    } catch (error) {
      if (nc) await nc.close().catch(() => {});
      if (rc) await rc.close().catch(() => {});
      say(`nats: waiting for JetStream: ${error.message}`);
      await sleep(waitMs);
    }
  }
}

/**
 * Keeps the readers' stream there with `ensure()` (what `ensureStream`
 * did), and what a person should know of it: once it had to be made
 * again, it began empty, and the page says so from then on.
 */
function readersKept(ensure, { say = console.error, now = () => new Date() } = {}) {
  let notice = null;
  return {
    async check() {
      const did = await ensure();
      if (did === 'found') return did;
      say(`nats: the readers' stream was ${did} again`);
      if (did === 'made') {
        notice = `The readers' stream ${STREAM} was gone, and was made again, empty, at ${now().toISOString()}: what was published before then is not in it.`;
      }
      return did;
    },
    notice: () => notice,
  };
}

module.exports = { ensureStream, ready, readersKept, LIMITS, READER_LIMITS, STREAM, SUBJECTS };
