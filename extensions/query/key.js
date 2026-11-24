'use strict';
// The key that reads everything the service holds: a secret a person sets
// for it (`keg system secret query QUERY_KEY`), bound to it as `key`. It
// is asked of the node, kept here a little while, never logged, and
// compared in a time that does not depend on how much of it was right.

const crypto = require('node:crypto');
const { KegError } = require('./vendor/keg-node/node.js');

/** The key an `Authorization: Bearer <key>` header gives, or null. */
function keyGiven(header) {
  const m = /^Bearer (\S+)$/i.exec(String(header ?? ''));
  return m ? m[1] : null;
}

const digest = (text) => crypto.createHash('sha256').update(String(text)).digest();

/**
 * The key, asked of `node` again once what was kept is `ms` old.
 * `matches(given)` says whether `given` is it; a key not set matches
 * nothing.
 */
/** The least a key has. */
const KEY_LEAST = 32;

function keyHolder(node, { ms = 10000, now = Date.now } = {}) {
  let kept = null;
  let short = false;
  let at = -Infinity;
  const read = async () => {
    if (now() - at <= ms) return kept;
    let value = null;
    try {
      const bound = await node.binding('key');
      value = bound && bound.kind === 'secret' && typeof bound.value === 'string' && bound.value ? bound.value : null;
    } catch (error) {
      // Not set, or not allowed: no key. Anything else is said again.
      if (!(error instanceof KegError)) throw error;
    }
    // One too short to be a key is none.
    short = value !== null && value.length < KEY_LEAST;
    kept = short ? null : value;
    at = now();
    return kept;
  };
  return {
    /** Why no key reads anything, when none does; null when one is set. */
    async why() {
      if ((await read()) !== null) return null;
      return short
        ? `the key set is shorter than ${KEY_LEAST} characters, so it reads nothing: a person sets another with \`keg system secret query QUERY_KEY\``
        : 'no key is set: a person sets one with `keg system secret query QUERY_KEY`';
    },
    async set() {
      return (await read()) !== null;
    },
    async matches(given) {
      const key = await read();
      if (key === null || typeof given !== 'string' || !given) return false;
      return crypto.timingSafeEqual(digest(given), digest(key));
    },
  };
}

module.exports = { keyHolder, keyGiven };
