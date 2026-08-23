// gen-keys.mjs — fabrique les secrets d'une instance.
//
//   node scripts/gen-keys.mjs > .env.secrets
//
// Produit : le secret JWT partage par GoTrue et PostgREST, les deux
// cles d'API derivees de ce secret (anon et service_role, au format
// attendu par supabase-js), les mots de passe des roles Postgres, et la
// paire de cles Ed25519 qui donne son identite a l'instance dans la
// federation.
//
// La cle privee de federation est ecrite dans deploy/secrets/ ; elle ne
// doit jamais quitter la machine. Seule la cle PUBLIQUE est communiquee
// aux autres instances.

import { createHmac, randomBytes, generateKeyPairSync } from 'node:crypto';
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const secretsDir = resolve(here, '..', 'secrets');

const b64url = (buf) => Buffer.from(buf).toString('base64url');

// Jeton HS256 sans expiration : c'est ce que PostgREST attend pour
// reconnaitre les roles anon et service_role.
function apiKey(role, secret) {
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({
    role,
    iss: 'cohabitat',
    iat: Math.floor(Date.now() / 1000),
    exp: Math.floor(Date.now() / 1000) + 20 * 365 * 24 * 3600,
  }));
  const sig = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${sig}`;
}

const jwtSecret = randomBytes(48).toString('base64url');
const pg = () => randomBytes(24).toString('base64url');

mkdirSync(secretsDir, { recursive: true });
const keyPath = resolve(secretsDir, 'federation_key.pem');

let publicSpki;
if (existsSync(keyPath)) {
  // On ne remplace jamais une identite existante : les pairs deja
  // jumeles ne reconnaitraient plus l'instance.
  console.error(`[gen-keys] cle de federation conservee : ${keyPath}`);
  const { createPrivateKey, createPublicKey } = await import('node:crypto');
  const { readFileSync } = await import('node:fs');
  publicSpki = b64url(createPublicKey(createPrivateKey(readFileSync(keyPath, 'utf8')))
    .export({ format: 'der', type: 'spki' }));
} else {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  writeFileSync(keyPath, privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });
  publicSpki = b64url(publicKey.export({ format: 'der', type: 'spki' }));
  console.error(`[gen-keys] cle de federation ecrite : ${keyPath}`);
}

process.stdout.write([
  '# Secrets generes par scripts/gen-keys.mjs — a conserver hors du depot.',
  `JWT_SECRET=${jwtSecret}`,
  `ANON_KEY=${apiKey('anon', jwtSecret)}`,
  `SERVICE_ROLE_KEY=${apiKey('service_role', jwtSecret)}`,
  `POSTGRES_PASSWORD=${pg()}`,
  `AUTHENTICATOR_PASSWORD=${pg()}`,
  `AUTH_ADMIN_PASSWORD=${pg()}`,
  '',
  `# Cle publique de federation — a communiquer aux instances jumelees.`,
  `# FEDERATION_PUBLIC_KEY=${publicSpki}`,
  '',
].join('\n'));
