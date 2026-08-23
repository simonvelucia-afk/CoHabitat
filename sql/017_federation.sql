-- 017_federation.sql
-- Federation entre instances CoHabitat autonomes.
--
-- Modele : chaque immeuble fait tourner sa propre instance complete
-- (base + auth + interface). Deux instances jumelees se joignent par
-- VPN et se reconnaissent par leur cle publique Ed25519, echangee une
-- seule fois au jumelage. Il n'y a pas d'autorite centrale requise :
-- la centrale Modulimo, quand elle existe, n'est qu'un pair de plus
-- qui a le droit de presenter des pairs (introduced_by='central:<id>').
--
-- Deux capacites, activables independamment par pair :
--   * allow_reservations : un usager du pair peut reserver un espace ici
--   * allow_finance      : les soldes peuvent circuler entre les deux
--
-- Un usager distant n'a JAMAIS de compte ici. Il est represente par un
-- profil ombre (federation_guests -> profiles.origin_peer_id), ce qui
-- permet de reutiliser tel quel le reste du schema (reservations, RLS,
-- historique) sans le rendre conscient de la federation.
--
-- Idempotence : toute operation inter-instances porte une cle fournie
-- par l'appelant et journalisee dans federation_requests. Un rejeu
-- apres coupure VPN retourne la reponse d'origine au lieu de rejouer
-- l'effet. C'est la meme discipline que finance-bridge cote centrale.

BEGIN;

-- ============================================================
-- 1) Identite de CETTE instance (une seule ligne)
-- ============================================================
CREATE TABLE IF NOT EXISTS federation_identity (
  singleton    BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  instance_id  TEXT NOT NULL,              -- slug stable, ex 'pointe-est'
  display_name TEXT NOT NULL,
  public_key   TEXT NOT NULL,              -- Ed25519 SPKI, base64url
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 2) Pairs connus
-- ============================================================
CREATE TABLE IF NOT EXISTS federation_peers (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id          TEXT NOT NULL UNIQUE,
  display_name         TEXT NOT NULL,
  base_url             TEXT NOT NULL,       -- joignable par le VPN
  public_key           TEXT NOT NULL,       -- Ed25519 SPKI, base64url
  status               TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','active','suspended','revoked')),
  allow_reservations   BOOLEAN NOT NULL DEFAULT FALSE,
  allow_finance        BOOLEAN NOT NULL DEFAULT FALSE,
  -- Exposition maximale acceptee : au-dela, les debits entrants sont
  -- refuses. Protege d'un pair compromis ou en derive comptable.
  finance_credit_limit NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (finance_credit_limit >= 0),
  introduced_by        TEXT,                -- 'local' ou 'central:<instance_id>'
  last_seen_at         TIMESTAMPTZ,
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  updated_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS federation_peers_status_idx ON federation_peers(status);

-- ============================================================
-- 3) Profils ombres des usagers distants
-- ============================================================
ALTER TABLE profiles           ADD COLUMN IF NOT EXISTS origin_peer_id UUID REFERENCES federation_peers(id) ON DELETE SET NULL;
ALTER TABLE space_reservations ADD COLUMN IF NOT EXISTS origin_peer_id UUID REFERENCES federation_peers(id) ON DELETE SET NULL;

-- Un espace n'est offert aux pairs que si un administrateur l'a
-- explicitement partage. Par defaut, rien ne sort de l'immeuble.
ALTER TABLE common_spaces      ADD COLUMN IF NOT EXISTS federation_shared BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS federation_guests (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  peer_id        UUID NOT NULL REFERENCES federation_peers(id) ON DELETE CASCADE,
  remote_user_id TEXT NOT NULL,             -- identifiant de l'usager chez le pair
  profile_id     UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  display_name   TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (peer_id, remote_user_id)
);

