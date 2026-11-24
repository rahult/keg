'use strict';
// What a request may read, by the credential it carries. Nothing here
// needs DuckDB.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { whoAsks } = require('../who.js');

const KEY = 'k'.repeat(40);
const key = { matches: async (given) => given === KEY, set: async () => true };
const tokens = new Map([
  ['supportdesk', 'a'.repeat(64)],
  ['ledger', 'b'.repeat(64)],
]);

const NOW = 1795000000;
const A = '0b6f7c2e-5d4a-4c1b-9e8f-1a2b3c4d5e6f';
const B = '9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f';
/** A token for one organization, as `serviceToken` of @keg/app/service makes it. */
function scoped({ app = 'supportdesk', org = A, exp = NOW + 300, with: secret = tokens.get(app) || 'z'.repeat(64), payload } = {}) {
  const body = payload ?? Buffer.from(JSON.stringify({ app, org, exp })).toString('base64url');
  return `v1.${body}.${crypto.createHmac('sha256', secret).update(body).digest('base64url')}`;
}
const now = () => NOW * 1000;

test("all the service holds is read with its key; an app's own events with that app's token, from a program", async () => {
  assert.deepEqual(await whoAsks({ originApp: null, given: KEY, key, tokens, now }), { app: null, org: null });
  assert.deepEqual(await whoAsks({ originApp: null, given: 'a'.repeat(64), key, tokens, now }), { app: 'supportdesk', org: null });
  assert.deepEqual(await whoAsks({ originApp: null, given: 'b'.repeat(64), key, tokens, now }), { app: 'ledger', org: null });
});

test("an app's own token is never taken from a page: not from the app's, nor from any request a browser made", async () => {
  for (const [originApp, browser] of [['supportdesk', true], [null, true]]) {
    const said = await whoAsks({ originApp, browser, given: 'a'.repeat(64), key, tokens, now });
    assert.equal(said.refuse, 401, `${originApp} ${browser}`);
    assert.match(said.error, /never taken from a page/);
  }
});

test('a token for one organization reads that organization alone, from a page of its app or a program', async () => {
  assert.deepEqual(await whoAsks({ originApp: 'supportdesk', browser: true, given: scoped(), key, tokens, now }), { app: 'supportdesk', org: A });
  assert.deepEqual(await whoAsks({ originApp: null, given: scoped({ org: B }), key, tokens, now }), { app: 'supportdesk', org: B });
  // Within a little of the clocks' difference.
  assert.deepEqual(await whoAsks({ originApp: null, given: scoped({ exp: NOW - 20 }), key, tokens, now }), { app: 'supportdesk', org: A });
});

test('a token for one organization that is expired, altered, of another app, too long or not made with the token is refused', async () => {
  const payload = Buffer.from(JSON.stringify({ app: 'supportdesk', org: B, exp: NOW + 300 })).toString('base64url');
  const good = scoped();
  const cases = [
    [scoped({ exp: NOW - 60 }), /expired/],
    [scoped({ exp: NOW + 901 + 60 }), /at most 15 minutes/],
    // Its organization changed, its mac kept.
    [`v1.${payload}.${good.split('.')[2]}`, /^this token for one organization was not made with the token of an app this service is bound to: /],
    // Made with an old token: one from before the service was installed again.
    [scoped({ with: 'c'.repeat(64) }), /installed again/],
    // Of another app, on the page of this one.
    [scoped({ app: 'ledger' }), /a page of supportdesk reads with a token for one of supportdesk's organizations/],
    // Of an app it is not bound to with a token: said as one not made
    // with the token, so that nobody learns which apps are bound.
    [scoped({ app: 'nowhere' }), /^this token for one organization was not made with the token of an app this service is bound to: /],
    [scoped({ org: '../../x' }), /not one/],
    ['v1.' + Buffer.from('{').toString('base64url') + '.x', /not one/],
    ['v2.a.b', /token|key/],
  ];
  for (const [given, why] of cases) {
    const said = await whoAsks({ originApp: 'supportdesk', browser: true, given, key, tokens, now });
    assert.equal(said.refuse, 401, given);
    assert.match(said.error, why, `${given}: ${said.error}`);
  }
});

test("a token's mac is taken in one spelling alone", async () => {
  const good = scoped();
  const mac = good.split('.')[2];
  // Its last character carries two bits that are always naught; another
  // that differs in those alone reads as the same bytes, and is refused.
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  const last = alphabet.indexOf(mac.at(-1));
  const other = `${good.slice(0, -1)}${alphabet[last + 1]}`;
  assert.deepEqual(Buffer.from(other.split('.')[2], 'base64url'), Buffer.from(mac, 'base64url'));
  const said = await whoAsks({ originApp: null, given: other, key, tokens, now });
  assert.equal(said.refuse, 401, other);
  assert.deepEqual(await whoAsks({ originApp: null, given: good, key, tokens, now }), { app: 'supportdesk', org: A });
});

test('nothing is read without a credential, from a program or from a page the node vouched for', async () => {
  for (const [originApp, given] of [
    [null, null],
    [null, 'c'.repeat(64)],
    ['supportdesk', null],
    // A vouched page with an app's token, its own or another's, or the key.
    ['supportdesk', 'a'.repeat(64)],
    ['supportdesk', 'b'.repeat(64)],
    ['supportdesk', KEY],
  ]) {
    const said = await whoAsks({ originApp, browser: originApp !== null, given, key, tokens, now });
    assert.equal(said.refuse, 401, `${originApp} ${given}`);
    assert.match(said.error, /token|key/);
  }
});

test('a token of an app that is not bound, or empty, is nobody', async () => {
  assert.equal((await whoAsks({ originApp: null, given: '', key, tokens: new Map([['x', '']]), now })).refuse, 401);
});

test('a token that is nothing here says it may be from before the service was installed again', async () => {
  const said = await whoAsks({ originApp: null, given: 'c'.repeat(64), key, tokens, now });
  assert.equal(said.refuse, 401);
  assert.match(said.error, /made before query was installed again is no longer one: the app is given its new token when it is next deployed/);
  // Nothing given at all is told only what is needed.
  assert.doesNotMatch((await whoAsks({ originApp: null, given: null, key, tokens, now })).error, /installed again/);
});
