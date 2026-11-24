'use strict';
// Who may do what on the NATS server, against a real one, where there is
// one: `nats-server` on the PATH, and the `nats` client installed (`npm
// ci`). Skipped otherwise; CI fetches a pinned server and runs these.

const { tmp } = require('./tmp.js');
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { serverConfig, inboxOf, INBOX, PUBLISHER, ADMIN, READER } = require('../server.js');
const { ensureStream, LIMITS, READER_LIMITS, STREAM } = require('../stream.js');

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
const PASSWORD = 'a'.repeat(48);
const READS_WITH = 'r'.repeat(40);

/**
 * A server as the service runs it, with its two streams made as the
 * service makes them: `keg` publishing in KEG, `admin` in READERS, and a
 * reader with `readerPassword`, or none.
 */
async function started(t, { readerPassword = READS_WITH, configured = (text) => text } = {}) {
  const probe = net.createServer();
  await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const { port } = probe.address();
  await new Promise((resolve) => probe.close(resolve));
  const dir = tmp('keg-nats-');
  const file = path.join(dir, 'nats.conf');
  const write = (readers) => fs.writeFileSync(file, configured(serverConfig({ password: PASSWORD, readerPassword: readers, port, store: path.join(dir, 'js') })));
  write(null);
  const child = spawn('nats-server', ['-c', file], { stdio: ['ignore', 'ignore', 'pipe'] });
  // What it says as it starts, or refuses to: a test that expects it to
  // refuse checks its own words, not only that it did not start.
  let said = '';
  child.stderr.on('data', (chunk) => (said += chunk));
  t.after(() => child.kill('SIGTERM'));
  const servers = `127.0.0.1:${port}`;
  let keg = null;
  for (let tries = 0; !keg; tries += 1) {
    try {
      keg = await nats.connect({ servers, user: PUBLISHER, pass: PASSWORD, inboxPrefix: inboxOf() });
    } catch {
      if (tries > 50 || child.exitCode !== null) throw new Error(`nats-server did not start: ${said.trim()}`);
      await sleep(100);
    }
  }
  t.after(() => keg.close());
  const jsm = await keg.jetstreamManager();
  await ensureStream(jsm);
  const admin = await nats.connect({ servers, user: ADMIN, pass: PASSWORD, inboxPrefix: inboxOf() });
  t.after(() => admin.close());
  const readers = await admin.jetstreamManager();
  await ensureStream(readers, READER_LIMITS);
  // Readers are let in once the service's own connections are made.
  const letIn = async (readers2) => {
    write(readers2);
    child.kill('SIGHUP');
    await sleep(500);
  };
  if (readerPassword !== null) await letIn(readerPassword);
  return { servers, keg, js: keg.jetstream(), jsm, admin, readers, letIn };
}

/** A reader, with the password, its errors kept. */
async function reader(t, servers, options = {}) {
  const nc = await nats.connect({ servers, user: READER, pass: READS_WITH, ...options });
  t.after(() => nc.close().catch(() => {}));
  const errors = [];
  (async () => {
    for await (const s of nc.status()) if (s.type === 'error') errors.push(String(s.data) + (s.permissionContext ? ` ${s.permissionContext.operation} ${s.permissionContext.subject}` : ''));
  })();
  return { nc, errors };
}

test('no reader is let in without the password a person set, nor before one is set', { skip }, async (t) => {
  const { servers, letIn } = await started(t, { readerPassword: null });
  const tries = [{}, { user: READER, pass: READS_WITH }];
  for (const given of tries) {
    await assert.rejects(nats.connect({ servers, reconnect: false, ...given }), /Authorization/, JSON.stringify(given));
  }
  await letIn(READS_WITH);
  await assert.rejects(nats.connect({ servers, reconnect: false }), /Authorization/);
  await assert.rejects(nats.connect({ servers, reconnect: false, user: READER, pass: 'b'.repeat(40) }), /Authorization/);
  const { nc } = await reader(t, servers);
  assert.ok(nc.info.server_id);
  // The service's own passwords are the only way in as it.
  await assert.rejects(nats.connect({ servers, user: PUBLISHER, pass: 'b'.repeat(48), reconnect: false }), /Authorization/);
});

