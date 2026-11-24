'use strict';
// Who the query service answers. Nothing here needs DuckDB.

const test = require('node:test');
const assert = require('node:assert/strict');
const { appOf, hostAllowed } = require('../reach.js');

test("an app's page is one whose origin the node vouched for, exactly", () => {
  // As the node says of SupportDesk, made of the service desk-web, with
  // names served on 7380 and 7443.
  const apps = new Map([
    ['supportdesk', ['http://desk-web.keg.localhost:7380', 'https://desk-web.keg.localhost:7443']],
  ]);
  assert.equal(appOf('http://desk-web.keg.localhost:7380', apps), 'supportdesk');
  assert.equal(appOf('https://desk-web.keg.localhost:7443', apps), 'supportdesk');
  for (const origin of [
    undefined,
    'null',
    'http://evil.example',
    // Named like the app, which the node serves nothing as.
    'http://supportdesk.keg.localhost:7380',
    'https://supportdesk.keg.localhost',
    // Its name on a port anything on this computer may listen on.
    'http://desk-web.keg.localhost:18555',
    'http://desk-web.keg.localhost',
    'https://desk-web.keg.localhost:7380',
    'http://desk-web.keg.localhost:7380/path',
    'http://DESK-WEB.keg.localhost:7380',
    'http://desk-web.keg.localhost.evil.example:7380',
    'http://query.svc.keg.localhost:7380',
  ]) {
    assert.equal(appOf(origin, apps), null, origin);
  }
  assert.equal(appOf('http://desk-web.keg.localhost:7380', new Map()), null);
});

test('only names of this computer are answered', () => {
  for (const host of [undefined, '127.0.0.1:8224', 'localhost:8224', '[::1]:8224', 'query.svc.keg.localhost:8080', 'keg-query.keg.localhost']) {
    assert.equal(hostAllowed(host), true, host);
  }
  for (const host of ['rebound.example', 'rebound.example:8224', '10.0.0.5:8224', 'keg.localhost.evil.example']) {
    assert.equal(hostAllowed(host), false, host);
  }
});

const { admitted } = require('../reach.js');

const apps = new Map([['supportdesk', ['http://desk-web.keg.localhost:7380']]]);
const asking = (headers, method = 'POST', path = '/query') => ({
  method,
  path,
  headers: { host: '127.0.0.1:8224', 'x-keg-query': '1', 'content-type': 'application/json', ...headers },
});

test('a query is a POST of JSON with X-Keg-Query, from the service itself or a bound app', () => {
  assert.deepEqual(admitted(asking({}), apps), { kind: 'query', app: null, cors: {} });
  assert.deepEqual(admitted(asking({ origin: 'http://127.0.0.1:8224', 'sec-fetch-site': 'same-origin' }), apps), {
    kind: 'query',
    app: null,
    cors: {},
  });
  assert.deepEqual(admitted(asking({ origin: 'http://desk-web.keg.localhost:7380', 'sec-fetch-site': 'cross-site' }), apps), {
    kind: 'query',
    app: 'supportdesk',
    cors: { 'Access-Control-Allow-Origin': 'http://desk-web.keg.localhost:7380' },
  });
  // GET is gone; without the header or JSON, refused.
  assert.equal(admitted(asking({}, 'GET'), apps).status, 405);
  assert.equal(admitted({ ...asking({}), headers: { host: '127.0.0.1:8224', 'content-type': 'application/json' } }, apps).status, 400);
  assert.equal(admitted(asking({ 'content-type': 'text/plain' }), apps).status, 415);
});

test("a request another site's page made is refused, with an Origin or without", () => {
  // As a browser sends an <img>, a <script>, a link or a frame: no Origin.
  for (const site of ['cross-site', 'same-site']) {
    for (const [method, path] of [['GET', '/query'], ['POST', '/query'], ['GET', '/']]) {
      const said = admitted(asking({ 'sec-fetch-site': site, 'sec-fetch-mode': 'no-cors' }, method, path), apps);
      assert.equal(said.status, 403, `${site} ${method} ${path}`);
    }
  }
  for (const origin of ['http://evil.example', 'http://supportdesk.keg.localhost:7380', 'http://desk-web.keg.localhost:18555']) {
    assert.equal(admitted(asking({ origin, 'sec-fetch-site': 'cross-site' }), apps).status, 403, origin);
    assert.equal(admitted(asking({ origin }, 'OPTIONS'), apps).status, 403, origin);
  }
  // What a person opens, or a program asks, is answered.
  assert.equal(admitted(asking({ 'sec-fetch-site': 'none' }, 'GET', '/'), apps).kind, 'page');
  assert.equal(admitted(asking({}, 'GET', '/'), apps).kind, 'page');
});

test("only a bound app's page passes the preflight", () => {
  assert.deepEqual(admitted(asking({ origin: 'http://desk-web.keg.localhost:7380' }, 'OPTIONS'), apps), {
    kind: 'preflight',
    app: 'supportdesk',
    cors: {
      'Access-Control-Allow-Origin': 'http://desk-web.keg.localhost:7380',
      'Access-Control-Allow-Methods': 'POST',
      'Access-Control-Allow-Headers': 'authorization, content-type, x-keg-query',
      'Access-Control-Max-Age': '600',
    },
  });
  assert.equal(admitted(asking({}, 'OPTIONS'), apps).status, 405);
});

test('a name another site pointed here is refused first', () => {
  assert.equal(admitted({ ...asking({}), headers: { ...asking({}).headers, host: 'rebound.example' } }, apps).status, 403);
});
