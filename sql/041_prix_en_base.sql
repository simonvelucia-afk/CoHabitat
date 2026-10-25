-- 041_prix_en_base.sql
-- Le prix se calcule en base : espaces communs, serre, véhicules.
--
-- Jusqu'ici la page du résident calculait le prix, créait la réservation,
-- puis demandait à la base de débiter ce montant. Depuis 040, elle ne peut
-- plus débiter qu'elle-même — mais le MONTANT restait le sien : en
-- modifiant la page, on pouvait réserver une salle pour un sou.
--
-- Trois défauts de plus, que la même conception entraînait :
--   * une réservation créée puis non payée si la page se fermait entre
--     les deux appels ;
--   * deux résidents sur le même créneau d'un espace : la vérification de
--     disponibilité tournait avec les droits du résident, qui ne voit que
--     SES réservations ;
--   * le tarif lu dans la page, parfois périmé.
--
-- Désormais la page dit « je réserve ceci ». La base, en UNE transaction :
-- vérifie le créneau (verrou par ressource, toutes réservations
-- confondues), lit le tarif en vigueur, calcule, vérifie le solde, débite
-- et enregistre.
--
--   espace_reserver       espace + début + fin
--   serre_louer           zone (+ fin envisagée) ; premier mois débité
--   serre_facturer        mois échus des locations du résident
--   vehicule_reserver     véhicule + début + fin ; acompte au temps
--   vehicule_retourner    compteur au retour ; règlement de l'écart
--   vehicule_annuler      remboursé si plus de 2 h avant le début
--
-- Un verrou interdit au résident d'écrire lui-même les colonnes de prix,
-- ou de créer ces lignes sans passer par ces fonctions. Les
-- administrateurs gardent la main.
--
-- solde_debiter (040) ne sert plus qu'aux réservations d'espaces dans un
-- AUTRE immeuble du réseau, dont le tarif n'est pas dans cette base.
-- solde_rembourser n'a plus d'appelant et se ferme.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ============================================================
-- 0) Outils communs
-- ============================================================
-- Écriture au grand livre AVEC sa clé d'idempotence, en une instruction.
-- Même effet qu'adjust_balance (schema.sql) — solde mis à jour, ligne de
-- transaction — mais la clé est posée sur la ligne même. La retrouver
-- après coup (« la plus récente ») échouait dès que deux écritures
-- partageaient le même horodatage, c'est-à-dire la même transaction.
CREATE OR REPLACE FUNCTION _grand_livre(p_uid UUID, p_montant NUMERIC, p_type TEXT, p_ref UUID,
                                       p_ref_type TEXT, p_desc TEXT, p_par UUID, p_cle TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_solde NUMERIC;
BEGIN
  UPDATE profiles SET virtual_balance = virtual_balance + p_montant
   WHERE id = p_uid
   RETURNING virtual_balance INTO v_solde;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROFILE_NOT_FOUND'; END IF;
  INSERT INTO transactions (user_id, amount, balance_after, type, reference_id, reference_type,
                            description, created_by, is_demo, idempotency_key)
  VALUES (p_uid, p_montant, v_solde, p_type, p_ref, p_ref_type, p_desc, p_par, FALSE, p_cle);
  RETURN v_solde;
END;
$$;

-- Débit du résident connecté, solde verrouillé et vérifié, avec clé
-- d'idempotence au grand livre. Réservé aux fonctions de cette migration.
CREATE OR REPLACE FUNCTION _prix_debiter(p_uid UUID, p_montant NUMERIC, p_type TEXT,
                                        p_ref UUID, p_ref_type TEXT, p_desc TEXT, p_cle TEXT,
                                        p_verifier_fonds BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_solde NUMERIC;
BEGIN
  v_solde := (SELECT virtual_balance FROM profiles WHERE id = p_uid FOR UPDATE);
  IF p_cle IS NOT NULL AND EXISTS (SELECT 1 FROM transactions WHERE idempotency_key = p_cle) THEN
    RETURN v_solde;
  END IF;
  IF p_montant <= 0 THEN RETURN v_solde; END IF;
  IF p_verifier_fonds AND COALESCE(v_solde, 0) < p_montant THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;
  RETURN _grand_livre(p_uid, -p_montant, p_type, p_ref, p_ref_type, p_desc, p_uid, p_cle);
END;
$$;

CREATE OR REPLACE FUNCTION _prix_crediter(p_uid UUID, p_montant NUMERIC, p_type TEXT,
                                         p_ref UUID, p_ref_type TEXT, p_desc TEXT, p_cle TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_solde NUMERIC;
BEGIN
  v_solde := (SELECT virtual_balance FROM profiles WHERE id = p_uid FOR UPDATE);
  IF p_cle IS NOT NULL AND EXISTS (SELECT 1 FROM transactions WHERE idempotency_key = p_cle) THEN
    RETURN v_solde;
  END IF;
  IF p_montant <= 0 THEN RETURN v_solde; END IF;
  RETURN _grand_livre(p_uid, p_montant, p_type, p_ref, p_ref_type, p_desc, p_uid, p_cle);
END;
$$;

REVOKE ALL ON FUNCTION _grand_livre(UUID, NUMERIC, TEXT, UUID, TEXT, TEXT, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _prix_debiter(UUID, NUMERIC, TEXT, UUID, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _prix_crediter(UUID, NUMERIC, TEXT, UUID, TEXT, TEXT, TEXT)         FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION _prix_appelant()
RETURNS UUID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'SESSION_REQUISE'; END IF;
  IF get_my_role() = 'demo' THEN RAISE EXCEPTION 'DEMO'; END IF;
  RETURN auth.uid();
END;
$$;

-- ============================================================
-- 1) Espaces communs
-- ============================================================
-- Prix : tranches de 15 minutes entamées × tarif en vigueur
-- (calculate_space_cost, schema.sql).
CREATE OR REPLACE FUNCTION espace_reserver(p_space_id UUID, p_debut TIMESTAMPTZ, p_fin TIMESTAMPTZ)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := _prix_appelant();
  v_cout   NUMERIC;
  v_slots  INT;
  v_id     UUID;
  v_nom    TEXT;
  v_solde  NUMERIC;
BEGIN
  IF p_debut IS NULL OR p_fin IS NULL OR p_fin <= p_debut THEN RAISE EXCEPTION 'CRENEAU_INVALIDE'; END IF;
  IF p_fin <= now() THEN RAISE EXCEPTION 'CRENEAU_PASSE'; END IF;
  IF p_fin - p_debut > interval '7 days' THEN RAISE EXCEPTION 'CRENEAU_TROP_LONG'; END IF;

  SELECT name INTO v_nom FROM common_spaces WHERE id = p_space_id AND COALESCE(is_available, TRUE);
  IF NOT FOUND THEN RAISE EXCEPTION 'ESPACE_INDISPONIBLE'; END IF;

  -- Un verrou par espace : deux réservations simultanées s'attendent, et
  -- la seconde voit la première.
  PERFORM pg_advisory_xact_lock(hashtext('espace:' || p_space_id::TEXT));
  IF EXISTS (SELECT 1 FROM space_reservations
              WHERE space_id = p_space_id AND status IN ('confirmed','pending')
                AND (start_time, end_time) OVERLAPS (p_debut, p_fin)) THEN
    RAISE EXCEPTION 'CRENEAU_PRIS';
  END IF;

  v_slots := CEIL(EXTRACT(EPOCH FROM (p_fin - p_debut)) / 60.0 / 15.0);
  v_cout  := round(COALESCE(calculate_space_cost(p_space_id, p_debut, p_fin), 0), 2);

  INSERT INTO space_reservations (space_id, tenant_id, start_time, end_time, total_slots, total_cost, status)
  VALUES (p_space_id, v_uid, p_debut, p_fin, v_slots, v_cout, 'confirmed')
  RETURNING id INTO v_id;

  v_solde := _prix_debiter(v_uid, v_cout, 'space_reservation', v_id, 'space_reservation',
                           'Réservation ' || v_nom, 'space-resv:' || v_id);

  RETURN jsonb_build_object('reservation_id', v_id, 'cout', v_cout, 'tranches', v_slots, 'virtual_balance', v_solde);
END;
$$;

-- ============================================================
-- 2) Serre
-- ============================================================
CREATE OR REPLACE FUNCTION serre_louer(p_zone_id UUID, p_date_fin_prevue DATE DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := _prix_appelant();
  v_zone  serre_zones%ROWTYPE;
  v_id    UUID;
  v_mois  DATE := date_trunc('month', current_date)::DATE;
  v_solde NUMERIC;
BEGIN
  SELECT * INTO v_zone FROM serre_zones WHERE id = p_zone_id AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'ZONE_INDISPONIBLE'; END IF;
  IF p_date_fin_prevue IS NOT NULL AND p_date_fin_prevue < current_date THEN RAISE EXCEPTION 'DATE_INVALIDE'; END IF;

  -- Fonds vérifiés avant d'occuper la zone.
  IF COALESCE((SELECT virtual_balance FROM profiles WHERE id = v_uid), 0) < v_zone.frais_mensuel THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS';
  END IF;

  BEGIN
    INSERT INTO serre_locations (zone_id, tenant_id, date_debut, date_fin_prevue, frais_mensuel,
                                 derniere_facturation, statut)
    VALUES (p_zone_id, v_uid, current_date, p_date_fin_prevue, v_zone.frais_mensuel, v_mois, 'active')
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'ZONE_DEJA_LOUEE';
  END;

  -- Trois sections, chacune son cycle de culture, vide au départ.
  INSERT INTO serre_cultures (zone_id, location_id, section, statut)
  SELECT p_zone_id, v_id, s, 'vide' FROM generate_series(1, 3) s;

  v_solde := _prix_debiter(v_uid, round(v_zone.frais_mensuel, 2), 'space_reservation', v_id, 'serre_location',
                           'Serre — location zone ' || v_zone.code || ' (frais mensuel ' || to_char(v_mois, 'YYYY-MM') || ')',
                           'serre-fee:' || v_id || ':' || to_char(v_mois, 'YYYY-MM'));

  RETURN jsonb_build_object('location_id', v_id, 'frais_mensuel', v_zone.frais_mensuel, 'virtual_balance', v_solde);
END;
$$;

-- Mois échus de MES locations actives, au tarif fixé à la location.
-- S'arrête au premier mois que le solde ne couvre pas : ce mois reste dû
-- et sera repris au prochain passage.
CREATE OR REPLACE FUNCTION serre_facturer()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := _prix_appelant();
  v_loc    RECORD;
  v_mois   DATE;
  v_actuel DATE := date_trunc('month', current_date)::DATE;
  v_nb     INT := 0;
  v_total  NUMERIC := 0;
  v_manque BOOLEAN := FALSE;
BEGIN
  FOR v_loc IN
    SELECT l.*, z.code FROM serre_locations l JOIN serre_zones z ON z.id = l.zone_id
     WHERE l.tenant_id = v_uid AND l.statut = 'active'
     ORDER BY l.date_debut
     FOR UPDATE OF l
  LOOP
    v_mois := COALESCE((date_trunc('month', v_loc.derniere_facturation) + interval '1 month')::DATE,
                       date_trunc('month', v_loc.date_debut)::DATE);
    WHILE v_mois <= v_actuel LOOP
      IF v_loc.frais_mensuel > 0 THEN
        IF COALESCE((SELECT virtual_balance FROM profiles WHERE id = v_uid), 0) < v_loc.frais_mensuel THEN
          v_manque := TRUE;
          EXIT;
        END IF;
        -- Un mois déjà payé (clé présente) n'est ni redébité ni recompté.
        IF NOT EXISTS (SELECT 1 FROM transactions
                        WHERE idempotency_key = 'serre-fee:' || v_loc.id || ':' || to_char(v_mois, 'YYYY-MM')) THEN
          PERFORM _prix_debiter(v_uid, round(v_loc.frais_mensuel, 2), 'space_reservation', v_loc.id, 'serre_location',
                                'Serre — frais mensuel ' || to_char(v_mois, 'YYYY-MM'),
                                'serre-fee:' || v_loc.id || ':' || to_char(v_mois, 'YYYY-MM'));
          v_total := v_total + round(v_loc.frais_mensuel, 2);
          v_nb := v_nb + 1;
        END IF;
      END IF;
      UPDATE serre_locations SET derniere_facturation = v_mois WHERE id = v_loc.id;
      v_mois := (v_mois + interval '1 month')::DATE;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('mois', v_nb, 'total', v_total, 'solde_insuffisant', v_manque,
                            'virtual_balance', (SELECT virtual_balance FROM profiles WHERE id = v_uid));
END;
$$;

-- ============================================================
-- 3) Véhicules
-- ============================================================
-- Acompte : durée réservée × prix à la minute en vigueur. Le reste
-- (kilomètres, temps réel) se règle au retour.
CREATE OR REPLACE FUNCTION vehicule_reserver(p_vehicle_id UUID, p_debut TIMESTAMPTZ, p_fin TIMESTAMPTZ,
                                             p_purpose TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := _prix_appelant();
  v_modele  TEXT;
  v_taux    NUMERIC;
  v_minutes INT;
  v_cout    NUMERIC;
  v_id      UUID;
  v_solde   NUMERIC;
BEGIN
  IF p_debut IS NULL OR p_fin IS NULL OR p_fin <= p_debut THEN RAISE EXCEPTION 'CRENEAU_INVALIDE'; END IF;
  IF p_fin <= now() THEN RAISE EXCEPTION 'CRENEAU_PASSE'; END IF;
  IF p_fin - p_debut > interval '7 days' THEN RAISE EXCEPTION 'CRENEAU_TROP_LONG'; END IF;

  SELECT model INTO v_modele FROM vehicles WHERE id = p_vehicle_id AND COALESCE(is_reservable, TRUE);
  IF NOT FOUND THEN RAISE EXCEPTION 'VEHICULE_INDISPONIBLE'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('vehicule:' || p_vehicle_id::TEXT));
  IF NOT check_vehicle_availability(p_vehicle_id, p_debut, p_fin) THEN RAISE EXCEPTION 'CRENEAU_PRIS'; END IF;

  SELECT COALESCE(price_per_minute, 0) INTO v_taux
    FROM vehicle_pricing
   WHERE vehicle_id = p_vehicle_id AND valid_from <= now() AND (valid_to IS NULL OR valid_to > now())
   ORDER BY valid_from DESC LIMIT 1;
  v_minutes := round(EXTRACT(EPOCH FROM (p_fin - p_debut)) / 60.0);
  v_cout    := round(v_minutes * COALESCE(v_taux, 0), 2);

  INSERT INTO vehicle_reservations (vehicle_id, tenant_id, start_time, end_time, total_minutes,
                                    time_cost, deposit_cost, total_cost, purpose, status)
  VALUES (p_vehicle_id, v_uid, p_debut, p_fin, v_minutes, v_cout, v_cout, v_cout,
          NULLIF(left(trim(p_purpose), 300), ''), 'confirmed')
  RETURNING id INTO v_id;

  v_solde := _prix_debiter(v_uid, v_cout, 'vehicle_reservation', v_id, 'vehicle_reservation',
                           'Reservation ' || v_modele, 'vehicle-resv:' || v_id);

  RETURN jsonb_build_object('reservation_id', v_id, 'cout', v_cout, 'minutes', v_minutes, 'virtual_balance', v_solde);
END;
$$;

-- Retour : vehicle_return (033) arrête le compteur et calcule le total ;
-- l'écart avec l'acompte est réglé ici, dans la même transaction. Un
-- complément est débité même si le solde ne suffit pas : le véhicule a
-- roulé, le résident le doit.
CREATE OR REPLACE FUNCTION vehicule_retourner(p_reservation_id UUID, p_km NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := _prix_appelant();
  v_bilan  JSONB;
  v_delta  NUMERIC;
  v_modele TEXT;
  v_solde  NUMERIC;
BEGIN
  v_bilan := vehicle_return(p_reservation_id, p_km);
  v_delta := round(COALESCE((v_bilan->>'delta')::NUMERIC, 0), 2);
  v_modele := (SELECT v.model FROM vehicle_reservations r JOIN vehicles v ON v.id = r.vehicle_id WHERE r.id = p_reservation_id);

  IF v_delta > 0 THEN
    v_solde := _prix_debiter(v_uid, v_delta, 'vehicle_reservation', p_reservation_id, 'vehicle_reservation',
                             'Retour ' || COALESCE(v_modele, ''), 'vehicle-resv-final:' || p_reservation_id, FALSE);
  ELSIF v_delta < 0 THEN
    v_solde := _prix_crediter(v_uid, -v_delta, 'vehicle_reservation_refund', p_reservation_id, 'vehicle_reservation',
                              'Retour ' || COALESCE(v_modele, ''), 'vehicle-resv-final:' || p_reservation_id);
  ELSE
    v_solde := (SELECT virtual_balance FROM profiles WHERE id = v_uid);
  END IF;

  RETURN v_bilan || jsonb_build_object('virtual_balance', v_solde);
END;
$$;

-- Annulation : l'acompte est rendu si l'on annule plus de 2 h avant le
-- début (conditions d'utilisation), gardé sinon.
CREATE OR REPLACE FUNCTION vehicule_annuler(p_reservation_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := _prix_appelant();
  v_res    vehicle_reservations%ROWTYPE;
  v_tard   BOOLEAN;
  v_paye   NUMERIC;
  v_modele TEXT;
  v_solde  NUMERIC;
BEGIN
  SELECT * INTO v_res FROM vehicle_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESERVATION_INTROUVABLE'; END IF;
  IF v_res.tenant_id <> v_uid AND COALESCE(get_my_role(), '') NOT IN ('admin','principal_admin') THEN
    RAISE EXCEPTION 'PAS_LA_VOTRE';
  END IF;
  IF v_res.status NOT IN ('confirmed','pending') THEN RAISE EXCEPTION 'NON_ANNULABLE'; END IF;

  v_tard := v_res.start_time - now() < interval '2 hours';
  UPDATE vehicle_reservations
     SET status = 'cancelled', cancelled_at = now(),
         cancel_reason = CASE WHEN v_tard THEN 'Annulation tardive (moins de 2 h)' ELSE 'Annulé par le résident' END
   WHERE id = p_reservation_id;

  -- Ce qui a été payé pour cette réservation, moins ce qui a été rendu.
  v_paye := -(SELECT COALESCE(SUM(amount), 0) FROM transactions
               WHERE user_id = v_res.tenant_id AND reference_id = p_reservation_id);
  IF NOT v_tard AND v_paye > 0 THEN
    v_modele := (SELECT model FROM vehicles WHERE id = v_res.vehicle_id);
    v_solde := _prix_crediter(v_res.tenant_id, round(v_paye, 2), 'vehicle_reservation_refund', p_reservation_id,
                              'vehicle_reservation', 'Annulation ' || COALESCE(v_modele, ''),
                              'vehicle-resv-refund:' || p_reservation_id);
  ELSE
    v_solde := (SELECT virtual_balance FROM profiles WHERE id = v_res.tenant_id);
  END IF;

  RETURN jsonb_build_object('rembourse', NOT v_tard AND v_paye > 0,
                            'montant', CASE WHEN NOT v_tard AND v_paye > 0 THEN round(v_paye, 2) ELSE 0 END,
                            'virtual_balance', v_solde);
END;
$$;

-- ============================================================
-- 4) Verrou : le prix ne s'écrit plus depuis la page
-- ============================================================
-- Dans une fonction SECURITY DEFINER, current_user est le propriétaire de
-- la fonction ; directement depuis l'API, c'est « authenticated ». Le
-- verrou ne vise donc que les écritures directes d'un résident.
CREATE OR REPLACE FUNCTION trg_prix_verrou()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_user <> 'authenticated' OR COALESCE(get_my_role(), '') IN ('admin','principal_admin') THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    RAISE EXCEPTION 'PASSER_PAR_LA_RESERVATION' USING HINT = 'Réservez par espace_reserver, serre_louer ou vehicule_reserver.';
  END IF;
  -- Un IF par table : PL/pgSQL n'évalue pas « A AND B » paresseusement,
  -- et NEW.space_id n'existe pas sur serre_locations.
  IF TG_TABLE_NAME = 'space_reservations' THEN
    IF NEW.space_id IS DISTINCT FROM OLD.space_id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.start_time IS DISTINCT FROM OLD.start_time OR NEW.end_time IS DISTINCT FROM OLD.end_time
       OR NEW.total_slots IS DISTINCT FROM OLD.total_slots OR NEW.total_cost IS DISTINCT FROM OLD.total_cost THEN
      RAISE EXCEPTION 'PRIX_VERROUILLE';
    END IF;
  ELSIF TG_TABLE_NAME = 'vehicle_reservations' THEN
    -- Le statut aussi : annuler passe par vehicule_annuler (qui rembourse),
    -- prendre et rendre par vehicle_pickup / vehicule_retourner.
    IF NEW.vehicle_id IS DISTINCT FROM OLD.vehicle_id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.start_time IS DISTINCT FROM OLD.start_time OR NEW.end_time IS DISTINCT FROM OLD.end_time
       OR NEW.total_minutes IS DISTINCT FROM OLD.total_minutes OR NEW.time_cost IS DISTINCT FROM OLD.time_cost
       OR NEW.deposit_cost IS DISTINCT FROM OLD.deposit_cost OR NEW.km_cost IS DISTINCT FROM OLD.km_cost
       OR NEW.total_cost IS DISTINCT FROM OLD.total_cost OR NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'PRIX_VERROUILLE';
    END IF;
  ELSIF TG_TABLE_NAME = 'serre_locations' THEN
    IF NEW.zone_id IS DISTINCT FROM OLD.zone_id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.date_debut IS DISTINCT FROM OLD.date_debut OR NEW.frais_mensuel IS DISTINCT FROM OLD.frais_mensuel
       OR NEW.derniere_facturation IS DISTINCT FROM OLD.derniere_facturation
       OR (NEW.statut IS DISTINCT FROM OLD.statut AND NEW.statut = 'active') THEN
      RAISE EXCEPTION 'PRIX_VERROUILLE';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_prix_verrou ON space_reservations;
CREATE TRIGGER trigger_prix_verrou BEFORE INSERT OR UPDATE ON space_reservations
  FOR EACH ROW EXECUTE FUNCTION trg_prix_verrou();
DROP TRIGGER IF EXISTS trigger_prix_verrou ON vehicle_reservations;
CREATE TRIGGER trigger_prix_verrou BEFORE INSERT OR UPDATE ON vehicle_reservations
  FOR EACH ROW EXECUTE FUNCTION trg_prix_verrou();
DROP TRIGGER IF EXISTS trigger_prix_verrou ON serre_locations;
CREATE TRIGGER trigger_prix_verrou BEFORE INSERT OR UPDATE ON serre_locations
  FOR EACH ROW EXECUTE FUNCTION trg_prix_verrou();

-- ============================================================
-- 5) Les portes génériques de 040 se resserrent
-- ============================================================
-- solde_debiter : seulement pour un espace d'un AUTRE immeuble du réseau,
-- dont le tarif vit dans l'autre base. Les espaces, la serre et les
-- véhicules d'ici passent par les fonctions ci-dessus.
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
  v_uid UUID := _prix_appelant();
BEGIN
  IF p_type <> 'space_reservation' OR p_reference_type IS DISTINCT FROM 'space_reservation_network' THEN
    RAISE EXCEPTION 'TYPE_INTERDIT';
  END IF;
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_cle IS NOT NULL AND EXISTS (SELECT 1 FROM transactions WHERE idempotency_key = p_cle AND user_id <> v_uid) THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;
  RETURN _prix_debiter(v_uid, round(p_montant, 2), p_type, p_reference_id, p_reference_type, p_description, p_cle);
END;
$$;

REVOKE ALL ON FUNCTION solde_rembourser(NUMERIC, TEXT, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ============================================================
-- 6) Droits
-- ============================================================
DO $g$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'espace_reserver(uuid,timestamptz,timestamptz)',
    'serre_louer(uuid,date)',
    'serre_facturer()',
    'vehicule_reserver(uuid,timestamptz,timestamptz,text)',
    'vehicule_retourner(uuid,numeric)',
    'vehicule_annuler(uuid)',
    'solde_debiter(numeric,text,uuid,text,text,text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
END $g$;

COMMIT;

NOTIFY pgrst, 'reload schema';