test('a reader reads the readers\' stream, and neither publishes an event nor runs a stream', { skip }, async (t) => {
  const { servers, js, jsm } = await started(t);
  await js.publish('keg.work.changed', '{"n":1}', { msgID: 'one' });
  const { nc: anyone, errors } = await reader(t, servers);
  const heard = [];
  const sub = anyone.subscribe('keg.>');
  (async () => {
    for await (const m of sub) heard.push(m.subject);
  })();
  await anyone.flush();
  await js.publish('keg.work.changed', '{"n":2}', { msgID: 'two' });
  anyone.publish('keg.work.changed', '{"forged":true}');
  await anyone.flush();
  await sleep(300);
  assert.ok(errors.some((e) => e.includes('publish keg.work.changed')), errors.join('\n'));
  assert.deepEqual(heard, ['keg.work.changed']);
  assert.equal((await jsm.streams.info(STREAM)).state.messages, 2);
  const theirs = await anyone.jetstreamManager();
  assert.equal((await theirs.streams.info(STREAM)).state.messages, 2);
  await assert.rejects(theirs.streams.delete(STREAM), /Permissions Violation/);
  await assert.rejects(theirs.streams.purge(STREAM), /Permissions Violation/);
  await assert.rejects(theirs.streams.update(STREAM, { max_bytes: 1 }), /Permissions Violation/);
  await assert.rejects(theirs.streams.add({ name: 'MINE', subjects: ['mine.>'] }), /Permissions Violation/);
  await theirs.consumers.add(STREAM, { durable_name: 'mine', ack_policy: nats.AckPolicy.Explicit });
  const consumer = await anyone.jetstream().consumers.get(STREAM, 'mine');
  const first = await consumer.next({ expires: 2000 });
  assert.equal(first.json().n, 1);
  first.ack();
});

test("nothing a reader does reaches the service's stream, its API or where it is answered", { skip }, async (t) => {
  const { servers, keg, js, jsm, readers } = await started(t);
  await js.publish('keg.work.changed', '{"n":1}', { msgID: 'one' });
  const config = JSON.stringify((await jsm.streams.info(STREAM)).config);
  const reached = [];
  for (const subject of ['$JS.API.>', `${INBOX}.>`, '$JS.FC.>']) {
    const sub = keg.subscribe(subject);
    (async () => {
      for await (const m of sub) if (!m.subject.startsWith(`${INBOX}.`) || m.subject === `${INBOX}.x`) reached.push(m.subject);
    })();
  }
  await keg.flush();
  const { nc: anyone } = await reader(t, servers);
  const theirs = await anyone.jetstreamManager();
  // What a reader may not ask, asked.
  for (const [subject, body] of [
    ['$JS.API.STREAM.PURGE.KEG', ''],
    ['$JS.API.STREAM.DELETE.KEG', ''],
    ['$JS.API.STREAM.UPDATE.KEG', JSON.stringify({ name: STREAM, subjects: ['keg.>'], max_bytes: 1 })],
    ['keg.work.changed', '{"forged":true}'],
  ]) {
    anyone.publish(subject, body);
  }
  // Consumers that deliver where an API, the service's inbox or flow
  // control would be.
  for (const [n, deliver] of [['purge', '$JS.API.STREAM.PURGE.KEG'], ['inbox', `${INBOX}.x`], ['fc', '$JS.FC.KEG.x']]) {
    await theirs.consumers.add(STREAM, { durable_name: n, deliver_subject: deliver, ack_policy: nats.AckPolicy.None });
  }
  await anyone.flush();
  await js.publish('keg.work.changed', '{"n":2}', { msgID: 'two' });
  await sleep(1000);
  assert.deepEqual(reached, []);
  const info = await jsm.streams.info(STREAM);
  assert.equal(info.state.messages, 2);
  assert.equal(JSON.stringify(info.config), config);
  // Nor, as it happens, does a delivery act as a request in the readers'
  // own account: their copy is whole too.
  assert.equal((await readers.streams.info(STREAM)).state.messages, 2);
});

test('readers are held to their consumers, connections, subscriptions and what they publish, and the service is not shut out', { skip }, async (t) => {
  const { servers, js, readers } = await started(t);
  const { nc: anyone, errors } = await reader(t, servers);
  const theirs = await anyone.jetstreamManager();
  let made = 0;
  let refused = null;
  for (; made < 40; made += 1) {
    try {
      await theirs.consumers.add(STREAM, { durable_name: `c${made}`, ack_policy: nats.AckPolicy.Explicit });
    } catch (error) {
      refused = error.message;
      break;
    }
  }
  assert.equal(made, 32, refused);
  assert.match(refused, /maximum consumers/i);
  await theirs.consumers.delete(STREAM, 'c0');
  await assert.rejects(
    theirs.consumers.add(STREAM, { durable_name: 'greedy', ack_policy: nats.AckPolicy.Explicit, max_ack_pending: 100000 }),
    /max ack pending/i,
  );
  // 64 readers at once, and no more.
  let connected = 1;
  for (; connected < 70; connected += 1) {
    try {
      await reader(t, servers, { reconnect: false });
    } catch (error) {
      assert.match(error.message, /maximum account active connections/i);
      break;
    }
  }
  assert.equal(connected, 64);
  // The service, connected first, still publishes, and still reads and
  // keeps the readers' stream.
  assert.equal((await js.publish('keg.work.changed', '{}', { msgID: 'after' })).seq, 1);
  await sleep(200);
  assert.equal((await readers.streams.info(STREAM)).state.messages, 1);
  assert.equal(await ensureStream(readers, READER_LIMITS), 'found');
  // What a reader publishes is small: a request, never an event.
  assert.throws(() => anyone.publish('$JS.API.INFO', 'x'.repeat(128 * 1024)), /MAX_PAYLOAD/);
  for (let n = 0; n < 1100; n += 1) anyone.subscribe(`mine.${n}`);
  await anyone.flush().catch(() => {});
  await sleep(300);
  assert.ok(errors.some((e) => /PROTOCOL|subscriptions/i.test(e)), errors.join('\n'));
});

