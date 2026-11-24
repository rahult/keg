'use strict';
// The key that reads everything the service holds. Nothing here needs
// DuckDB.

const test = require('node:test');
const assert = require('node:assert/strict');
const { KegError } = require('../vendor/keg-node/node.js');
const { keyHolder, keyGiven } = require('../key.js');

test('the key is read from an Authorization header, as a bearer', () => {
  assert.equal(keyGiven('Bearer abc'), 'abc');
  assert.equal(keyGiven('bearer abc'), 'abc');
  for (const header of [undefined, '', 'Basic abc', 'Bearer', 'Bearer ', 'abc']) assert.equal(keyGiven(header), null, header);
});

test('the key is asked of the node, kept a little while, and compared as a whole', async () => {
  let asked = 0;
  let value = 's3cret-key-of-some-length-0123456789';
  const node = {
    async binding(name) {
      assert.equal(name, 'key');
      asked += 1;
      if (value === null) throw new KegError('not_found', 'the secret QUERY_KEY of query is not set');
      return { kind: 'secret', value };
    },
  };
  let now = 0;
  const key = keyHolder(node, { ms: 10000, now: () => now });
  assert.equal(await key.matches('s3cret-key-of-some-length-0123456789'), true);
  for (const wrong of ['s3cret-key-of-some-length-0123456789X', 's3cret', '', null, 's3cret-key-of-some-length-0123456789-and-more']) {
    assert.equal(await key.matches(wrong), false, String(wrong));
  }
  assert.equal(asked, 1);
  // A key set again is the key once what was kept is old.
  value = 'another-key-of-some-length-0123456789';
  now = 10001;
  assert.equal(await key.matches('another-key-of-some-length-0123456789'), true);
  assert.equal(asked, 2);
  // A key not set matches nothing, and is said to be not set.
  value = null;
  now = 20002;
  assert.equal(await key.matches('another-key-of-some-length-0123456789'), false);
  assert.equal(await key.set(), false);
});

test('a key shorter than 32 characters is no key, and is said to be too short', async () => {
  const node = { binding: async () => ({ kind: 'secret', value: 'short-key' }) };
  const key = keyHolder(node);
  assert.equal(await key.matches('short-key'), false);
  assert.equal(await key.set(), false);
  assert.equal(await key.why(), 'the key set is shorter than 32 characters, so it reads nothing: a person sets another with `keg system secret query QUERY_KEY`');
});
