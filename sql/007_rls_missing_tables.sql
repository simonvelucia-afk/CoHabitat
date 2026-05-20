-- 007_rls_missing_tables.sql
-- Correction de l'alerte securite Supabase : "rls_disabled_in_public"
-- Projet CoHabitat (uwyhrdjlwetcbtskijrs).
--
-- Les tables bulletin_board, passenger_requests, driver_offers et
-- resource_access ont ete creees sans Row-Level Security, exposant
-- toutes leurs lignes a n'importe quelle requete anon ou authenticated
-- via l'API REST Supabase.
--
-- Cette migration :
--   1. Active RLS sur chaque table (IF EXISTS pour idempotence).
--   2. Cree les policies minimales pour conserver le comportement applicatif.
--
-- Idempotente : peut etre rejouee sans erreur.
-- Retrograde : ROLLBACK en bas du fichier.

BEGIN;

-- ============================================================
-- 1) bulletin_board
--    Babillard communautaire : les residents publient des
--    messages visibles par tous leurs voisins.
--    Colonnes attendues : id UUID, content TEXT,
--    user_id UUID -> profiles(id), created_at TIMESTAMPTZ.
-- ============================================================
DO $do_bb$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'bulletin_board'
      AND table_type = 'BASE TABLE'
  ) THEN

    EXECUTE 'ALTER TABLE bulletin_board ENABLE ROW LEVEL SECURITY';

    -- Tous les residents authentifies voient tous les messages.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'bulletin_board' AND policyname = 'bb_select'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY bb_select ON bulletin_board
          FOR SELECT TO authenticated
          USING (TRUE)
      $pol$;
    END IF;

    -- Un resident ne peut publier que pour lui-meme.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'bulletin_board' AND policyname = 'bb_insert'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY bb_insert ON bulletin_board
          FOR INSERT TO authenticated
          WITH CHECK (user_id = auth.uid())
      $pol$;
    END IF;

    -- Le proprietaire du message ou un admin peut le supprimer.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'bulletin_board' AND policyname = 'bb_delete'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY bb_delete ON bulletin_board
          FOR DELETE TO authenticated
          USING (
            user_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    RAISE NOTICE 'RLS active sur bulletin_board';
  ELSE
    RAISE NOTICE 'Table bulletin_board absente ou vue, rien a faire';
  END IF;
END $do_bb$;


-- ============================================================
-- 2) passenger_requests
--    Demandes de covoiturage publiees par les passagers.
--    Colonnes attendues : id UUID, requester_id UUID -> profiles(id),
--    departure_point TEXT, destination TEXT, desired_datetime TIMESTAMPTZ,
--    seats_requested INT, luggage_ft3 NUMERIC, status TEXT,
--    is_demo BOOLEAN.
-- ============================================================
DO $do_pr$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'passenger_requests'
      AND table_type = 'BASE TABLE'
  ) THEN

    EXECUTE 'ALTER TABLE passenger_requests ENABLE ROW LEVEL SECURITY';

    -- Tous les authentifies voient les demandes ouvertes (chauffeurs potentiels)
    -- + le demandeur voit les siennes quel que soit le statut
    -- + les admins voient tout.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'passenger_requests' AND policyname = 'pr_select'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY pr_select ON passenger_requests
          FOR SELECT TO authenticated
          USING (
            status = 'open'
            OR requester_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    -- Chaque resident cree ses propres demandes.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'passenger_requests' AND policyname = 'pr_insert'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY pr_insert ON passenger_requests
          FOR INSERT TO authenticated
          WITH CHECK (requester_id = auth.uid())
      $pol$;
    END IF;

    -- Le demandeur peut modifier/annuler sa propre demande ; admins aussi.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'passenger_requests' AND policyname = 'pr_update'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY pr_update ON passenger_requests
          FOR UPDATE TO authenticated
          USING (
            requester_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    -- Le demandeur peut supprimer sa propre demande ; admins aussi.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'passenger_requests' AND policyname = 'pr_delete'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY pr_delete ON passenger_requests
          FOR DELETE TO authenticated
          USING (
            requester_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    RAISE NOTICE 'RLS active sur passenger_requests';
  ELSE
    RAISE NOTICE 'Table passenger_requests absente ou vue, rien a faire';
  END IF;
END $do_pr$;


-- ============================================================
-- 3) driver_offers
--    Propositions de covoiturage faites par des conducteurs
--    en reponse a une passenger_request.
--    Colonnes attendues : id UUID, request_id UUID,
--    driver_id UUID -> profiles(id), driver_name TEXT,
--    vehicle_id UUID, luggage_accepted_ft3 NUMERIC, message TEXT.
-- ============================================================
DO $do_do$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'driver_offers'
      AND table_type = 'BASE TABLE'
  ) THEN

    EXECUTE 'ALTER TABLE driver_offers ENABLE ROW LEVEL SECURITY';

    -- Le chauffeur voit ses propres offres.
    -- Le passager voit les offres sur ses propres demandes.
    -- Les admins voient tout.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'driver_offers' AND policyname = 'do_select'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY do_select ON driver_offers
          FOR SELECT TO authenticated
          USING (
            driver_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM passenger_requests pr
              WHERE pr.id = request_id
                AND pr.requester_id = auth.uid()
            )
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    -- Seuls les conducteurs approuves peuvent publier une offre pour eux-memes.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'driver_offers' AND policyname = 'do_insert'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY do_insert ON driver_offers
          FOR INSERT TO authenticated
          WITH CHECK (
            driver_id = auth.uid()
            AND EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.is_approved_driver = TRUE
            )
          )
      $pol$;
    END IF;

    -- Le chauffeur peut modifier sa propre offre.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'driver_offers' AND policyname = 'do_update'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY do_update ON driver_offers
          FOR UPDATE TO authenticated
          USING (
            driver_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    -- Le chauffeur peut retirer sa propre offre ; admins aussi.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'driver_offers' AND policyname = 'do_delete'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY do_delete ON driver_offers
          FOR DELETE TO authenticated
          USING (
            driver_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    RAISE NOTICE 'RLS active sur driver_offers';
  ELSE
    RAISE NOTICE 'Table driver_offers absente ou vue, rien a faire';
  END IF;
END $do_do$;


-- ============================================================
-- 4) resource_access
--    Controle fin d'acces aux ressources (espaces, vehicules)
--    pour les residents et leurs dependants. La table porte
--    soit user_id (resident direct) soit dependent_id (dependant),
--    l'autre etant NULL selon le cas.
--    Colonnes attendues : id UUID, user_id UUID (nullable),
--    dependent_id UUID (nullable), resource_type TEXT,
--    resource_id UUID, granted_by UUID.
-- ============================================================
DO $do_ra$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'resource_access'
      AND table_type = 'BASE TABLE'
  ) THEN

    EXECUTE 'ALTER TABLE resource_access ENABLE ROW LEVEL SECURITY';

    -- Un resident voit ses propres entrees (user_id = auth.uid()).
    -- Un parent voit les acces de ses dependants (via dependents.parent_id).
    -- Les admins voient tout.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'resource_access' AND policyname = 'ra_select'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY ra_select ON resource_access
          FOR SELECT TO authenticated
          USING (
            user_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM dependents d
              WHERE d.id = dependent_id
                AND d.parent_id = auth.uid()
            )
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    -- Les admins accordent l'acces a un resident.
    -- Un parent peut aussi accorder l'acces a ses propres dependants.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'resource_access' AND policyname = 'ra_insert'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY ra_insert ON resource_access
          FOR INSERT TO authenticated
          WITH CHECK (
            EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
            OR (
              dependent_id IS NOT NULL
              AND EXISTS (
                SELECT 1 FROM dependents d
                WHERE d.id = dependent_id
                  AND d.parent_id = auth.uid()
              )
            )
          )
      $pol$;
    END IF;

    -- Les admins revoquent l'acces d'un resident.
    -- Un parent peut revoquer l'acces de ses propres dependants.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'resource_access' AND policyname = 'ra_delete'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY ra_delete ON resource_access
          FOR DELETE TO authenticated
          USING (
            EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
            OR (
              dependent_id IS NOT NULL
              AND EXISTS (
                SELECT 1 FROM dependents d
                WHERE d.id = dependent_id
                  AND d.parent_id = auth.uid()
              )
            )
          )
      $pol$;
    END IF;

    RAISE NOTICE 'RLS active sur resource_access';
  ELSE
    RAISE NOTICE 'Table resource_access absente ou vue, rien a faire';
  END IF;
