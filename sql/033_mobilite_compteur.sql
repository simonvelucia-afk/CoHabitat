-- 033_mobilite_compteur.sql
-- Le compteur du vehicule devient la source, et le temps se mesure.
--
-- La migration 032 facturait les kilometres declares au retour, et le
-- temps restait celui du creneau reserve. Deux faiblesses :
--
--   * un residant qui rendait le vehicule deux heures plus tot payait
--     quand meme ses deux heures. Rien ne recompensait de rendre tot,
--     alors que c'est exactement ce qu'on veut encourager : un vehicule
--     rendu est un vehicule disponible ;
--
--   * les kilometres etaient declares de memoire. Personne ne verifiait,
--     et un oubli de bonne foi se payait sur la marge.
--
-- Desormais le compteur tranche. On le releve deux fois :
--
--   * a la prise, ou le residant confirme le relevé laissé par la
--     personne precedente. C'est la que se detecte un ecart — un trajet
--     fait sans reservation, ou une saisie erronee au retour d'avant.
--     L'ecart est garde en base plutot que corrige en silence ;
--
--   * au retour, ou la saisie arrete le temps. La duree facturee est
--     celle qui separe reellement la prise du retour, et la distance est
--     la difference des deux relevés.
--
-- Ce qui a ete debite a la reservation reste un acompte, calcule sur le
-- creneau. Le retour reconcilie : on debite le complement, ou on
-- rembourse la difference si l'usage a ete plus court que prevu.

BEGIN;

-- ---------------------------------------------------------------------
-- 1) Le compteur vit sur le vehicule
-- ---------------------------------------------------------------------
-- C'est lui qu'on propose au residant suivant, et c'est lui qu'il
-- confirme. Mis a jour a chaque retour.
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS odometer_km NUMERIC(10,1) NOT NULL DEFAULT 0;

COMMENT ON COLUMN vehicles.odometer_km IS
  'Dernier releve de compteur connu, pose au retour du vehicule. Sert de
  valeur attendue a la prise suivante.';

-- ---------------------------------------------------------------------
-- 2) Une reservation en cours
-- ---------------------------------------------------------------------
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS km_start   NUMERIC(10,1);
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS km_end     NUMERIC(10,1);
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ;
-- Ecart entre le compteur trouve et celui attendu. NULL = pas d'ecart.
-- Conserve, pas corrige : c'est une information d'exploitation, l'admin
-- decide quoi en faire.
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS km_ecart   NUMERIC(10,1);

COMMENT ON COLUMN vehicle_reservations.km_start IS
  'Compteur releve a la prise du vehicule, confirme par le residant.';
COMMENT ON COLUMN vehicle_reservations.km_end IS
  'Compteur releve au retour. La saisie arrete le temps facture.';
COMMENT ON COLUMN vehicle_reservations.started_at IS
  'Prise du vehicule. C''est d''ici que court la duree reellement facturee.';
COMMENT ON COLUMN vehicle_reservations.km_ecart IS
  'Difference entre le compteur trouve a la prise et le dernier releve
  connu. Non nul = quelqu''un a roule hors reservation, ou le releve
  precedent etait faux.';

-- Un vehicule pris mais pas encore rendu.
ALTER TABLE vehicle_reservations DROP CONSTRAINT IF EXISTS vehicle_reservations_status_check;
ALTER TABLE vehicle_reservations
  ADD CONSTRAINT vehicle_reservations_status_check
  CHECK (status IN ('pending', 'confirmed', 'in_progress', 'cancelled', 'completed'));

-- Le compteur ne recule pas.
ALTER TABLE vehicle_reservations DROP CONSTRAINT IF EXISTS vehicle_resv_compteur_croissant;
ALTER TABLE vehicle_reservations
  ADD CONSTRAINT vehicle_resv_compteur_croissant
  CHECK (km_start IS NULL OR km_end IS NULL OR km_end >= km_start);

