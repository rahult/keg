'use strict';
// Runs a NATS server with JetStream, and puts each event the node tells
// this service of in the stream KEG, as keg.<type>, once JetStream has it.
// Its page, on port 8222, lists the last it put there. It stops when the
// server stops, with the server's code.

const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { connect } = require('nats');
const { connectNode } = require('./vendor/keg-node/node.js');
const { pageHandler } = require('./page.js');
const { ready, STREAM, SUBJECTS } = require('./stream.js');
const { serverConfig, inboxOf, PUBLISHER, ADMIN, MAX_PAYLOAD } = require('./server.js');
const { keepReaders, readerPasswordOf } = require('./readers.js');
const { ensureStream, readersKept, READER_LIMITS } = require('./stream.js');
const { publisher } = require('./publish.js');

/** How many of the last published the page lists. */
const LISTED = 50;
const PAGE_PORT = 8222;

// The server's configuration is written where only this program reads it.
const CONFIG_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'keg-nats-'));
const CONFIG = path.join(CONFIG_DIR, 'nats.conf');
// The password the service publishes with, made afresh each start, held
// here and in that file alone: never logged, never on its page.
const PASSWORD = crypto.randomBytes(24).toString('hex');
const STORE = '/data/jetstream';
/** Writes the server's file, with the readers' password or no reader. */
const written = (readerPassword) =>
  fs.writeFileSync(CONFIG, serverConfig({ password: PASSWORD, readerPassword, port: 4222, store: STORE }), { mode: 0o600 });
// Begun with no reader, so the service's own connections are made before
// any reader can take the readers' connections.
written(null);
// A version before the two accounts kept its stream in NATS's global
// account, which nothing reads now: its room is given back.
const GLOBAL = path.join(STORE, 'jetstream', '$G');
if (fs.existsSync(GLOBAL)) {
  fs.rmSync(GLOBAL, { recursive: true, force: true });
  console.error('nats: the stream of a version before readers had an account of their own was removed');
}

const server = spawn('nats-server', ['-c', CONFIG], {
  stdio: 'inherit',
  // The server and this program share the service's memory.
  env: { ...process.env, GOMEMLIMIT: '96MiB' },
});
server.on('error', (error) => {
  console.error(`nats: the NATS server could not be started: ${error.message}`);
  process.exit(1);
});
server.on('exit', (code, signal) => {
  console.error(`nats: the NATS server stopped (${signal || code})`);
  process.exit(code ?? 1);
});
// Asked to stop, the server stops, and this program with it.
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => server.kill(signal));

/** What was published, newest last, and how many since it started. */
const published = [];
let count = 0;

async function main() {
  // Its connections are kept for as long as it runs: one lost is not
  // made again, since readers may hold every connection of their account
  // by then. The service stops, and the node starts it again.
  const { nc, rc, js, readers } = await ready(
    connect,
    { servers: '127.0.0.1:4222', name: 'keg', user: PUBLISHER, pass: PASSWORD, inboxPrefix: inboxOf(), reconnect: false },
    { servers: '127.0.0.1:4222', name: 'keg-readers', user: ADMIN, pass: PASSWORD, inboxPrefix: inboxOf(), reconnect: false },
  );
  for (const [c, what] of [[nc, 'its connection to the server'], [rc, "its connection to the readers' account"]]) {
    c.closed().then(() => {
      console.error(`nats: the service lost ${what}, and stops`);
      server.kill('SIGTERM');
    });
  }
  // Only now are readers let in, with the password a person set.
  const node = connectNode();
  const keeper = keepReaders({
    ask: () => readerPasswordOf(node),
    apply: (readerPassword) => {
      written(readerPassword);
      server.kill('SIGHUP');
    },
  });
  await keeper.check();
  setInterval(() => keeper.check().catch((error) => console.error(`nats: the reader password could not be asked: ${error.message}`)), 10000).unref();
  // Someone with the reader password may harm the readers' stream; it is
  // made again if it is gone, and given its limits again.
  const kept = readersKept(() => ensureStream(readers, READER_LIMITS));
  setInterval(async () => {
    try {
      await kept.check();
    } catch (error) {
      console.error(`nats: the readers' stream could not be checked: ${error.message}`);
    }
  }, 30000).unref();
  // What readers can read: the stream in their account.
  const held = async () => {
    const { state, config } = await readers.streams.info(STREAM);
    const mib = (bytes) => `${(bytes / 1048576).toFixed(1)} MiB`;
    return `${state.messages} events, ${mib(state.bytes)} of at most ${mib(config.max_bytes)}; the oldest go when it is full`;
  };
  http
    .createServer(pageHandler({ stream: STREAM, published, count: () => count, held, password: () => readerPasswordOf(node), notice: () => [keeper.notice(), kept.notice()].filter(Boolean).join(' ') }))
    .listen(PAGE_PORT, '0.0.0.0');
  node.watch(
    publisher(js, (p) => {
      count += 1;
      published.push(p);
      if (published.length > LISTED) published.shift();
    }, { maxPayload: MAX_PAYLOAD }),
  );
  console.log(`nats: publishing to ${SUBJECTS} in ${STREAM}`);
}

main().catch((error) => {
  console.error(`nats: ${error.message}`);
  server.kill('SIGTERM');
});
