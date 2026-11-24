'use strict';
// How the readers' password is kept to what a person set.

const test = require('node:test');
const assert = require('node:assert/strict');
const { keepReaders } = require('../readers.js');

test('readers are let in only with a password a person set that can be one, and told why not', async () => {
  let given = null;
  const applied = [];
  const said = [];
  const keeper = keepReaders({ ask: async () => given, apply: async (p) => applied.push(p), say: (s) => said.push(s) });
  await keeper.check();
  assert.deepEqual(applied, [null]);
  assert.match(keeper.notice(), /every reader is refused: a person sets one with `keg system secret nats READER_PASSWORD`/);
  given = 'short';
  await keeper.check();
  assert.deepEqual(applied, [null, null]);
  assert.match(keeper.notice(), /cannot be used \(the reader password is shorter than 32 characters\)/);
  given = 'k'.repeat(40);
  await keeper.check();
  await keeper.check();
  assert.deepEqual(applied, [null, null, 'k'.repeat(40)]);
  assert.equal(keeper.notice(), null);
  // The password is in nothing it says.
  assert.ok(said.every((s) => !s.includes('k'.repeat(40))), said.join('\n'));
});
