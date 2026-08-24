#!/bin/sh
# sync-assets.sh — copie l'application web dans l'APK.
#
#   ./sync-assets.sh
#
# A relancer apres chaque modification de l'interface, avant de
# reconstruire dans Android Studio. Ne copie que ce dont la
# demonstration a besoin : pas de sql/, pas de deploy/, pas de .git.

set -eu
ICI="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
DEPOT="$(CDPATH='' cd -- "$ICI/.." && pwd)"
DEST="$ICI/app/src/main/assets"

mkdir -p "$DEST"
rm -f "$DEST"/*.html "$DEST"/*.js
for f in index.html balanceOps.js demo-data.js manifest.webmanifest; do
  cp "$DEPOT/$f" "$DEST/$f"
  echo "  + $f"
done

# Icones de l'application installable.
if [ -d "$DEPOT/icons" ]; then
  mkdir -p "$DEST/icons"
  cp "$DEPOT/icons/"* "$DEST/icons/" 2>/dev/null || true
  echo "  + icons/"
fi

# Librairies tierces si elles ont ete rapatriees (deploy/scripts/fetch-vendor.sh).
# Facultatif : le mode demonstration fonctionne sans, l'interface tolere
# l'absence du SDK Supabase.
if [ -d "$DEPOT/vendor" ]; then
  mkdir -p "$DEST/vendor"
  cp "$DEPOT/vendor/"* "$DEST/vendor/" 2>/dev/null || true
  echo "  + vendor/"
fi

# Configuration de demonstration : aucune adresse reelle. Meme si
# quelqu'un quittait le mode demo, il n'y aurait rien a joindre — et
# l'application n'a de toute facon pas la permission reseau.
cat > "$DEST/config.js" <<'CFG'
/* Genere par android/sync-assets.sh — configuration de demonstration.
   Aucune adresse reelle : cette application ne se connecte a rien. */
window.COHABITAT_CONFIG = {
  instance: { id: 'demo', name: 'Immeuble de démonstration' },
  supabaseUrl: 'https://demo.invalid',
  supabaseAnonKey: 'demo',
  siteUrl: 'https://demo.invalid',
  central:    { enabled: false, url: '', key: '', viaFederation: false },
  federation: { enabled: false, url: '' },
  analytics:  { enabled: false, gaId: '' },
  lunchMachine: { kioskBase: '', centralUrl: '' },
  assets: {
    supabaseJs: 'vendor/supabase.js',
    jspdf: 'vendor/jspdf.umd.min.js',
    jspdfAutotable: 'vendor/jspdf.plugin.autotable.min.js',
    fontsCss: null, fontsPreconnect: null, favicon: null
  }
};
CFG
# Le fichier du depot definit CohabitatConfig en fusionnant les valeurs
# ci-dessus avec ses defauts : sans lui, l'interface ne trouve pas sa
# configuration et s'arrete des la premiere ligne.
cat "$DEPOT/config.js" >> "$DEST/config.js"
echo "  + config.js (démonstration)"

# Les URL tierces de la page pointent vers vendor/ : sans reseau, un
# appel au CDN resterait pendant jusqu'au delai d'expiration.
node "$DEPOT/deploy/scripts/render-index.mjs" > "$DEST/index.html.tmp" 2>/dev/null \
  && mv "$DEST/index.html.tmp" "$DEST/index.html" \
  && echo "  + index.html (librairies locales)" \
  || { rm -f "$DEST/index.html.tmp"; echo "  ! render-index indisponible — index.html copie tel quel"; }

echo "Assets prêts dans $DEST"
