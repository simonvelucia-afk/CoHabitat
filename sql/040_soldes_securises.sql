-- 040_soldes_securises.sql
-- Fermer les fonctions qui touchent aux soldes et aux rôles.
--
-- CE QUI ÉTAIT OUVERT
--
-- Supabase accorde par défaut le droit d'exécuter toute fonction du
-- schéma public aux rôles anon et authenticated. Plusieurs fonctions
-- SECURITY DEFINER n'avaient jamais retiré ce droit. Vérifié sur une
-- base montée depuis ce dépôt, SANS être connecté (clé anon publique) :
--
--   adjust_balance(victime, 1000, 'admin_credit')   → solde crédité ;
--   admin_update_profile(id, ..., 'principal_admin') → rôle obtenu.
--
-- admin_update_profile, admin_set_balance et anonymize_profile gardent
-- bien leur porte (get_my_role() NOT IN ('admin', ...)), mais sans
-- connexion get_my_role() vaut NULL, « NULL NOT IN (...) » vaut NULL, et
-- le IF ne lève rien. transfer_to_dependent ne vérifie l'appelant que
-- s'il y en a un. Les fonctions de fédération, faites pour le service de
-- fédération (clé service_role), étaient elles aussi appelables par tous.
--
-- Et même connecté, un résident pouvait appeler adjust_balance pour se
-- créditer, ou débiter un voisin : c'est ainsi que la page débitait les
-- passagers d'un covoiturage, avec des montants calculés dans le
-- navigateur du chauffeur.
--
-- CE QUE CETTE MIGRATION FAIT
--
--   1. Retire ces droits. adjust_balance n'est plus appelable que depuis
--      d'autres fonctions de la base (et par service_role).
--   2. Donne à chaque besoin légitime sa propre porte, qui vérifie qui
--      appelle et ce qu'il demande :
--        solde_debiter     — un résident paie, de son propre solde, un
--                            service de l'immeuble ;
--        solde_rembourser  — il est remboursé, jamais au-delà de ce qu'il
--                            a payé pour cette même réservation ;
--        admin_crediter    — un administrateur crédite un résident ;
--        trajet_confirmer  — le chauffeur termine un covoiturage : la base
--                            calcule le prix, débite les passagers,
--                            crédite le chauffeur, une seule fois.
--   3. Clé d'idempotence au grand livre : une même opération renvoyée
--      après une coupure ne débite pas deux fois.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ============================================================
-- 1) Retirer les droits
-- ============================================================
DO $rev$
DECLARE
  f TEXT;
BEGIN
  -- Ni anon ni résident : appelées seulement depuis la base ou par le
  -- service de fédération (service_role).
  FOREACH f IN ARRAY ARRAY[
    'adjust_balance(uuid,numeric,text,uuid,text,text,uuid,boolean)',
    'federation_apply_transfer(uuid,text,uuid,numeric,text,text)',
    'federation_begin_outbound(uuid,text,text,uuid,numeric,jsonb)',
    'federation_cancel_reservation(uuid,text,uuid,text,numeric)',
    'federation_defer_outbound(uuid,interval,text)',
    'federation_reserve_space(uuid,text,uuid,uuid,timestamptz,timestamptz,integer,numeric)',
    'federation_settle_outbound(uuid,text,jsonb,text)'
  ] LOOP
    IF to_regprocedure(f) IS NOT NULL THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END IF;
  END LOOP;

  -- Pas sans connexion : ces fonctions vérifient le rôle de l'appelant,
  -- mais laissaient passer celui qui n'en a pas.
  FOREACH f IN ARRAY ARRAY[
    'admin_set_balance(uuid,numeric)',
    'admin_update_profile(uuid,text,text,text,boolean,boolean)',
    'anonymize_profile(uuid)',
    'transfer_to_dependent(uuid,uuid,numeric)'
  ] LOOP
    IF to_regprocedure(f) IS NOT NULL THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
    END IF;
  END LOOP;
END $rev$;

-- Les nouvelles fonctions du schéma ne s'ouvrent plus d'office à anon.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;

-- ============================================================
-- 2) Idempotence au grand livre
-- ============================================================
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS transactions_idempotency
  ON transactions (idempotency_key) WHERE idempotency_key IS NOT NULL;

-- Colonnes du covoiturage employées par la page, ajoutées en production
-- hors des migrations du dépôt : créées ici si elles manquent.
ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS actual_km                  NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS vehicle_taken_at           TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS vehicle_returned_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS vehicle_returned_confirmed BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS driver_note                TEXT,
  ADD COLUMN IF NOT EXISTS confirmed_at               TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS facture_le                 TIMESTAMPTZ;
ALTER TABLE trip_bookings
  ADD COLUMN IF NOT EXISTS actual_km NUMERIC(10,2);
ALTER TABLE vehicle_pricing
  ADD COLUMN IF NOT EXISTS driver_reduction_pct NUMERIC(5,2) DEFAULT 25;

