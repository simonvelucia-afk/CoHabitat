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
      key:     'sb_publishable_2V-eHOvw1v_Xwr1bpHfHLg_cbHW9ctD'
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

    // Analytique. Coupee automatiquement en reseau ferme : le script
    // Google ne serait de toute facon pas joignable.
    analytics: {
      enabled: true,
      gaId:    'G-EWP5ER8KFJ'
    },

    // Librairies tierces et polices. En reseau ferme, deploy/ les
    // sert depuis vendor/ — voir deploy/scripts/fetch-vendor.sh.
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

  // Injection des <link>/<script> tiers depuis le <head>. document.write
  // est volontaire : il preserve l'ordre d'execution synchrone attendu
  // par le reste de la page (supabase-js doit exister avant l'init).
  cfg.writeHeadAssets = function (parts) {
    var a = cfg.assets;
    var want = {};
    (parts || ['favicon', 'supabaseJs', 'jspdf', 'fonts']).forEach(function (p) { want[p] = true; });
    var out = '';
    if (want.favicon && a.favicon) {
      out += '<link rel="icon" type="image/png" href="' + a.favicon + '">';
    }
    if (want.supabaseJs && a.supabaseJs) {
      out += '<scr' + 'ipt src="' + a.supabaseJs + '"></scr' + 'ipt>';
    }
    if (want.jspdf && a.jspdf) {
      out += '<scr' + 'ipt src="' + a.jspdf + '"></scr' + 'ipt>';
      if (a.jspdfAutotable) out += '<scr' + 'ipt src="' + a.jspdfAutotable + '"></scr' + 'ipt>';
    }
    if (want.fonts && a.fontsCss) {
      if (a.fontsPreconnect) out += '<link rel="preconnect" href="' + a.fontsPreconnect + '">';
      out += '<link href="' + a.fontsCss + '" rel="stylesheet">';
    }
    if (out) document.write(out);
  };

  global.CohabitatConfig = cfg;
})(window);
