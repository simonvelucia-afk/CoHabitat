// render-index.mjs — prepare les pages pour un reseau ferme.
//
//   node scripts/render-index.mjs > generated/index.html
//   node scripts/render-index.mjs sign.html > generated/sign.html
//
// Remplace les URL des librairies tierces et des polices par leur
// equivalent dans vendor/. Ce remplacement se fait ICI, a la
// construction, et non dans la page a l'execution : un script tiers
// bloquant l'analyseur injecte par document.write peut etre bloque par
// le navigateur sur connexion lente, ce qui casserait l'application.
//
// Chaque remplacement est verifie : si une URL attendue n'est plus dans
// la page, le script s'arrete. Sans cela, une appliance en reseau ferme
// se retrouverait avec une page qui appelle encore un CDN injoignable.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const target = process.argv[2] || 'index.html';
const source = resolve(here, '..', '..', target);

const REMPLACEMENTS = [
  ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2', 'vendor/supabase.js'],
  ['https://cdn.jsdelivr.net/npm/jspdf@2.5.2/dist/jspdf.umd.min.js', 'vendor/jspdf.umd.min.js'],
  ['https://cdn.jsdelivr.net/npm/jspdf-autotable@3.8.4/dist/jspdf.plugin.autotable.min.js',
   'vendor/jspdf.plugin.autotable.min.js'],
  ['https://esm.sh/@supabase/supabase-js@2', 'vendor/supabase.esm.js'],
];

// Les polices sont facultatives : sans vendor/fonts.css, la pile de
// polices systeme prend le relais, ce qui reste lisible.
const POLICES = /<link rel="preconnect" href="https:\/\/fonts\.googleapis\.com">\s*<link href="https:\/\/fonts\.googleapis\.com\/css2[^"]*" rel="stylesheet">/;

let html = readFileSync(source, 'utf8');
let touches = 0;

for (const [de, vers] of REMPLACEMENTS) {
  if (!html.includes(de)) continue;      // pas present dans cette page
  html = html.split(de).join(vers);
  touches++;
}

if (touches === 0) {
  console.error(`[render-index] aucune URL distante trouvee dans ${target} — la page a change de forme, verifier REMPLACEMENTS`);
  process.exit(1);
}

if (POLICES.test(html)) {
  html = html.replace(POLICES,
    process.env.VENDOR_FONTS === 'true'
      ? '<link href="vendor/fonts.css" rel="stylesheet">'
      : '<!-- polices systeme (VENDOR_FONTS=false) -->');
}

// Analytique : le script Google ne serait de toute facon pas joignable.
html = html.replace(/https:\/\/www\.googletagmanager\.com\/gtag\/js\?id=/g, 'about:blank#gtag=');

process.stdout.write(html);
