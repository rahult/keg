'use strict';
// What stream.js does where a real NATS server cannot show it: a failure
// to ask, and a try that fails. Its streams' limits, made, updated and
// found, are tested against a real server in live*.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const { ensureStream } = require('../stream.js');

/** A fake JetStream manager holding at most one stream, and what was asked of it. */
function fakeJsm(config) {
  const asked = [];
  let held = config ? { ...config } : null;
  return {
    asked,
    streams: {
      async info(name) {
        asked.push(['info', name]);
        if (!held) {
          const error = new Error('stream not found');
          error.api_error = { code: 404, err_code: 10059, description: 'stream not found' };
          throw error;
        }
        return { config: { ...held }, state: { messages: 0 } };
      },
      async add(config) {
        asked.push(['add', config]);
        held = { ...config };
        return { config: held };
      },
      async update(name, config) {
        asked.push(['update', name, config]);
        held = { ...held, ...config };
        return { config: held };
      },
    },
  };
}

test('a failure to ask is not taken for a stream that is not there', async () => {
  const jsm = fakeJsm(null);
  jsm.streams.info = async () => {
    throw new Error('timeout');
  };
  await assert.rejects(ensureStream(jsm), /timeout/);
});

const { ready } = require('../stream.js');

test('a try to get ready that fails closes its connection, and the next is kept', async () => {
  const made = [];
  const connect = async () => {
    const n = made.length;
    const nc = {
      closed: false,
      async close() {
        this.closed = true;
      },
      async jetstreamManager() {
        if (n === 0) throw new Error('JetStream not ready');
        return fakeJsm(null);
      },
      jetstream: () => ({}),
    };
    made.push(nc);
    return nc;
  };
  const said = [];
  const got = await ready(connect, {}, {}, { waitMs: 1, say: (s) => said.push(s) });
  assert.equal(made.length, 3);
  assert.equal(made[0].closed, true);
  assert.equal(made[1].closed, false);
  assert.equal(got.nc, made[1]);
  assert.equal(got.rc, made[2]);
  assert.deepEqual(said, ['nats: waiting for JetStream: JetStream not ready', "nats: the stream KEG was made, and the readers' made"]);
});

test("the readers' stream made again, empty, is said on the page until the service starts again", async () => {
  const { readersKept } = require('../stream.js');
  let did = 'found';
  const said = [];
  const kept = readersKept(async () => did, { say: (line) => said.push(line), now: () => new Date('2026-11-23T10:00:00Z') });
  await kept.check();
  assert.equal(kept.notice(), null);
  did = 'made';
  await kept.check();
  assert.equal(
    kept.notice(),
    "The readers' stream KEG was gone, and was made again, empty, at 2026-11-23T10:00:00.000Z: what was published before then is not in it.",
  );
  assert.ok(said.some((l) => /made again/.test(l)));
  // Still said once it is there again.
  did = 'found';
  await kept.check();
  assert.match(kept.notice(), /made again, empty/);
});
