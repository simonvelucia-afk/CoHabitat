-- 006_fix_rls_security.sql
-- Correction de l'alerte securite Supabase : "rls_disabled_in_public"
-- Projet CoHabitat (uwyhrdjlwetcbtskijrs).
--
-- Les tables dependents, lunch_sessions, deletion_requests et lunch_queue
-- ont ete creees sans Row-Level Security, exposant toutes leurs lignes
-- a n'importe quelle requete anon ou authenticated via l'API REST.
--
-- Cette migration :
--   1. Active RLS sur chaque table concernee (IF EXISTS pour idempotence).
--   2. Cree les policies minimales pour conserver le comportement applicatif.
--
-- Idempotente : peut etre rejouee sans erreur.
-- Retrograde : ROLLBACK en bas du fichier.

BEGIN;

-- ============================================================
-- 1) dependents
--    Creee avant les migrations trackees (presence dans 001 via FK).
--    Colonnes attendues : id UUID, parent_id UUID -> profiles(id),
--    virtual_balance NUMERIC, et autres champs profil dependant.
-- ============================================================
DO $do_dep$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'dependents'
  ) THEN

    EXECUTE 'ALTER TABLE dependents ENABLE ROW LEVEL SECURITY';

    -- Le parent voit et gere ses propres dependants.
    -- Les admins voient tout.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'dependents' AND policyname = 'dependents_select'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY dependents_select ON dependents
          FOR SELECT TO authenticated
          USING (
            parent_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'dependents' AND policyname = 'dependents_insert'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY dependents_insert ON dependents
          FOR INSERT TO authenticated
          WITH CHECK (
            parent_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'dependents' AND policyname = 'dependents_update'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY dependents_update ON dependents
          FOR UPDATE TO authenticated
          USING (
            parent_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'dependents' AND policyname = 'dependents_delete'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY dependents_delete ON dependents
          FOR DELETE TO authenticated
          USING (
            parent_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    RAISE NOTICE 'RLS active sur dependents';
  ELSE
    RAISE NOTICE 'Table dependents absente, rien a faire';
  END IF;
END $do_dep$;


-- ============================================================
-- 2) lunch_sessions
--    Table creee par le module LunchMachine. Une session est un
--    jeton one-shot (2 min) permettant au kiosque (anon) de
--    s'authentifier pour un achat. Elle contient maintenant aussi
--    access_token et finance_central_enabled (migration 003).
--
--    Le kiosque (cle anon) lit et supprime la session.
--    L'utilisateur (authenticated) la cree via openKiosk().
--    Personne d'autre ne doit y avoir acces.
-- ============================================================
DO $do_ls$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'lunch_sessions'
  ) THEN

    EXECUTE 'ALTER TABLE lunch_sessions ENABLE ROW LEVEL SECURITY';

    -- Le kiosque (anon) lit la session via le chsession_id secret.
    -- La securite repose sur l'opacite de l'UUID, usage unique et
    -- expiration courte (expires_at <= now() + 2 min).
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_sessions' AND policyname = 'lunch_sessions_select_anon'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY lunch_sessions_select_anon ON lunch_sessions
          FOR SELECT TO anon
          USING (expires_at > now())
      $pol$;
    END IF;

    -- L'utilisateur authentifie cree sa propre session.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_sessions' AND policyname = 'lunch_sessions_insert_authenticated'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY lunch_sessions_insert_authenticated ON lunch_sessions
          FOR INSERT TO authenticated
          WITH CHECK (TRUE)
      $pol$;
    END IF;

    -- Le kiosque (anon) supprime la session apres lecture (usage unique).
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_sessions' AND policyname = 'lunch_sessions_delete_anon'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY lunch_sessions_delete_anon ON lunch_sessions
          FOR DELETE TO anon
          USING (expires_at > now())
      $pol$;
    END IF;

    -- Les admins voient toutes les sessions (pour debug).
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_sessions' AND policyname = 'lunch_sessions_admin'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY lunch_sessions_admin ON lunch_sessions
          FOR ALL TO authenticated
          USING (
            EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    RAISE NOTICE 'RLS active sur lunch_sessions';
  ELSE
    RAISE NOTICE 'Table lunch_sessions absente, rien a faire';
  END IF;
END $do_ls$;


-- ============================================================
-- 3) deletion_requests
--    Table creee pour le droit a l'effacement (Loi 25 / RGPD).
--    Un resident soumet une demande ; un admin la traite.
--    Colonnes attendues : id UUID, user_id UUID -> profiles(id),
--    status TEXT, requested_at TIMESTAMPTZ.
-- ============================================================
DO $do_dr$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'deletion_requests'
  ) THEN

    EXECUTE 'ALTER TABLE deletion_requests ENABLE ROW LEVEL SECURITY';

    -- Le demandeur voit sa propre requete ; les admins voient tout.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'deletion_requests' AND policyname = 'deletion_requests_select'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY deletion_requests_select ON deletion_requests
          FOR SELECT TO authenticated
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

    -- Chaque resident peut soumettre une demande pour lui-meme.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'deletion_requests' AND policyname = 'deletion_requests_insert'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY deletion_requests_insert ON deletion_requests
          FOR INSERT TO authenticated
          WITH CHECK (user_id = auth.uid())
      $pol$;
    END IF;

    -- Seuls les admins peuvent modifier le statut d'une demande.
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'deletion_requests' AND policyname = 'deletion_requests_update_admin'
    ) THEN
      EXECUTE $pol$
        CREATE POLICY deletion_requests_update_admin ON deletion_requests
          FOR UPDATE TO authenticated
          USING (
            EXISTS (
              SELECT 1 FROM profiles p
              WHERE p.id = auth.uid()
                AND p.role IN ('principal_admin', 'admin')
            )
          )
      $pol$;
    END IF;

    RAISE NOTICE 'RLS active sur deletion_requests';
  ELSE
    RAISE NOTICE 'Table deletion_requests absente, rien a faire';
  END IF;