test('the service publishes as one message what NATS takes, and its stream is bounded', { skip }, async (t) => {
  const { jsm, readers } = await started(t);
  assert.equal((await jsm.streams.info(STREAM)).config.max_bytes, LIMITS.max_bytes);
  const theirs = (await readers.streams.info(STREAM)).config;
  assert.deepEqual([theirs.max_bytes, theirs.max_consumers, theirs.discard], [READER_LIMITS.max_bytes, 32, 'old']);
});

test("a reader can neither listen where the service is answered in the readers' account nor be taken for an answer there", { skip }, async (t) => {
  const { servers, admin, readers, js } = await started(t);
  const { nc: anyone, errors } = await reader(t, servers);
  // Every internal connection is answered under an inbox made at random
  // each start, below a prefix no reader may subscribe to.
  const sub = anyone.subscribe(`${INBOX}.>`);
  await anyone.flush().catch(() => {});
  await sleep(200);
  assert.ok(errors.some((e) => e.includes(`subscription ${INBOX}.>`)), errors.join('\n'));
  sub.unsubscribe();
  // Even one that knew the admin's inbox, and had a consumer deliver
  // there, is not taken for an answer: the client drops what it did not ask.
  const prefix = admin.options.inboxPrefix;
  assert.match(prefix, new RegExp(`^${INBOX.replace('$', '\\$')}\\.[0-9a-f]{24}$`));
  const theirs = await anyone.jetstreamManager();
  await theirs.consumers.add(STREAM, { durable_name: 'forge', deliver_subject: `${prefix}.forged`, ack_policy: nats.AckPolicy.None });
  await js.publish('keg.work.changed', '{"n":1}', { msgID: 'one' });
  await sleep(300);
  assert.equal(await ensureStream(readers, READER_LIMITS), 'found');
  assert.equal((await readers.streams.info(STREAM)).state.messages, 1);
});

test("a reader answers flow control for the readers' stream KEG alone", { skip }, async (t) => {
  const { servers } = await started(t);
  const { nc, errors } = await reader(t, servers);
  nc.publish('$JS.FC.KEG.c.1', '');
  nc.publish('$JS.FC.OTHER.c.1', '');
  await nc.flush();
  await sleep(300);
  assert.deepEqual(errors.filter((e) => /\$JS\.FC/.test(e)), ['PERMISSIONS_VIOLATION publish $JS.FC.OTHER.c.1']);
});

test("KEG gives the readers' account its events alone, though the readers' account asked for more", { skip }, async (t) => {
  // Were the readers' import ever widened, what KEG exports still holds.
  const wide = (text) => {
    const was = 'imports: [ { stream: { account: KEG, subject: "keg.>" } } ]';
    assert.ok(text.includes(was));
    return text.replace(was, 'imports: [ { stream: { account: KEG, subject: "keg.>" } }, { stream: { account: KEG, subject: "other.>" } } ]');
  };
  let up;
  try {
    up = await started(t, { configured: wide });
  } catch (error) {
    // NATS refuses an import that nothing exports: the server does not
    // start, saying so in its own words, and nothing is given. Not
    // starting for any other reason is a failure.
    assert.match(error.message, /did not start: .*Error adding stream import "other\.>": stream import not authorized/);
    return;
  }
  const { servers, keg } = up;
  const { nc } = await reader(t, servers);
  const heard = [];
  const sub = nc.subscribe('other.>');
  (async () => {
    for await (const m of sub) heard.push(m.subject);
  })();
  await nc.flush();
  keg.publish('other.secret', 'not for readers');
  keg.publish('keg.work.changed', '{}');
  await keg.flush();
  await sleep(300);
  assert.deepEqual(heard, []);
});

test("the readers' account holds them to 32 consumers, though their stream were made again without its own limit", { skip }, async (t) => {
  const { servers, readers } = await started(t);
  // As one made again by someone who forgot its limit would be.
  await readers.streams.delete(STREAM);
  await readers.streams.add({ name: STREAM, subjects: ['keg.>'], max_bytes: READER_LIMITS.max_bytes, discard: 'old' });
  const { nc } = await reader(t, servers);
  const theirs = await nc.jetstreamManager();
  let made = 0;
  for (; made < 40; made += 1) {
    try {
      await theirs.consumers.add(STREAM, { durable_name: `c${made}`, ack_policy: nats.AckPolicy.Explicit });
    } catch (error) {
      assert.match(String(error.message), /maximum consumers limit reached/);
      break;
    }
  }
  assert.equal(made, 32);
});
