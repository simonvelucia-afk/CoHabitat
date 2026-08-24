/* Service worker — permet a l'application de s'ouvrir sans reseau.
 *
 * Strategie : « cache d'abord, mise a jour en arriere-plan ». La page
 * s'affiche instantanement depuis le cache, et la version fraiche est
 * recuperee en silence pour la prochaine ouverture. C'est ce qui convient
 * a une demonstration (aucune attente, aucune dependance au reseau) sans
 * figer l'application sur une version perimee.
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
      url.pathname.includes('/federation/')) return;

  const mettreEnCache = (rep) => {
    if (rep && rep.ok && rep.type === 'basic') {
      const copie = rep.clone();
      caches.open(VERSION).then((c) => c.put(req, copie));
    }
    return rep;
  };

  // La PAGE est cherchee sur le reseau d'abord, avec repli sur le cache.
  // Sinon, un deploiement ne serait visible qu'a la deuxieme ouverture :
  // l'usager verrait l'ancienne version apres chaque mise a jour du site.
  // Hors ligne, le repli sur le cache rend le comportement identique.
  if (req.mode === 'navigate' || url.pathname.endsWith('/index.html')) {
    e.respondWith(
      fetch(req).then(mettreEnCache).catch(() => caches.match(req).then(
        (c) => c || caches.match('./index.html')
      ))
    );
    return;
  }

  // Le reste (scripts, icones, manifeste) : cache d'abord pour
  // l'affichage instantane, rafraichi en arriere-plan.
  e.respondWith(
    caches.match(req).then((enCache) => {
      const reseau = fetch(req).then(mettreEnCache).catch(() => enCache);
      return enCache || reseau;
    })
  );
});
