'use strict';
// Keeps each event the node tells this service of in DuckDB, in the table
// `events` of /data/events.duckdb, and answers SQL that only reads, on
// port 8224: a POST to `/query` of `{"sql": ...}` answers JSON, and its
// page takes a query and shows the answer as a table.
//
// Each app it is bound to has a database of its own beside it, of that
// app's events alone, and a page of that app is answered from it and from
// nothing else.
//
// Events are kept by the databases' process (db.js), which answers no
// query. A query is answered by a reader (reader.js), a process of its
// own, from a copy of the database it reads that the databases' process
// made a moment before: a reader that runs past its time is killed, and
// nothing else is.

const http = require('node:http');
const { connectNode, KegError } = require('./vendor/keg-node/node.js');
const { ROWS, MS, DAYS, MAIN_BYTES, MAIN_BUDGET, APP_BYTES } = require('./store.js');
const { startStore, DOWN } = require('./worker.js');
const { readers } = require('./readers.js');
const { gate, rate } = require('./gate.js');
const { keyHolder, keyGiven } = require('./key.js');
const { admitted, APP_NAME } = require('./reach.js');
const { whoAsks } = require('./who.js');
const { refresher } = require('./refresh.js');

const PORT = 8224;
const DATA = '/data';
/** Its manifest's bindings that are an app's events. */
const APP_BINDINGS = ['tickets', 'ratings'];
/**
 * How many queries run at once in all, each in a reader of its own, and
 * one for each organization of each app (and one for the key, one for each
 * app's own token); one more is answered 429.
 */
const RUNNING = 4;
/** How many queries a token for one organization may ask in a minute. */
const ORG_ASKS = 20;
/** How often the node is asked again which pages are each app's. */
const ORIGINS_MS = 60000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * The apps this service is bound to, asked of the node, each with the
 * origins of its pages and the token the node gave its servers for this
 * service: a binding a person did not allow is not there, and is left out.
 * @returns {Promise<Map<string, { origins: string[], token: string }>>}
 */
async function boundApps(node) {
  const apps = new Map();
  for (const name of APP_BINDINGS) {
    for (;;) {
      try {
        const bound = await node.binding(name);
        if (bound && bound.kind === 'app-events' && APP_NAME.test(String(bound.app))) {
          const origins = Array.isArray(bound.origins) ? bound.origins.filter((o) => typeof o === 'string') : [];
          // Its manifest asks for a token for each app it is bound to.
          const token = typeof bound.token === 'string' ? bound.token : '';
          const had = apps.get(bound.app);
          apps.set(bound.app, { origins: [...(had ? had.origins : []), ...origins], token: token || (had ? had.token : '') });
        }
        break;
      } catch (error) {
        if (error instanceof KegError) break;
        // The node is not answering yet.
        console.error(`query: waiting for the node: ${error.message}`);
        await sleep(1000);
      }
    }
  }
  return apps;
}

/** Each bound app's origins alone, as `admitted` takes them. */
const originsOf = (bound) => new Map([...bound].map(([app, { origins }]) => [app, origins]));
/** Each bound app's token. */
const tokensOf = (bound) => new Map([...bound].map(([app, { token }]) => [app, token]));

/** The most a query's request may hold. */
const ASKED_BYTES = 64 * 1024;

/** The SQL a request's JSON body asks, or null if it is not one. */
function sqlOf(req) {
  return new Promise((resolve) => {
    let text = '';
    let over = false;
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      text += chunk;
      if (text.length > ASKED_BYTES) {
        over = true;
        req.destroy();
        resolve(null);
      }
    });
    req.on('end', () => {
      if (over) return;
      try {
        const body = JSON.parse(text);
        resolve(body && typeof body.sql === 'string' ? body.sql : null);
      } catch {
        resolve(null);
      }
    });
    req.on('error', () => resolve(null));
  });
}

/** `text` as it goes in HTML. */
function escaped(text) {
  return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    Vary: 'Origin',
    ...headers,
  });
  res.end(JSON.stringify(body));
}

