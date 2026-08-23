import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createApp } from '../lib/app.mjs';
import { signPeerToken, b64urlJson } from '../lib/jwt.mjs';
import { makeDb, makeConfig, makeKeypair } from './helpers.mjs';

// Le pair « immeuble-b » vu depuis « immeuble-a ».
function peerRow(kp, extra = {}) {
  return {
    id: 'peer-1',
    instance_id: 'immeuble-b',
    display_name: 'Immeuble B',
    base_url: 'https://10.8.0.2',
    public_key: kp.spki,
    status: 'active',
    allow_reservations: true,
    allow_finance: true,
    ...extra,
  };
}

function peerAuth(kp, { iss = 'immeuble-b', aud = 'immeuble-a' } = {}) {
  return { authorization: 'Bearer ' + signPeerToken({ iss, aud }, kp.privateKey, { kid: iss }) };
}

function localAuth(secret, sub = 'user-local-1') {
  const header = b64urlJson({ alg: 'HS256', typ: 'JWT' });
  const body = b64urlJson({ sub, role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 60 });
  const sig = createHmac('sha256', secret).update(`${header}.${body}`).digest('base64url');
  return { authorization: `Bearer ${header}.${body}.${sig}` };
}

test('/health et /identity repondent sans authentification', async () => {
  const config = makeConfig();
  const app = createApp({ config, db: makeDb() });
  assert.equal((await app.handle({ method: 'GET', path: '/federation/v1/health' })).status, 200);
  const id = await app.handle({ method: 'GET', path: '/federation/v1/identity' });
  assert.equal(id.body.instance_id, 'immeuble-a');
  assert.equal(id.body.public_key, config.publicKeyB64);
});

test('une route de pair sans jeton renvoie 401', async () => {
  const app = createApp({ config: makeConfig(), db: makeDb() });
  const res = await app.handle({ method: 'GET', path: '/federation/v1/spaces', headers: {} });
  assert.equal(res.status, 401);
});

test('un pair inconnu est refuse meme avec une signature valide', async () => {
  const kp = makeKeypair();
  const app = createApp({ config: makeConfig(), db: makeDb({ federation_peers: [] }) });
  const res = await app.handle({
    method: 'GET', path: '/federation/v1/spaces', headers: peerAuth(kp),
  });
  assert.equal(res.status, 403);
  assert.equal(res.body.error, 'unknown_peer');
});

test('un pair suspendu ne peut plus rien lire', async () => {
  const kp = makeKeypair();
  const db = makeDb({ federation_peers: [peerRow(kp, { status: 'suspended' })] });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({ method: 'GET', path: '/federation/v1/spaces', headers: peerAuth(kp) });
  assert.equal(res.body.error, 'peer_not_active');
});

test('un pair sans droit finance ne peut pas transferer', async () => {
  const kp = makeKeypair();
  const db = makeDb({ federation_peers: [peerRow(kp, { allow_finance: false })] });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/transfers', headers: peerAuth(kp),
    body: { idempotency_key: 'k1', target_email: 'x@y.z', amount: 10 },
  });
  assert.equal(res.status, 403);
  assert.equal(res.body.error, 'finance_not_allowed');
});

test('un jeton signe par une cle qui n est pas celle du pair est refuse', async () => {
  const vrai = makeKeypair();
  const faux = makeKeypair();
  const db = makeDb({ federation_peers: [peerRow(vrai)] });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({ method: 'GET', path: '/federation/v1/spaces', headers: peerAuth(faux) });
  assert.equal(res.status, 401);
  assert.equal(res.body.error, 'invalid_signature');
});

test('le catalogue ne contient que les espaces explicitement partages', async () => {
  const kp = makeKeypair();
  const db = makeDb({
    federation_peers: [peerRow(kp)],
    common_spaces: [
      { id: 's1', name: 'Atelier', federation_shared: true, is_available: true },
      { id: 's2', name: 'Buanderie privee', federation_shared: false, is_available: true },
    ],
  });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({ method: 'GET', path: '/federation/v1/spaces', headers: peerAuth(kp) });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.spaces.map((s) => s.id), ['s1']);
});

test('une reservation entrante sur un espace non partage est refusee', async () => {
  const kp = makeKeypair();
  const db = makeDb({
    federation_peers: [peerRow(kp)],
    common_spaces: [{ id: 's2', federation_shared: false, is_available: true }],
  });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/reservations', headers: peerAuth(kp),
    body: { idempotency_key: 'k', remote_user_id: 'u', space_id: 's2', start: 'x', end: 'y', slots: 4 },
  });
  assert.equal(res.status, 404);
  assert.equal(res.body.error, 'space_not_shared');
});

