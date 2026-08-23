-- 000_base_tables.sql
-- Tables et colonnes creees a la main dans le projet Supabase historique
-- et jamais versionnees. Une installation neuve (appliance en reseau
-- ferme, ou nouveau projet Supabase) demarrait donc avec une application
-- cassee : babillard, dependants, covoiturage a la demande, file lunch
-- et statistiques echouaient tous sur "relation does not exist".
--
-- Reconstruit ici a partir des requetes reelles de index.html, avec la
-- forme exacte attendue par le front (noms de colonnes, jointures
-- PostgREST profiles(...), valeurs de statut).
--
-- Numerote 000 pour s'appliquer avant 001 : plusieurs migrations
-- existantes (001, 003, 006) referencent ces tables.
--
-- Entierement idempotent : sur la base de production, ou tout existe
-- deja, ce fichier ne fait rien.

BEGIN;

-- ============================================================
-- 1) Colonnes profiles ajoutees au fil du temps
-- ============================================================
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS phone               TEXT,
  ADD COLUMN IF NOT EXISTS notes               TEXT,
  ADD COLUMN IF NOT EXISTS is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS resident_plan       TEXT    NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS resident_plan_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS terms_version       TEXT,
  ADD COLUMN IF NOT EXISTS terms_accepted_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS status_changed_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS status_changed_by   UUID REFERENCES profiles(id);

-- ============================================================
-- 2) Dependants (enfants, proches) rattaches a un locataire
-- ============================================================
CREATE TABLE IF NOT EXISTS dependents (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  age             INT,
  phone           TEXT,
  email           TEXT,
  pin             TEXT CHECK (pin IS NULL OR pin ~ '^[0-9]{4}$'),
  allow_spaces    BOOLEAN NOT NULL DEFAULT FALSE,
  allow_trips     BOOLEAN NOT NULL DEFAULT FALSE,
  allow_lunch     BOOLEAN NOT NULL DEFAULT FALSE,
  virtual_balance NUMERIC(10,2) NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS dependents_parent_idx ON dependents(parent_id);

-- ============================================================
-- 3) Acces aux ressources (espaces / vehicules)
-- ============================================================
-- Un droit s'attache soit a un locataire, soit a un dependant.
CREATE TABLE IF NOT EXISTS resource_access (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID REFERENCES profiles(id)   ON DELETE CASCADE,
  dependent_id  UUID REFERENCES dependents(id) ON DELETE CASCADE,
  resource_type TEXT NOT NULL CHECK (resource_type IN ('space','vehicle')),
  resource_id   UUID NOT NULL,
  granted_by    UUID REFERENCES profiles(id),
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  CHECK (num_nonnulls(user_id, dependent_id) = 1)
);
CREATE UNIQUE INDEX IF NOT EXISTS resource_access_user_idx
  ON resource_access(user_id, resource_type, resource_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS resource_access_dep_idx
  ON resource_access(dependent_id, resource_type, resource_id) WHERE dependent_id IS NOT NULL;

-- ============================================================
-- 4) Babillard
-- ============================================================
CREATE TABLE IF NOT EXISTS bulletin_board (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  content    TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS bulletin_board_created_idx ON bulletin_board(created_at DESC);

-- ============================================================
-- 5) Demandes de suppression de compte (Loi 25)
-- ============================================================
CREATE TABLE IF NOT EXISTS deletion_requests (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  reason       TEXT,
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','cancelled','processed','rejected')),
  requested_at TIMESTAMPTZ DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  processed_by UUID REFERENCES profiles(id)
);
CREATE INDEX IF NOT EXISTS deletion_requests_user_idx ON deletion_requests(user_id, status);

