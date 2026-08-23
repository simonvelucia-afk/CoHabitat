import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { signPeerToken, verifyPeerToken, verifyLocalToken, publicKeyFromSpki, b64urlJson } from '../lib/jwt.mjs';
import { makeKeypair } from './helpers.mjs';

test('un jeton de pair valide est accepte par le destinataire annonce', () => {
  const kp = makeKeypair();
  const token = signPeerToken({ iss: 'a', aud: 'b', sub: 'u1' }, kp.privateKey, { kid: 'a' });
  const payload = verifyPeerToken(token, publicKeyFromSpki(kp.spki), { audience: 'b' });
  assert.equal(payload.iss, 'a');
  assert.equal(payload.sub, 'u1');
});

test('un jeton destine a une autre instance est refuse', () => {
  const kp = makeKeypair();
  const token = signPeerToken({ iss: 'a', aud: 'b' }, kp.privateKey, { kid: 'a' });
  assert.throws(() => verifyPeerToken(token, publicKeyFromSpki(kp.spki), { audience: 'c' }),
    /destinataire inattendu/);
});

test('la cle publique d un autre pair ne valide pas la signature', () => {
  const a = makeKeypair();
  const b = makeKeypair();
  const token = signPeerToken({ iss: 'a', aud: 'b' }, a.privateKey, { kid: 'a' });
  assert.throws(() => verifyPeerToken(token, publicKeyFromSpki(b.spki), { audience: 'b' }),
    /signature invalide/);
});

test('un jeton expire est refuse', () => {
  const kp = makeKeypair();
  const token = signPeerToken({ iss: 'a', aud: 'b' }, kp.privateKey, { kid: 'a', ttlSeconds: -120 });
  assert.throws(() => verifyPeerToken(token, publicKeyFromSpki(kp.spki), { audience: 'b' }),
    /expire/);
});

test('un jeton dont on a change la charge utile est refuse', () => {
  const kp = makeKeypair();
  const token = signPeerToken({ iss: 'a', aud: 'b', sub: 'u1' }, kp.privateKey, { kid: 'a' });
  const [h, , s] = token.split('.');
  const forged = `${h}.${b64urlJson({ iss: 'a', aud: 'b', sub: 'admin', exp: 9e9, iat: 1 })}.${s}`;
  assert.throws(() => verifyPeerToken(forged, publicKeyFromSpki(kp.spki), { audience: 'b' }),
    /signature invalide/);
});

test('alg:none est refuse au lieu d etre traite comme non signe', () => {
  const kp = makeKeypair();
  const header = b64urlJson({ alg: 'none', typ: 'JWT' });
  const body = b64urlJson({ iss: 'a', aud: 'b', exp: 9e9, iat: 1 });
  assert.throws(() => verifyPeerToken(`${header}.${body}.`, publicKeyFromSpki(kp.spki), { audience: 'b' }),
    /algorithme refuse/);
});

test('un jeton GoTrue HS256 valide est accepte', () => {
  const secret = 'secret-local';
  const header = b64urlJson({ alg: 'HS256', typ: 'JWT' });
  const body = b64urlJson({ sub: 'user-1', role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 60 });
  const sig = createHmac('sha256', secret).update(`${header}.${body}`).digest('base64url');
  assert.equal(verifyLocalToken(`${header}.${body}.${sig}`, secret).sub, 'user-1');
});

test('un jeton HS256 signe avec un autre secret est refuse', () => {
  const header = b64urlJson({ alg: 'HS256', typ: 'JWT' });
  const body = b64urlJson({ sub: 'user-1', exp: Math.floor(Date.now() / 1000) + 60 });
  const sig = createHmac('sha256', 'mauvais-secret').update(`${header}.${body}`).digest('base64url');
  assert.throws(() => verifyLocalToken(`${header}.${body}.${sig}`, 'secret-local'), /signature invalide/);
});
