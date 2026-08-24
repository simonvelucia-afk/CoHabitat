#!/bin/sh
# fetch-vendor.sh — recupere les librairies tierces pour un deploiement
# sans acces Internet.
#
# A executer sur une machine CONNECTEE, avant de transporter le paquet
# vers le reseau ferme :
#
#   ./scripts/fetch-vendor.sh
#
# Depose dans ../vendor/ : le SDK Supabase (classique et module), jsPDF
# et son extension tableaux, et l'icone du site. Les polices Google sont
# facultatives (--fonts) : sans elles, l'interface utilise la pile de
# polices systeme, ce qui reste parfaitement lisible.

set -eu

DEST="$(CDPATH='' cd -- "$(dirname -- "$0")/../../vendor" 2>/dev/null && pwd || true)"
if [ -z "$DEST" ]; then
  DEST="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/vendor"
  mkdir -p "$DEST"
fi

get() {
  echo "  → $2"
  curl -fsSL "$1" -o "$DEST/$2"
}

echo "[vendor] destination : $DEST"
get "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"                                   "supabase.js"
get "https://esm.sh/@supabase/supabase-js@2?bundle"                                          "supabase.esm.js"
get "https://cdn.jsdelivr.net/npm/jspdf@2.5.2/dist/jspdf.umd.min.js"                         "jspdf.umd.min.js"
get "https://cdn.jsdelivr.net/npm/jspdf-autotable@3.8.4/dist/jspdf.plugin.autotable.min.js"  "jspdf.plugin.autotable.min.js"

if [ "${1:-}" = "--fonts" ]; then
  echo "[vendor] polices"
  UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
  CSS_URL="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Sans:wght@300;400;500;600&family=Space+Mono&display=swap"
  curl -fsSL -A "$UA" "$CSS_URL" -o "$DEST/fonts.css"
  # Chaque fichier de police est rapatrie, puis l'URL distante est
  # remplacee par le chemin local dans la feuille de style.
  grep -o 'https://fonts.gstatic.com[^)]*' "$DEST/fonts.css" | sort -u | while read -r url; do
    name="$(basename "$url")"
    curl -fsSL "$url" -o "$DEST/$name"
    sed -i.bak "s#$url#$name#g" "$DEST/fonts.css"
  done
  rm -f "$DEST/fonts.css.bak"
  echo "[vendor] polices locales pretes — mettre VENDOR_FONTS=true dans .env"
fi

echo "[vendor] termine"
