-- prix_test.sql — vérifie la migration 041 : les prix des espaces, de la
-- serre et des véhicules se calculent en base ; la page ne peut plus ni
-- fixer un montant, ni créer une réservation sans payer, ni réserver un
-- créneau déjà pris. Transaction annulée à la fin.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/prix_test.sql

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('e1000000-0000-0000-0000-0000000000a1', 'prix.a@test.local'),
  ('e1000000-0000-0000-0000-0000000000a2', 'prix.b@test.local');
UPDATE profiles SET virtual_balance = 100 WHERE id = 'e1000000-0000-0000-0000-0000000000a1';
UPDATE profiles SET virtual_balance = 3   WHERE id = 'e1000000-0000-0000-0000-0000000000a2';

-- Salle à 2 $ la tranche de 15 min ; zone de serre à 4 $/mois ; vélo à
-- 0,10 $/min et 0,50 $/km.
INSERT INTO common_spaces (id, name) VALUES ('e1000000-0000-0000-0000-0000000000b5', 'Salle test');
INSERT INTO space_pricing (space_id, price_per_slot, valid_from) VALUES ('e1000000-0000-0000-0000-0000000000b5', 2, now() - interval '1 day');
INSERT INTO serre_zones (id, code, planche, position, frais_mensuel)
VALUES ('e1000000-0000-0000-0000-0000000000c5', 'TZ1', 99, 99, 4);
INSERT INTO vehicles (id, model, license_plate) VALUES ('e1000000-0000-0000-0000-0000000000d5', 'Vélo test', 'V-TEST');
INSERT INTO vehicle_pricing (vehicle_id, price_per_minute, price_per_km, valid_from)
VALUES ('e1000000-0000-0000-0000-0000000000d5', 0.10, 0.50, now() - interval '1 day');

CREATE TEMP TABLE prix_ctx (cle TEXT PRIMARY KEY, val UUID);
GRANT ALL ON prix_ctx TO authenticated;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"e1000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);

-- ── 1) La page ne crée plus rien elle-même ───────────────────────────
DO $$
BEGIN
  BEGIN
    INSERT INTO space_reservations (space_id, tenant_id, start_time, end_time, total_slots, total_cost)
    VALUES ('e1000000-0000-0000-0000-0000000000b5', auth.uid(), now() + interval '1 day',
            now() + interval '1 day 4 hours', 16, 0.01);
    RAISE EXCEPTION 'ECHEC : réservation directe à un sou';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'PASSER_PAR_LA_RESERVATION' THEN RAISE; END IF;
  END;
  BEGIN
    INSERT INTO serre_locations (zone_id, tenant_id, frais_mensuel)
    VALUES ('e1000000-0000-0000-0000-0000000000c5', auth.uid(), 0);
    RAISE EXCEPTION 'ECHEC : location de serre gratuite';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'PASSER_PAR_LA_RESERVATION' THEN RAISE; END IF;
  END;
END $$;

-- ── 2) Espace : prix en base, créneau protégé ────────────────────────
DO $$
DECLARE r JSONB;
BEGIN
  -- 18 h → 19 h 10 : 70 min = 5 tranches entamées × 2 $ = 10 $
  r := espace_reserver('e1000000-0000-0000-0000-0000000000b5',
                       date_trunc('day', now()) + interval '2 days 18 hours',
                       date_trunc('day', now()) + interval '2 days 19 hours 10 minutes');
  IF (r->>'cout')::NUMERIC <> 10 OR (r->>'virtual_balance')::NUMERIC <> 90 THEN RAISE EXCEPTION 'ECHEC espace %', r; END IF;
  INSERT INTO prix_ctx VALUES ('espace', (r->>'reservation_id')::UUID);
  -- Le prix ne se réécrit pas.
  BEGIN
    UPDATE space_reservations SET total_cost = 0 WHERE id = (r->>'reservation_id')::UUID;
    RAISE EXCEPTION 'ECHEC : prix réécrit';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'PRIX_VERROUILLE' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM espace_reserver('e1000000-0000-0000-0000-0000000000b5',
                            date_trunc('day', now()) + interval '2 days 19 hours',
                            date_trunc('day', now()) + interval '2 days 20 hours');
    RAISE EXCEPTION 'ECHEC : chevauchement accepté';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'CRENEAU_PRIS' THEN RAISE; END IF;
  END;