-- ============================================================
-- 4) Journal idempotent des operations inter-instances
-- ============================================================
CREATE TABLE IF NOT EXISTS federation_requests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  direction       TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  peer_id         UUID NOT NULL REFERENCES federation_peers(id) ON DELETE CASCADE,
  idempotency_key TEXT NOT NULL,
  kind            TEXT NOT NULL CHECK (kind IN (
                    'reservation.create',
                    'reservation.cancel',
                    'finance.transfer'
                  )),
  payload         JSONB NOT NULL,
  response        JSONB,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','settled','failed','rejected')),
  attempts        INT NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ,
  error           TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  settled_at      TIMESTAMPTZ,
  UNIQUE (direction, peer_id, idempotency_key)
);

-- File d'attente sortante : ce que le boucleur doit reessayer quand le
-- VPN revient. Index partiel — la table grossit, la file reste petite.
CREATE INDEX IF NOT EXISTS federation_requests_outbox_idx
  ON federation_requests (next_attempt_at)
  WHERE direction = 'outbound' AND status = 'pending';

-- ============================================================
-- 5) Grand livre par pair
-- ============================================================
-- amount > 0 : le pair nous doit (on a rendu un service, encaisse ici)
-- amount < 0 : on doit au pair (notre locataire a consomme chez lui)
CREATE TABLE IF NOT EXISTS federation_ledger (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  peer_id     UUID NOT NULL REFERENCES federation_peers(id) ON DELETE CASCADE,
  request_id  UUID REFERENCES federation_requests(id) ON DELETE SET NULL,
  amount      NUMERIC(10,2) NOT NULL,
  kind        TEXT NOT NULL,
  description TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS federation_ledger_peer_idx ON federation_ledger(peer_id, created_at DESC);

CREATE OR REPLACE VIEW federation_peer_balances AS
  SELECT p.id            AS peer_id,
         p.instance_id,
         p.display_name,
         p.status,
         p.finance_credit_limit,
         COALESCE(SUM(l.amount), 0)::NUMERIC(10,2) AS net_balance,
         MAX(l.created_at)                          AS last_movement_at
    FROM federation_peers p
    LEFT JOIN federation_ledger l ON l.peer_id = p.id
   GROUP BY p.id;

-- ============================================================
-- 6) Reservation d'un espace par un usager distant (entrant)
-- ============================================================
-- Atomique : verification de disponibilite, creation de la reservation
-- et ecriture au grand livre dans la meme transaction. Rejouable : la
-- meme cle d'idempotence retourne la reponse d'origine.
CREATE OR REPLACE FUNCTION federation_reserve_space(
  p_peer_id    UUID,
  p_key        TEXT,
  p_profile_id UUID,
  p_space_id   UUID,
  p_start      TIMESTAMPTZ,
  p_end        TIMESTAMPTZ,
  p_slots      INT,
  p_cost       NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_existing federation_requests%ROWTYPE;
  v_peer     federation_peers%ROWTYPE;
  v_req_id   UUID;
  v_res_id   UUID;
BEGIN
  SELECT * INTO v_existing FROM federation_requests
   WHERE direction = 'inbound' AND peer_id = p_peer_id AND idempotency_key = p_key;
  IF FOUND THEN
    RETURN v_existing.response;
  END IF;

  SELECT * INTO v_peer FROM federation_peers WHERE id = p_peer_id;
  IF NOT FOUND OR v_peer.status <> 'active' OR NOT v_peer.allow_reservations THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'peer_not_allowed');
  END IF;

  IF p_cost < 0 THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'invalid_cost');
  END IF;

  IF NOT check_space_availability(p_space_id, p_start, p_end, NULL) THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'space_unavailable');
  END IF;

  INSERT INTO federation_requests (direction, peer_id, idempotency_key, kind, payload, status)
  VALUES ('inbound', p_peer_id, p_key, 'reservation.create',
          jsonb_build_object('space_id', p_space_id, 'profile_id', p_profile_id,
                             'start', p_start, 'end', p_end, 'cost', p_cost),
          'pending')
  RETURNING id INTO v_req_id;

  INSERT INTO space_reservations (space_id, tenant_id, start_time, end_time,
                                  total_slots, total_cost, status, origin_peer_id)
  VALUES (p_space_id, p_profile_id, p_start, p_end, p_slots, p_cost, 'confirmed', p_peer_id)
  RETURNING id INTO v_res_id;

  -- Le pair nous doit le cout : son locataire a consomme notre espace.
  IF p_cost > 0 THEN
    INSERT INTO federation_ledger (peer_id, request_id, amount, kind, description)
    VALUES (p_peer_id, v_req_id, p_cost, 'reservation.create',
            'Reservation espace ' || p_space_id::TEXT);
  END IF;

  UPDATE federation_requests
     SET status = 'settled', settled_at = NOW(),
         response = jsonb_build_object('ok', TRUE, 'reservation_id', v_res_id, 'cost', p_cost)
   WHERE id = v_req_id;

  RETURN jsonb_build_object('ok', TRUE, 'reservation_id', v_res_id, 'cost', p_cost);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 7) Annulation d'une reservation federee (entrant)
