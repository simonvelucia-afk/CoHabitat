-- 031_mobilite_partagee.sql
-- Mobilite partagee (MaaS) — reservation directe d'un vehicule.
--
-- Jusqu'ici, un vehicule ne s'atteignait qu'a travers un trajet publie par
-- un chauffeur approuve : il fallait un conducteur, des passagers, un
-- point de depart et une destination. Ce cadre convient a l'auto-partage,
-- il ne convient pas aux velomobiles du batiment — on les prend pour une
-- heure, seul, sans annoncer ou l'on va.
--
-- D'ou la reservation directe, calquee sur celle des espaces communs :
-- un vehicule, un creneau, un cout au temps d'utilisation, debite du
-- solde virtuel. Le covoiturage reste inchange ; les deux usages
-- partagent la meme flotte, et se voient l'un l'autre (voir
-- check_vehicle_availability plus bas).
--
-- Ajoute :
--   * vehicles.vehicle_type    auto / velomobile / velo / autre
--   * vehicles.is_reservable   ce vehicule accepte-t-il la reservation
--                              directe ? (un vehicule reserve au
--                              covoiturage reste a false)
--   * vehicle_reservations     un creneau reserve par un resident
--   * check_vehicle_availability(), qui regarde AUSSI les trajets

BEGIN;

-- ============================================================
-- 1) Typer la flotte
-- ============================================================
-- Le type ne sert pas qu'a l'icone : c'est lui qui distingue une flotte
-- multimodale d'un parc automobile. Defaut 'auto' — les vehicules deja
-- en base sont des voitures.
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS vehicle_type TEXT NOT NULL DEFAULT 'auto';
ALTER TABLE vehicles DROP CONSTRAINT IF EXISTS vehicles_type_check;
ALTER TABLE vehicles
  ADD CONSTRAINT vehicles_type_check
  CHECK (vehicle_type IN ('auto', 'velomobile', 'velo', 'autre'));

-- Un vehicule peut etre disponible (is_available) sans etre reservable a
-- l'heure : une voiture reservee au covoiturage encadre reste dans la
-- flotte, mais hors du libre-service.
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS is_reservable BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN vehicles.vehicle_type IS
  'Mode de transport : auto, velomobile, velo, autre. Sert au regroupement
  de la flotte et au choix de l''icone.';
COMMENT ON COLUMN vehicles.is_reservable IS
  'Ce vehicule accepte la reservation directe (libre-service). A false, il
  ne reste accessible que par un trajet publie.';

-- ============================================================
-- 2) Reservations de vehicules
-- ============================================================
-- Meme forme que space_reservations, a deux details pres : la duree est
-- comptee en minutes (le tarif des vehicules est au menu, pas a la
-- tranche de 15 min) et `purpose` garde la raison declaree, utile quand
-- deux personnes veulent le meme creneau.
CREATE TABLE IF NOT EXISTS vehicle_reservations (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id     UUID NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  tenant_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  start_time     TIMESTAMPTZ NOT NULL,
  end_time       TIMESTAMPTZ NOT NULL,
  total_minutes  INT NOT NULL,
  total_cost     DECIMAL(10,2) NOT NULL DEFAULT 0,
  purpose        TEXT,
  status         TEXT NOT NULL DEFAULT 'confirmed'
                 CHECK (status IN ('pending', 'confirmed', 'cancelled', 'completed')),
  is_demo        BOOLEAN NOT NULL DEFAULT FALSE,
  cancelled_at   TIMESTAMPTZ,
  cancel_reason  TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT vehicle_resv_ordre   CHECK (end_time > start_time),
  CONSTRAINT vehicle_resv_purpose CHECK (purpose IS NULL OR char_length(purpose) <= 300)
);

CREATE INDEX IF NOT EXISTS vehicle_reservations_vehicle_idx ON vehicle_reservations (vehicle_id, start_time);
CREATE INDEX IF NOT EXISTS vehicle_reservations_tenant_idx  ON vehicle_reservations (tenant_id, start_time DESC);

-- ============================================================
-- 3) Disponibilite
-- ============================================================
-- Un vehicule est pris par une reservation OU par un trajet publie : les
-- deux usages puisent dans la meme flotte, ignorer les trajets ferait
-- partir un velomobile deja engage sur un covoiturage.
--
-- Un trajet n'a pas toujours d'heure d'arrivee estimee. Faute de mieux on
-- lui reserve deux heures : mieux vaut refuser un creneau de trop que
-- promettre un vehicule absent.
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
      AND status IN ('confirmed', 'pending')
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