END $$;

-- Un autre résident, qui ne voit pas la réservation du premier, ne prend
-- pas le même créneau (l'ancien contrôle tournait avec ses droits).
SELECT set_config('request.jwt.claims',
  '{"sub":"e1000000-0000-0000-0000-0000000000a2","role":"authenticated"}', TRUE);
DO $$
BEGIN
  BEGIN
    PERFORM espace_reserver('e1000000-0000-0000-0000-0000000000b5',
                            date_trunc('day', now()) + interval '2 days 18 hours 30 minutes',
                            date_trunc('day', now()) + interval '2 days 18 hours 45 minutes');
    RAISE EXCEPTION 'ECHEC : créneau d''un voisin réservé';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'CRENEAU_PRIS' THEN RAISE; END IF;
  END;
  -- Fonds insuffisants (3 $ pour 4 $) : rien n'est créé.
  BEGIN
    PERFORM espace_reserver('e1000000-0000-0000-0000-0000000000b5',
                            date_trunc('day', now()) + interval '3 days 10 hours',
                            date_trunc('day', now()) + interval '3 days 10 hours 30 minutes');
    RAISE EXCEPTION 'ECHEC : réservation sans fonds';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'INSUFFICIENT_FUNDS' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM space_reservations WHERE tenant_id = 'e1000000-0000-0000-0000-0000000000a2') THEN
    RAISE EXCEPTION 'ECHEC : réservation non payée restée en base';
  END IF;
END $$;
SET LOCAL ROLE authenticated;

