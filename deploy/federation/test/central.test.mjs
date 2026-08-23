import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, createPublicKey, verify as cryptoVerify } from 'node:crypto';
import { createApp } from '../lib/app.mjs';
import { b64urlJson } from '../lib/jwt.mjs';
import { makeDb, makeConfig } from './helpers.mjs';

function localAuth(secret, sub = 'resident-1') {
  const header = b64urlJson({ alg: 'HS256', typ: 'JWT' });
  const body = b64urlJson({ sub, role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 60 });
  const sig = createHmac('sha256', secret).update(`${header}.${body}`).digest('base64url');
  return { authorization: `Bearer ${header}.${body}.${sig}` };
}

function centralConfig(over = {}) {
  return makeConfig({
    centralUrl: 'https://central.modulimo.lan',
    centralKey: 'cle-publique-centrale',
    centralIssuer: 'https://cohabitat.pointe-est.lan/auth/v1',
    ...over,
  });
}

const decode = (t) => JSON.parse(Buffer.from(t.split('.')[1], 'base64url'));

test('la sonde de sante passe sans authentification ni assertion', async () => {
  const config = centralConfig();
  let seen = null;
  const fetchImpl = async (url, opts) => {
    seen = { url, opts };
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, latency_ms: 12 }) };
  };
  const app = createApp({ config, db: makeDb(), fetchImpl });
  const res = await app.handle({ method: 'GET', path: '/federation/v1/local/central/health' });
  assert.equal(res.status, 200);
  assert.equal(res.body.latency_ms, 12);
  assert.equal(seen.opts.method, 'GET');
  assert.equal(seen.opts.headers.Authorization, undefined);
});

test('un debit exige le jeton local et part avec une assertion signee', async () => {
  const config = centralConfig();
  let seen = null;
  const fetchImpl = async (url, opts) => {
    seen = { url, opts };
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, balance_after: 90 }) };
  };
  const app = createApp({ config, db: makeDb(), fetchImpl });

  // Sans jeton : refus, et rien n'est envoye a la centrale.
  const anon = await app.handle({
    method: 'POST', path: '/federation/v1/local/central/debit', body: { amount: 10 },
  });
  assert.equal(anon.status, 401);
  assert.equal(seen, null);

  const res = await app.handle({
    method: 'POST', path: '/federation/v1/local/central/debit',
    headers: { ...localAuth(config.localJwtSecret), 'idempotency-key': 'cle-1' },
    body: { amount: 10, type: 'space_reservation' },
  });
  assert.equal(res.status, 200);
  assert.equal(res.body.balance_after, 90);
  assert.equal(seen.url, 'https://central.modulimo.lan/functions/v1/finance-bridge/debit');
  assert.equal(seen.opts.headers['Idempotency-Key'], 'cle-1');
  assert.equal(seen.opts.headers.apikey, 'cle-publique-centrale');

  // L'assertion porte l'identite de l'instance et celle du resident,
  // sous la forme attendue par finance-bridge.
  const claims = decode(seen.opts.headers.Authorization.replace('Bearer ', ''));
  assert.equal(claims.iss, 'https://cohabitat.pointe-est.lan/auth/v1');
  assert.equal(claims.aud, 'authenticated');
  assert.equal(claims.sub, 'resident-1');
  assert.ok(claims.exp - claims.iat <= 60, 'assertion de courte duree');
});

test('le secret local ne quitte jamais l instance', async () => {
  const config = centralConfig();
  let seen = null;
  const fetchImpl = async (url, opts) => { seen = { url, opts }; return { ok: true, status: 200, text: async () => '{}' }; };
  const app = createApp({ config, db: makeDb(), fetchImpl });
  await app.handle({
    method: 'POST', path: '/federation/v1/local/central/get-balance',
    headers: localAuth(config.localJwtSecret), body: {},
  });
  const envoye = JSON.stringify(seen);
  assert.ok(!envoye.includes(config.localJwtSecret), 'le secret HS256 ne doit pas etre transmis');
  // Le jeton du resident non plus : il est remplace, pas relaye.
  assert.ok(!seen.opts.headers.Authorization.includes('HS256'));
});

test('un endpoint hors liste est refuse avant tout appel sortant', async () => {
  const config = centralConfig();
  let appele = false;
  const app = createApp({ config, db: makeDb(), fetchImpl: async () => { appele = true; return { ok: true, status: 200, text: async () => '{}' }; } });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/local/central/anonymize-everything',
    headers: localAuth(config.localJwtSecret), body: {},
  });
  assert.equal(res.status, 404);
  assert.equal(appele, false);
});

test('sans centrale configuree, le relais refuse proprement', async () => {
  const config = makeConfig();       // aucune centrale
  const app = createApp({ config, db: makeDb() });
  const res = await app.handle({ method: 'GET', path: '/federation/v1/local/central/health' });
  assert.equal(res.status, 503);
  assert.equal(res.body.error, 'central_not_configured');
});

test('centrale injoignable : 503 explicite, pas une exception', async () => {
  const config = centralConfig();
  const app = createApp({ config, db: makeDb(), fetchImpl: async () => { throw new Error('ECONNREFUSED'); } });
  const res = await app.handle({ method: 'GET', path: '/federation/v1/local/central/health' });
  assert.equal(res.status, 503);
  assert.equal(res.body.error, 'central_unreachable');
});

test('le refus metier de la centrale est rendu tel quel', async () => {
  const config = centralConfig();
  const fetchImpl = async () => ({ ok: false, status: 409, text: async () => JSON.stringify({ error: 'INSUFFICIENT_FUNDS' }) });
  const app = createApp({ config, db: makeDb(), fetchImpl });
  const res = await app.handle({
    method: 'POST', path: '/federation/v1/local/central/debit',
    headers: localAuth(config.localJwtSecret), body: { amount: 999 },
  });
  assert.equal(res.status, 409);
  assert.equal(res.body.error, 'INSUFFICIENT_FUNDS');
});

// Ce test verifie l'hypothese d'interoperabilite sur laquelle repose
// tout le mode ed25519 : la cle publique que cette instance publie
// (SPKI base64url) se reconstitue en PEM exactement comme le fait
// spkiToPem() cote finance-bridge, et verifie bien nos signatures.
test('la cle publique publiee verifie les assertions apres conversion en PEM', async () => {
  const config = centralConfig();
  let seen = null;
  const app = createApp({
    config, db: makeDb(),
    fetchImpl: async (url, opts) => { seen = opts; return { ok: true, status: 200, text: async () => '{}' }; },
  });
  await app.handle({
    method: 'POST', path: '/federation/v1/local/central/get-balance',
    headers: localAuth(config.localJwtSecret), body: {},
  });
  const token = seen.headers.Authorization.replace('Bearer ', '');
  const [h, p, sig] = token.split('.');

  // Conversion identique a celle de finance-bridge (lib/registry.ts).
  const b64 = config.publicKeyB64.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const pem = `-----BEGIN PUBLIC KEY-----\n${padded.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----\n`;

  const key = createPublicKey(pem);
  assert.equal(key.asymmetricKeyType, 'ed25519');
  assert.ok(
    cryptoVerify(null, Buffer.from(`${h}.${p}`), key, Buffer.from(sig, 'base64url')),
    'la signature doit etre valide sous la cle publiee',
  );
  assert.equal(JSON.parse(Buffer.from(h, 'base64url')).alg, 'EdDSA');
});
