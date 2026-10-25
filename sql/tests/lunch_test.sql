-- lunch_test.sql — verifie la Machine Lunch dans l'immeuble (migration
-- 037) sur une base fraichement migree : lecture sans PIN, ecritures
-- d'administration, achat atomique, remboursement unique, garde-fous.
-- A jouer dans une transaction annulee a la fin : aucune trace laissee.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/lunch_test.sql

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('a1000000-0000-0000-0000-0000000000a1', 'lunch.resident@test.local'),
  ('a1000000-0000-0000-0000-0000000000a2', 'lunch.voisin@test.local'),
  ('a1000000-0000-0000-0000-0000000000ad', 'lunch.admin@test.local');
UPDATE profiles SET role = 'principal_admin' WHERE id = 'a1000000-0000-0000-0000-0000000000ad';
UPDATE profiles SET virtual_balance = 10 WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
UPDATE profiles SET virtual_balance = 0  WHERE id = 'a1000000-0000-0000-0000-0000000000a2';
INSERT INTO dependents (id, parent_id, name, allow_lunch, virtual_balance)
VALUES ('a1000000-0000-0000-0000-0000000000d1', 'a1000000-0000-0000-0000-0000000000a1', 'Enfant', TRUE, 3);

CREATE TEMP TABLE lunch_test_ctx (cle TEXT PRIMARY KEY, val TEXT);
GRANT ALL ON lunch_test_ctx TO anon, authenticated;

-- ── 1) Import par l'administrateur principal ─────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"a1000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
DO $$
DECLARE r JSONB;
BEGIN
  r := lunch_importer('{
    "machines":[{"id":"LM-T","name":"Machine test","pin":"4321","active":true}],
    "zones":[{"machine_id":"LM-T","zone_key":"froid","name":"Froid","setpoint":4,"slot_count":2}],
    "slots":[{"machine_id":"LM-T","slot_num":1,"zone_key":"froid","description":"Sandwich","price":6.5},
             {"machine_id":"LM-T","slot_num":2,"zone_key":"froid","description":"Œufs","price":0}],
    "menus":[{"id":"m_1","machine_id":"LM-T","description":"Soupe","price":4}]}'::jsonb);
  IF (r->>'cases')::INT <> 2 OR (r->>'machines')::INT <> 1 THEN RAISE EXCEPTION 'ECHEC import %', r; END IF;
END $$;

-- ── 2) Le kiosque sans session lit tout, sauf le PIN ─────────────────
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', TRUE);
DO $$
BEGIN
  IF (SELECT COUNT(*) FROM lunch_slots WHERE machine_id = 'LM-T') <> 2 THEN
    RAISE EXCEPTION 'ECHEC : le kiosque ne lit pas les cases';
  END IF;
  BEGIN
    PERFORM pin FROM lunch_machines WHERE id = 'LM-T';
    RAISE EXCEPTION 'ECHEC : le PIN est lisible';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE lunch_slots SET price = 0 WHERE machine_id = 'LM-T';
    RAISE EXCEPTION 'ECHEC : anon ecrit directement une case';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Mauvais PIN : refuse ; bon PIN : ecriture acceptee.
  IF lunch_kiosque_ecrire('LM-T', '0000', 'case', '{"slot_num":3,"description":"Pirate","price":1}') ->> 'erreur' <> 'FORBIDDEN' THEN
    RAISE EXCEPTION 'ECHEC : mauvais PIN accepte';
  END IF;
  PERFORM lunch_kiosque_ecrire('LM-T', '4321', 'case', '{"slot_num":3,"zone_key":"froid","description":"Salade","price":5}');
  IF (SELECT price FROM lunch_slots WHERE machine_id = 'LM-T' AND slot_num = 3) <> 5 THEN
    RAISE EXCEPTION 'ECHEC : ecriture avec PIN non appliquee';
  END IF;
  IF lunch_pin_valide('LM-T', '4321') <> 'ok' THEN RAISE EXCEPTION 'ECHEC : PIN valide refuse'; END IF;
  -- Un achat exige une session.
  BEGIN
    PERFORM lunch_acheter('LM-T', 1, NULL, 'x', NULL);
    RAISE EXCEPTION 'ECHEC : achat anonyme';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- Dix mauvais PIN bloquent la machine.