/** The page, with what a person should know. */
const page = (notices) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Query</title>
<style>
body { font: 14px system-ui, sans-serif; margin: 2rem; }
textarea { width: 100%; height: 8rem; font: 13px ui-monospace, monospace; }
table { border-collapse: collapse; margin-top: 1rem; }
th, td { border: 1px solid #ccc; padding: 0.2rem 0.5rem; text-align: left; font: 13px ui-monospace, monospace; }
#said { margin-top: 1rem; }
.notice { color: #a00; }
</style></head>
<body>
<h1>Query</h1>
${notices.map((n) => `<p class="notice">${escaped(n)}</p>`).join('\n')}
<p>What this service has heard is in the table <code>events</code>: id, cursor, type, subject, "at", actor_role, actor_name, payload. Write <code>"at"</code> in quotes. Only a query that reads is answered, at most ${ROWS} rows (fewer of wide columns) and 100 columns, each value that is not a number or a time cut at 4 KiB, for at most ${MS / 1000} seconds. It is answered from a copy of what is kept, made at most a few seconds before: the answer says as of when.</p>
<p>It keeps ${DAYS} days of events, and at most ${MAIN_BYTES / 1048576} MiB of them: ${MAIN_BUDGET.node / 1048576} MiB of the node's own and ${MAIN_BUDGET.app / 1048576} MiB of apps', each apart (an app's own database, ${APP_BYTES / 1048576} MiB); the oldest go first.</p>
<p><label>Key <input id="key" type="password" autocomplete="off"></label> (set with <code>keg system secret query QUERY_KEY</code>; kept on this page only until it is closed)</p>
<textarea id="sql">SELECT type, count(*) AS n FROM events GROUP BY type ORDER BY type</textarea>
<p><button id="ask">Ask</button></p>
<div id="said"></div>
<table id="answer"></table>
<script>
const said = document.getElementById('said');
const table = document.getElementById('answer');
function row(cells, tag) {
  const tr = document.createElement('tr');
  for (const cell of cells) {
    const td = document.createElement(tag);
    td.textContent = cell === null ? 'null' : typeof cell === 'object' ? JSON.stringify(cell) : String(cell);
    tr.appendChild(td);
  }
  return tr;
}
document.getElementById('ask').addEventListener('click', async () => {
  said.textContent = 'Asking...';
  table.replaceChildren();
  try {
    const res = await fetch('/query', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + document.getElementById('key').value,
        'Content-Type': 'application/json',
        'X-Keg-Query': '1',
      },
      body: JSON.stringify({ sql: document.getElementById('sql').value }),
    });
    const body = await res.json();
    if (!res.ok) { said.textContent = body.error; return; }
    said.textContent = body.rows.length + ' rows' + (body.cut ? ', and more not shown' : '') + ', as of ' + body.as_of + '.';
    table.appendChild(row(body.columns, 'th'));
    for (const r of body.rows) table.appendChild(row(r, 'td'));
  } catch (error) {
    said.textContent = 'The service did not answer: ' + error.message;
  }
});
</script>
</body></html>
`;

async function main() {
  const node = connectNode();
  let bound = await boundApps(node);
  // The databases, in a process of their own that no query reaches; the
  // queries, in readers of their own.
  const store = startStore({ dir: DATA, apps: [...bound.keys()] });
  await store.ready();
  const reading = readers({ most: RUNNING });
  const apps = new Set(bound.keys());
  const queries = gate(RUNNING);
  const orgAsks = rate({ most: ORG_ASKS, ms: 60000 });
  const key = keyHolder(node);
  // Which pages are an app's, and its token, can change as it is deployed
  // and as the service is installed again: asked again each minute, and
  // at once (not more than once in five seconds) when a request is
  // refused for want of an origin or a token the service was not told of.
  const fresh = refresher(async () => {
    const now = await boundApps(node);
    bound = new Map([...now].filter(([app]) => apps.has(app)));
    return bound;
  });
  setInterval(() => fresh.again().catch(() => {}), ORIGINS_MS).unref();

  http
    .createServer(async (req, res) => {
      // What lets a page of a bound app read the answer, its errors too.
      let allow = {};
      try {
        const asked = { method: req.method, path: new URL(req.url || '/', 'http://localhost').pathname, headers: req.headers };
        let said = admitted(asked, originsOf(bound));
        // A page the node may have vouched for since: asked again.
        if (said.kind === 'refuse' && said.status === 403 && req.headers.origin && (await fresh.again())) {
          said = admitted(asked, originsOf(bound));
        }
        allow = said.cors;
        if (said.kind === 'refuse') {
          send(res, said.status, { error: said.error }, allow);
          return;
        }
        if (said.kind === 'preflight') {
          res.writeHead(204, { ...allow, Vary: 'Origin' });
          res.end();
          return;
        }
        if (said.kind === 'page') {
          res.writeHead(200, {
            'Content-Type': 'text/html; charset=utf-8',
            'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'",
            'X-Frame-Options': 'DENY',
            'X-Content-Type-Options': 'nosniff',
          });
          res.end(page(store.notices()));
          return;
        }
        // Nothing is read, and nothing reaches the databases' process,
        // without a credential: the key for all of it, an app's token for
        // that app's events alone (a page of the app sends it too).
        const given = keyGiven(req.headers.authorization);
        // Whether a browser made it: an app's own token is never taken then.
        const site = req.headers['sec-fetch-site'];
        const browser = req.headers.origin !== undefined || (site !== undefined && site !== 'none');
        const asks = () => whoAsks({ originApp: said.app, browser, given, key, tokens: tokensOf(bound) });
        let who = await asks();
        // A token the node may have made since: asked again.
        if (who.refuse && given && (await fresh.again())) who = await asks();
        if (who.refuse) {
          send(res, who.refuse, { error: who.error }, { ...allow, 'WWW-Authenticate': 'Bearer' });
          return;
        }
        // An app's token is answered from that app's events alone, and a
        // token for one organization from that organization's alone.
        const { app, org } = who;
        const sql = await sqlOf(req);
        if (sql === null) {
          send(res, 400, { error: 'a query is sent as JSON, {"sql": "..."}, of at most 64 KiB' }, allow);
          return;
        }
        // While the databases are being started again, nothing is asked
        // of them: said so, and not as too many queries.
        if (store.down()) {
          send(res, 503, { error: DOWN }, { ...allow, 'Retry-After': '2' });
          return;
        }
        // A token for one organization asks at most so often: its users
        // cannot keep the others' from being answered.
        if (org) {
          const wait = orgAsks.take(`${app}/${org}`);
          if (wait > 0) {
            const seconds = Math.ceil(wait / 1000);
            send(res, 429, { error: `this organization asked ${ORG_ASKS} queries in the last minute, the most it may; ask again in ${seconds} seconds` }, { ...allow, 'Retry-After': String(seconds) });
            return;
          }
        }
        // From a copy of what it reads, made at most a few seconds before:
        // the answer says as of when.
        const ran = await queries.run(async () => {
          const copy = await store.snapshot(app, org);
          const value = await reading.answer(copy.file, sql);
          return { ...value, as_of: new Date(copy.asOf).toISOString() };
        }, `${app || ''}/${org || ''}`);
        if (ran.busy === 'all') send(res, 429, { error: `${RUNNING} queries are running; ask again soon` }, { ...allow, 'Retry-After': '1' });
        else if (ran.busy === 'one') send(res, 429, { error: 'a query of this one is running already; ask again once it is answered' }, { ...allow, 'Retry-After': '1' });
        else send(res, 200, ran.value, allow);
      } catch (error) {
        const status = error && error.down ? 503 : error && error.refused ? 400 : 500;
        send(res, status, { error: String(error && error.message ? error.message : error) }, allow);
      }
    })
    .listen(PORT, '0.0.0.0');

  const watching = node.watch((event) => store.keep(event));
  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, async () => {
      await watching.stop();
      await reading.close();
      await store.close();
      process.exit(0);
    });
  }
  console.log(`query: answering on ${PORT}; bound to ${bound.size ? [...bound.keys()].join(', ') : 'no app'}`);
}

main().catch((error) => {
  console.error(`query: ${error.message}`);
  process.exit(1);
});
