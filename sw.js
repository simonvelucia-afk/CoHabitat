/* Service worker — permet a l'application de s'ouvrir sans reseau.
 *
 * Strategie : « reseau d'abord, cache en repli ». En ligne, le
 * comportement est exactement celui d'avant ce fichier : tout vient du
 * serveur, rien n'est perime. Hors ligne, le cache prend le relais et
 * l'application s'ouvre quand meme.
 *
 * Ce choix est volontairement conservateur. Servir les scripts depuis le
 * cache en priorite exposerait a un melange de versions apres un
 * deploiement — un index.html neuf avec un balanceOps.js d'hier — ce qui
 * casse de facon difficile a diagnostiquer. Sur un site en production,
 * ce risque ne vaut pas les quelques millisecondes gagnees.
 *
 * Seuls les fichiers reellement stables (icones, manifeste) sont servis
 * depuis le cache en premier.
 *
 * Changer VERSION invalide l'ancien cache : a incrementer quand les
 * fichiers du noyau changent.
 */
const VERSION = 'cohabitat-v1';

// Le strict necessaire pour ouvrir l'application hors ligne. Les
// librairies tierces ne sont pas listees : elles viennent d'un CDN, et
// le mode demonstration fonctionne sans elles.
const NOYAU = [
  './',
  './index.html',
  './config.js',
  './balanceOps.js',
  './demo-data.js',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(VERSION)
      // Un fichier manquant ne doit pas faire echouer toute l'installation.
      .then((c) => Promise.allSettled(NOYAU.map((u) => c.add(u))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((noms) => Promise.all(noms.filter((n) => n !== VERSION).map((n) => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  // Les appels de donnees ne sont jamais servis depuis le cache : un
  // solde ou une reservation perimes seraient pires qu'une erreur.
  const url = new URL(req.url);
  if (url.pathname.includes('/rest/v1/') ||
      url.pathname.includes('/auth/v1/') ||
      url.pathname.includes('/functions/v1/') ||
      url.pathname.includes('/federation/') ||
      // Un flux video n'a rien a faire dans un cache : hors ligne, mieux
      // vaut un cadre vide qu'un lecteur fige sur une page mise en cache.
      url.pathname.includes('/stream/')) return;

  const mettreEnCache = (rep) => {
    if (rep && rep.ok && rep.type === 'basic') {
      const copie = rep.clone();
      caches.open(VERSION).then((c) => c.put(req, copie));
    }
    return rep;
  };

  // Fichiers stables : le cache d'abord, sans risque de melange.
  if (/\.(png|svg|webmanifest|woff2?)$/.test(url.pathname)) {
    e.respondWith(
      caches.match(req).then((enCache) => enCache || fetch(req).then(mettreEnCache))
    );
    return;
  }

  // Page et scripts : le reseau d'abord. Le cache ne sert que lorsque le
  // reseau ne repond pas — donc hors ligne, ou sur une tablette de
  // demonstration.
  e.respondWith(
    fetch(req).then(mettreEnCache).catch(() =>
      caches.match(req).then((c) => c || (req.mode === 'navigate' ? caches.match('./index.html') : undefined))
    )
  );
});
