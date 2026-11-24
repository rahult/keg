'use strict';
// The NATS service's page. Nothing here needs NATS.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { pageHandler } = require('../page.js');

/** A request to the page naming `host`: its status and body. */
async function ask(t, handler, { host = '127.0.0.1:8222', method = 'GET', path = '/', headers = {} } = {}) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const { port } = server.address();
  return new Promise((resolve, reject) => {
    const req = http.request({ port, host: '127.0.0.1', path, method, headers: { Host: host, ...headers } }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

const PASSWORD = 'a-reader-password-a-person-chose';
const state = (password = PASSWORD) => ({
  stream: 'KEG',
  published: [{ seq: 1, subject: 'keg.work.changed', type: 'work.changed', about: 'work/<1>', at: 1795000000 }],
  count: () => 1,
  held: async () => '1',
  password: async () => password,
});
const listed = (password, more = {}) => ({
  method: 'POST',
  path: '/published',
  headers: { 'X-Keg-Nats': '1', ...(password === undefined ? {} : { Authorization: `Bearer ${password}` }), ...more },
});

test('the page itself shows nothing of the events', async (t) => {
  const { status, body } = await ask(t, pageHandler(state()));
  assert.equal(status, 200);
  assert.ok(!body.includes('work.changed') && !body.includes('work/'), body);
  assert.ok(body.includes('type="password"'), body);
});

test('what was published is had with the reader password alone', async (t) => {
  const { status, body } = await ask(t, pageHandler(state()), listed(PASSWORD));
  assert.equal(status, 200);
  const said = JSON.parse(body);
  assert.equal(said.count, 1);
  assert.equal(said.published[0].about, 'work/<1>');
  for (const wrong of [undefined, '', 'not-it', `${PASSWORD}x`]) {
    const refused = await ask(t, pageHandler(state()), listed(wrong));
    assert.equal(refused.status, 401, String(wrong));
    assert.ok(!refused.body.includes('work/'), refused.body);
  }
  // Without the header of its own, or from another site's page: refused.
  const bare = await ask(t, pageHandler(state()), { method: 'POST', path: '/published', headers: { Authorization: `Bearer ${PASSWORD}` } });
  assert.equal(bare.status, 400);
  const across = await ask(t, pageHandler(state()), listed(PASSWORD, { 'Sec-Fetch-Site': 'cross-site' }));
  assert.equal(across.status, 403);
});

test('with no reader password set, nothing is shown to anyone', async (t) => {
  const { status, body } = await ask(t, pageHandler(state(null)), listed(''));
  assert.equal(status, 401);
  assert.ok(body.includes('keg system secret nats READER_PASSWORD'), body);
});

test('a reader password the server itself refuses lets nobody in', async (t) => {
  const short = 'too-short';
  const { status, body } = await ask(t, pageHandler(state(short)), listed(short));
  assert.equal(status, 401);
  assert.ok(body.includes('cannot be used'), body);
});

test('wrong guesses are slowed, from each source and in all', async (t) => {
  let now = 1000000;
  const handler = pageHandler({ ...state(), clock: () => now });
  for (let n = 0; n < 3; n += 1) {
    assert.equal((await ask(t, handler, listed('wrong'))).status, 401);
  }
  // After three, even the right one waits, and is told how long.
  const held = await ask(t, handler, listed(PASSWORD));
  assert.equal(held.status, 429, held.body);
  now += 61 * 1000;
  assert.equal((await ask(t, handler, listed(PASSWORD))).status, 200);
  // Many sources guessing at once hold everyone back for a while.
  const all = pageHandler({ ...state(), clock: () => now, source: (() => { let n = 0; return () => `s${(n += 1)}`; })() });
  for (let n = 0; n < 30; n += 1) await ask(t, all, listed('wrong'));
  assert.equal((await ask(t, all, listed(PASSWORD))).status, 429);
});

test('a name another site pointed here is not answered', async (t) => {
  for (const host of ['rebound.example', 'rebound.example:8222']) {
    const { status, body } = await ask(t, pageHandler(state()), { host });
    assert.equal(status, 403, host);
    assert.ok(!body.includes('work/'), body);
  }
});
