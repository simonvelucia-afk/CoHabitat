-- soldes_test.sql — vérifie la migration 040 : plus aucune fonction de
-- solde ou de rôle n'est ouverte sans connexion ; un résident ne paie
-- que pour lui, n'est remboursé que de ce qu'il a payé ; le covoiturage
-- se facture en base, une seule fois. Transaction annulée à la fin.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/soldes_test.sql

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('d0000000-0000-0000-0000-0000000000c1', 'chauffeur@test.local'),
  ('d0000000-0000-0000-0000-0000000000a1', 'passager1@test.local'),
  ('d0000000-0000-0000-0000-0000000000a2', 'passager2@test.local'),
  ('d0000000-0000-0000-0000-0000000000ad', 'admin.soldes@test.local');
UPDATE profiles SET role = 'admin' WHERE id = 'd0000000-0000-0000-0000-0000000000ad';
UPDATE profiles SET virtual_balance = 50
 WHERE id IN ('d0000000-0000-0000-0000-0000000000c1', 'd0000000-0000-0000-0000-0000000000a1',
              'd0000000-0000-0000-0000-0000000000a2');

INSERT INTO vehicles (id, model, license_plate)
VALUES ('d0000000-0000-0000-0000-0000000000e1', 'Modèle test', 'TEST-01');
INSERT INTO vehicle_pricing (vehicle_id, price_per_minute, price_per_km, driver_reduction_pct)
VALUES ('d0000000-0000-0000-0000-0000000000e1', 0.10, 0.50, 25);

-- Trajet de 60 min, 20 km ; passager 1 : 1 place, 20 km ; passager 2 :
-- 1 place, 10 km.
INSERT INTO trips (id, vehicle_id, driver_id, title, departure_point, destination, departure_time,
                   available_seats, status, actual_km, vehicle_taken_at, vehicle_returned_at)
VALUES ('d0000000-0000-0000-0000-0000000000f1', 'd0000000-0000-0000-0000-0000000000e1',
        'd0000000-0000-0000-0000-0000000000c1', 'Test', 'A', 'B', now(), 3, 'published',
        20, now() - interval '60 minutes', now());
INSERT INTO trip_bookings (trip_id, passenger_id, pickup_location, dropoff_location, seats_requested, status, actual_km)
VALUES ('d0000000-0000-0000-0000-0000000000f1', 'd0000000-0000-0000-0000-0000000000a1', 'A', 'B', 1, 'accepted', 20),
       ('d0000000-0000-0000-0000-0000000000f1', 'd0000000-0000-0000-0000-0000000000a2', 'A', 'B', 1, 'accepted', 10);

-- ── 1) Sans connexion : plus rien ────────────────────────────────────
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    $q$SELECT adjust_balance('d0000000-0000-0000-0000-0000000000a1', 1000, 'admin_credit')$q$,
    $q$SELECT admin_update_profile('d0000000-0000-0000-0000-0000000000a1','X',NULL,'principal_admin',TRUE,TRUE)$q$,
    $q$SELECT admin_set_balance('d0000000-0000-0000-0000-0000000000a1', 1000)$q$,
    $q$SELECT anonymize_profile('d0000000-0000-0000-0000-0000000000a1')$q$,
    $q$SELECT solde_debiter(1, 'space_reservation')$q$,
    $q$SELECT admin_crediter('d0000000-0000-0000-0000-0000000000a1', 1000)$q$,
    $q$SELECT trajet_confirmer('d0000000-0000-0000-0000-0000000000f1')$q$
  ] LOOP
    BEGIN
      EXECUTE f;
      RAISE EXCEPTION 'ECHEC : appel anonyme accepté : %', f;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
END $$;

