'use strict';
// What is asked of the node again: each minute, and at once when a request
// is refused for want of what it holds (an origin or a token the service
// has not been told of yet), but not more than once in `minMs`.

/**
 * `again()` asks with `ask` and gives what it said, or null when it was
 * asked too lately, or is being asked now.
 */
function refresher(ask, { minMs = 5000, now = Date.now } = {}) {
  let last = -Infinity;
  let asking = false;
  return {
    async again() {
      if (asking || now() - last < minMs) return null;
      asking = true;
      last = now();
      try {
        return await ask();
      } finally {
        asking = false;
      }
    },
  };
}

module.exports = { refresher };
