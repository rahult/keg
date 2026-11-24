'use strict';
// How each event the node tells this service of is put in the stream.

/** The subject an event of `type` is published on. */
function subjectOf(type) {
  return `keg.${String(type).replace(/[^A-Za-z0-9_.-]/g, '_')}`;
}

/**
 * What publishes an event to JetStream, as `keg.<type>`, and says the
 * place it was given. What JetStream does not take is thrown, so the
 * delivery fails and the node tries it again; the event's id is its
 * `Nats-Msg-Id`, so one tried again, or told of twice, is kept once.
 * `record` is told of each published. One larger than `maxPayload`, what
 * NATS takes, is finished saying so: it would fail every try.
 */
function publisher(js, record, { maxPayload = Infinity } = {}) {
  return async (event) => {
    const subject = subjectOf(event.type);
    const data = JSON.stringify(event);
    // One NATS could never take would fail as often as it was tried.
    const size = Buffer.byteLength(data);
    if (size > maxPayload) {
      return { published: false, refused: `not published: it is ${size} bytes, and NATS takes at most ${maxPayload}` };
    }
    const ack = await js.publish(subject, data, { msgID: event.id });
    if (!ack || typeof ack.seq !== 'number') throw new Error(`JetStream did not take ${event.id}`);
    // One it already had is where it was put the first time, and was
    // counted then.
    if (!ack.duplicate) record({ seq: ack.seq, subject, type: event.type, about: event.subject, at: event.at });
    return { seq: ack.seq };
  };
}

module.exports = { publisher, subjectOf };