DO $$
DECLARE i INT;
BEGIN
  FOR i IN 1..10 LOOP PERFORM lunch_pin_valide('LM-T', '1111'); END LOOP;
  IF lunch_pin_valide('LM-T', '4321') <> 'bloque' THEN RAISE EXCEPTION 'ECHEC : pas de blocage apres 10 essais'; END IF;
END $$;
RESET ROLE;
DELETE FROM lunch_pin_essais WHERE machine_id = 'LM-T';
SET LOCAL ROLE authenticated;

-- ── 3) Achat : prix en base, solde verifie, case videe ───────────────
SELECT set_config('request.jwt.claims',
  '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);
DO $$
DECLARE r JSONB;
BEGIN
  r := lunch_acheter('LM-T', 1, NULL, 'Résident', 'cle-1');
  IF (r->>'prix')::NUMERIC <> 6.5 OR (r->>'virtual_balance')::NUMERIC <> 3.5 THEN
    RAISE EXCEPTION 'ECHEC achat %', r;
  END IF;
  INSERT INTO lunch_test_ctx VALUES ('achat', r->>'achat_id');
  -- Rejeu de la meme cle : pas de second debit.
  r := lunch_acheter('LM-T', 1, NULL, 'Résident', 'cle-1');
  IF NOT (r->>'rejeu')::BOOLEAN OR lunch_mon_solde(NULL) <> 3.5 THEN RAISE EXCEPTION 'ECHEC : rejeu a redebite'; END IF;
  -- La case est vide : on ne la rachete pas.
  BEGIN
    PERFORM lunch_acheter('LM-T', 1, NULL, 'Résident', 'cle-2');
    RAISE EXCEPTION 'ECHEC : case videe rachetee';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'CASE_VIDE' THEN RAISE; END IF;
  END;
  -- Solde insuffisant (5 $ > 3,50 $).
  BEGIN
    PERFORM lunch_acheter('LM-T', 3, NULL, 'Résident', 'cle-3');
    RAISE EXCEPTION 'ECHEC : achat sans fonds';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'SOLDE_INSUFFISANT' THEN RAISE; END IF;
  END;
  -- Le dependant paie de son propre solde (3 $ < 5 $ : refuse aussi).
  BEGIN
    PERFORM lunch_acheter('LM-T', 3, 'a1000000-0000-0000-0000-0000000000d1', 'Enfant', 'cle-4');
    RAISE EXCEPTION 'ECHEC : dependant sans fonds';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'SOLDE_INSUFFISANT' THEN RAISE; END IF;
  END;
  -- Retrait sans prix : pas de debit, case videe.
  r := lunch_acheter('LM-T', 2, NULL, 'Résident', NULL);
  IF r->>'achat_id' IS NOT NULL OR lunch_mon_solde(NULL) <> 3.5 THEN RAISE EXCEPTION 'ECHEC retrait gratuit %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM transactions WHERE user_id = auth.uid() AND type = 'lunch_purchase' AND amount = -6.5) THEN
    RAISE EXCEPTION 'ECHEC : achat absent du grand livre';
  END IF;
END $$;

-- Un voisin ne paie pas avec le dependant d'un autre, ni ne rembourse son achat.
SELECT set_config('request.jwt.claims',
  '{"sub":"a1000000-0000-0000-0000-0000000000a2","role":"authenticated"}', TRUE);
DO $$
BEGIN
  BEGIN
    PERFORM lunch_acheter('LM-T', 3, 'a1000000-0000-0000-0000-0000000000d1', 'Voisin', NULL);
    RAISE EXCEPTION 'ECHEC : dependant d''un autre accepte';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'DEPENDANT_INVALIDE' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM lunch_rembourser((SELECT val FROM lunch_test_ctx WHERE cle = 'achat')::UUID);
    RAISE EXCEPTION 'ECHEC : remboursement par un tiers';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'FORBIDDEN' THEN RAISE; END IF;
  END;
END $$;

-- ── 4) Remboursement : une fois, et la case retrouve son contenu ─────
SELECT set_config('request.jwt.claims',
  '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);
DO $$
DECLARE v_achat UUID := (SELECT val FROM lunch_test_ctx WHERE cle = 'achat')::UUID;
BEGIN
  PERFORM lunch_rembourser(v_achat);
  PERFORM lunch_rembourser(v_achat);
  IF lunch_mon_solde(NULL) <> 10 THEN RAISE EXCEPTION 'ECHEC : solde apres remboursement %', lunch_mon_solde(NULL); END IF;
  IF (SELECT description FROM lunch_slots WHERE machine_id = 'LM-T' AND slot_num = 1) <> 'Sandwich' THEN
    RAISE EXCEPTION 'ECHEC : case non restauree';
  END IF;
END $$;

-- ── 5) Ajout par numéro de série (038) ───────────────────────────────
-- Numéros fabriqués par deploy/scripts/numero-serie-lunch.mjs : la base
-- doit retrouver la même clé.
DO $$
BEGIN
  IF NOT lunch_serie_valide('LM-2026-00001-R') OR NOT lunch_serie_valide('lm-2026-00123-7')
     OR NOT lunch_serie_valide('LM-2026-00005-J') THEN
    RAISE EXCEPTION 'ECHEC : clé différente du script de génération';
  END IF;
  IF lunch_serie_valide('LM-2026-00132-7') OR lunch_serie_valide('LM-2026-00001-S')
     OR lunch_serie_valide('LM-2026-0001-R') OR lunch_serie_valide(NULL) THEN
    RAISE EXCEPTION 'ECHEC : numéro faux accepté';
  END IF;
