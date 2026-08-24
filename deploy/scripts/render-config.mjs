// render-config.mjs — genere le config.js servi par l'appliance.
//
//   node scripts/render-config.mjs > generated/config.js
//
// Le fichier produit est monte par-dessus celui du depot : l'interface
// ne contient donc aucune URL ni cle en dur, et un meme checkout sert
// aussi bien le site public que l'instance en reseau ferme.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

// Lecture du .env sans dependance : suffisant pour des paires cle=valeur.
function readEnv(path) {
  const out = {};
  let raw = '';
  try { raw = readFileSync(path, 'utf8'); } catch { return out; }
  for (const line of raw.split('\n')) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (!m) continue;
    out[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return out;
}

const env = { ...readEnv(resolve(here, '..', '.env')),
              ...readEnv(resolve(here, '..', '.env.secrets')),
              ...process.env };

const need = (k) => {
  if (!env[k]) { console.error(`[render-config] variable manquante : ${k}`); process.exit(1); }
  return env[k];
};

const offline = String(env.OFFLINE_ASSETS || 'true') !== 'false';
const centralEnabled = String(env.CENTRAL_ENABLED || 'false') === 'true';

const config = {
  instance: { id: need('INSTANCE_ID'), name: env.INSTANCE_NAME || need('INSTANCE_ID') },
  supabaseUrl: need('SITE_URL'),
  supabaseAnonKey: need('ANON_KEY'),
  siteUrl: need('SITE_URL'),
  // Instance auto-hebergee : les appels a la centrale passent
  // obligatoirement par la passerelle locale, qui signe une assertion
  // Ed25519. La centrale ne sait pas verifier nos jetons HS256.
  central: centralEnabled
    ? { enabled: true, url: need('CENTRAL_URL'), key: env.CENTRAL_KEY || '', viaFederation: true }
    : { enabled: false, url: '', key: '', viaFederation: false },
  lunchMachine: {
    kioskBase: env.LUNCH_KIOSK_URL || '',
    centralUrl: centralEnabled ? (env.CENTRAL_URL || '') : '',
  },
  federation: { enabled: String(env.FEDERATION_ENABLED || 'true') !== 'false', url: '/federation/v1' },
  // Camera : affichage seul sur la page Espaces. baseUrl vide = meme
  // origine, ce qui suppose le proxy /stream dans le Caddyfile.
  cameras: {
    enabled:     String(env.CAMERA_ENABLED || 'false') === 'true',
    visibility:  env.CAMERA_VISIBILITY === 'tenants' ? 'tenants' : 'admin',
    baseUrl:     env.CAMERA_BASE_URL || '',
    streamPath:  env.CAMERA_STREAM_PATH || '/stream/stream.html?src=',
    camera:      env.CAMERA_ID || 'cam1',
    label:       env.CAMERA_LABEL || 'Caméra',
    description: env.CAMERA_DESCRIPTION || 'Vue en direct. Aucune image n’est enregistrée par CoHabitat.',
  },
  analytics: { enabled: false, gaId: '' },
  assets: offline
    ? {
        supabaseJs: 'vendor/supabase.js',
        supabaseEsm: 'vendor/supabase.esm.js',
        jspdf: 'vendor/jspdf.umd.min.js',
        jspdfAutotable: 'vendor/jspdf.plugin.autotable.min.js',
        // Sans polices locales, le navigateur retombe sur la pile
        // systeme declaree dans la feuille de style : lisible, sobre.
        fontsCss: env.VENDOR_FONTS === 'true' ? 'vendor/fonts.css' : null,
        fontsPreconnect: null,
      }
    : {},
};

process.stdout.write(
  '/* Genere par deploy/scripts/render-config.mjs — ne pas modifier a la main. */\n' +
  'window.COHABITAT_CONFIG = ' + JSON.stringify(config, null, 2) + ';\n' +
  readFileSync(resolve(here, '..', '..', 'config.js'), 'utf8'),
);
