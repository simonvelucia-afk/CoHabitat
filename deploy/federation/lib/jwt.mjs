// jwt.mjs — jetons echanges entre instances et jetons locaux.
//
// Deux familles, volontairement distinctes :
//
//   * EdDSA (Ed25519) — un pair signe ses requetes avec sa cle privee.
//     Sa cle publique a ete echangee une seule fois, au jumelage. Aucun
//     secret partage ne circule, et une instance compromise ne permet
//     pas d'usurper les autres.
//
//   * HS256 — jetons emis par GoTrue pour nos propres usagers. On les
//     verifie avec le secret JWT local, exactement comme PostgREST.
//
// Aucune dependance : node:crypto suffit pour les deux.

import { createHmac, createPublicKey, createPrivateKey, sign, verify, timingSafeEqual, randomUUID } from 'node:crypto';

const enc = (buf) => Buffer.from(buf).toString('base64url');
const dec = (str) => Buffer.from(str, 'base64url');

export function b64urlJson(obj) {
  return enc(JSON.stringify(obj));
}

// ── Ed25519 ────────────────────────────────────────────────────────
export function privateKeyFromPem(pem) {
  return createPrivateKey(pem);
}

export function publicKeyFromSpki(b64) {
  return createPublicKey({ key: dec(b64), format: 'der', type: 'spki' });
}

export function publicKeyToSpki(keyObject) {
  return enc(keyObject.export({ format: 'der', type: 'spki' }));
}

// Signe un jeton court (60 s par defaut) : il ne sert qu'a authentifier
// une requete en vol, jamais a porter une session.
export function signPeerToken(payload, privateKey, { kid, ttlSeconds = 60 } = {}) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'EdDSA', typ: 'JWT', kid };
  const body = { iat: now, exp: now + ttlSeconds, jti: randomUUID(), ...payload };
  const input = `${b64urlJson(header)}.${b64urlJson(body)}`;
  const sig = sign(null, Buffer.from(input), privateKey);
  return `${input}.${enc(sig)}`;
}

// Verifie signature ET fenetre temporelle. `audience` est obligatoire :
// un jeton destine a une autre instance ne doit pas etre rejouable ici.
export function verifyPeerToken(token, publicKey, { audience, clockSkew = 30 } = {}) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) throw new Error('jeton malforme');
  const [h, p, s] = parts;

  let header, payload;
  try {
    header = JSON.parse(dec(h));
    payload = JSON.parse(dec(p));
  } catch {
    throw new Error('jeton illisible');
  }
  if (header.alg !== 'EdDSA') throw new Error('algorithme refuse');
  if (!verify(null, Buffer.from(`${h}.${p}`), publicKey, dec(s))) {
    throw new Error('signature invalide');
  }

  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp !== 'number' || payload.exp + clockSkew < now) throw new Error('jeton expire');
  if (typeof payload.iat !== 'number' || payload.iat - clockSkew > now) throw new Error('jeton date du futur');
  if (audience && payload.aud !== audience) throw new Error('destinataire inattendu');
  return payload;
}

// ── HS256 (GoTrue) ─────────────────────────────────────────────────
export function verifyLocalToken(token, secret) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) throw new Error('jeton malforme');
  const [h, p, s] = parts;

  let header, payload;
  try {
    header = JSON.parse(dec(h));
    payload = JSON.parse(dec(p));
  } catch {
    throw new Error('jeton illisible');
  }
  if (header.alg !== 'HS256') throw new Error('algorithme refuse');

  const expected = createHmac('sha256', secret).update(`${h}.${p}`).digest();
  const got = dec(s);
  if (got.length !== expected.length || !timingSafeEqual(got, expected)) {
    throw new Error('signature invalide');
  }
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp === 'number' && payload.exp < now) throw new Error('jeton expire');
  return payload;
}
