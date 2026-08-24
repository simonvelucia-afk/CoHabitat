/* ============================================================
 * CoHabitat — configuration runtime
 * ============================================================
 * Ce fichier porte TOUTES les valeurs qui changent d'un
 * deploiement a l'autre : URL de la base, cles publiques, URL de
 * la centrale, emplacement des librairies tierces.
 *
 * Les valeurs ci-dessous sont celles du deploiement historique
 * (GitHub Pages + Supabase heberge) : un checkout sans rien
 * configurer se comporte exactement comme avant.
 *
 * En mode APPLIANCE (reseau ferme, cf. deploy/), le serveur sert
 * son propre config.js genere a partir du .env — ce fichier est
 * alors remplace, pas modifie. Ne mettez donc jamais de logique
 * applicative ici : uniquement des valeurs.
 *
 * Surcharge ponctuelle (test local) : definir window.COHABITAT_CONFIG
 * AVANT le chargement de ce script ; les cles fournies sont
 * fusionnees par-dessus les valeurs par defaut.
 * ============================================================ */
(function (global) {
  'use strict';

  var CDN = 'https://cdn.jsdelivr.net/npm/';

  var DEFAULTS = {
    // Identite de l'instance. Sert d'etiquette dans l'UI et de
    // valeur par defaut pour l'emetteur des jetons de federation.
    instance: {
      id:   'cohabitat',
      name: 'CoHabitat'
    },

    // Base de donnees de l'immeuble (Supabase heberge ou appliance).
    supabaseUrl:     'https://uwyhrdjlwetcbtskijrs.supabase.co',
    supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV3eWhyZGpsd2V0Y2J0c2tpanJzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI1NzMxNjYsImV4cCI6MjA4ODE0OTE2Nn0.NHo_RY4DjTmtkFcjOJ3dFPzNRN1rCwBCDXyIixOSrn4',

    // URL publique du site — utilisee pour les liens de retour
    // envoyes par courriel (reinitialisation de mot de passe).
    siteUrl: 'https://cohabitat.modulimo.com',

    // Centrale Modulimo. enabled:false = instance autonome : aucune
    // requete sortante, la finance reste locale.
    central: {
      enabled: true,
      url:     'https://bpxscgrbxjscicpnheep.supabase.co',
      key:     'sb_publishable_2V-eHOvw1v_Xwr1bpHfHLg_cbHW9ctD',
      // true : les appels a la centrale passent par la passerelle de
      // federation locale, qui signe une assertion Ed25519 a notre place.
      // Necessaire des que cette instance est auto-hebergee : ses jetons
      // sont signes HS256 avec un secret local, que la centrale ne peut
      // pas verifier.
      viaFederation: false
    },

    // Machine Lunch (kiosque en iframe + tables lunch_* sur la centrale).
    lunchMachine: {
      kioskBase:  'https://simonvelucia-afk.github.io/LunchMachine/',
      centralUrl: 'https://bpxscgrbxjscicpnheep.supabase.co'
    },

    // Federation entre instances CoHabitat (reservations croisees et
    // transferts de solde par VPN). Desactivee par defaut : le service
    // federation n'existe que dans le paquet appliance.
    federation: {
      enabled: false,
      url:     '/federation'
    },

    // Camera des espaces communs, affichee sur la page Espaces entre la
    // grille et la serre. Desactivee par defaut : sans configuration, la
    // section n'apparait pas.
    //
    // baseUrl vide = meme origine que l'application. C'est le montage
    // recommande : faire servir le serveur camera sous /stream et /ptz
    // par le meme reverse proxy. Une URL http:// explicite fonctionne
    // tant que CoHabitat est lui aussi en http, mais sera bloquee par le
    // navigateur (contenu mixte) des que le site passe en https.
    cameras: {
      enabled:     false,
      baseUrl:     '',
      streamPath:  '/stream/stream.html?src=',
      ptzPath:     '/ptz',
      camera:      'cam1',
      label:       'Caméra — espaces communs',
      description: 'Vue en direct. Aucune image n’est enregistrée par CoHabitat.'
    },

    // Analytique. Coupee automatiquement en reseau ferme : le script
    // Google ne serait de toute facon pas joignable.
    analytics: {
      enabled: true,
      gaId:    'G-EWP5ER8KFJ'
    },

    // Librairies tierces et polices. Ces URL sont ecrites en dur dans
    // les balises <script>/<link> de la page : un script tiers injecte
    // a l'execution peut etre bloque par le navigateur sur connexion
    // lente. Elles sont listees ici parce que le deploiement en reseau
    // ferme les remplace par leur equivalent local au moment de la
    // construction — voir deploy/scripts/render-index.mjs.
    assets: {
      supabaseJs:      CDN + '@supabase/supabase-js@2',
      supabaseEsm:     'https://esm.sh/@supabase/supabase-js@2',
      jspdf:           CDN + 'jspdf@2.5.2/dist/jspdf.umd.min.js',
      jspdfAutotable:  CDN + 'jspdf-autotable@3.8.4/dist/jspdf.plugin.autotable.min.js',
      fontsCss:        'https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@300;400;500;600&family=Space+Mono&display=swap',
      fontsPreconnect: 'https://fonts.googleapis.com',
      favicon:         'https://raw.githubusercontent.com/simonvelucia-afk/modulimo-home/main/images/favicon_Modulimo.png'
    }
  };

  // Fusion recursive : un objet surcharge cle par cle, toute autre
  // valeur (chaine, booleen, null) remplace la valeur par defaut.
  function merge(base, over) {
    var out = {}, k;
    for (k in base) if (Object.prototype.hasOwnProperty.call(base, k)) out[k] = base[k];
    if (!over) return out;
    for (k in over) {
      if (!Object.prototype.hasOwnProperty.call(over, k)) continue;
      var b = out[k], o = over[k];
      out[k] = (b && o && typeof b === 'object' && typeof o === 'object' &&
                !Array.isArray(b) && !Array.isArray(o)) ? merge(b, o) : o;
    }
    return out;
  }

  var cfg = merge(DEFAULTS, global.COHABITAT_CONFIG || {});

  global.CohabitatConfig = cfg;
})(window);