-- Creneaux deja pris, pour les montrer avant de choisir. Renvoie les
-- bornes, jamais qui a reserve : savoir qu'un velomobile est pris de 14h a
-- 16h suffit a en choisir un autre, et la RLS de vehicle_reservations ne
-- laisse personne lire les reservations des autres.
--
-- p_vehicle_id NULL = toute la flotte, en un appel : la page liste une
-- dizaine de vehicules, une requete par vehicule serait dix allers-retours
-- pour afficher une pastille.
CREATE OR REPLACE FUNCTION vehicle_busy_slots(
  p_vehicle_id UUID DEFAULT NULL,
  p_jours      INT  DEFAULT 14
)
RETURNS TABLE (vehicle_id UUID, debut TIMESTAMPTZ, fin TIMESTAMPTZ, source TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT r.vehicle_id, r.start_time, r.end_time, 'reservation'::TEXT
    FROM vehicle_reservations r
   WHERE (p_vehicle_id IS NULL OR r.vehicle_id = p_vehicle_id)
     AND r.status IN ('confirmed', 'pending')
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

-- ============================================================
-- 4) RLS
-- ============================================================
-- Calquee sur space_reservations : chacun voit et gere les siennes,
-- l'admin voit tout. Pas de DELETE : une reservation annulee garde sa
-- ligne (statut 'cancelled'), comme pour les espaces, sinon la trace du
-- debit et du remboursement se perd.
ALTER TABLE vehicle_reservations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vehicle_resv_select ON vehicle_reservations;
CREATE POLICY vehicle_resv_select ON vehicle_reservations
  FOR SELECT TO authenticated
  USING (tenant_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin'));

DROP POLICY IF EXISTS vehicle_resv_insert ON vehicle_reservations;
CREATE POLICY vehicle_resv_insert ON vehicle_reservations
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin'));

DROP POLICY IF EXISTS vehicle_resv_update ON vehicle_reservations;
CREATE POLICY vehicle_resv_update ON vehicle_reservations
  FOR UPDATE TO authenticated
  USING (tenant_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin'))
  WITH CHECK (tenant_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin'));

-- ============================================================
-- 4bis) Ledger : accepter les deux nouveaux types
-- ============================================================
-- Sans ca, adjust_balance() et la centrale rejettent le debit et la
-- reservation s'annule d'elle-meme. La liste est reprise telle quelle de
-- sql/001_lunch_coherence.sql, augmentee des deux types de mobilite.
--
-- ATTENTION : la centrale (finance-bridge) tient SA PROPRE liste blanche
-- de types, hors de ce depot. Sur une installation branchee a la
-- centrale, il faut y ajouter 'vehicle_reservation' et
-- 'vehicle_reservation_refund', sinon le debit revient en erreur et la
-- reservation est annulee automatiquement. Une instance autonome
-- (central desactive) n'est pas concernee : elle passe par
-- adjust_balance(), que ce CHECK suffit a debloquer.
DO $ck$
BEGIN
  ALTER TABLE transactions DROP CONSTRAINT IF EXISTS transactions_type_check;
  ALTER TABLE transactions ADD CONSTRAINT transactions_type_check
    CHECK (type IN (
      'admin_credit',
      'space_reservation',
      'space_cancel_refund',
      'trip_booking',
      'trip_cancel_refund',
      'trip_cancel_charge',
      'trip_driver_earning',
      'trip_driver_charge',
      'lunch_purchase',
      'vehicle_reservation',
      'vehicle_reservation_refund',
      'demo'
    ));
END $ck$;

COMMENT ON TABLE vehicle_reservations IS
  'Reservation directe d''un vehicule sur un creneau (libre-service).
  Complete le covoiturage : meme flotte, deux facons de s''en servir.';

-- ============================================================
-- 5) Les velomobiles du batiment
-- ============================================================
-- Rien a inserer si la flotte n'existe pas encore (installation neuve
-- sans donnees d'exemple) : le bloc ne fait rien plutot que d'echouer.
-- Les vehicules deja presents restent des autos, la migration ne les
-- retype pas.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM vehicles LIMIT 1)
     AND NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_type = 'velomobile') THEN

    INSERT INTO vehicles (model, license_plate, seat_count, cargo_capacity_m3,
                          vehicle_type, is_reservable, color, notes)
    VALUES
      ('Velomobile 1', 'VM-01', 1, 0.15, 'velomobile', TRUE, 'Jaune',
       'Velomobile carene du batiment. Reservation a l''heure.'),
      ('Velomobile 2', 'VM-02', 1, 0.15, 'velomobile', TRUE, 'Bleu',
       'Velomobile carene du batiment. Reservation a l''heure.')
    ON CONFLICT (license_plate) DO NOTHING;

    INSERT INTO vehicle_pricing (vehicle_id, price_per_minute, price_per_km, price_per_cargo_slot)
    SELECT id, 0.02, 0, 0 FROM vehicles
     WHERE license_plate IN ('VM-01', 'VM-02')
       AND NOT EXISTS (SELECT 1 FROM vehicle_pricing WHERE vehicle_id = vehicles.id);
  END IF;
END $$;

-- ============================================================
-- 7) Le module change de nom
-- ============================================================
-- La cle reste `module_trips` : la renommer casserait les reglages en
-- place et toutes les lectures cote client. Seul le libelle bouge.
UPDATE system_settings
   SET description = 'Module Mobilité partagée : réservation de véhicules, covoiturage et demandes de passagers'
 WHERE key = 'module_trips';

COMMIT;

NOTIFY pgrst, 'reload schema';
