'use strict';
// What a request may read, by the credential it carries, as
// `Authorization: Bearer <credential>`. Nothing is read without one, from
// a program or from a browser's page.
//
// - The service's key, which a person sets, reads all it holds.
// - An app's token, which the node made for this service and that app,
//   and gave the app's own servers, reads that app's events, of every
//   organization. It is taken only from a request no browser made (no
//   `Origin`, and no `Sec-Fetch-Site` but `none`): never from a page.
// - A token for one organization, which the app's server makes with its
//   token (`serviceToken` of @keg/app/service) for a few minutes and hands
//   its page, reads that organization's events alone. A page of an app
//   the node vouched for (by its Origin) reads with such a token of that
//   app and nothing else.

const crypto = require('node:crypto');

const digest = (text) => crypto.createHash('sha256').update(String(text)).digest();
/** Whether `given` is `kept`, in a time that does not depend on how much of it was right. */
const same = (given, kept) => typeof kept === 'string' && kept.length > 0 && crypto.timingSafeEqual(digest(given), digest(kept));

/** The longest a token for one organization may last, in seconds. */
const TTL_MAX = 900;
/** How far apart the app's clock and this one may be, in seconds. */
const SKEW = 30;
/** An organization's id, as the node writes it. Nothing else names a file. */
const ORG = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SCOPED = /^v1\.([A-Za-z0-9_-]{1,512})\.([A-Za-z0-9_-]{43})$/;

/** What a token made before the service was installed again is told. */
const STALE =
  'one made before query was installed again is no longer one: the app is given its new token when it is next deployed (keg up)';

/**
 * A token for one organization, checked: `{ app, org }`, or `{ why }`.
 * Null when `given` is not of that form at all.
 */
function scopedOf(given, tokens, nowS) {
  if (!given.startsWith('v1.')) return null;
  const m = SCOPED.exec(given);
  const notOne = { why: 'this token for one organization is not one: it is v1.<payload>.<mac>, as serviceToken of @keg/app/service makes it' };
  if (!m) return notOne;
  let said;
  try {
    said = JSON.parse(Buffer.from(m[1], 'base64url').toString('utf8'));
  } catch {
    return notOne;
  }
  if (!said || typeof said !== 'object' || Array.isArray(said)) return notOne;
  const { app, org, exp } = said;
  if (Object.keys(said).length !== 3 || typeof app !== 'string' || typeof org !== 'string' || !ORG.test(org) || !Number.isSafeInteger(exp)) {
    return notOne;
  }
  // One message whether or not the app is bound with a token: what is
  // refused says nothing of which apps are.
  const notMade = { why: `this token for one organization was not made with the token of an app this service is bound to: ${STALE}` };
  const token = tokens.get(app);
  // Made with a token of none, it is checked all the same, so that the
  // time taken says nothing either.
  const mac = crypto.createHmac('sha256', typeof token === 'string' && token ? token : crypto.randomBytes(32)).update(m[1]).digest();
  const theirs = Buffer.from(m[2], 'base64url');
  // One spelling of the mac alone: base64url's last character carries
  // bits that are always naught, and another spelling of them is refused.
  const canonical = theirs.toString('base64url') === m[2];
  if (theirs.length !== mac.length || !crypto.timingSafeEqual(theirs, mac) || !canonical || typeof token !== 'string' || !token) {
    return notMade;
  }
  if (exp < nowS - SKEW) return { why: 'this token for one organization has expired: the app makes another' };
  if (exp > nowS + TTL_MAX + SKEW) return { why: 'this token for one organization lasts more than its most: a token is made for at most 15 minutes' };
  return { app, org };
}

/**
 * `{ app, org }`, what a request may read (`app` null: all of it; `org`
 * null: all of that app's), or `{ refuse: 401, error }`. `browser` is
 * whether a browser made the request (an `Origin`, or a `Sec-Fetch-Site`
 * but `none`).
 * @param {{ originApp: string | null, browser?: boolean, given: string | null, key: { matches: (g: string | null) => Promise<boolean>, set: () => Promise<boolean>, why?: () => Promise<string | null> }, tokens: Map<string, string>, now?: () => number }} asked
 */
async function whoAsks({ originApp, browser = false, given, key, tokens, now = Date.now }) {
  const has = typeof given === 'string' && given.length > 0;
  const scoped = has ? scopedOf(given, tokens, Math.floor(now() / 1000)) : null;
  const appToken = has && !scoped ? [...tokens].find(([, token]) => same(given, token)) : undefined;
  const fromPage = (app) =>
    `an app's own token is never taken from a page: ${app}'s server makes a token for one of its organizations with it (serviceToken of @keg/app/service), and hands that to its page`;
  if (originApp) {
    if (scoped && scoped.app === originApp) return { app: scoped.app, org: scoped.org };
    if (scoped && scoped.why) return { refuse: 401, error: scoped.why };
    if (appToken) return { refuse: 401, error: fromPage(originApp) };
    return {
      refuse: 401,
      error: `a page of ${originApp} reads with a token for one of ${originApp}'s organizations, which ${originApp}'s server makes (serviceToken of @keg/app/service), as Authorization: Bearer <token>`,
    };
  }
  if (scoped) return scoped.why ? { refuse: 401, error: scoped.why } : { app: scoped.app, org: scoped.org };
  if (has && (await key.matches(given))) return { app: null, org: null };
  if (appToken) return browser ? { refuse: 401, error: fromPage(appToken[0]) } : { app: appToken[0], org: null };
  const why = key.why ? await key.why() : (await key.set()) ? null : 'no key is set: a person sets one with `keg system secret query QUERY_KEY`';
  let error = why
    ? `the key, or an app's token, is needed, and ${why}`
    : "the key, or an app's token, is needed, as Authorization: Bearer <key>";
  // One given that is nothing here may be an app's from before.
  if (has) error += `; an app's token ${STALE}`;
  return { refuse: 401, error };
}

module.exports = { whoAsks, ORG, TTL_MAX, SKEW };