-- ============================================================
-- 6) Covoiturage a la demande : demandes et offres
-- ============================================================
CREATE TABLE IF NOT EXISTS passenger_requests (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id     UUID REFERENCES profiles(id) ON DELETE CASCADE,
  requester_name   TEXT,
  requester_email  TEXT,
  departure_point  TEXT NOT NULL,
  destination      TEXT NOT NULL,
  desired_datetime TIMESTAMPTZ NOT NULL,
  seats_requested  INT NOT NULL DEFAULT 1 CHECK (seats_requested > 0),
  luggage_ft3      NUMERIC(8,2) NOT NULL DEFAULT 0,
  notes            TEXT,
  status           TEXT NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','matched','cancelled','closed')),
  is_demo          BOOLEAN NOT NULL DEFAULT FALSE,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS passenger_requests_open_idx
  ON passenger_requests(status, desired_datetime);

CREATE TABLE IF NOT EXISTS driver_offers (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id           UUID NOT NULL REFERENCES passenger_requests(id) ON DELETE CASCADE,
  driver_id            UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  driver_name          TEXT,
  vehicle_id           UUID REFERENCES vehicles(id) ON DELETE SET NULL,
  luggage_accepted_ft3 NUMERIC(8,2) NOT NULL DEFAULT 0,
  message              TEXT,
  status               TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','accepted','declined','withdrawn')),
  created_at           TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS driver_offers_request_idx ON driver_offers(request_id);

-- ============================================================
-- 7) Machine Lunch : file d'attente et sessions kiosque
-- ============================================================
-- Ces deux tables vivent cote immeuble (pas sur la centrale) : le
-- kiosque les lit avec la cle anon, d'ou les politiques de 006.
CREATE TABLE IF NOT EXISTS lunch_queue (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id TEXT NOT NULL,
  user_id    UUID REFERENCES profiles(id) ON DELETE CASCADE,
  full_name  TEXT,
  unit       TEXT,
  status     TEXT NOT NULL DEFAULT 'waiting',
  joined_at  TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS lunch_queue_machine_idx ON lunch_queue(machine_id, joined_at);

-- id : genere par le client (crypto.randomUUID, avec repli texte), d'ou TEXT.
CREATE TABLE IF NOT EXISTS lunch_sessions (
  id                      TEXT PRIMARY KEY,
  machine_id              TEXT NOT NULL,
  user_id                 UUID REFERENCES profiles(id) ON DELETE CASCADE,
  full_name               TEXT,
  unit                    TEXT,
  role                    TEXT,
  resident_plan           TEXT,
  expires_at              TIMESTAMPTZ NOT NULL,
  created_at              TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 8) Vues de statistiques (page admin)
-- ============================================================
CREATE OR REPLACE VIEW stats_spaces AS
  SELECT cs.id                                        AS space_id,
         cs.name                                      AS space_name,
         COUNT(sr.id) FILTER (WHERE sr.status IN ('confirmed','completed'))          AS nb_reservations,
         COALESCE(SUM(EXTRACT(EPOCH FROM (sr.end_time - sr.start_time)) / 3600.0)
                  FILTER (WHERE sr.status IN ('confirmed','completed')), 0)::NUMERIC(10,2) AS heures_totales,
         COALESCE(SUM(sr.total_cost) FILTER (WHERE sr.status IN ('confirmed','completed')), 0)::NUMERIC(10,2) AS revenus_total,
         -- Taux d'occupation sur les 30 derniers jours, 24 h/j.
         ROUND(COALESCE(SUM(EXTRACT(EPOCH FROM (sr.end_time - sr.start_time)) / 3600.0)
               FILTER (WHERE sr.status IN ('confirmed','completed')
                         AND sr.start_time > NOW() - INTERVAL '30 days'), 0)
               / (30 * 24) * 100)::INT                AS taux_occupation_pct
    FROM common_spaces cs
    LEFT JOIN space_reservations sr ON sr.space_id = cs.id
   GROUP BY cs.id, cs.name;

CREATE OR REPLACE VIEW stats_tenants AS
  SELECT p.id                                          AS user_id,
         p.full_name,
         p.unit,
         COUNT(DISTINCT sr.id)                         AS nb_reservations_espaces,
         COUNT(DISTINCT tb.id)                         AS nb_trajets,
         COALESCE(-SUM(t.amount) FILTER (WHERE t.amount < 0 AND t.reference_type = 'space_reservation'), 0)::NUMERIC(10,2) AS depenses_espaces,
         COALESCE(-SUM(t.amount) FILTER (WHERE t.amount < 0 AND t.reference_type IN ('trip','trip_booking')), 0)::NUMERIC(10,2)  AS depenses_trajets,
         COALESCE(-SUM(t.amount) FILTER (WHERE t.amount < 0), 0)::NUMERIC(10,2) AS depenses_total
    FROM profiles p
    LEFT JOIN space_reservations sr ON sr.tenant_id = p.id AND sr.status <> 'cancelled'
    LEFT JOIN trip_bookings      tb ON tb.passenger_id = p.id
    LEFT JOIN transactions       t  ON t.user_id = p.id
   WHERE p.role <> 'demo'
   GROUP BY p.id, p.full_name, p.unit;

CREATE OR REPLACE VIEW stats_vehicles AS
  SELECT v.id                                          AS vehicle_id,
         v.model,
         v.license_plate,
         COUNT(DISTINCT tr.id)                         AS nb_trajets,
         COUNT(tb.id)                                  AS nb_passagers_total,
         COALESCE(SUM(tb.total_cost), 0)::NUMERIC(10,2) AS revenus_total
    FROM vehicles v
    LEFT JOIN trips         tr ON tr.vehicle_id = v.id
    LEFT JOIN trip_bookings tb ON tb.trip_id = tr.id AND tb.status <> 'cancelled'
   GROUP BY v.id, v.model, v.license_plate;

-- ============================================================
-- 9) RLS
-- ============================================================
-- 006_fix_rls_security.sql pose deja les politiques de dependents,
-- lunch_sessions, lunch_queue et deletion_requests, mais seulement si
-- les tables existent — ce qui n'est pas le cas sur une base neuve,
-- ou 006 s'execute avant ce fichier. On rejoue donc ici la meme
-- protection pour les tables introduites ci-dessus.
ALTER TABLE dependents         ENABLE ROW LEVEL SECURITY;
ALTER TABLE resource_access    ENABLE ROW LEVEL SECURITY;
ALTER TABLE bulletin_board     ENABLE ROW LEVEL SECURITY;
ALTER TABLE deletion_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE passenger_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_offers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE lunch_queue        ENABLE ROW LEVEL SECURITY;
ALTER TABLE lunch_sessions     ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  v_admin TEXT := 'get_my_role() IN (''admin'',''principal_admin'')';
BEGIN
  -- dependents : le parent gere les siens, l'admin voit tout.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='dependents' AND policyname='dependents_select') THEN
    EXECUTE 'CREATE POLICY dependents_select ON dependents FOR SELECT TO authenticated USING (parent_id = auth.uid() OR ' || v_admin || ')';
    EXECUTE 'CREATE POLICY dependents_insert ON dependents FOR INSERT TO authenticated WITH CHECK (parent_id = auth.uid() OR ' || v_admin || ')';
    EXECUTE 'CREATE POLICY dependents_update ON dependents FOR UPDATE TO authenticated USING (parent_id = auth.uid() OR ' || v_admin || ')';
    EXECUTE 'CREATE POLICY dependents_delete ON dependents FOR DELETE TO authenticated USING (parent_id = auth.uid() OR ' || v_admin || ')';
  END IF;

  -- resource_access : lecture de ses propres droits, gestion par l'admin.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='resource_access' AND policyname='resource_access_select') THEN
    EXECUTE 'CREATE POLICY resource_access_select ON resource_access FOR SELECT TO authenticated USING (
               user_id = auth.uid()
               OR dependent_id IN (SELECT id FROM dependents WHERE parent_id = auth.uid())
               OR ' || v_admin || ')';
    EXECUTE 'CREATE POLICY resource_access_admin ON resource_access FOR ALL TO authenticated USING (' || v_admin || ')';
  END IF;

  -- babillard : lecture par tous les authentifies, chacun supprime ses
  -- messages, l'admin moderes tout.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='bulletin_board' AND policyname='bulletin_select') THEN
    EXECUTE 'CREATE POLICY bulletin_select ON bulletin_board FOR SELECT TO authenticated USING (TRUE)';
    EXECUTE 'CREATE POLICY bulletin_insert ON bulletin_board FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid())';
    EXECUTE 'CREATE POLICY bulletin_delete ON bulletin_board FOR DELETE TO authenticated USING (user_id = auth.uid() OR ' || v_admin || ')';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='deletion_requests' AND policyname='deletion_requests_select') THEN
    EXECUTE 'CREATE POLICY deletion_requests_select ON deletion_requests FOR SELECT TO authenticated USING (user_id = auth.uid() OR ' || v_admin || ')';
    EXECUTE 'CREATE POLICY deletion_requests_insert ON deletion_requests FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid())';
    EXECUTE 'CREATE POLICY deletion_requests_update ON deletion_requests FOR UPDATE TO authenticated USING (user_id = auth.uid() OR ' || v_admin || ')';
  END IF;

  -- covoiturage a la demande : visible par tous les authentifies.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='passenger_requests' AND policyname='passenger_requests_select') THEN
    EXECUTE 'CREATE POLICY passenger_requests_select ON passenger_requests FOR SELECT TO authenticated USING (TRUE)';
    EXECUTE 'CREATE POLICY passenger_requests_insert ON passenger_requests FOR INSERT TO authenticated WITH CHECK (requester_id = auth.uid())';
    EXECUTE 'CREATE POLICY passenger_requests_update ON passenger_requests FOR UPDATE TO authenticated USING (requester_id = auth.uid() OR ' || v_admin || ')';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='driver_offers' AND policyname='driver_offers_select') THEN
    EXECUTE 'CREATE POLICY driver_offers_select ON driver_offers FOR SELECT TO authenticated USING (TRUE)';
    EXECUTE 'CREATE POLICY driver_offers_insert ON driver_offers FOR INSERT TO authenticated WITH CHECK (driver_id = auth.uid())';
    EXECUTE 'CREATE POLICY driver_offers_update ON driver_offers FOR UPDATE TO authenticated USING (driver_id = auth.uid() OR ' || v_admin || ')';
  END IF;

  -- Machine Lunch : le kiosque lit avec la cle anon, dans la fenetre
  -- de validite seulement. Meme regle que 006 pour la base historique.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lunch_queue' AND policyname='lunch_queue_select_anon') THEN
    EXECUTE 'CREATE POLICY lunch_queue_select_anon ON lunch_queue FOR SELECT TO anon, authenticated USING (TRUE)';
    EXECUTE 'CREATE POLICY lunch_queue_write ON lunch_queue FOR ALL TO authenticated USING (user_id = auth.uid() OR ' || v_admin || ') WITH CHECK (user_id = auth.uid() OR ' || v_admin || ')';
    EXECUTE 'CREATE POLICY lunch_queue_delete_anon ON lunch_queue FOR DELETE TO anon USING (expires_at < NOW())';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lunch_sessions' AND policyname='lunch_sessions_select_anon') THEN
    EXECUTE 'CREATE POLICY lunch_sessions_select_anon ON lunch_sessions FOR SELECT TO anon USING (expires_at > NOW())';
    EXECUTE 'CREATE POLICY lunch_sessions_insert_authenticated ON lunch_sessions FOR INSERT TO authenticated WITH CHECK (TRUE)';
    EXECUTE 'CREATE POLICY lunch_sessions_delete_anon ON lunch_sessions FOR DELETE TO anon USING (TRUE)';
    EXECUTE 'CREATE POLICY lunch_sessions_admin ON lunch_sessions FOR ALL TO authenticated USING (' || v_admin || ')';
  END IF;
