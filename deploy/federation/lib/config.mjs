// config.mjs — lecture de l'environnement, une seule fois, avec des
// erreurs explicites au demarrage plutot que des 500 a la premiere
// requete.

import { readFileSync } from 'node:fs';
import { privateKeyFromPem } from './jwt.mjs';

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Variable d'environnement manquante : ${name}`);
  return v;
}

export function loadConfig(env = process.env) {
  const keyPem = env.FEDERATION_PRIVATE_KEY
    ? env.FEDERATION_PRIVATE_KEY
    : readFileSync(required('FEDERATION_PRIVATE_KEY_FILE'), 'utf8');

  return {
    port:            Number(env.FEDERATION_PORT || 8080),
    instanceId:      required('INSTANCE_ID'),
    displayName:     env.INSTANCE_NAME || required('INSTANCE_ID'),
    // URL interne de PostgREST (jamais exposee hors du reseau de l'appliance).
    postgrestUrl:    required('POSTGREST_URL'),
    serviceKey:      required('SERVICE_ROLE_KEY'),
    // Secret HS256 de GoTrue, pour verifier les jetons de nos usagers.
    localJwtSecret:  required('JWT_SECRET'),
    gotrueUrl:       env.GOTRUE_URL || null,
    // URL publique de cette instance : sert d'emetteur (`iss`) des
    // assertions presentees a la centrale, et doit donc correspondre au
    // jwt_issuer inscrit dans son registre des immeubles.
    siteUrl:         env.SITE_URL || null,
    centralIssuer:   env.CENTRAL_ISSUER || (env.SITE_URL ? env.SITE_URL.replace(/\/$/, '') + '/auth/v1' : null),
    // Centrale Modulimo, joignable par le VPN. Absente = instance
    // entierement autonome : les routes /local/central refusent.
    centralUrl:      env.CENTRAL_URL || null,
    centralKey:      env.CENTRAL_KEY || '',
    privateKey:      privateKeyFromPem(keyPem),
    // Delais de reprise de la file sortante (coupure VPN).
    outboxIntervalMs: Number(env.FEDERATION_OUTBOX_INTERVAL_MS || 30000),
    outboxMaxAttempts: Number(env.FEDERATION_OUTBOX_MAX_ATTEMPTS || 20),
    peerTimeoutMs:    Number(env.FEDERATION_PEER_TIMEOUT_MS || 8000),
  };
}