test('le prix annonce par le pair ne fait pas foi', async () => {
  const kp = makeKeypair();
  const db = makeDb({
    federation_peers: [peerRow(kp)],
    common_spaces: [{ id: 's1', federation_shared: true, is_available: true }],
    space_pricing: [{ space_id: 's1', price_per_slot: 3, valid_from: '2020-01-01' }],
  });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/reservations', headers: peerAuth(kp),
    body: { idempotency_key: 'k', remote_user_id: 'u', space_id: 's1',
            start: 'x', end: 'y', slots: 4, cost: 1 },   // 4 x 3 = 12, pas 1
  });
  assert.equal(res.status, 409);
  assert.equal(res.body.error, 'price_mismatch');
  assert.equal(res.body.cost, 12);
});

test('une reservation entrante conforme cree un invite puis appelle la RPC', async () => {
  const kp = makeKeypair();
  const db = makeDb({
    federation_peers: [peerRow(kp)],
    common_spaces: [{ id: 's1', federation_shared: true, is_available: true }],
    space_pricing: [{ space_id: 's1', price_per_slot: 2.5, valid_from: '2020-01-01' }],
    federation_guests: [],
    profiles: [],
  }, {
    federation_reserve_space: (args) => ({ ok: true, reservation_id: 'r1', cost: args.p_cost }),
  });
  const fetchImpl = async () => ({ ok: true, json: async () => ({ id: 'guest-uuid' }) });
  const app = createApp({ config: makeConfig(), db, fetchImpl });

  const res = await app.handle({
    method: 'POST', path: '/federation/v1/reservations', headers: peerAuth(kp),
    body: { idempotency_key: 'k', remote_user_id: 'u-distant', remote_user_name: 'Sam',
            space_id: 's1', start: 'x', end: 'y', slots: 4, cost: 10 },
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.reservation_id, 'r1');
  assert.equal(db.store.federation_guests.length, 1);
  assert.equal(db.store.federation_guests[0].remote_user_id, 'u-distant');

  // Second appel : l'invite existe deja, on ne recree pas de compte.
  await app.handle({
    method: 'POST', path: '/federation/v1/reservations', headers: peerAuth(kp),
    body: { idempotency_key: 'k2', remote_user_id: 'u-distant', space_id: 's1',
            start: 'x', end: 'y', slots: 4, cost: 10 },
  });
  assert.equal(db.store.federation_guests.length, 1);
});

test('une demande de jumelage cree un pair en attente, jamais actif', async () => {
  const kp = makeKeypair();
  const db = makeDb({ federation_peers: [] });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/pair',
    body: { instance_id: 'immeuble-c', display_name: 'C', base_url: 'https://10.8.0.3', public_key: kp.spki },
  });
  assert.equal(res.status, 201);
  assert.equal(db.store.federation_peers[0].status, 'pending');
});

test('un jumelage ne peut pas remplacer la cle d un pair deja connu', async () => {
  const vrai = makeKeypair();
  const attaquant = makeKeypair();
  const db = makeDb({ federation_peers: [peerRow(vrai)] });
  const app = createApp({ config: makeConfig(), db });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/pair',
    body: { instance_id: 'immeuble-b', base_url: 'https://malveillant', public_key: attaquant.spki },
  });
  assert.equal(res.status, 409);
  assert.equal(res.body.error, 'key_mismatch');
  assert.equal(db.store.federation_peers[0].public_key, vrai.spki);
});

test('les routes locales exigent un jeton de notre propre GoTrue', async () => {
  const config = makeConfig();
  const app = createApp({ config, db: makeDb({ federation_peers: [] }) });
  const mauvais = { authorization: 'Bearer ' + 'a.b.c' };
  assert.equal((await app.handle({ method: 'GET', path: '/federation/v1/local/peers', headers: mauvais })).status, 401);
  const bon = localAuth(config.localJwtSecret);
  assert.equal((await app.handle({ method: 'GET', path: '/federation/v1/local/peers', headers: bon })).status, 200);
});

