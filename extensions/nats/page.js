'use strict';
// The service's page, on port 8222: the last events it published, and how
// many. It is answered only for a name of this computer, so a site that
// points a name of its own here cannot read it from a browser. What it
// published is had only with the reader password: anything on this node's
// network can reach the port, a coding agent's machine among them, and a
// Host header stops a browser, never a program. The page asks for the
// password, keeps it in the page alone while it is open, and asks with it.

const crypto = require('node:crypto');
const { hostAllowed } = require('./vendor/keg-node/node.js');
const { SET_IT } = require('./readers.js');
const { readerPasswordRefused } = require('./server.js');

function escape(text) {
  return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

/** Whether `given` is `password`, in a time that does not say how much of it is. */
function same(given, password) {
  const a = crypto.createHash('sha256').update(String(given)).digest();
  const b = crypto.createHash('sha256').update(String(password)).digest();
  return crypto.timingSafeEqual(a, b) && given === password;
}

function send(res, status, body) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(JSON.stringify(body));
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>NATS</title></head>
<body>
<h1>NATS</h1>
<p><label>Reader password <input id="password" type="password" autocomplete="off"></label>
<button id="show">Show</button> (set with <code>${escape(SET_IT)}</code>; kept on this page only until it is closed)</p>
<p id="said"></p>
<table id="published"></table>
<script>
const said = document.getElementById('said');
const table = document.getElementById('published');
function row(cells, tag) {
  const tr = document.createElement('tr');
  for (const cell of cells) {
    const td = document.createElement(tag);
    td.textContent = String(cell);
    tr.appendChild(td);
  }
  return tr;
}
document.getElementById('show').addEventListener('click', async () => {
  said.textContent = 'Asking...';
  table.replaceChildren();
  try {
    const res = await fetch('/published', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + document.getElementById('password').value, 'X-Keg-Nats': '1' },
    });
    const body = await res.json();
    if (!res.ok) { said.textContent = body.error; return; }
    said.textContent = (body.notice ? body.notice + ' ' : '') + body.count + ' events published since it started. The stream ' + body.stream + ' holds ' + body.held + '.';
    table.appendChild(row(['Seq', 'NATS subject', 'Type', 'About', 'At'], 'th'));
    for (const p of body.published) table.appendChild(row([p.seq, p.subject, p.type, p.about, new Date(p.at * 1000).toISOString()], 'td'));
  } catch (error) {
    said.textContent = 'The service did not answer: ' + error.message;
  }
});
</script>
</body></html>
`;

/**
 * What answers a request to the page. `state.published` is the last
 * published, oldest first; `state.count()` how many since it started;
 * `state.held()` what the stream holds, said as text; `state.password()`
 * the reader password, or null while none is set.
 * @param {{ stream: string, published: any[], count: () => number, held: () => Promise<string>, password: () => Promise<string | null>, notice?: () => string }} state
 */
function pageHandler(state) {
  const clock = state.clock || Date.now;
  const sourceOf = state.source || ((req) => String(req.socket.remoteAddress));
  // Wrong guesses, from each source and in all: three from one source,
  // and it waits a minute, then twice as long each time, at most fifteen;
  // twenty in a minute from anywhere, and everyone waits a minute.
  const guesses = new Map();
  let recent = [];
  let allUntil = 0;
  const waitOf = (source, now) => {
    const one = guesses.get(source);
    return Math.max(one ? one.until - now : 0, allUntil - now, 0);
  };
  const wrong = (source, now) => {
    const one = guesses.get(source) || { count: 0, until: 0 };
    one.count += 1;
    if (one.count >= 3) one.until = now + Math.min(60000 * 2 ** (one.count - 3), 900000);
    guesses.delete(source);
    guesses.set(source, one);
    if (guesses.size > 1000) guesses.delete(guesses.keys().next().value);
    recent = recent.filter((at) => now - at < 60000);
    recent.push(now);
    if (recent.length >= 20) allUntil = now + 60000;
  };
  return async (req, res) => {
    if (!hostAllowed(req.headers.host)) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Only names of this computer are answered.\n');
      return;
    }
    const path = new URL(req.url || '/', 'http://localhost').pathname;
    if (req.method === 'GET' && path === '/') {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'",
        'X-Frame-Options': 'DENY',
      });
      res.end(PAGE);
      return;
    }
    if (path !== '/published') return send(res, 404, { error: 'not here' });
    if (req.method !== 'POST') return send(res, 405, { error: 'what was published is had with POST' });
    const site = req.headers['sec-fetch-site'];
    if (site !== undefined && site !== 'same-origin' && site !== 'none') {
      return send(res, 403, { error: "a request another site's page made is not answered" });
    }
    if (req.headers['x-keg-nats'] !== '1') return send(res, 400, { error: 'ask with the header X-Keg-Nats: 1' });
    let password = null;
    try {
      password = await state.password();
    } catch {
      // Not known: nobody is let in.
    }
    if (!password) return send(res, 401, { error: `no reader password is set: a person sets one with \`${SET_IT}\`` });
    // As the server holds readers to it: one it refuses lets nobody in.
    const refused = readerPasswordRefused(password);
    if (refused) return send(res, 401, { error: `the reader password set cannot be used (${refused}): a person sets another with \`${SET_IT}\`` });
    const source = sourceOf(req);
    const now = clock();
    const wait = waitOf(source, now);
    if (wait > 0) {
      const seconds = Math.ceil(wait / 1000);
      res.setHeader('Retry-After', String(seconds));
      return send(res, 429, { error: `too many wrong passwords; ask again in ${seconds} seconds` });
    }
    const given = String(req.headers.authorization || '').replace(/^Bearer /, '');
    if (!same(given, password)) {
      wrong(source, now);
      return send(res, 401, { error: 'the reader password is asked for' });
    }
    guesses.delete(source);
    let held = '?';
    try {
      held = await state.held();
    } catch {
      // Said as not known.
    }
    send(res, 200, {
      stream: state.stream,
      count: state.count(),
      held,
      notice: state.notice ? state.notice() : '',
      published: state.published.slice().reverse(),
    });
  };
}

module.exports = { pageHandler, escape };
