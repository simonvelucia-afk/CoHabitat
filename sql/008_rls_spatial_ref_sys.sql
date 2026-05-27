-- 008_rls_spatial_ref_sys.sql
-- Correction de l'alerte securite Supabase : "rls_disabled_in_public"
-- Projet CoHabitat (uwyhrdjlwetcbtskijrs).
--
-- La table public.spatial_ref_sys est installee automatiquement par
-- l'extension postgis (cf. schema.sql en tete : CREATE EXTENSION postgis).
-- Elle contient uniquement des donnees de reference statiques (codes
-- EPSG / definitions de systemes de coordonnees) ; aucune donnee
-- utilisateur n'y transite. Mais comme elle vit dans le schema public,
-- elle est exposee par PostgREST et declenche l'alerte Supabase tant
-- que RLS n'est pas active.
--
-- Note : on n'utilise pas reellement PostGIS dans l'app (les colonnes
-- lat/lng sont des DECIMAL, pas des geometry/geography). On garde
-- toutefois l'extension installee pour ne pas casser de futurs usages
-- (calcul de detour, etc.) ; on se contente de proteger sa table de
-- reference.
--
-- Fix : activer RLS + policy SELECT permissive pour anon/authenticated
-- afin que tout appel PostGIS qui lit spatial_ref_sys continue de
-- fonctionner. Aucune policy INSERT/UPDATE/DELETE : seuls les roles
-- superuser/postgres (qui bypassent RLS) peuvent ecrire, ce qui est
-- exactement le comportement attendu pour une table de reference.
--
-- Idempotente : peut etre rejouee sans erreur.

BEGIN;

-- spatial_ref_sys appartient a l'extension postgis. Sur Supabase le role
-- postgres a les droits pour activer RLS dessus ; sur une instance plus
-- restreinte cet ALTER pourrait necessiter d'etre execute par le role
-- proprietaire de l'extension. Le bloc DO permet a la migration de
-- continuer si la table n'existe pas (postgis non installe).
DO $do_srs$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'spatial_ref_sys'
      AND table_type = 'BASE TABLE'
  ) THEN

    EXECUTE 'ALTER TABLE public.spatial_ref_sys ENABLE ROW LEVEL SECURITY';

    -- Lecture autorisee pour tout le monde (donnees de reference publiques).
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'spatial_ref_sys'
        AND policyname = 'spatial_ref_sys_read_all'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY spatial_ref_sys_read_all ON public.spatial_ref_sys
          FOR SELECT TO anon, authenticated
          USING (TRUE)
      $pol$;
    END IF;

    -- Pas de policy INSERT/UPDATE/DELETE : les ecritures restent reservees
    -- aux roles qui bypassent RLS (postgres, superuser), ce qui correspond
    -- au comportement par defaut de PostGIS lors des mises a jour.

    RAISE NOTICE 'RLS active sur public.spatial_ref_sys';
  ELSE
    RAISE NOTICE 'Table spatial_ref_sys absente (postgis non installe), rien a faire';
  END IF;
END $do_srs$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- ROLLBACK (a executer manuellement si besoin)
-- ============================================================
-- DROP POLICY IF EXISTS spatial_ref_sys_read_all ON public.spatial_ref_sys;
-- ALTER TABLE public.spatial_ref_sys DISABLE ROW LEVEL SECURITY;