-- ---------------------------------------------------------------------
-- 3) Un vehicule en cours d'utilisation reste occupe
-- ---------------------------------------------------------------------
-- check_vehicle_availability() et vehicle_busy_slots() ne retenaient que
-- 'confirmed' et 'pending'. Sans 'in_progress', un vehicule pris mais pas
-- encore rendu redeviendrait libre au moment ou son creneau se termine,
-- alors qu'il est sur la route.
CREATE OR REPLACE FUNCTION check_vehicle_availability(
  p_vehicle_id UUID,
  p_start      TIMESTAMPTZ,
  p_end        TIMESTAMPTZ,
  p_exclude_id UUID DEFAULT NULL
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM vehicle_reservations
    WHERE vehicle_id = p_vehicle_id
      AND status IN ('confirmed', 'pending', 'in_progress')
      AND id IS DISTINCT FROM p_exclude_id
      AND (start_time, end_time) OVERLAPS (p_start, p_end)
  ) THEN
    RETURN FALSE;
  END IF;

  IF EXISTS (
    SELECT 1 FROM trips
    WHERE vehicle_id = p_vehicle_id
      AND status IN ('published', 'in_progress')
      AND (departure_time,
           COALESCE(estimated_arrival, departure_time + INTERVAL '2 hours'))
          OVERLAPS (p_start, p_end)
  ) THEN
    RETURN FALSE;
  END IF;

  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION check_vehicle_availability(UUID, TIMESTAMPTZ, TIMESTAMPTZ, UUID) FROM public, anon;