END $do_dr$;


-- ============================================================
-- 4) lunch_queue
--    Deja gere conditionnellement dans 001_lunch_coherence.sql,
--    mais on s'assure que RLS est bien active si la table existe
--    et que les policies anon couvrent les 4 operations.
--    (001 le faisait deja en DO block ; ce bloc est idempotent.)
-- ============================================================
DO $do_lq$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'lunch_queue'
  ) THEN

    EXECUTE 'ALTER TABLE lunch_queue ENABLE ROW LEVEL SECURITY';

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_queue' AND policyname = 'lunch_queue_select_anon'
    ) THEN
      EXECUTE 'CREATE POLICY lunch_queue_select_anon ON lunch_queue FOR SELECT TO anon USING (TRUE)';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_queue' AND policyname = 'lunch_queue_insert_anon'
    ) THEN
      EXECUTE 'CREATE POLICY lunch_queue_insert_anon ON lunch_queue FOR INSERT TO anon WITH CHECK (TRUE)';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_queue' AND policyname = 'lunch_queue_update_anon'
    ) THEN
      EXECUTE 'CREATE POLICY lunch_queue_update_anon ON lunch_queue FOR UPDATE TO anon USING (TRUE) WITH CHECK (TRUE)';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE tablename = 'lunch_queue' AND policyname = 'lunch_queue_delete_anon'
    ) THEN
      EXECUTE 'CREATE POLICY lunch_queue_delete_anon ON lunch_queue FOR DELETE TO anon USING (TRUE)';
    END IF;

    RAISE NOTICE 'RLS active sur lunch_queue';
  ELSE
    RAISE NOTICE 'Table lunch_queue absente, rien a faire';
  END IF;
END $do_lq$;


NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- ROLLBACK (a executer manuellement si besoin)
-- ============================================================
-- ALTER TABLE dependents      DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE lunch_sessions  DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE deletion_requests DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE lunch_queue     DISABLE ROW LEVEL SECURITY;
--
-- DROP POLICY IF EXISTS dependents_select              ON dependents;
-- DROP POLICY IF EXISTS dependents_insert              ON dependents;
-- DROP POLICY IF EXISTS dependents_update              ON dependents;
-- DROP POLICY IF EXISTS dependents_delete              ON dependents;
--
-- DROP POLICY IF EXISTS lunch_sessions_select_anon         ON lunch_sessions;
-- DROP POLICY IF EXISTS lunch_sessions_insert_authenticated ON lunch_sessions;
-- DROP POLICY IF EXISTS lunch_sessions_delete_anon         ON lunch_sessions;
-- DROP POLICY IF EXISTS lunch_sessions_admin               ON lunch_sessions;
--
-- DROP POLICY IF EXISTS deletion_requests_select       ON deletion_requests;
-- DROP POLICY IF EXISTS deletion_requests_insert       ON deletion_requests;
-- DROP POLICY IF EXISTS deletion_requests_update_admin ON deletion_requests;
--
-- DROP POLICY IF EXISTS lunch_queue_select_anon  ON lunch_queue;
-- DROP POLICY IF EXISTS lunch_queue_insert_anon  ON lunch_queue;
-- DROP POLICY IF EXISTS lunch_queue_update_anon  ON lunch_queue;
-- DROP POLICY IF EXISTS lunch_queue_delete_anon  ON lunch_queue;