END $$;

-- Les vues de statistiques sont exposees en lecture aux authentifies ;
-- l'interface ne les affiche que dans la page admin.
GRANT SELECT ON stats_spaces, stats_tenants, stats_vehicles TO authenticated;

-- ============================================================
-- 10) Journal d'usage
-- ============================================================
CREATE TABLE IF NOT EXISTS usage_logs (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  module     TEXT,
  action     TEXT,
  is_demo    BOOLEAN NOT NULL DEFAULT FALSE,
  language   TEXT,
  metadata   JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS usage_logs_created_idx ON usage_logs(created_at DESC);
ALTER TABLE usage_logs ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='usage_logs' AND policyname='usage_logs_admin_read') THEN
    EXECUTE 'CREATE POLICY usage_logs_admin_read ON usage_logs FOR SELECT TO authenticated
               USING (get_my_role() IN (''admin'',''principal_admin''))';
  END IF;
END $$;

-- ============================================================
-- 11) Fonctions RPC appelees par l'interface
-- ============================================================
-- Creees seulement si absentes : sur la base de production, ou elles
-- existent deja avec une implementation potentiellement differente, ce
-- bloc ne touche a rien. C'est volontairement plus prudent qu'un
-- CREATE OR REPLACE, qui ecraserait l'existant.

