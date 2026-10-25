#!/usr/bin/env node
// numero-serie-lunch.mjs — numéros de série des Machines Lunch.
//
// Format : LM-AAAA-NNNNN-C
//   LM     Machine Lunch
//   AAAA   année de fabrication
//   NNNNN  numéro de la machine dans l'année
//   C      clé de contrôle, ISO 7064 MOD 37,36 sur « LMAAAANNNNN »
//
// CoHabitat reconnaît un numéro sans rien demander à personne : la base de
// l'immeuble recalcule la clé (sql/038, lunch_serie_valide) et refuse un
// numéro mal saisi. La clé repère une faute de frappe — un caractère
// changé ou deux caractères voisins inversés — ; elle n'est pas secrète.
//
// Garder l'algorithme identique à lunch_serie_cle() dans
// sql/038_lunch_numero_serie.sql : sql/tests/lunch_test.sql vérifie que
// les deux s'accordent.
//
// Usage :
//   node deploy/scripts/numero-serie-lunch.mjs generer 2026 1 20   # LM-2026-00001 à 00020
//   node deploy/scripts/numero-serie-lunch.mjs verifier LM-2026-00001-X

const ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

export function cle(corps) {
  let p = 36;
  for (const ch of corps.toUpperCase()) {
    const v = ALPHABET.indexOf(ch);
    if (v < 0) throw new Error(`caractère invalide : ${ch}`);
    let s = (p + v) % 36;
    if (s === 0) s = 36;
    p = (s * 2) % 37;
  }
  return ALPHABET[(37 - p) % 36];
}

export function numero(annee, rang) {
  const a = String(annee).padStart(4, '0');
  const n = String(rang).padStart(5, '0');
  return `LM-${a}-${n}-${cle('LM' + a + n)}`;
}

export function valide(texte) {
  const m = /^LM-(\d{4})-(\d{5})-([0-9A-Z])$/.exec(String(texte).trim().toUpperCase());
  return !!m && cle('LM' + m[1] + m[2]) === m[3];
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'generer') {
    const [annee, debut, fin] = args.map(Number);
    if (!annee || !debut) {
      console.error('usage : generer <année> <premier> [dernier]');
      process.exit(1);
    }
    for (let i = debut; i <= (fin || debut); i++) console.log(numero(annee, i));
  } else if (cmd === 'verifier') {
    const ok = valide(args[0] || '');
    console.log(ok ? 'valide' : 'invalide');
    process.exit(ok ? 0 : 2);
  } else {
    console.error('usage : generer <année> <premier> [dernier] | verifier <numéro>');
    process.exit(1);
  }
}