-- ── 2) Un résident ne se crédite pas, ne débite pas un voisin ────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"d0000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);
DO $$
DECLARE s NUMERIC;
BEGIN
  BEGIN PERFORM adjust_balance('d0000000-0000-0000-0000-0000000000a1', 1000, 'admin_credit');
        RAISE EXCEPTION 'ECHEC : résident appelle adjust_balance';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM admin_crediter('d0000000-0000-0000-0000-0000000000a1', 1000);
        RAISE EXCEPTION 'ECHEC : résident crédité par lui-même';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'FORBIDDEN' THEN RAISE; END IF; END;
  BEGIN PERFORM solde_debiter(-5, 'space_reservation');
        RAISE EXCEPTION 'ECHEC : débit négatif accepté';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'MONTANT_INVALIDE' THEN RAISE; END IF; END;
  BEGIN PERFORM solde_debiter(5, 'admin_credit');
        RAISE EXCEPTION 'ECHEC : type interdit accepté';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'TYPE_INTERDIT' THEN RAISE; END IF; END;
  BEGIN PERFORM solde_debiter(500, 'space_reservation');
        RAISE EXCEPTION 'ECHEC : débit sans fonds';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'INSUFFICIENT_FUNDS' THEN RAISE; END IF; END;

  -- Paiement d'une réservation, rejoué : un seul débit.
  s := solde_debiter(12, 'space_reservation', 'd0000000-0000-0000-0000-0000000000b1', 'space_reservation', 'Salle', 'resv-1');
  s := solde_debiter(12, 'space_reservation', 'd0000000-0000-0000-0000-0000000000b1', 'space_reservation', 'Salle', 'resv-1');
  IF s <> 38 THEN RAISE EXCEPTION 'ECHEC : rejeu a redébité (%)', s; END IF;

  -- Remboursement : jamais au-delà de ce qui a été payé pour cette référence.
  BEGIN PERFORM solde_rembourser(13, 'space_cancel_refund', 'd0000000-0000-0000-0000-0000000000b1');
        RAISE EXCEPTION 'ECHEC : remboursement excessif';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'REMBOURSEMENT_EXCESSIF' THEN RAISE; END IF; END;
  s := solde_rembourser(12, 'space_cancel_refund', 'd0000000-0000-0000-0000-0000000000b1', NULL, NULL, 'resv-1-rb');
  BEGIN PERFORM solde_rembourser(1, 'space_cancel_refund', 'd0000000-0000-0000-0000-0000000000b1');
        RAISE EXCEPTION 'ECHEC : second remboursement';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'REMBOURSEMENT_EXCESSIF' THEN RAISE; END IF; END;
  IF s <> 50 THEN RAISE EXCEPTION 'ECHEC : solde après remboursement (%)', s; END IF;

  -- Un passager ne confirme pas le trajet.
  BEGIN PERFORM trajet_confirmer('d0000000-0000-0000-0000-0000000000f1');
        RAISE EXCEPTION 'ECHEC : passager confirme le trajet';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'FORBIDDEN' THEN RAISE; END IF; END;
END $$;

-- ── 3) Le chauffeur confirme : prix calculé en base, une seule fois ──
SELECT set_config('request.jwt.claims',
  '{"sub":"d0000000-0000-0000-0000-0000000000c1","role":"authenticated"}', TRUE);
DO $$
DECLARE r JSONB;
BEGIN
  -- Passager 1 : 20 km × 0,50 + 60 min × 0,10 × 1/2 = 10 + 3 = 13
  -- Passager 2 : 10 km × 0,50 + 3 = 8
  -- Chauffeur  : (6 + 10) × 1/3 × 25 % = 1,33
  r := trajet_confirmer('d0000000-0000-0000-0000-0000000000f1');
  IF (r->>'total_passagers')::NUMERIC <> 21 OR (r->>'credit_chauffeur')::NUMERIC <> 1.33 THEN
    RAISE EXCEPTION 'ECHEC : facturation %', r;
  END IF;
  BEGIN PERFORM trajet_confirmer('d0000000-0000-0000-0000-0000000000f1');
        RAISE EXCEPTION 'ECHEC : trajet facturé deux fois';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'TRAJET_DEJA_FACTURE' THEN RAISE; END IF; END;
END $$;
RESET ROLE;
DO $$
BEGIN
  IF (SELECT virtual_balance FROM profiles WHERE id = 'd0000000-0000-0000-0000-0000000000a1') <> 37
  OR (SELECT virtual_balance FROM profiles WHERE id = 'd0000000-0000-0000-0000-0000000000a2') <> 42
  OR (SELECT virtual_balance FROM profiles WHERE id = 'd0000000-0000-0000-0000-0000000000c1') <> 51.33 THEN
    RAISE EXCEPTION 'ECHEC : soldes après trajet';
  END IF;
  IF (SELECT status FROM trips WHERE id = 'd0000000-0000-0000-0000-0000000000f1') <> 'completed' THEN
    RAISE EXCEPTION 'ECHEC : trajet non terminé';
  END IF;
END $$;

-- ── 4) L'admin crédite ───────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"d0000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
DO $$
BEGIN
  IF admin_crediter('d0000000-0000-0000-0000-0000000000a1', 20, 'Paiement comptant') <> 57 THEN
    RAISE EXCEPTION 'ECHEC : crédit admin';
  END IF;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'soldes_test : OK'; END $$;

ROLLBACK;
