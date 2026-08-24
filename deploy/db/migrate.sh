#!/bin/sh
# migrate.sh — application ordonnee et idempotente du schema.
#
#   migrate.sh bootstrap   roles, schema auth, extensions (avant GoTrue)
#   migrate.sh app         schema.sql puis sql/*.sql (apres GoTrue)
#
# Chaque fichier applique est inscrit dans app_migrations avec l'empreinte
# de son contenu. Un fichier deja applique est saute ; un fichier modifie
# apres coup arrete la migration plutot que de rejouer un SQL qui n'est
# pas idempotent (schema.sql ne l'est pas).

set -eu

PHASE="${1:-app}"
PSQL="psql -v ON_ERROR_STOP=1 -q"

wait_for_db() {
  i=0
  until pg_isready -q; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && { echo "[migrate] base injoignable"; exit 1; }
    sleep 1
  done
}

ensure_registry() {
  $PSQL -c "CREATE TABLE IF NOT EXISTS app_migrations (
              filename   TEXT PRIMARY KEY,
              checksum   TEXT NOT NULL,
              applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );"
}

apply_once() {
  file="$1"
  name="$(basename "$file")"
  sum="$(sha256sum "$file" | cut -d' ' -f1)"
  known="$($PSQL -tAc "SELECT checksum FROM app_migrations WHERE filename = '$name'")"

  if [ -n "$known" ]; then
    if [ "$known" != "$sum" ]; then
      echo "[migrate] ARRET : $name a change depuis son application."
      echo "[migrate] Creer une nouvelle migration plutot que de modifier celle-ci."
      exit 1
    fi
    echo "[migrate] = $name (deja applique)"
    return 0
  fi

  echo "[migrate] + $name"
  $PSQL -f "$file"
  $PSQL -c "INSERT INTO app_migrations (filename, checksum) VALUES ('$name', '$sum')"
}

wait_for_db

case "$PHASE" in
  bootstrap)
    ensure_registry
    # Le socle est rejoue a chaque demarrage : il est idempotent et doit
    # suivre les evolutions de l'image. Il n'entre donc pas au registre.
    $PSQL -f /db/00-bootstrap.sql
    # Mots de passe des roles de service : pris dans l'environnement,
    # jamais ecrits dans un fichier SQL du depot.
    $PSQL -c "ALTER ROLE authenticator       PASSWORD '${AUTHENTICATOR_PASSWORD}'"
    $PSQL -c "ALTER ROLE supabase_auth_admin PASSWORD '${AUTH_ADMIN_PASSWORD}'"
    echo "[migrate] socle en place"
    ;;

  app)
    ensure_registry
    # Le compte de demonstration reference par schema.sql doit exister
    # dans auth.users avant l'insertion du profil correspondant.
    $PSQL -c "INSERT INTO auth.users (id, email, aud, role, created_at, updated_at)
              VALUES ('00000000-0000-0000-0000-000000000001', 'demo@demo.local',
                      'authenticated', 'authenticated', NOW(), NOW())
              ON CONFLICT (id) DO NOTHING;"
    apply_once /app/schema.sql
    for f in /app/sql/*.sql; do
      [ -f "$f" ] || continue
      apply_once "$f"
    done
    # Rattrapage des droits : ALTER DEFAULT PRIVILEGES ne couvre que les
    # objets crees apres coup et par le meme role. Un GRANT explicite
    # garantit que toutes les tables et vues du schema public, y compris
    # celles d'une base plus ancienne, restent accessibles a PostgREST.
    # RLS reste seul juge de ce que chaque compte voit.
    $PSQL -c "GRANT ALL ON ALL TABLES    IN SCHEMA public TO anon, authenticated, service_role"
    $PSQL -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role"
    $PSQL -c "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role"
    $PSQL -c "NOTIFY pgrst, 'reload schema'"
    echo "[migrate] schema applicatif a jour"
    ;;

  *)
    echo "usage: migrate.sh [bootstrap|app]"
    exit 2
    ;;
esac
