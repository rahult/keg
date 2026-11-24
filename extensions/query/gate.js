'use strict';
// How many queries run at once: so many in all, and one for each
// organization of each app, and one more is turned away at once rather
// than kept waiting, so queries never hold up what the service is told
// of, and one organization's users cannot take every place.

/**
 * A gate that lets `running` run at once, and of those one for each key
 * given. `run(work, key)` gives `{ value }`, or `{ busy: 'all' }` past
 * `running`, or `{ busy: 'one' }` while one of that key runs.
 */
function gate(running) {
  let now = 0;
  const keys = new Set();
  return {
    async run(work, key = null) {
      if (now >= running) return { busy: 'all' };
      if (key !== null && keys.has(key)) return { busy: 'one' };
      now += 1;
      if (key !== null) keys.add(key);
      try {
        return { value: await work() };
      } finally {
        now -= 1;
        if (key !== null) keys.delete(key);
      }
    },
  };
}

/**
 * How often each key may ask: at most `most` in any `ms`. `take(key, at)`
 * counts an ask and gives 0, or, past that, how many ms until it may ask
 * again (and does not count it).
 */
function rate({ most, ms }) {
  const asked = new Map();
  return {
    take(key, at = Date.now()) {
      const recent = (asked.get(key) || []).filter((t) => t > at - ms);
      if (recent.length >= most) {
        asked.set(key, recent);
        return recent[0] + ms - at;
      }
      recent.push(at);
      asked.set(key, recent);
      // Keys that have not asked lately are forgotten.
      if (asked.size > 10000) {
        for (const [k, times] of asked) if (!times.some((t) => t > at - ms)) asked.delete(k);
      }
      return 0;
    },
  };
}

module.exports = { gate, rate };