END $do_ra$;


-- ============================================================
-- 5) stats_spaces / stats_tenants / stats_vehicles
--    Tables de statistiques admin (ignorees si ce sont des vues
--    grace au filtre table_type = 'BASE TABLE').
-- ============================================================
DO $do_stats$
DECLARE
  v_tbl TEXT;
BEGIN
  FOREACH v_tbl IN ARRAY ARRAY['stats_spaces', 'stats_tenants', 'stats_vehicles']
  LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public'
        AND table_name = v_tbl
        AND table_type = 'BASE TABLE'
    ) THEN
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', v_tbl);

      IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = v_tbl AND policyname = v_tbl || '_admin_select'
      ) THEN
        EXECUTE format(
          $fmt$CREATE POLICY %I ON %I
            FOR SELECT TO authenticated
            USING (
              EXISTS (
                SELECT 1 FROM profiles p
                WHERE p.id = auth.uid()
                  AND p.role IN ('principal_admin', 'admin')
              )
            )$fmt$,
          v_tbl || '_admin_select', v_tbl
        );
      END IF;

      RAISE NOTICE 'RLS active sur %', v_tbl;
    ELSE
      RAISE NOTICE 'Table % absente ou vue, rien a faire', v_tbl;
    END IF;
  END LOOP;
END $do_stats$;


NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- ROLLBACK (a executer manuellement si besoin)
-- ============================================================
-- ALTER TABLE bulletin_board      DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE passenger_requests  DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE driver_offers       DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE resource_access     DISABLE ROW LEVEL SECURITY;
--
-- DROP POLICY IF EXISTS bb_select   ON bulletin_board;
-- DROP POLICY IF EXISTS bb_insert   ON bulletin_board;
-- DROP POLICY IF EXISTS bb_delete   ON bulletin_board;
--
-- DROP POLICY IF EXISTS pr_select   ON passenger_requests;
-- DROP POLICY IF EXISTS pr_insert   ON passenger_requests;
-- DROP POLICY IF EXISTS pr_update   ON passenger_requests;
-- DROP POLICY IF EXISTS pr_delete   ON passenger_requests;
--
-- DROP POLICY IF EXISTS do_select   ON driver_offers;
-- DROP POLICY IF EXISTS do_insert   ON driver_offers;
-- DROP POLICY IF EXISTS do_update   ON driver_offers;
-- DROP POLICY IF EXISTS do_delete   ON driver_offers;
--
-- DROP POLICY IF EXISTS ra_select   ON resource_access;
-- DROP POLICY IF EXISTS ra_insert   ON resource_access;
-- DROP POLICY IF EXISTS ra_delete   ON resource_access;