test('un pair injoignable n empeche pas les autres de repondre', async () => {
  const config = makeConfig();
  const kp = makeKeypair();
  const db = makeDb({
    federation_peers: [
      peerRow(kp, { id: 'p1', instance_id: 'b', base_url: 'https://b' }),
      peerRow(kp, { id: 'p2', instance_id: 'c', base_url: 'https://c' }),
    ],
  });
  const fetchImpl = async (url) => {
    if (String(url).startsWith('https://c')) throw new Error('ECONNREFUSED');
    return { ok: true, text: async () => JSON.stringify({ spaces: [{ id: 's1', name: 'Atelier' }] }) };
  };
  const app = createApp({ config, db, fetchImpl });
  const res = await app.handle({
    method: 'GET', path: '/federation/v1/local/spaces', headers: localAuth(config.localJwtSecret),
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.spaces.length, 1);
  assert.deepEqual(res.body.unreachable, ['c']);
});

test('reservation sortante : engagement, appel, puis solde', async () => {
  const config = makeConfig();
  const kp = makeKeypair();
  const db = makeDb({ federation_peers: [peerRow(kp)] }, {
    federation_begin_outbound: () => ({ ok: true, request_id: 'req-1', status: 'pending' }),
    federation_settle_outbound: () => ({ ok: true, status: 'settled' }),
  });
  const fetchImpl = async (url, opts) => {
    if (opts?.method === 'POST') {
      return { ok: true, text: async () => JSON.stringify({ ok: true, reservation_id: 'r-distant' }) };
    }
    return { ok: true, text: async () => JSON.stringify({ spaces: [{ id: 's1', space_pricing: [{ price_per_slot: 2 }] }] }) };
  };
  const app = createApp({ config, db, fetchImpl });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/local/reservations', headers: localAuth(config.localJwtSecret),
    body: { peer_instance_id: 'immeuble-b', space_id: 's1', start: '2026-01-01T10:00:00Z', end: '2026-01-01T11:00:00Z', slots: 4 },
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.reservation_id, 'r-distant');

  const begin = db.calls.find((c) => c[1] === 'federation_begin_outbound');
  assert.equal(begin[2].p_amount, 8);                 // 4 tranches x 2 $
  const settle = db.calls.find((c) => c[1] === 'federation_settle_outbound');
  assert.equal(settle[2].p_status, 'settled');
});

test('reservation sortante : pair injoignable = mise en file, pas d echec', async () => {
  const config = makeConfig();
  const kp = makeKeypair();
  const db = makeDb({ federation_peers: [peerRow(kp)] }, {
    federation_begin_outbound: () => ({ ok: true, request_id: 'req-1', status: 'pending' }),
    federation_defer_outbound: () => null,
  });
  let premier = true;
  const fetchImpl = async () => {
    if (premier) { premier = false; return { ok: true, text: async () => JSON.stringify({ spaces: [{ id: 's1', space_pricing: [{ price_per_slot: 2 }] }] }) }; }
    throw new Error('ECONNRESET');
  };
  const app = createApp({ config, db, fetchImpl });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/local/reservations', headers: localAuth(config.localJwtSecret),
    body: { peer_instance_id: 'immeuble-b', space_id: 's1', start: 's', end: 'e', slots: 4 },
  });
  assert.equal(res.status, 202);
  assert.equal(res.body.queued, true);
  assert.ok(db.calls.some((c) => c[1] === 'federation_defer_outbound'));
});

test('reservation sortante : refus definitif du pair = solde rendu', async () => {
  const config = makeConfig();
  const kp = makeKeypair();
  const db = makeDb({ federation_peers: [peerRow(kp)] }, {
    federation_begin_outbound: () => ({ ok: true, request_id: 'req-1', status: 'pending' }),
    federation_settle_outbound: () => ({ ok: true, status: 'failed' }),
  });
  const fetchImpl = async (url, opts) => {
    if (opts?.method === 'POST') {
      return { ok: false, status: 409, text: async () => JSON.stringify({ ok: false, error: 'space_unavailable' }) };
    }
    return { ok: true, text: async () => JSON.stringify({ spaces: [{ id: 's1', space_pricing: [{ price_per_slot: 2 }] }] }) };
  };
  const app = createApp({ config, db, fetchImpl });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/local/reservations', headers: localAuth(config.localJwtSecret),
    body: { peer_instance_id: 'immeuble-b', space_id: 's1', start: 's', end: 'e', slots: 4 },
  });
  assert.equal(res.status, 409);
  const settle = db.calls.find((c) => c[1] === 'federation_settle_outbound');
  assert.equal(settle[2].p_status, 'failed');
});
