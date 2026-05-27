-- 008_rls_spatial_ref_sys.sql
-- Correction de l'alerte securite Supabase : "rls_disabled_in_public"
-- sur public.spatial_ref_sys.
-- Projet CoHabitat (uwyhrdjlwetcbtskijrs).
--
-- Contexte
-- --------
-- spatial_ref_sys est installee par l'extension postgis dans le schema
-- public. Elle est detenue par le role proprietaire de l'extension, pas
-- par le role qui execute les migrations via le SQL Editor de Supabase.
-- Resultat : toute tentative de proteger la table directement echoue
-- avec `42501: must be owner of table spatial_ref_sys`, que ce soit via
--   ALTER TABLE public.spatial_ref_sys ENABLE ROW LEVEL SECURITY;
-- ou via
--   ALTER EXTENSION postgis SET SCHEMA extensions;
--
-- Approche retenue
-- ----------------
-- L'extension postgis n'est PAS utilisee par l'application :
--   * schema.sql commente l'extension comme "(optionnel)" ;
--   * toutes les colonnes lat/lng sont DECIMAL(10,7), pas geometry
--     ni geography ;
--   * une recherche dans le repo (`ST_`, `postgis`, `geography`)
--     retourne zero match.
--
-- On supprime donc l'extension : spatial_ref_sys disparait avec elle,
-- ce qui resout l'alerte Supabase a la source sans avoir besoin des
-- droits sur la table. Si un usage PostGIS arrive un jour, il suffira
-- de relancer `CREATE EXTENSION postgis;` (de preference dans un schema
-- dedie, p.ex. extensions, plutot que public).
--
-- Idempotente : DROP EXTENSION IF EXISTS ne fait rien si deja absente.

BEGIN;

DROP EXTENSION IF EXISTS postgis CASCADE;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- ROLLBACK (a executer manuellement si besoin)
-- ============================================================
-- CREATE EXTENSION IF NOT EXISTS postgis;