END $$;

-- Un résident n'ajoute pas de machine.
DO $$
BEGIN
  PERFORM lunch_machine_ajouter('LM-2026-00002-P', 'Pirate', '1234');
  RAISE EXCEPTION 'ECHEC : résident a ajouté une machine';
EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'FORBIDDEN' THEN RAISE; END IF;
END $$;

SELECT set_config('request.jwt.claims',
  '{"sub":"a1000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
DO $$
BEGIN
  IF lunch_machine_ajouter(' lm-2026-00002-p ', 'Machine du hall', '2468') <> 'LM-2026-00002-P' THEN
    RAISE EXCEPTION 'ECHEC : ajout';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM lunch_machines WHERE id = 'LM-2026-00002-P' AND numero_serie = 'LM-2026-00002-P') THEN
    RAISE EXCEPTION 'ECHEC : machine absente';
  END IF;
  BEGIN PERFORM lunch_machine_ajouter('LM-2026-00002-P', 'Doublon', '2468'); RAISE EXCEPTION 'ECHEC doublon';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'SERIE_DEJA_AJOUTEE' THEN RAISE; END IF; END;
  BEGIN PERFORM lunch_machine_ajouter('LM-2026-00002-Q', 'Faute', '2468'); RAISE EXCEPTION 'ECHEC clé';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'SERIE_INVALIDE' THEN RAISE; END IF; END;
  -- Plus d'insertion directe, même pour un admin.
  BEGIN INSERT INTO lunch_machines (id, name) VALUES ('X', 'Directe'); RAISE EXCEPTION 'ECHEC insertion directe';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  -- La machine déjà en service (importée) reçoit son numéro.
  PERFORM lunch_machine_associer_serie('LM-T', 'LM-2026-00003-N');
  IF (SELECT numero_serie FROM lunch_machines WHERE id = 'LM-T') <> 'LM-2026-00003-N' THEN
    RAISE EXCEPTION 'ECHEC : association';
  END IF;
  BEGIN PERFORM lunch_machine_associer_serie('LM-T', 'LM-2026-00002-P'); RAISE EXCEPTION 'ECHEC numéro pris';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'SERIE_DEJA_AJOUTEE' THEN RAISE; END IF; END;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'lunch_test : OK'; END $$;

ROLLBACK;
