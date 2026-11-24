'use strict';
// How often the apps' origins and tokens are asked of the node again.

const test = require('node:test');
const assert = require('node:assert/strict');
const { refresher } = require('../refresh.js');

test('a miss asks again at once, but not more than once in a while, and two at once ask once', async () => {
  let asked = 0;
  let now = 0;
  const fresh = refresher(async () => {
    asked += 1;
    return `v${asked}`;
  }, { minMs: 5000, now: () => now });
  assert.equal(await fresh.again(), 'v1');
  // Soon after: what was had, not asked again.
  now = 1000;
  assert.equal(await fresh.again(), null);
  now = 6000;
  const [a, b] = await Promise.all([fresh.again(), fresh.again()]);
  assert.ok([a, b].includes('v2') && [a, b].includes(null), `${a} ${b}`);
  assert.equal(asked, 2);
});
