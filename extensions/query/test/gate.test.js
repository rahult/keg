'use strict';
// How many queries run at once, and how often one organization may ask.
// Nothing here needs DuckDB.

const test = require('node:test');
const assert = require('node:assert/strict');
const { gate, rate } = require('../gate.js');

test('so many run at once, and one more is turned away, not kept waiting', async () => {
  const queries = gate(2);
  let let1;
  let let2;
  const one = queries.run(() => new Promise((resolve) => (let1 = resolve)));
  const two = queries.run(() => new Promise((resolve) => (let2 = resolve)));
  assert.deepEqual(await queries.run(async () => 'three'), { busy: 'all' });
  let1('one');
  assert.deepEqual(await one, { value: 'one' });
  assert.deepEqual(await queries.run(async () => 'four'), { value: 'four' });
  let2('two');
  assert.deepEqual(await two, { value: 'two' });
});

test('one that fails frees its place', async () => {
  const queries = gate(1);
  await assert.rejects(queries.run(async () => {
    throw new Error('no');
  }), /no/);
  assert.deepEqual(await queries.run(async () => 1), { value: 1 });
});

test('one runs at once for each organization of each app, whatever the others run', async () => {
  const queries = gate(3);
  let done;
  const first = queries.run(() => new Promise((resolve) => (done = resolve)), 'desk/a');
  // The same organization waits its turn; another is answered.
  assert.deepEqual(await queries.run(async () => 'again', 'desk/a'), { busy: 'one' });
  assert.deepEqual(await queries.run(async () => 'other', 'desk/b'), { value: 'other' });
  done('first');
  assert.deepEqual(await first, { value: 'first' });
  assert.deepEqual(await queries.run(async () => 'now', 'desk/a'), { value: 'now' });
});

test('an organization asking more often than it may is told when to ask again', () => {
  const asks = rate({ most: 3, ms: 10000 });
  const t = 1000000;
  assert.equal(asks.take('desk/a', t), 0);
  assert.equal(asks.take('desk/a', t + 1), 0);
  assert.equal(asks.take('desk/a', t + 2), 0);
  // The fourth within ten seconds waits for the first to be ten seconds old.
  assert.equal(asks.take('desk/a', t + 3), 9997);
  // Another organization is not held to the first one's.
  assert.equal(asks.take('desk/b', t + 3), 0);
  assert.equal(asks.take('desk/a', t + 10000), 0);
});
