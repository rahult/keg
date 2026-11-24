'use strict';
// Who this service answers.
//
// It is reached on this computer only. A browser is answered only for a
// name of this computer, so a site that points a name of its own here is
// not. A page of an app this service is bound to may read what it
// answers, and is answered from that app's events alone; a page of
// anything else may not read it. Which pages are an app's the node says,
// with each binding: the exact origins of the names it serves for that
// app's services, on the ports it serves names on. A name like the app's,
// or the app's on another port, is not the app's: anything on this
// computer may listen on a port, and a browser sends every `*.localhost`
// here.

const { hostAllowed } = require('./vendor/keg-node/node.js');

/** An app's name as Keg gives it. Nothing else is ever put in a file name. */
const APP_NAME = /^[a-z][a-z0-9-]{0,62}$/;

/**
 * The app of `apps` whose page `origin` is, or null.
 * @param {string | undefined} origin
 * @param {Map<string, string[]>} apps each bound app, with its origins
 */
function appOf(origin, apps) {
  if (typeof origin !== 'string') return null;
  for (const [app, origins] of apps) {
    if (APP_NAME.test(app) && origins.includes(origin)) return app;
  }
  return null;
}

const refused = (status, error, cors = {}) => ({ kind: 'refuse', status, error, cors });

/**
 * What is done with a request: `{ kind: 'page' | 'query' | 'preflight',
 * app, cors }`, or `{ kind: 'refuse', status, error, cors }`.
 *
 * A query is a POST of JSON with the header `X-Keg-Query: 1`, which no
 * page of another site can send without asking first (a preflight), and
 * only a bound app's page is let past that. A request whose
 * `Sec-Fetch-Site` says another site's page made it is refused, whether
 * or not it has an `Origin`: a browser sends none for an image, a script,
 * a link or a frame. What a person opens, or a program asks, has neither.
 * @param {{ method: string, path: string, headers: Record<string, string | undefined> }} req
 * @param {Map<string, string[]>} apps
 */
function admitted({ method, path, headers }, apps) {
  if (!hostAllowed(headers.host)) return refused(403, 'only names of this computer are answered');
  const origin = headers.origin;
  const own = origin === undefined || [`http://${headers.host}`, `https://${headers.host}`].includes(origin);
  const app = own ? null : appOf(origin, apps);
  if (!own && !app) return refused(403, 'a page of another site may not read this');
  const cors = app ? { 'Access-Control-Allow-Origin': origin } : {};
  const site = headers['sec-fetch-site'];
  if (!app && site !== undefined && site !== 'same-origin' && site !== 'none') {
    return refused(403, "a request another site's page made is not answered");
  }
  if (method === 'OPTIONS') {
    if (!app) return refused(405, 'only a page of an app this service is bound to asks first');
    return {
      kind: 'preflight',
      app,
      cors: {
        ...cors,
        'Access-Control-Allow-Methods': 'POST',
        'Access-Control-Allow-Headers': 'authorization, content-type, x-keg-query',
        'Access-Control-Max-Age': '600',
      },
    };
  }
  if (path === '/' && own) {
    return method === 'GET' ? { kind: 'page', app: null, cors } : refused(405, 'the page is had with GET');
  }
  if (path !== '/query') return refused(404, 'not here', cors);
  if (method !== 'POST') return refused(405, 'a query is sent with POST', cors);
  if (headers['x-keg-query'] !== '1') return refused(400, 'a query is sent with the header X-Keg-Query: 1', cors);
  if (!/^application\/json(\s*;.*)?$/i.test(String(headers['content-type'] ?? ''))) {
    return refused(415, 'a query is sent as JSON: {"sql": "..."}', cors);
  }
  return { kind: 'query', app, cors };
}

module.exports = { appOf, admitted, hostAllowed, APP_NAME };