GRANT  EXECUTE ON FUNCTION check_vehicle_availability(UUID, TIMESTAMPTZ, TIMESTAMPTZ, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION vehicle_busy_slots(
  p_vehicle_id UUID DEFAULT NULL,
  p_jours      INT  DEFAULT 14
)
RETURNS TABLE (vehicle_id UUID, debut TIMESTAMPTZ, fin TIMESTAMPTZ, source TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT r.vehicle_id, r.start_time, r.end_time, 'reservation'::TEXT
    FROM vehicle_reservations r
   WHERE (p_vehicle_id IS NULL OR r.vehicle_id = p_vehicle_id)
     AND r.status IN ('confirmed', 'pending', 'in_progress')
     AND r.end_time >= NOW()
     AND r.start_time <= NOW() + (p_jours || ' days')::INTERVAL
  UNION ALL
  SELECT t.vehicle_id, t.departure_time,
         COALESCE(t.estimated_arrival, t.departure_time + INTERVAL '2 hours'),
         'trajet'::TEXT
    FROM trips t
   WHERE (p_vehicle_id IS NULL OR t.vehicle_id = p_vehicle_id)
     AND t.status IN ('published', 'in_progress')
     AND COALESCE(t.estimated_arrival, t.departure_time + INTERVAL '2 hours') >= NOW()
     AND t.departure_time <= NOW() + (p_jours || ' days')::INTERVAL
  ORDER BY 2;
$$;
REVOKE ALL ON FUNCTION vehicle_busy_slots(UUID, INT) FROM public, anon;
GRANT  EXECUTE ON FUNCTION vehicle_busy_slots(UUID, INT) TO authenticated;

-- ---------------------------------------------------------------------
-- 4) Prise et retour : deux RPC, parce que la RLS a raison
-- ---------------------------------------------------------------------
-- Le compteur vit sur `vehicles`, table que les residants lisent mais
-- n'ecrivent pas — et il ne faut pas leur ouvrir : la meme policy leur
-- donnerait le tarif et la disponibilite. Deux fonctions SECURITY
-- DEFINER font le travail, chacune bornee a la reservation de celui qui
-- appelle.
--
-- Elles calculent aussi les montants : la duree reelle et la distance ne
-- doivent pas dependre de l'horloge ni de l'arithmetique du navigateur.
-- Le client ne fait que regler la difference avec l'acompte.

-- Ce qui a ete debite a la reservation, sur la base du creneau. Le retour
-- s'y compare : on ne redebite pas ce qui est deja paye.
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS deposit_cost DECIMAL(10,2);
UPDATE vehicle_reservations SET deposit_cost = time_cost WHERE deposit_cost IS NULL;
COMMENT ON COLUMN vehicle_reservations.deposit_cost IS
  'Acompte debite a la reservation (duree du creneau x tarif/min). Le
  retour reconcilie le total reel avec ce montant.';

CREATE OR REPLACE FUNCTION vehicle_pickup(p_reservation_id UUID, p_km NUMERIC)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res      vehicle_reservations%ROWTYPE;
  v_attendu  NUMERIC;
  v_ecart    NUMERIC;
BEGIN
  SELECT * INTO v_res FROM vehicle_reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESERVATION_INTROUVABLE'; END IF;
  IF v_res.tenant_id <> auth.uid() THEN RAISE EXCEPTION 'PAS_LA_VOTRE'; END IF;
  IF v_res.status <> 'confirmed' THEN RAISE EXCEPTION 'STATUT_INATTENDU'; END IF;
  IF p_km IS NULL OR p_km < 0 THEN RAISE EXCEPTION 'COMPTEUR_INVALIDE'; END IF;

  SELECT odometer_km INTO v_attendu FROM vehicles WHERE id = v_res.vehicle_id;
  v_ecart := p_km - COALESCE(v_attendu, 0);

  UPDATE vehicle_reservations
     SET km_start   = p_km,
         km_ecart   = NULLIF(v_ecart, 0),
         started_at = NOW(),
         status     = 'in_progress'
   WHERE id = p_reservation_id;

  -- Le compteur du vehicule suit ce que la personne a reellement trouve :
  -- sinon l'ecart se repeterait a chaque prise suivante.
  UPDATE vehicles SET odometer_km = p_km WHERE id = v_res.vehicle_id;

  RETURN jsonb_build_object('km_attendu', COALESCE(v_attendu, 0), 'ecart', v_ecart);
END;
$$;
REVOKE ALL ON FUNCTION vehicle_pickup(UUID, NUMERIC) FROM public, anon;
GRANT  EXECUTE ON FUNCTION vehicle_pickup(UUID, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION vehicle_return(p_reservation_id UUID, p_km NUMERIC)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_res       vehicle_reservations%ROWTYPE;
  v_min_rate  NUMERIC := 0;
  v_km_rate   NUMERIC := 0;
  v_minutes   INT;
  v_distance  NUMERIC;
  v_time      NUMERIC;
  v_km_cost   NUMERIC;
  v_total     NUMERIC;
  v_delta     NUMERIC;
BEGIN
  SELECT * INTO v_res FROM vehicle_reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESERVATION_INTROUVABLE'; END IF;
  IF v_res.tenant_id <> auth.uid() THEN RAISE EXCEPTION 'PAS_LA_VOTRE'; END IF;
  IF v_res.status <> 'in_progress' THEN RAISE EXCEPTION 'VEHICULE_PAS_PRIS'; END IF;
  IF p_km IS NULL OR p_km < v_res.km_start THEN RAISE EXCEPTION 'COMPTEUR_RECULE'; END IF;

  SELECT COALESCE(price_per_minute, 0), COALESCE(price_per_km, 0)
    INTO v_min_rate, v_km_rate
    FROM vehicle_pricing
   WHERE vehicle_id = v_res.vehicle_id
     AND valid_from <= NOW()
     AND (valid_to IS NULL OR valid_to > NOW())
   ORDER BY valid_from DESC
   LIMIT 1;

  -- La saisie du compteur arrete le temps : la duree facturee court de la
  -- prise a maintenant, pas jusqu'a la fin du creneau reserve. Rendre tot
  -- coute moins cher, et rend le vehicule au parc.
  v_minutes  := GREATEST(1, CEIL(EXTRACT(EPOCH FROM (NOW() - v_res.started_at)) / 60.0));
  v_distance := p_km - v_res.km_start;
  v_time     := ROUND(v_minutes * v_min_rate, 2);
  v_km_cost  := ROUND(v_distance * v_km_rate, 2);
  v_total    := v_time + v_km_cost;
  v_delta    := v_total - COALESCE(v_res.deposit_cost, 0);

  UPDATE vehicle_reservations
     SET km_end        = p_km,
         total_km      = v_distance,
         total_minutes = v_minutes,
         time_cost     = v_time,
         km_cost       = v_km_cost,
         total_cost    = v_total,
         returned_at   = NOW(),
         status        = 'completed'
   WHERE id = p_reservation_id;

  UPDATE vehicles SET odometer_km = p_km WHERE id = v_res.vehicle_id;

  RETURN jsonb_build_object(
    'minutes',  v_minutes,
    'distance', v_distance,
    'time_cost', v_time,
    'km_cost',  v_km_cost,
    'total',    v_total,
    'deposit',  COALESCE(v_res.deposit_cost, 0),
    'delta',    v_delta
  );
END;
$$;
REVOKE ALL ON FUNCTION vehicle_return(UUID, NUMERIC) FROM public, anon;
GRANT  EXECUTE ON FUNCTION vehicle_return(UUID, NUMERIC) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