-- ============================================================
CREATE OR REPLACE FUNCTION federation_cancel_reservation(
  p_peer_id UUID,
  p_key     TEXT,
  p_res_id  UUID,
  p_reason  TEXT DEFAULT NULL,
  p_refund  NUMERIC DEFAULT 0
)
RETURNS JSONB AS $$
DECLARE
  v_existing federation_requests%ROWTYPE;
  v_res      space_reservations%ROWTYPE;
  v_req_id   UUID;
BEGIN
  SELECT * INTO v_existing FROM federation_requests
   WHERE direction = 'inbound' AND peer_id = p_peer_id AND idempotency_key = p_key;
  IF FOUND THEN
    RETURN v_existing.response;
  END IF;

  SELECT * INTO v_res FROM space_reservations WHERE id = p_res_id;
  IF NOT FOUND OR v_res.origin_peer_id IS DISTINCT FROM p_peer_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'reservation_not_found');
  END IF;

  INSERT INTO federation_requests (direction, peer_id, idempotency_key, kind, payload, status)
  VALUES ('inbound', p_peer_id, p_key, 'reservation.cancel',
          jsonb_build_object('reservation_id', p_res_id, 'refund', p_refund), 'pending')
  RETURNING id INTO v_req_id;

  UPDATE space_reservations
     SET status = 'cancelled', cancelled_at = NOW(), cancel_reason = p_reason
   WHERE id = p_res_id;

  IF p_refund > 0 THEN
    INSERT INTO federation_ledger (peer_id, request_id, amount, kind, description)
    VALUES (p_peer_id, v_req_id, -p_refund, 'reservation.cancel',
            'Remboursement reservation ' || p_res_id::TEXT);
  END IF;

  UPDATE federation_requests
     SET status = 'settled', settled_at = NOW(),
         response = jsonb_build_object('ok', TRUE, 'reservation_id', p_res_id, 'refund', p_refund)
   WHERE id = v_req_id;

  RETURN jsonb_build_object('ok', TRUE, 'reservation_id', p_res_id, 'refund', p_refund);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 8) Transfert de solde entrant
