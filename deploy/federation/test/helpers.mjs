// helpers.mjs — doubles de test : une base en memoire qui parle le
// dialecte PostgREST utilise par lib/db.mjs, et un pair simule.

import { generateKeyPairSync } from 'node:crypto';
import { publicKeyToSpki } from '../lib/jwt.mjs';

export function makeKeypair() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return { publicKey, privateKey, spki: publicKeyToSpki(publicKey) };
}

// Filtre minimal : `col=eq.valeur` uniquement, ce qui couvre toutes les
// requetes emises par app.mjs. Toute autre syntaxe est ignoree, donc un
// test qui la produirait echouerait de facon visible.
function matches(row, query) {
  for (const part of (query || '').split('&')) {
    const m = /^([a-z_]+)=eq\.(.*)$/.exec(part);
    if (!m) continue;
    const [, col, val] = m;
    const actual = row[col];
    const expected = decodeURIComponent(val);
    if (String(actual) !== expected && !(expected === 'true' && actual === true) &&
        !(expected === 'false' && actual === false)) return false;
  }
  return true;
}

export function makeDb(tables = {}, rpcImpl = {}) {
  const store = { ...tables };
  const calls = [];
  return {
    store,
    calls,
    select: async (table, query = '') => {
      calls.push(['select', table, query]);
      return (store[table] || []).filter((r) => matches(r, query.split('&select=')[0]));
    },
    insert: async (table, row) => {
      calls.push(['insert', table, row]);
      store[table] = store[table] || [];
      const withId = { id: row.id || `id-${store[table].length + 1}`, ...row };
      store[table].push(withId);
      return [withId];
    },
    patch: async (table, query, row) => {
      calls.push(['patch', table, query, row]);
      for (const r of store[table] || []) if (matches(r, query)) Object.assign(r, row);
      return [];
    },
    rpc: async (fn, args) => {
      calls.push(['rpc', fn, args]);
      if (!rpcImpl[fn]) throw new Error(`rpc non simulee : ${fn}`);
      return rpcImpl[fn](args);
    },
  };
}

export function makeConfig(overrides = {}) {
  const kp = makeKeypair();
  return {
    instanceId: 'immeuble-a',
    displayName: 'Immeuble A',
    privateKey: kp.privateKey,
    publicKeyB64: kp.spki,
    localJwtSecret: 'secret-local-de-test',
    serviceKey: 'service-key-de-test',
    gotrueUrl: 'http://gotrue:9999',
    peerTimeoutMs: 1000,
    outboxIntervalMs: 1000,
    outboxMaxAttempts: 3,
    _keypair: kp,
    ...overrides,
  };
}