-- ============================================================
-- 3) Un résident paie, de son propre solde
-- ============================================================
-- Types permis : ce qu'un résident achète lui-même. Le montant est
-- positif ; il est retiré du solde. Refusé si le solde ne suffit pas.
CREATE OR REPLACE FUNCTION solde_debiter(
  p_montant        NUMERIC,
  p_type           TEXT,
  p_reference_id   UUID DEFAULT NULL,
  p_reference_type TEXT DEFAULT NULL,
  p_description    TEXT DEFAULT NULL,
  p_cle            TEXT DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_solde NUMERIC;
  v_prec  transactions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'SESSION_REQUISE'; END IF;
  IF get_my_role() = 'demo' THEN RAISE EXCEPTION 'DEMO'; END IF;
  IF p_type NOT IN ('space_reservation', 'vehicle_reservation') THEN RAISE EXCEPTION 'TYPE_INTERDIT'; END IF;
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  IF p_cle IS NOT NULL THEN
    SELECT * INTO v_prec FROM transactions WHERE idempotency_key = p_cle;
    IF FOUND THEN
      IF v_prec.user_id <> v_uid THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
      RETURN (SELECT virtual_balance FROM profiles WHERE id = v_uid);
    END IF;
  END IF;

  v_solde := (SELECT virtual_balance FROM profiles WHERE id = v_uid FOR UPDATE);
  IF COALESCE(v_solde, 0) < round(p_montant, 2) THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  v_solde := adjust_balance(v_uid, -round(p_montant, 2), p_type, p_reference_id, p_reference_type,
                            p_description, v_uid, FALSE);
  IF p_cle IS NOT NULL THEN
    UPDATE transactions SET idempotency_key = p_cle
     WHERE id = (SELECT id FROM transactions WHERE user_id = v_uid ORDER BY created_at DESC, id DESC LIMIT 1);
  END IF;
  RETURN v_solde;
END;
$$;

-- ============================================================
-- 4) Il est remboursé, jamais au-delà de ce qu'il a payé
-- ============================================================
-- Le plafond : ce que ce résident a payé pour cette référence, moins ce
-- qui lui a déjà été rendu pour elle.
CREATE OR REPLACE FUNCTION solde_rembourser(
  p_montant        NUMERIC,
  p_type           TEXT,
  p_reference_id   UUID,
  p_reference_type TEXT DEFAULT NULL,
  p_description    TEXT DEFAULT NULL,
  p_cle            TEXT DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_net     NUMERIC;
  v_solde   NUMERIC;
  v_prec    transactions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'SESSION_REQUISE'; END IF;
  IF p_type NOT IN ('space_cancel_refund', 'vehicle_reservation_refund') THEN RAISE EXCEPTION 'TYPE_INTERDIT'; END IF;
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_reference_id IS NULL THEN RAISE EXCEPTION 'REFERENCE_REQUISE'; END IF;

  IF p_cle IS NOT NULL THEN
    SELECT * INTO v_prec FROM transactions WHERE idempotency_key = p_cle;
    IF FOUND THEN
      IF v_prec.user_id <> v_uid THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
      RETURN (SELECT virtual_balance FROM profiles WHERE id = v_uid);
    END IF;
  END IF;

  PERFORM 1 FROM profiles WHERE id = v_uid FOR UPDATE;
  v_net := -(SELECT COALESCE(SUM(amount), 0) FROM transactions
              WHERE user_id = v_uid AND reference_id = p_reference_id);
  IF round(p_montant, 2) > v_net + 0.005 THEN RAISE EXCEPTION 'REMBOURSEMENT_EXCESSIF'; END IF;

  v_solde := adjust_balance(v_uid, round(p_montant, 2), p_type, p_reference_id, p_reference_type,
                            p_description, v_uid, FALSE);
  IF p_cle IS NOT NULL THEN
    UPDATE transactions SET idempotency_key = p_cle
     WHERE id = (SELECT id FROM transactions WHERE user_id = v_uid ORDER BY created_at DESC, id DESC LIMIT 1);
  END IF;
  RETURN v_solde;
END;
$$;

-- ============================================================
-- 5) Un administrateur crédite un résident
-- ============================================================
CREATE OR REPLACE FUNCTION admin_crediter(p_user_id UUID, p_montant NUMERIC, p_description TEXT DEFAULT NULL)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(get_my_role(), '') NOT IN ('admin','principal_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_montant IS NULL OR p_montant = 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_user_id) THEN RAISE EXCEPTION 'PROFILE_NOT_FOUND'; END IF;
  RETURN adjust_balance(p_user_id, round(p_montant, 2), 'admin_credit', NULL, NULL,
                        p_description, auth.uid(), FALSE);
END;
$$;

-- ============================================================
-- 6) Le chauffeur termine un covoiturage
-- ============================================================
-- Le prix se calcule en base, avec la meme formule que la page appliquait :
--   passager : km du passager × prix/km
--              + durée (min) × prix/min × sa part des places
--   chauffeur : (durée × prix/min + km du trajet × prix/km)
--               × 1/(places + 1) × réduction chauffeur (%)
-- Les kilomètres et heures sont ceux que le chauffeur a déclarés sur le
-- trajet (trips) et pour chaque passager (trip_bookings).
--
-- Une seule fois : trips.facture_le est posé, et un trajet déjà terminé
-- ou annulé est refusé.
CREATE OR REPLACE FUNCTION trajet_confirmer(p_trip_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trip     trips%ROWTYPE;
  v_pmin     NUMERIC;
  v_pkm      NUMERIC;
  v_red      NUMERIC;
  v_duree    NUMERIC;
  v_places   INT;
  v_b        RECORD;
  v_cout     NUMERIC;
  v_total    NUMERIC := 0;
  v_nb       INT := 0;
  v_credit   NUMERIC := 0;
  v_ref      TEXT;
BEGIN
  SELECT * INTO v_trip FROM trips WHERE id = p_trip_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'TRAJET_INTROUVABLE'; END IF;
  IF auth.uid() IS DISTINCT FROM v_trip.driver_id
     AND COALESCE(get_my_role(), '') NOT IN ('admin','principal_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;
  IF v_trip.facture_le IS NOT NULL OR v_trip.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'TRAJET_DEJA_FACTURE';
  END IF;
  IF v_trip.actual_km IS NULL OR v_trip.vehicle_taken_at IS NULL OR v_trip.vehicle_returned_at IS NULL THEN
    RAISE EXCEPTION 'TRAJET_INCOMPLET';
  END IF;
  IF v_trip.vehicle_returned_at <= v_trip.vehicle_taken_at THEN RAISE EXCEPTION 'HEURES_INVALIDES'; END IF;

  SELECT COALESCE(price_per_minute, 0), COALESCE(price_per_km, 0), COALESCE(driver_reduction_pct, 25)
    INTO v_pmin, v_pkm, v_red
    FROM vehicle_pricing
   WHERE vehicle_id = v_trip.vehicle_id
   ORDER BY (valid_to IS NULL) DESC, valid_from DESC NULLS LAST
   LIMIT 1;
  v_pmin := COALESCE(v_pmin, 0); v_pkm := COALESCE(v_pkm, 0); v_red := COALESCE(v_red, 25);

  v_duree  := EXTRACT(EPOCH FROM (v_trip.vehicle_returned_at - v_trip.vehicle_taken_at)) / 60.0;
  v_places := (SELECT COALESCE(SUM(seats_requested), 0) FROM trip_bookings
                WHERE trip_id = p_trip_id AND status <> 'cancelled' AND seats_requested > 0);
  v_ref := 'Covoiturage #' || left(p_trip_id::TEXT, 8);

  FOR v_b IN
    SELECT id, passenger_id, seats_requested, COALESCE(actual_km, 0) AS km
      FROM trip_bookings
     WHERE trip_id = p_trip_id AND status <> 'cancelled' AND seats_requested > 0
     FOR UPDATE
  LOOP
    v_cout := round(v_b.km * v_pkm
                    + v_duree * v_pmin * (CASE WHEN v_places > 0 THEN v_b.seats_requested::NUMERIC / v_places ELSE 0 END), 2);
    UPDATE trip_bookings SET total_cost = v_cout WHERE id = v_b.id;
    IF v_cout > 0 THEN
      PERFORM adjust_balance(v_b.passenger_id, -v_cout, 'trip_booking', p_trip_id, 'trip', v_ref, auth.uid(), FALSE);
      v_total := v_total + v_cout;
      v_nb := v_nb + 1;
    END IF;
  END LOOP;

  v_credit := round((v_duree * v_pmin + v_trip.actual_km * v_pkm)
                    * (CASE WHEN v_places > 0 THEN 1.0 / (v_places + 1) ELSE 1 END)
                    * (v_red / 100.0), 2);
  IF v_credit > 0 THEN
    PERFORM adjust_balance(v_trip.driver_id, v_credit, 'trip_driver_earning', p_trip_id, 'trip',
                           'Réduction chauffeur #' || left(p_trip_id::TEXT, 8), auth.uid(), FALSE);
  END IF;

  UPDATE trips SET status = 'completed', confirmed_at = now(), facture_le = now(), updated_at = now()
   WHERE id = p_trip_id;

  RETURN jsonb_build_object('passagers', v_nb, 'total_passagers', v_total, 'credit_chauffeur', v_credit,
                            'solde_chauffeur', (SELECT virtual_balance FROM profiles WHERE id = v_trip.driver_id));
END;
$$;

-- ============================================================
-- 7) Droits des nouvelles portes
-- ============================================================
REVOKE ALL ON FUNCTION solde_debiter(NUMERIC, TEXT, UUID, TEXT, TEXT, TEXT)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION solde_rembourser(NUMERIC, TEXT, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION admin_crediter(UUID, NUMERIC, TEXT)                     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION trajet_confirmer(UUID)                                  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION solde_debiter(NUMERIC, TEXT, UUID, TEXT, TEXT, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION solde_rembourser(NUMERIC, TEXT, UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_crediter(UUID, NUMERIC, TEXT)                     TO authenticated;
GRANT EXECUTE ON FUNCTION trajet_confirmer(UUID)                                  TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