-- ============================================================
-- Un pair credite (p_amount > 0) ou debite (p_amount < 0) un de NOS
-- locataires. Le plafond finance_credit_limit borne l'exposition nette
-- que l'on accepte vis-a-vis de ce pair.
CREATE OR REPLACE FUNCTION federation_apply_transfer(
  p_peer_id     UUID,
  p_key         TEXT,
  p_profile_id  UUID,
  p_amount      NUMERIC,
  p_type        TEXT,
  p_description TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_existing  federation_requests%ROWTYPE;
  v_peer      federation_peers%ROWTYPE;
  v_req_id    UUID;
  v_balance   NUMERIC;
  v_exposure  NUMERIC;
BEGIN
  SELECT * INTO v_existing FROM federation_requests
   WHERE direction = 'inbound' AND peer_id = p_peer_id AND idempotency_key = p_key;
  IF FOUND THEN
    RETURN v_existing.response;
  END IF;

  SELECT * INTO v_peer FROM federation_peers WHERE id = p_peer_id FOR UPDATE;
  IF NOT FOUND OR v_peer.status <> 'active' OR NOT v_peer.allow_finance THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'peer_not_allowed');
  END IF;

  IF p_amount = 0 THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'invalid_amount');
  END IF;

  -- Exposition apres l'operation : un credit vers nos locataires est
  -- une creance sur le pair.
  SELECT COALESCE(SUM(amount), 0) INTO v_exposure FROM federation_ledger WHERE peer_id = p_peer_id;
  IF p_amount > 0 AND (v_exposure + p_amount) > v_peer.finance_credit_limit THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'credit_limit_exceeded',
                              'exposure', v_exposure, 'limit', v_peer.finance_credit_limit);
  END IF;

  INSERT INTO federation_requests (direction, peer_id, idempotency_key, kind, payload, status)
  VALUES ('inbound', p_peer_id, p_key, 'finance.transfer',
          jsonb_build_object('profile_id', p_profile_id, 'amount', p_amount, 'type', p_type),
          'pending')
  RETURNING id INTO v_req_id;

  v_balance := adjust_balance(p_profile_id, p_amount, p_type, NULL, 'federation',
                              COALESCE(p_description, 'Federation ' || v_peer.instance_id),
                              NULL, FALSE);

  INSERT INTO federation_ledger (peer_id, request_id, amount, kind, description)
  VALUES (p_peer_id, v_req_id, p_amount, 'finance.transfer', p_description);

  UPDATE federation_requests
     SET status = 'settled', settled_at = NOW(),
         response = jsonb_build_object('ok', TRUE, 'balance_after', v_balance)
   WHERE id = v_req_id;

  RETURN jsonb_build_object('ok', TRUE, 'balance_after', v_balance);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 9) Cote sortant : engager puis solder une operation
