'use strict';
// The NATS server's configuration, written as the service starts.
//
// Two accounts. The service publishes the node's events in the account
// KEG, as the user `keg`, with a password made at random each time it
// starts, which is in this file alone, never in its log or on its page.
// KEG exports one thing, the events as they are published (`keg.>`), and
// imports nothing: no API, flow control or inbox of KEG's can be reached
// from the other account by any route.
//
// Readers are in the account READERS, which imports `keg.>` and keeps
// what arrives in a stream of its own, also called KEG, which the service
// makes as the user `admin` of READERS (with the same random password). A
// reader is the user `reader`, with a password a person sets; until one
// is set there is no such user, and no reader is let in. A reader may
// subscribe to anything in its account and may publish only to what
// reading the readers' stream needs: its info, its messages, and
// consumers of its own (made, read, acknowledged and removed). It cannot
// publish an event, nor make, change, purge or remove a stream. A
// consumer a reader makes, and wherever it delivers, are in READERS: at
// worst someone with the reader password damages the readers' copy, which
// the service makes again; the service's own stream and what it
// publishes cannot be touched from there.

/** The user the service publishes as, in the account KEG. */
const PUBLISHER = 'keg';
/** The user the service keeps the readers' stream as, in READERS. */
const ADMIN = 'admin';
/** The user a reader is, with the password a person sets. */
const READER = 'reader';
/**
 * Below what the service is answered: each of its connections is answered
 * under an inbox of its own made at random each start, `inboxOf()`, and
 * no reader may subscribe below it, nor publish there.
 */
const INBOX = '_KEG_INBOX';

/** An inbox for one of the service's connections, made at random. */
function inboxOf() {
  return `${INBOX}.${require('node:crypto').randomBytes(12).toString('hex')}`;
}
/** What a reader may publish to: JetStream's API for reading, and nothing more. */
const READS = [
  '$JS.API.INFO',
  '$JS.API.STREAM.NAMES',
  '$JS.API.STREAM.LIST',
  '$JS.API.STREAM.INFO.KEG',
  '$JS.API.STREAM.MSG.GET.KEG',
  '$JS.API.DIRECT.GET.KEG',
  '$JS.API.DIRECT.GET.KEG.>',
  '$JS.API.CONSUMER.CREATE.KEG',
  '$JS.API.CONSUMER.CREATE.KEG.>',
  '$JS.API.CONSUMER.DURABLE.CREATE.KEG.*',
  '$JS.API.CONSUMER.DELETE.KEG.*',
  '$JS.API.CONSUMER.INFO.KEG.*',
  '$JS.API.CONSUMER.NAMES.KEG',
  '$JS.API.CONSUMER.LIST.KEG',
  '$JS.API.CONSUMER.MSG.NEXT.KEG.*',
  '$JS.ACK.KEG.>',
  '$JS.FC.KEG.>',
];

/**
 * What JetStream may keep on the service's volume of 1 GiB: room for both
 * streams and JetStream's own files. Left to itself it would take three
 * quarters of what is free, and refuse a stream that large.
 */
const MAX_FILE_STORE = 896 * 1024 * 1024;

/**
 * What NATS takes in one message: its own default, 1 MiB, which is past
 * any event the node tells of (an app's payload is cut at 16 KiB, a
 * service's is at most 16 KiB). One larger is finished, saying so.
 */
const MAX_PAYLOAD = 1024 * 1024;
/** Connections to the server in all: the service's two and the readers'. */
const MAX_CONNECTIONS = 128;
/**
 * What all readers together may hold: connections, subscriptions, and
 * what one message they publish may carry (a request of the API, never an
 * event); and of JetStream, their one stream, and 32 consumers of it,
 * each holding at most 1000 delivered and not yet acknowledged. The
 * connections are 64 readers' and the service's own as `admin`.
 */
const READER_LIMITS = { max_connections: 65, max_subscriptions: 1000, max_payload: 64 * 1024 };
const READER_JETSTREAM = {
  max_file: 712 * 1024 * 1024,
  max_mem: 16 * 1024 * 1024,
  max_streams: 1,
  max_consumers: 32,
  max_ack_pending: 1000,
};
/** The service's own account: its stream, and no consumer. */
const KEG_JETSTREAM = { max_file: 72 * 1024 * 1024, max_mem: 0, max_streams: 1, max_consumers: 1 };

/** What a reader password is made of. */
const READER_PASSWORD = /^[A-Za-z0-9._~+/=-]{32,256}$/;

/**
 * Why `password` cannot be the readers' password, or null. It is put in
 * the server's file, so it is held to what cannot break it.
 */
function readerPasswordRefused(password) {
  if (typeof password !== 'string' || password.length < 32) return 'the reader password is shorter than 32 characters';
  if (!READER_PASSWORD.test(password)) {
    return 'the reader password is longer than 256 characters, or has a character that is not a letter, a digit or one of . _ ~ + / = -';
  }
  return null;
}

const block = (fields) => `{ ${Object.entries(fields).map(([k, v]) => `${k}: ${v}`).join(', ')} }`;

const quoted = (list) => list.map((s) => JSON.stringify(s)).join(', ');

/**
 * The server's configuration: listening on `port`, keeping JetStream in
 * `store`, the service's users with `password`, and the reader with
 * `readerPassword`, or no reader at all while it is null.
 * @param {{ password: string, readerPassword?: string | null, port: number, store: string }} options
 */
function serverConfig({ password, readerPassword = null, port, store }) {
  if (!/^[A-Za-z0-9]{32,}$/.test(String(password))) throw new Error('the password is 32 or more letters and digits');
  if (readerPassword !== null && readerPasswordRefused(readerPassword)) throw new Error(readerPasswordRefused(readerPassword));
  const reader =
    readerPassword === null
      ? ''
      : `
      { user: "${READER}", password: "${readerPassword}", permissions: {
          publish: { allow: [${quoted(READS)}] }
          subscribe: { allow: [">"], deny: [${quoted([`${INBOX}.>`, '$JS.API.>', '$SYS.>'])}] }
      } }`;
  return `listen: "0.0.0.0:${Number(port)}"
max_connections: ${MAX_CONNECTIONS}
max_payload: ${MAX_PAYLOAD}
jetstream { store_dir: ${JSON.stringify(store)}, max_file_store: ${MAX_FILE_STORE} }
accounts {
  KEG: {
    jetstream: ${block(KEG_JETSTREAM)}
    users: [ { user: "${PUBLISHER}", password: "${password}" } ]
    exports: [ { stream: "keg.>", accounts: [READERS] } ]
  }
  READERS: {
    jetstream: ${block(READER_JETSTREAM)}
    limits: ${block(READER_LIMITS)}
    users: [
      { user: "${ADMIN}", password: "${password}" }${reader}
    ]
    imports: [ { stream: { account: KEG, subject: "keg.>" } } ]
  }
}
`;
}

module.exports = {
  serverConfig,
  inboxOf,
  readerPasswordRefused,
  MAX_PAYLOAD,
  READER_LIMITS,
  READER_JETSTREAM,
  PUBLISHER,
  ADMIN,
  READER,
  INBOX,
  READS,
};