DO $ins$
BEGIN

IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'insert_usage_log') THEN
  EXECUTE $f$
    CREATE FUNCTION insert_usage_log(
      p_module TEXT, p_action TEXT, p_is_demo BOOLEAN DEFAULT FALSE,
      p_language TEXT DEFAULT NULL, p_metadata JSONB DEFAULT NULL
    ) RETURNS VOID AS $body$
      INSERT INTO usage_logs (user_id, module, action, is_demo, language, metadata)
      VALUES (auth.uid(), p_module, p_action, COALESCE(p_is_demo, FALSE), p_language, p_metadata);
    $body$ LANGUAGE sql SECURITY DEFINER;
  $f$;
END IF;

IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'admin_update_profile') THEN
  EXECUTE $f$
    CREATE FUNCTION admin_update_profile(
      p_user_id UUID, p_full_name TEXT, p_unit TEXT, p_role TEXT,
      p_is_approved_driver BOOLEAN, p_is_active BOOLEAN
    ) RETURNS VOID AS $body$
    BEGIN
      IF get_my_role() NOT IN ('admin','principal_admin') THEN
        RAISE EXCEPTION 'FORBIDDEN';
      END IF;
      -- Seul l'admin principal peut nommer ou destituer un admin.
      IF p_role IN ('admin','principal_admin') AND get_my_role() <> 'principal_admin' THEN
        RAISE EXCEPTION 'FORBIDDEN';
      END IF;
      UPDATE profiles
         SET full_name = p_full_name,
             unit = p_unit,
             role = p_role,
             is_approved_driver = COALESCE(p_is_approved_driver, FALSE),
             is_active = COALESCE(p_is_active, TRUE),
             updated_at = NOW()
       WHERE id = p_user_id;
    END;
    $body$ LANGUAGE plpgsql SECURITY DEFINER;
  $f$;
