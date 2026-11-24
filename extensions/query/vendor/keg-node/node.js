'use strict';
// @keg/app/node: a service's side of the node's events.
//
// A service that Keg runs, and that a person allowed events:take, is told
// of what it listens for through deliveries: it claims them, holds them
// while it works, and finishes or fails each. Only the node decides what a
// service is told of. This speaks HTTP over the node's Unix socket, with
// nothing but Node's own modules.

const http = require('node:http');
const { KegError } = require('./error.js');

/** How long a claim waits for a delivery, in milliseconds. The node's most. */
const WAIT_MS = 20000;

/** How long each extend holds a delivery from now, in seconds. */
const HOLD_SECONDS = 60;

/**
 * One request to the node. Resolves with what it answered, or rejects with
 * a KegError carrying the node's code.
 * @param {string} socket
 * @param {string} method
 * @param {string} path
 * @param {unknown} [body]
 * @param {AbortSignal} [signal]
 */
function call(socket, method, path, body, signal) {
  const text = body === undefined ? '' : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        socketPath: socket,
        method,
        path,
        signal,
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text) },
      },
      (res) => {
        let said = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          said += chunk;
        });
        res.on('error', reject);
        res.on('end', () => {
          let answer = null;
          try {
            answer = said ? JSON.parse(said) : null;
          } catch {
            // Not JSON: told as it is below.
          }
          const status = res.statusCode || 0;
          if (status >= 200 && status < 300) {
            resolve(answer);
            return;
          }
          const error = answer && answer.error;
          reject(
            new KegError(
              (error && error.code) || 'unexpected',
              (error && error.message) || `the node answered ${status}`,
            ),
          );
        });
      },
    );
    req.on('error', reject);
    req.end(text);
  });
}

/** @param {unknown} error */
function said(error) {
  return error instanceof Error ? error.message : String(error);
}

/**
 * The node, on the socket Keg gave this service: `socket`, or
 * $KEG_SOCKET, or /run/keg/kegd.sock.
 * @param {string} [socket]
 */
