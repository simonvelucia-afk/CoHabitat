import test from 'node:test';
import assert from 'node:assert/strict';
import { createOutbox } from '../lib/outbox.mjs';
import { makeDb, makeConfig, makeKeypair } from './helpers.mjs';

const silence = { info() {}, warn() {} };

function context({ rpc = {}, callPeer, peer = {} } = {}) {
  const kp = makeKeypair();
  const config = makeConfig({ outboxMaxAttempts: 3 });
  const db = makeDb({
    federation_peers: [{
      id: 'peer-1', instance_id: 'immeuble-b', display_name: 'B', base_url: 'https://b',
      public_key: kp.spki, status: 'active', allow_reservations: true, allow_finance: true, ...peer,
    }],
    federation_requests: [],
  }, {
    federation_settle_outbound: () => ({ ok: true }),
    federation_defer_outbound: () => null,
    ...rpc,
  });
  const app = { callPeer: callPeer || (async () => ({ ok: true, status: 200, data: { ok: true } })) };
  return { db, config, outbox: createOutbox({ config, db, app, log: silence }) };
}

const pendingRow = (over = {}) => ({
  id: 'req-1', direction: 'outbound', status: 'pending',
  peer_id: 'peer-1', idempotency_key: 'k1', kind: 'reservation.create',
  attempts: 0, payload: { user_id: 'u1', space_id: 's1', start: 'x', end: 'y', slots: 4, cost: 8 },
  ...over,
});

test('une requete en file qui aboutit est soldee', async () => {
  const { db, outbox } = context();
  db.store.federation_requests = [pendingRow()];
  const r = await outbox.drainOnce();
  assert.equal(r.sent, 1);
  const settle = db.calls.find((c) => c[1] === 'federation_settle_outbound');
  assert.equal(settle[2].p_status, 'settled');
});

test('un pair toujours injoignable fait replanifier, pas echouer', async () => {
  const { db, outbox } = context({ callPeer: async () => { throw new Error('ECONNREFUSED'); } });
  db.store.federation_requests = [pendingRow()];
  const r = await outbox.drainOnce();
  assert.equal(r.deferred, 1);
  assert.ok(db.calls.some((c) => c[1] === 'federation_defer_outbound'));
  assert.ok(!db.calls.some((c) => c[1] === 'federation_settle_outbound'));
});

test('au bout des tentatives autorisees, l argent est rendu', async () => {
  const { db, outbox } = context({ callPeer: async () => { throw new Error('ECONNREFUSED'); } });
  db.store.federation_requests = [pendingRow({ attempts: 3 })];
  const r = await outbox.drainOnce();
  assert.equal(r.abandoned, 1);
  const settle = db.calls.find((c) => c[1] === 'federation_settle_outbound');
  assert.equal(settle[2].p_status, 'failed');
  assert.equal(settle[2].p_error, 'max_attempts');
});

test('un refus definitif du pair ne se rejoue pas', async () => {
  const { db, outbox } = context({
    callPeer: async () => ({ ok: false, status: 409, data: { ok: false, error: 'space_unavailable' } }),
  });
  db.store.federation_requests = [pendingRow()];
  const r = await outbox.drainOnce();
  assert.equal(r.abandoned, 1);
  const settle = db.calls.find((c) => c[1] === 'federation_settle_outbound');
  assert.equal(settle[2].p_error, 'space_unavailable');
});

test('une erreur serveur du pair est reessayee plus tard', async () => {
  const { db, outbox } = context({ callPeer: async () => ({ ok: false, status: 503, data: null }) });
  db.store.federation_requests = [pendingRow()];
  const r = await outbox.drainOnce();
  assert.equal(r.deferred, 1);
});

test('un pair desactive entre-temps libere la retenue', async () => {
  const { db, outbox } = context({ peer: { status: 'revoked' } });
  db.store.federation_requests = [pendingRow()];
  const r = await outbox.drainOnce();
  assert.equal(r.abandoned, 1);
  const settle = db.calls.find((c) => c[1] === 'federation_settle_outbound');
  assert.equal(settle[2].p_error, 'peer_inactive');
});

test('le recul entre tentatives croit puis se plafonne a 30 min', async () => {
  const { db, outbox } = context();
  await outbox.defer({ id: 'r', attempts: 0 }, 'test');
  await outbox.defer({ id: 'r', attempts: 3 }, 'test');
  await outbox.defer({ id: 'r', attempts: 20 }, 'test');
  const delais = db.calls.filter((c) => c[1] === 'federation_defer_outbound').map((c) => c[2].p_delay);
  assert.deepEqual(delais, ['00:00:30', '00:04:00', '00:30:00']);
});