-- ── 3) Serre : tarif de la zone, mois suivants ───────────────────────
SELECT set_config('request.jwt.claims',
  '{"sub":"e1000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);
DO $$
DECLARE r JSONB; v_loc UUID;
BEGIN
  r := serre_louer('e1000000-0000-0000-0000-0000000000c5');
  IF (r->>'frais_mensuel')::NUMERIC <> 4 OR (r->>'virtual_balance')::NUMERIC <> 86 THEN RAISE EXCEPTION 'ECHEC serre %', r; END IF;
  v_loc := (r->>'location_id')::UUID;
  IF (SELECT COUNT(*) FROM serre_cultures WHERE location_id = v_loc) <> 3 THEN RAISE EXCEPTION 'ECHEC : sections'; END IF;
  BEGIN
    UPDATE serre_locations SET frais_mensuel = 0 WHERE id = v_loc;
    RAISE EXCEPTION 'ECHEC : frais réécrits';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'PRIX_VERROUILLE' THEN RAISE; END IF;
  END;
  -- Libérer la zone reste permis.
  INSERT INTO prix_ctx VALUES ('serre', v_loc);
  -- Rien d'échu ce mois-ci.
  r := serre_facturer();
  IF (r->>'mois')::INT <> 0 THEN RAISE EXCEPTION 'ECHEC : facturation prématurée %', r; END IF;
END $$;
-- Trois mois plus tard (on recule la dernière facturation) : deux mois
-- dus, le mois courant ayant été payé à la location.
RESET ROLE;
UPDATE serre_locations SET derniere_facturation = (date_trunc('month', current_date) - interval '3 months')::DATE
 WHERE id = (SELECT val FROM prix_ctx WHERE cle = 'serre');
SET LOCAL ROLE authenticated;
DO $$
DECLARE r JSONB;
BEGIN
  r := serre_facturer();
  IF (r->>'mois')::INT <> 2 OR (r->>'total')::NUMERIC <> 8 OR (r->>'virtual_balance')::NUMERIC <> 78 THEN
    RAISE EXCEPTION 'ECHEC : mois échus %', r;
  END IF;
  r := serre_facturer();
  IF (r->>'mois')::INT <> 0 THEN RAISE EXCEPTION 'ECHEC : double facturation'; END IF;
  UPDATE serre_locations SET statut = 'terminee', date_fin = current_date WHERE id = (SELECT val FROM prix_ctx WHERE cle = 'serre');
END $$;

-- ── 4) Véhicule : acompte, retour, annulation ────────────────────────
DO $$
DECLARE r JSONB; v_res UUID;
BEGIN
  -- 2 h × 0,10 $/min = 12 $
  r := vehicule_reserver('e1000000-0000-0000-0000-0000000000d5', now() + interval '1 day', now() + interval '1 day 2 hours', 'Courses');
  IF (r->>'cout')::NUMERIC <> 12 OR (r->>'virtual_balance')::NUMERIC <> 66 THEN RAISE EXCEPTION 'ECHEC vehicule %', r; END IF;
  v_res := (r->>'reservation_id')::UUID;
  BEGIN
    UPDATE vehicle_reservations SET status = 'cancelled' WHERE id = v_res;
    RAISE EXCEPTION 'ECHEC : annulation directe (sans passer par le remboursement)';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'PRIX_VERROUILLE' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM vehicule_reserver('e1000000-0000-0000-0000-0000000000d5', now() + interval '1 day 1 hour', now() + interval '1 day 3 hours');
    RAISE EXCEPTION 'ECHEC : véhicule réservé deux fois';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'CRENEAU_PRIS' THEN RAISE; END IF;
  END;
  -- Annulée plus de 2 h avant : acompte rendu, une fois.
  r := vehicule_annuler(v_res);
  IF NOT (r->>'rembourse')::BOOLEAN OR (r->>'virtual_balance')::NUMERIC <> 78 THEN RAISE EXCEPTION 'ECHEC annulation %', r; END IF;
  BEGIN PERFORM vehicule_annuler(v_res); RAISE EXCEPTION 'ECHEC : double annulation';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'NON_ANNULABLE' THEN RAISE; END IF; END;

  -- Annulée à moins de 2 h : acompte gardé.
  r := vehicule_reserver('e1000000-0000-0000-0000-0000000000d5', now() + interval '30 minutes', now() + interval '90 minutes');
  v_res := (r->>'reservation_id')::UUID;
  r := vehicule_annuler(v_res);
  IF (r->>'rembourse')::BOOLEAN OR (r->>'virtual_balance')::NUMERIC <> 72 THEN RAISE EXCEPTION 'ECHEC annulation tardive %', r; END IF;

  -- Prise puis retour : 30 min réelles, 10 km → 3 + 5 = 8 $ ; acompte 6 $ → complément 2 $.
  r := vehicule_reserver('e1000000-0000-0000-0000-0000000000d5', now(), now() + interval '1 hour');
  v_res := (r->>'reservation_id')::UUID;
  INSERT INTO prix_ctx VALUES ('vehicule', v_res);
END $$;
RESET ROLE;
UPDATE vehicle_reservations SET status = 'in_progress', started_at = now() - interval '30 minutes', km_start = 100,
       deposit_cost = 6
 WHERE id = (SELECT val FROM prix_ctx WHERE cle = 'vehicule');
SET LOCAL ROLE authenticated;
DO $$
DECLARE r JSONB; avant NUMERIC;
BEGIN
  avant := (SELECT virtual_balance FROM profiles WHERE id = auth.uid());
  r := vehicule_retourner((SELECT val FROM prix_ctx WHERE cle = 'vehicule'), 110);
  IF (r->>'total')::NUMERIC < 8 OR (r->>'total')::NUMERIC > 8.11 THEN RAISE EXCEPTION 'ECHEC retour %', r; END IF;
  IF (r->>'virtual_balance')::NUMERIC <> avant - (r->>'delta')::NUMERIC THEN RAISE EXCEPTION 'ECHEC règlement %', r; END IF;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'prix_test : OK'; END $$;

ROLLBACK;