function connectNode(socket = process.env.KEG_SOCKET || '/run/keg/kegd.sock') {
  /** @param {string | number} id */
  const at = (id, what) => `/v1/deliveries/${encodeURIComponent(String(id))}/${what}`;
  /** @param {AbortSignal} [signal] */
  const claim = async (options = {}, signal) =>
    (await call(socket, 'POST', '/v1/deliveries/claim', { max: options.max ?? 1, wait: options.waitMs ?? WAIT_MS }, signal)) ||
    [];
  const extend = async (/** @type {number} */ id, /** @type {string} */ token, seconds = HOLD_SECONDS) => {
    const held = await call(socket, 'POST', at(id, 'extend'), { token, seconds });
    if (!held || typeof held.held_until !== 'number') {
      throw new KegError('unexpected', 'the node did not say until when the delivery is held');
    }
    return held.held_until;
  };
  const finish = async (/** @type {number} */ id, /** @type {string} */ token, result = {}) => {
    await call(socket, 'POST', at(id, 'finish'), { token, result: result ?? {} });
  };
  const fail = async (/** @type {number} */ id, /** @type {string} */ token, /** @type {string} */ error) => {
    await call(socket, 'POST', at(id, 'fail'), { token, error });
  };

  /**
   * Waits `ms`, or less if `signal` is aborted first. The listener goes
   * with the wait, so waits do not pile listeners on the signal.
   * @param {number} ms
   * @param {AbortSignal} signal
   */
  const rest = (ms, signal) =>
    new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        signal.removeEventListener('abort', done);
        resolve(undefined);
      };
      const timer = setTimeout(done, ms);
      signal.addEventListener('abort', done, { once: true });
    });

  /**
   * Runs the handler for one claimed delivery, extending its hold every
   * `everyMs` until it returns, then finishes or fails it. Every extend
   * still on its way is waited for first, so none arrives after the finish.
   * @param {any} delivery
   * @param {Function} handler
   * @param {number} everyMs
   */
  async function answer(delivery, handler, everyMs) {
    const { id, token } = delivery;
    // Each extend is chained on to those before it, so waiting for the
    // last waits for them all.
    let extending = Promise.resolve();
    const keeping = setInterval(() => {
      const sent = extend(id, token).then(
        () => {},
        (error) => {
          // The hold is lost or refused; the node gives it to another try.
          console.error(`keg: delivery ${id} could not be held longer: ${said(error)}`);
          clearInterval(keeping);
        },
      );
      extending = Promise.all([extending, sent]).then(() => {});
    }, everyMs);
    let result;
    try {
      const gave = await handler(delivery.event, delivery);
      result =
        gave === undefined || gave === null || (typeof gave === 'object' && !Array.isArray(gave))
          ? { ok: gave ?? {} }
          : { error: new Error(`the handler gave back ${JSON.stringify(gave)}; a delivery is finished with an object, or nothing`) };
    } catch (error) {
      result = { error };
    } finally {
      clearInterval(keeping);
    }
    await extending;
    try {
      if ('error' in result) await fail(id, token, said(result.error));
      else await finish(id, token, result.ok);
    } catch (error) {
      console.error(`keg: delivery ${id} could not be handed back: ${said(error)}`);
    }
  }

  /**
   * Writes an event of this service's own. The type is sent bare, `heard`,
   * and the node keeps it under the service's name, as `echo.heard`. Its
   * subject is one of the service's own, beginning `echo/`.
   * @param {string} type
   * @param {string} subject
   */
  const emit = async (type, subject, payload = {}) => call(socket, 'POST', '/v1/events', { type, subject, payload });

  /**
   * Sets a timer: at `at`, in seconds since 1970, the node writes this
   * service's `type` about `subject`, once. Setting the same type and
   * subject again replaces it; a time past fires at once.
   * @param {string} type
   * @param {string} subject
   * @param {number} at
   */
  const setTimer = async (type, subject, at) => call(socket, 'PUT', '/v1/timers', { type, subject, at });
  /**
   * Unsets a timer of this service's own. Whether there was one.
   * @param {string} type
   * @param {string} subject
   */
  const unsetTimer = async (type, subject) => {
    const query = `subject=${encodeURIComponent(subject)}&type=${encodeURIComponent(type)}`;
    const said = await call(socket, 'DELETE', `/v1/timers?${query}`);
    return Boolean(said && said.removed);
  };

  /**
   * What one of this service's own bindings is, asked of the node each
   * time: `{ kind: 'volume', path }`, `{ kind: 'secret', value }`,
   * `{ kind: 'publish', port }` or `{ kind: 'app-events', app, types,
   * origins }`, `origins` being the exact origins of the app's own pages,
   * which the node serves and nothing else may. A secret is never kept
   * here; ask again when it is needed.
   * @param {string} name
   */
  const binding = async (name) => call(socket, 'GET', `/v1/bind/${encodeURIComponent(name)}`);

  return {
    claim: (options) => claim(options),
    binding,
    setTimer,
    unsetTimer,
    extend,
    finish,
    fail,
    emit,
    watch(handler, options = {}) {
      if (typeof handler !== 'function') {
        throw new TypeError('watch needs a function to run for each delivery');
      }
      const everyMs = options.extendEveryMs ?? 20000;
      const stopping = new AbortController();
      const loop = (async () => {
        while (!stopping.signal.aborted) {
          const asked = Date.now();
          let claimed;
          try {
            claimed = await claim({ max: 1 }, stopping.signal);
          } catch (error) {
            if (stopping.signal.aborted) break;
            console.error(`keg: no delivery could be claimed: ${said(error)}`);
            await rest(2000, stopping.signal);
            continue;
          }
          // Nothing, at once: the node has too many waiting. Not again at once.
          if (claimed.length === 0 && Date.now() - asked < 1000) await rest(1000, stopping.signal);
          for (const delivery of claimed) await answer(delivery, handler, everyMs);
        }
      })();
      return {
        /** Stops claiming, once the delivery being run is handed back. */
        stop: async () => {
          stopping.abort();
          await loop;
        },
      };
    },
  };
}

/**
 * Whether a request to a service's page that names `host` is answered: one
 * that names none, or a name of this computer's own (`127.0.0.1`,
 * `localhost`, `[::1]`, or a name under `.keg.localhost`), with any port. A
 * site that points a name of its own at this computer (DNS rebinding) is
 * not, so a browser cannot be led to read a page here for it.
 * @param {string | undefined} host the request's Host header
 */
function hostAllowed(host) {
  if (host === undefined) return true;
  const name = String(host)
    .toLowerCase()
    .replace(/:\d{1,5}$/, '');
  // Run for a check, the service is reached at the address the node gave
  // it there, and at no other.
  const own = process.env.KEG_ADDRESS;
  return name === '127.0.0.1' || name === 'localhost' || name === '[::1]' || name.endsWith('.keg.localhost') || (!!own && name === own);
}

module.exports = { connectNode, KegError, hostAllowed };
