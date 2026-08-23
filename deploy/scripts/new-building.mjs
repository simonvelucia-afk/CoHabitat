// new-building.mjs — prepare le config.js d'un nouvel immeuble heberge.
//
//   node deploy/scripts/new-building.mjs \
//     --id pointe-est \
//     --nom "Pointe-Est" \
//     --site https://cohabitat.pointe-est.com \
//     --supabase https://abcxyz.supabase.co \
//     --cle eyJhbGciOi... \
//     > config.js
//
// Ne cree ni le projet Supabase ni le depot : ces deux gestes demandent
// vos identifiants et restent manuels. Ce script produit le SEUL fichier
// qui differe d'un immeuble a l'autre, et rappelle les etapes restantes
// sur la sortie d'erreur.
//
// Pour une instance auto-hebergee, ce fichier n'est pas necessaire :
// deploy/scripts/render-config.mjs le genere a partir du .env.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

function args(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i]?.replace(/^--/, '');
    if (k) out[k] = argv[i + 1];
  }
  return out;
}

const a = args(process.argv.slice(2));
const manquants = ['id', 'nom', 'site', 'supabase', 'cle'].filter((k) => !a[k]);
if (manquants.length) {
  console.error(`Options manquantes : ${manquants.map((m) => '--' + m).join(', ')}`);
  console.error('\nExemple :\n  node deploy/scripts/new-building.mjs \\');
  console.error('    --id pointe-est --nom "Pointe-Est" \\');
  console.error('    --site https://cohabitat.pointe-est.com \\');
  console.error('    --supabase https://abcxyz.supabase.co --cle eyJ... > config.js');
  process.exit(2);
}

const site = a.site.replace(/\/$/, '');

// On part du config.js du depot et on ne remplace que les valeurs :
// commentaires, structure et valeurs par defaut restent alignes sur
// l'amont, donc une mise a jour ne cree pas de conflit artificiel.
let src = readFileSync(resolve(here, '..', '..', 'config.js'), 'utf8');

const remplace = (motif, valeur, quoi) => {
  const avant = src;
  src = src.replace(motif, valeur);
  if (src === avant) {
    console.error(`[new-building] ${quoi} : motif introuvable dans config.js — le fichier a change de forme.`);
    process.exit(1);
  }
};

remplace(/id:\s*'[^']*'/, `id:   '${a.id}'`, 'instance.id');
remplace(/name:\s*'[^']*'/, `name: '${a.nom.replace(/'/g, "\\'")}'`, 'instance.name');
remplace(/supabaseUrl:\s*'[^']*'/, `supabaseUrl:     '${a.supabase.replace(/\/$/, '')}'`, 'supabaseUrl');
remplace(/supabaseAnonKey:\s*'[^']*'/, `supabaseAnonKey: '${a.cle}'`, 'supabaseAnonKey');
remplace(/siteUrl:\s*'[^']*'/, `siteUrl: '${site}'`, 'siteUrl');

process.stdout.write(src);

console.error(`
Fichier config.js produit pour « ${a.nom} ».

Il reste, dans l'ordre :

  1. Projet Supabase — appliquer schema.sql puis sql/*.sql par numero
     croissant (000 en premier).

  2. Auth Supabase — Site URL et Redirect URLs = ${site}

  3. Depot et hebergement — deposer ce config.js a la racine du depot de
     l'immeuble, activer Pages, pointer ${new URL(site).hostname} dessus.

  4. Premier administrateur — s'inscrire par l'interface, puis passer
     son profil a principal_admin :
       UPDATE profiles SET role='principal_admin' WHERE email='...';

  5. Centrale — enregistrer l'immeuble :
       ./modulimo building add <uuid> "${a.nom}" ${a.supabase} \\
           ${a.supabase}/auth/v1/.well-known/jwks.json
     et creer sa licence (domaine ${new URL(site).hostname}) dans l'admin.
`);
