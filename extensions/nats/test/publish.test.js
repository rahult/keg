'use strict';
// How an event is published, against a fake JetStream. Nothing here needs
// NATS.

const test = require('node:test');
const assert = require('node:assert/strict');
const { publisher, subjectOf } = require('../publish.js');

const event = { id: 'e1', type: 'work.changed', subject: 'work/1', at: 1795000000, payload: {} };

test("an event's type is its subject, with what NATS cannot carry as _", () => {
  assert.equal(subjectOf('work.changed'), 'keg.work.changed');
  assert.equal(subjectOf('app.supportdesk.ticket.opened'), 'keg.app.supportdesk.ticket.opened');
  assert.equal(subjectOf('a b*>'), 'keg.a_b__');
});

test('what JetStream refuses fails the delivery, and is published once it is taken', async () => {
  const sent = [];
  let refuse = true;
  const js = {
    async publish(subject, data, options) {
      sent.push({ subject, data: JSON.parse(data), msgID: options.msgID });
      if (refuse) throw new Error('maximum messages exceeded');
      return { seq: 7, duplicate: false, stream: 'KEG' };
    },
  };
  const kept = [];
  const publish = publisher(js, (p) => kept.push(p));
  // Thrown, so the node's client fails the delivery, and it is tried again.
  await assert.rejects(publish(event), /maximum messages exceeded/);
  assert.deepEqual(kept, []);
  refuse = false;
  assert.deepEqual(await publish(event), { seq: 7 });
  // Both tries carry the event's id, so JetStream keeps it once.
  assert.deepEqual(
    sent.map((s) => [s.subject, s.msgID, s.data.id]),
    [
      ['keg.work.changed', 'e1', 'e1'],
      ['keg.work.changed', 'e1', 'e1'],
    ],
  );
  assert.deepEqual(kept, [{ seq: 7, subject: 'keg.work.changed', type: 'work.changed', about: 'work/1', at: 1795000000 }]);
});

test('an answer that is not an acknowledgement fails the delivery', async () => {
  for (const ack of [undefined, null, {}, { seq: '7' }]) {
    const publish = publisher({ publish: async () => ack }, () => {});
    await assert.rejects(publish(event), /JetStream did not take e1/);
  }
});

test('an event JetStream already has is not counted or listed again', async () => {
  const kept = [];
  let duplicate = false;
  const publish = publisher({ publish: async () => ({ seq: 7, duplicate }) }, (p) => kept.push(p));
  assert.deepEqual(await publish(event), { seq: 7 });
  duplicate = true;
  assert.deepEqual(await publish(event), { seq: 7 });
  assert.equal(kept.length, 1);
});

test('an event larger than NATS takes is finished saying so, never failed for it', async () => {
  let sent = 0;
  const publish = publisher({ publish: async () => ((sent += 1), { seq: 1 }) }, () => {}, { maxPayload: 1000 });
  const big = { ...event, payload: { text: 'x'.repeat(2000) } };
  const said = await publish(big);
  assert.equal(sent, 0);
  assert.equal(said.published, false);
  assert.match(said.refused, /^not published: it is \d+ bytes, and NATS takes at most 1000$/);
  assert.deepEqual(await publish(event), { seq: 1 });
});

test("an app's event is published with its audience and what it is about, as the node told of them", async () => {
  const sent = [];
  const publish = publisher({ publish: async (subject, data) => (sent.push(JSON.parse(data)), { seq: 1 }) }, () => {});
  const told = {
    id: 'e2',
    type: 'app.supportdesk.ticket.opened',
    subject: 'app/supportdesk/e2',
    at: 1795000000,
    payload: { app: 'supportdesk', env: 'prod', type: 'ticket.opened', organization: 'o1', audience: { users: ['u1'] }, about: 'ticket/42', payload: {} },
  };
  await publish(told);
  assert.deepEqual(sent[0].payload.audience, { users: ['u1'] });
  assert.equal(sent[0].payload.about, 'ticket/42');
  await publish({ ...told, id: 'e3', payload: { ...told.payload, audience: null, about: null } });
  assert.equal(sent[1].payload.audience, null);
  assert.equal(sent[1].payload.about, null);
});