-- ============================================================
-- Le service de federation appelle federation_begin_outbound AVANT le
-- reseau (l'argent quitte notre livre tout de suite, en meme temps que
-- la creance sur le pair), puis federation_settle_outbound apres la
-- reponse. Si l'appel a echoue definitivement, le solde est rendu au
-- locataire dans la meme transaction que le retrait de la creance : il
-- n'existe aucun etat ou l'argent a disparu des deux cotes.
CREATE OR REPLACE FUNCTION federation_begin_outbound(
  p_peer_id UUID,
  p_key     TEXT,
  p_kind    TEXT,
  p_user_id UUID,
  p_amount  NUMERIC,        -- montant debite localement (>= 0)
  p_payload JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_existing federation_requests%ROWTYPE;
  v_peer     federation_peers%ROWTYPE;
  v_req_id   UUID;
  v_balance  NUMERIC;
BEGIN
  SELECT * INTO v_existing FROM federation_requests
   WHERE direction = 'outbound' AND peer_id = p_peer_id AND idempotency_key = p_key;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', TRUE, 'request_id', v_existing.id,
                              'status', v_existing.status, 'replayed', TRUE,
                              'response', v_existing.response);
  END IF;

  SELECT * INTO v_peer FROM federation_peers WHERE id = p_peer_id;
  IF NOT FOUND OR v_peer.status <> 'active' THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'peer_not_allowed');
  END IF;

  INSERT INTO federation_requests (direction, peer_id, idempotency_key, kind, payload,
                                   status, next_attempt_at)
  VALUES ('outbound', p_peer_id, p_key, p_kind, p_payload, 'pending', NOW())
  RETURNING id INTO v_req_id;

  IF COALESCE(p_amount, 0) > 0 THEN
    v_balance := adjust_balance(p_user_id, -p_amount, 'space_reservation', NULL, 'federation',
                                'Reservation chez ' || v_peer.instance_id, NULL, FALSE);
    INSERT INTO federation_ledger (peer_id, request_id, amount, kind, description)
    VALUES (p_peer_id, v_req_id, -p_amount, p_kind, 'Engagement vers ' || v_peer.instance_id);
  END IF;

  RETURN jsonb_build_object('ok', TRUE, 'request_id', v_req_id, 'status', 'pending',
                            'balance_after', v_balance);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION federation_settle_outbound(
  p_request_id UUID,
  p_status     TEXT,          -- 'settled' | 'failed'
  p_response   JSONB DEFAULT NULL,
  p_error      TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_req    federation_requests%ROWTYPE;
  v_amount NUMERIC;
  v_user   UUID;
BEGIN
  SELECT * INTO v_req FROM federation_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'request_not_found');
  END IF;
  IF v_req.status <> 'pending' THEN
    -- Deja solde : on ne rejoue ni le remboursement ni la reponse.
    RETURN jsonb_build_object('ok', TRUE, 'status', v_req.status, 'replayed', TRUE);
  END IF;
  IF p_status NOT IN ('settled','failed') THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'invalid_status');
  END IF;

  IF p_status = 'failed' THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_amount FROM federation_ledger WHERE request_id = p_request_id;
    v_user := NULLIF(v_req.payload ->> 'user_id', '')::UUID;
    IF v_amount < 0 AND v_user IS NOT NULL THEN
      PERFORM adjust_balance(v_user, -v_amount, 'space_cancel_refund', NULL, 'federation',
                             'Annulation federation (echec definitif)', NULL, FALSE);
      INSERT INTO federation_ledger (peer_id, request_id, amount, kind, description)
      VALUES (v_req.peer_id, p_request_id, -v_amount, v_req.kind, 'Reprise apres echec');
    END IF;
  END IF;

  UPDATE federation_requests
     SET status = p_status,
         response = COALESCE(p_response, response),
         error = p_error,
         attempts = attempts + 1,
         settled_at = NOW(),
         next_attempt_at = NULL
   WHERE id = p_request_id;

  RETURN jsonb_build_object('ok', TRUE, 'status', p_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Replanifie une tentative sortante (coupure VPN) sans rien solder.
CREATE OR REPLACE FUNCTION federation_defer_outbound(
  p_request_id UUID,
  p_delay      INTERVAL,
  p_error      TEXT DEFAULT NULL
)
RETURNS VOID AS $$
  UPDATE federation_requests
     SET attempts = attempts + 1,
         next_attempt_at = NOW() + p_delay,
         error = p_error
   WHERE id = p_request_id AND status = 'pending';
$$ LANGUAGE sql SECURITY DEFINER;

-- ============================================================
-- 10) RLS — lecture reservee aux administrateurs
-- ============================================================
-- Toutes les ecritures passent par le service de federation, qui se
-- connecte avec la cle service_role (hors RLS). L'interface admin a
-- seulement besoin de lire.
ALTER TABLE federation_identity ENABLE ROW LEVEL SECURITY;
ALTER TABLE federation_peers    ENABLE ROW LEVEL SECURITY;
ALTER TABLE federation_guests   ENABLE ROW LEVEL SECURITY;
ALTER TABLE federation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE federation_ledger   ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['federation_identity','federation_peers','federation_guests',
                           'federation_requests','federation_ledger']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_admin_read', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR SELECT TO authenticated USING (get_my_role() IN (''admin'',''principal_admin''))',
      t || '_admin_read', t);
  END LOOP;
END $$;

-- ============================================================
-- 11) Parametres
-- ============================================================
INSERT INTO system_settings (key, value, description)
VALUES ('federation_enabled', 'false',
        'Active les echanges avec les instances CoHabitat jumelees (reservations croisees, transferts).')
ON CONFLICT (key) DO NOTHING;

COMMIT;