END IF;

IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'admin_set_balance') THEN
  EXECUTE $f$
    CREATE FUNCTION admin_set_balance(p_user_id UUID, p_balance NUMERIC)
    RETURNS NUMERIC AS $body$
    DECLARE
      v_current NUMERIC;
      v_delta   NUMERIC;
    BEGIN
      IF get_my_role() NOT IN ('admin','principal_admin') THEN
        RAISE EXCEPTION 'FORBIDDEN';
      END IF;
      SELECT virtual_balance INTO v_current FROM profiles WHERE id = p_user_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'PROFILE_NOT_FOUND'; END IF;
      v_delta := COALESCE(p_balance, 0) - COALESCE(v_current, 0);
      IF v_delta = 0 THEN RETURN v_current; END IF;
      -- Passe par adjust_balance pour que l'ajustement laisse une trace
      -- au grand livre plutot que de modifier le solde en silence.
      RETURN adjust_balance(p_user_id, v_delta, 'admin_credit', NULL, NULL,
                            'Ajustement administrateur', auth.uid(), FALSE);
    END;
    $body$ LANGUAGE plpgsql SECURITY DEFINER;
  $f$;
END IF;

IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'transfer_to_dependent') THEN
  EXECUTE $f$
    CREATE FUNCTION transfer_to_dependent(p_parent_id UUID, p_dependent_id UUID, p_amount NUMERIC)
    RETURNS NUMERIC AS $body$
    DECLARE
      v_parent_balance NUMERIC;
    BEGIN
      IF p_amount <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
      IF auth.uid() IS NOT NULL AND auth.uid() <> p_parent_id
         AND get_my_role() NOT IN ('admin','principal_admin') THEN
        RAISE EXCEPTION 'FORBIDDEN';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM dependents WHERE id = p_dependent_id AND parent_id = p_parent_id) THEN
        RAISE EXCEPTION 'DEPENDENT_NOT_FOUND';
      END IF;
      SELECT virtual_balance INTO v_parent_balance FROM profiles WHERE id = p_parent_id FOR UPDATE;
      IF COALESCE(v_parent_balance, 0) < p_amount THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

      UPDATE dependents SET virtual_balance = COALESCE(virtual_balance, 0) + p_amount
       WHERE id = p_dependent_id;
      RETURN adjust_balance(p_parent_id, -p_amount, 'admin_credit', p_dependent_id, 'dependent',
                            'Transfert vers dependant', p_parent_id, FALSE);
    END;
    $body$ LANGUAGE plpgsql SECURITY DEFINER;
  $f$;
END IF;

IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'anonymize_profile') THEN
  EXECUTE $f$
    CREATE FUNCTION anonymize_profile(p_user_id UUID)
    RETURNS VOID AS $body$
    BEGIN
      IF get_my_role() NOT IN ('admin','principal_admin') THEN
        RAISE EXCEPTION 'FORBIDDEN';
      END IF;
      -- Loi 25 : on efface les renseignements personnels mais on garde
      -- la ligne, car l'historique financier y est rattache.
      UPDATE profiles
         SET full_name = 'Compte anonymise',
             email     = 'anonyme+' || LEFT(p_user_id::TEXT, 8) || '@anonyme.local',
             phone     = NULL,
             notes     = NULL,
             unit      = NULL,
             is_active = FALSE,
             updated_at = NOW()
       WHERE id = p_user_id;
      UPDATE dependents SET name = 'Dependant anonymise', phone = NULL, email = NULL, pin = NULL
       WHERE parent_id = p_user_id;
    END;
    $body$ LANGUAGE plpgsql SECURITY DEFINER;
  $f$;
END IF;

END
$ins$;

-- Les RPC de facturation appelees par l'interface (list_client_invoices,
-- get_invoice_detail, request_plan_upgrade) appartiennent a la centrale
-- Modulimo : elles ne sont pas recreees ici. En instance autonome, les
-- ecrans correspondants affichent une erreur de chargement, ce qui est le
-- comportement attendu tant que le module de facturation centrale n'est
-- pas jumele.

COMMIT;
