'use strict';
// The NATS service's parts against a real NATS server, where there is one:
// `nats-server` on the PATH, and the `nats` client installed (`npm ci`).
// Skipped otherwise; CI runs the tests beside this one, which need neither.

const { tmp } = require('./tmp.js');
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { ensureStream, STREAM } = require('../stream.js');

let nats = null;
try {
  nats = require('nats');
} catch {
  // Not installed: skipped.
}
const hasServer = spawnSync('nats-server', ['--version']).status === 0;
const skip = !nats || !hasServer ? 'needs nats-server on the PATH and npm ci' : false;
// CI has both, and says so: there, these never skip.
if (skip && process.env.KEG_NATS_LIVE === '1') throw new Error(`KEG_NATS_LIVE is 1, and these tests would skip (${skip})`);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

/**
 * A NATS server with JetStream on a port of its own, storing in `dir`,
 * run from `config` (its text, with PORT and DIR in it), stopped after the
 * test.
 */
async function server(t, config, dir = tmp('keg-nats-')) {
  const port = await freePort();
  const file = path.join(dir, 'nats.conf');
  fs.writeFileSync(file, config.replaceAll('PORT', String(port)).replaceAll('DIR', path.join(dir, 'js')));
  const child = spawn('nats-server', ['-c', file], { stdio: 'ignore' });
  const stop = async () => {
    if (child.exitCode !== null) return;
    child.kill('SIGTERM');
    await new Promise((resolve) => child.once('exit', resolve));
  };
  t.after(stop);
  for (let tries = 0; ; tries += 1) {
    try {
      const nc = await nats.connect({ servers: `127.0.0.1:${port}`, user: 'keg', pass: 'pw', reconnect: false });
      await nc.close();
      break;
    } catch {
      if (tries > 50) throw new Error('nats-server did not start');
      await sleep(100);
    }
  }
  return { port, dir, stop };
}

const OPEN = `listen: "127.0.0.1:PORT"
jetstream { store_dir: "DIR" }
authorization { users: [ { user: "keg", password: "pw" } ] }
`;

test('a full stream drops its oldest and still takes the newest', { skip }, async (t) => {
  const { port } = await server(t, OPEN);
  const nc = await nats.connect({ servers: `127.0.0.1:${port}`, user: 'keg', pass: 'pw' });
  t.after(() => nc.close());
  const jsm = await nc.jetstreamManager();
  // As it was before it had limits: made with none.
  await jsm.streams.add({ name: STREAM, subjects: ['keg.>'] });
  assert.equal(await ensureStream(jsm, { max_bytes: 4096, discard: 'old' }), 'updated');
  const js = nc.jetstream();
  for (let n = 1; n <= 60; n += 1) {
    const ack = await js.publish('keg.work.changed', JSON.stringify({ n, pad: 'x'.repeat(100) }), { msgID: `e${n}` });
    assert.equal(ack.seq, n);
  }
  const info = await jsm.streams.info(STREAM);
  assert.equal(info.config.max_bytes, 4096);
  assert.equal(info.config.discard, 'old');
  assert.ok(info.state.bytes <= 4096, `${info.state.bytes}`);
  assert.ok(info.state.first_seq > 1, `${info.state.first_seq}`);
  assert.equal(info.state.last_seq, 60);
  assert.equal(await ensureStream(jsm, { max_bytes: 4096, discard: 'old' }), 'found');
});

const { publisher } = require('../publish.js');

test('what JetStream refuses fails, and tried again once there is room, is kept once', { skip }, async (t) => {
  const { port } = await server(t, OPEN);
  const nc = await nats.connect({ servers: `127.0.0.1:${port}`, user: 'keg', pass: 'pw' });
  t.after(() => nc.close());
  const jsm = await nc.jetstreamManager();
  // A stream that refuses what it has no room for.
  await jsm.streams.add({ name: STREAM, subjects: ['keg.>'], max_msgs: 1, discard: 'new' });
  const kept = [];
  const publish = publisher(nc.jetstream(), (p) => kept.push(p));
  const event = (id) => ({ id, type: 'work.changed', subject: 'work/1', at: 1795000000, payload: {} });
  assert.deepEqual(await publish(event('e1')), { seq: 1 });
  // JetStream answers 503, maximum messages exceeded.
  await assert.rejects(publish(event('e2')), /503|maximum messages exceeded/);
  await jsm.streams.purge(STREAM);
  assert.deepEqual(await publish(event('e2')), { seq: 2 });
  // Told of again, as the node may: kept once.
  assert.deepEqual(await publish(event('e2')), { seq: 2 });
  const info = await jsm.streams.info(STREAM);
  assert.equal(info.state.messages, 1);
  assert.equal(info.state.last_seq, 2);
});

test('a server started again finds its stream, and carries on from where it was', { skip }, async (t) => {
  const first = await server(t, OPEN);
  let nc = await nats.connect({ servers: `127.0.0.1:${first.port}`, user: 'keg', pass: 'pw' });
  assert.equal(await ensureStream(await nc.jetstreamManager()), 'made');
  const event = (id) => ({ id, type: 'work.changed', subject: 'work/1', at: 1795000000, payload: {} });
  await publisher(nc.jetstream(), () => {})(event('e1'));
  await publisher(nc.jetstream(), () => {})(event('e2'));
  await nc.close();
  await first.stop();
  const again = await server(t, OPEN, first.dir);
  nc = await nats.connect({ servers: `127.0.0.1:${again.port}`, user: 'keg', pass: 'pw' });
  t.after(() => nc.close());
  assert.equal(await ensureStream(await nc.jetstreamManager()), 'found');
  assert.deepEqual(await publisher(nc.jetstream(), () => {})(event('e3')), { seq: 3 });
});
