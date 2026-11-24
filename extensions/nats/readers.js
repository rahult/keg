'use strict';
// The readers' password: a secret a person sets for the service (`keg
// system secret nats READER_PASSWORD`), bound to it as `readers`. Until it
// is set, and while what is set cannot be one, there is no reader, and
// every reader is refused. It is asked of the node again from time to
// time, never logged, never on the page.

const { KegError } = require('./vendor/keg-node/node.js');
const { readerPasswordRefused } = require('./server.js');

/** How a person sets it. */
const SET_IT = 'keg system secret nats READER_PASSWORD';

/** The password bound as `readers`, or null when none is set. */
async function readerPasswordOf(node) {
  try {
    const bound = await node.binding('readers');
    return bound && bound.kind === 'secret' && typeof bound.value === 'string' && bound.value ? bound.value : null;
  } catch (error) {
    // Not set, or not allowed: no readers. Anything else is said again.
    if (error instanceof KegError) return null;
    throw error;
  }
}

/**
 * Keeps the server's readers to the password `ask()` gives: `apply(p)`
 * puts `p` in the server (null: no reader at all) when it changes. What
 * a person should know is `notice()`, and is said with `say`.
 */
function keepReaders({ ask, apply, say = console.error }) {
  let last;
  let notice = `No reader password is set, so every reader is refused: a person sets one with \`${SET_IT}\`.`;
  return {
    notice: () => notice,
    async check() {
      const given = await ask();
      if (given === last) return;
      last = given;
      const refused = given === null ? null : readerPasswordRefused(given);
      if (given === null) {
        notice = `No reader password is set, so every reader is refused: a person sets one with \`${SET_IT}\`.`;
      } else if (refused) {
        notice = `The reader password set cannot be used (${refused}), so every reader is refused: a person sets another with \`${SET_IT}\`.`;
      } else {
        notice = null;
      }
      await apply(given === null || refused ? null : given);
      say(`nats: ${notice || 'readers connect as the user reader, with the password a person set'}`);
    },
  };
}

module.exports = { keepReaders, readerPasswordOf, SET_IT };
