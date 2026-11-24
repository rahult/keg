'use strict';
// The NATS server's configuration. Nothing here needs NATS; what it does
// is tested against a real server in live-auth.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const { serverConfig, readerPasswordRefused } = require('../server.js');

test('a password that could break the file is refused', () => {
  for (const password of ['', 'a"b', 'a\nb', 'short']) {
    assert.throws(() => serverConfig({ password, port: 4222, store: '/data/jetstream' }), password);
  }
});

test('a reader password is 32 characters or more, of what cannot break the file', () => {
  assert.equal(readerPasswordRefused('x'.repeat(31)), 'the reader password is shorter than 32 characters');
  assert.match(readerPasswordRefused(`${'x'.repeat(32)}"`), /not a letter, a digit/);
  assert.equal(readerPasswordRefused('0123456789abcdef0123456789abcdef'), null);
  assert.throws(() => serverConfig({ password: 'p'.repeat(48), readerPassword: 'short', port: 4222, store: '/d' }), /shorter than 32/);
});
