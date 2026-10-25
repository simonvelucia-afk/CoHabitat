-- emplois_test.sql — verifie le parcours d'un emploi (migration 036) sur
-- une base fraichement migree : publication, candidature, embauche,
-- declaration d'heures, approbation, remuneration. A jouer dans une
-- transaction que l'on annule a la fin : aucune trace laissee.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/emplois_test.sql
--
-- Chaque etape bascule dans le role `authenticated` avec les claims
-- qu'aurait poses PostgREST, et leve une exception si l'invariant
-- attendu est faux.

BEGIN;

-- ── Contexte ─────────────────────────────────────────────────────────
INSERT INTO auth.users (id, email) VALUES
  ('f0000000-0000-0000-0000-0000000000a1', 'resident1@test.local'),
  ('f0000000-0000-0000-0000-0000000000a2', 'resident2@test.local'),
  ('f0000000-0000-0000-0000-0000000000ad', 'admin.emplois@test.local');
UPDATE profiles SET role = 'admin' WHERE id = 'f0000000-0000-0000-0000-0000000000ad';
UPDATE profiles SET virtual_balance = 0
 WHERE id IN ('f0000000-0000-0000-0000-0000000000a1', 'f0000000-0000-0000-0000-0000000000a2');

CREATE TEMP TABLE emplois_test_ctx (cle TEXT PRIMARY KEY, val UUID);
GRANT ALL ON emplois_test_ctx TO authenticated;

-- ── 1) Seul l'admin publie ───────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);
DO $$
BEGIN
  BEGIN
    INSERT INTO emplois (titre, secteur) VALUES ('Poste pirate', 'autre');
    RAISE EXCEPTION 'ECHEC : un resident a publie une offre';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
WITH x AS (
  INSERT INTO emplois (titre, secteur, niveau, taux_horaire, nb_postes, responsabilites, taches)
  VALUES ('Employé du poulailler', 'poulailler', 'employe', 18, 1,
          'Bien-être des poules', 'Ramasser les œufs')
  RETURNING id)
INSERT INTO emplois_test_ctx SELECT 'poule', id FROM x;

-- ── 2) Le resident lit l'offre et postule ────────────────────────────
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);
DO $$
DECLARE v_emploi UUID := (SELECT val FROM emplois_test_ctx WHERE cle = 'poule');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM emplois WHERE id = v_emploi) THEN
    RAISE EXCEPTION 'ECHEC : l''offre n''est pas visible du resident';
  END IF;
  PERFORM emploi_postuler(v_emploi, 'J''aime les poules');
  BEGIN
    PERFORM emploi_postuler(v_emploi, 'encore');
    RAISE EXCEPTION 'ECHEC : double candidature acceptee';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'DEJA_POSTULE' THEN RAISE; END IF;
  END;
  -- Pas d'heures tant qu'on n'est pas retenu.
  BEGIN
    INSERT INTO emploi_heures (emploi_id, user_id, date_travail, heures)
    VALUES (v_emploi, 'f0000000-0000-0000-0000-0000000000a1', current_date, 2);
    RAISE EXCEPTION 'ECHEC : heures acceptees sans embauche';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- Le second resident postule aussi, et ne voit pas la candidature du premier.
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000a2","role":"authenticated"}', TRUE);
DO $$
DECLARE v_emploi UUID := (SELECT val FROM emplois_test_ctx WHERE cle = 'poule');
BEGIN
  PERFORM emploi_postuler(v_emploi, NULL);
  IF (SELECT COUNT(*) FROM emploi_candidatures) <> 1 THEN
    RAISE EXCEPTION 'ECHEC : un resident voit les candidatures des autres';
  END IF;
END $$;

-- ── 3) L'admin retient le premier : poste pourvu, droit d'operateur ──
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
DO $$
DECLARE v_emploi UUID := (SELECT val FROM emplois_test_ctx WHERE cle = 'poule');
BEGIN
  UPDATE emploi_candidatures
     SET statut = 'retenue', decided_by = 'f0000000-0000-0000-0000-0000000000ad', decided_at = now()
   WHERE emploi_id = v_emploi AND user_id = 'f0000000-0000-0000-0000-0000000000a1';
  IF (SELECT statut FROM emplois WHERE id = v_emploi) <> 'pourvu' THEN
    RAISE EXCEPTION 'ECHEC : l''offre n''est pas passee a pourvu';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM elevage_operateurs
                  WHERE user_id = 'f0000000-0000-0000-0000-0000000000a1' AND module = 'poulailler') THEN
    RAISE EXCEPTION 'ECHEC : l''employe du poulailler n''est pas operateur';
  END IF;
END $$;

-- ── 4) L'employe declare ses heures ; taux et statut imposes ─────────
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);
DO $$
DECLARE
  v_emploi UUID := (SELECT val FROM emplois_test_ctx WHERE cle = 'poule');
  v_h      emploi_heures%ROWTYPE;
BEGIN
  INSERT INTO emploi_heures (emploi_id, user_id, date_travail, heures, taux_horaire, statut)
  VALUES (v_emploi, 'f0000000-0000-0000-0000-0000000000a1', current_date, 2.5, 999, 'payee')
  RETURNING * INTO v_h;
  IF v_h.taux_horaire <> 18 OR v_h.statut <> 'soumise' OR v_h.montant <> 45 THEN
    RAISE EXCEPTION 'ECHEC : taux/statut/montant non imposes (% / % / %)',
      v_h.taux_horaire, v_h.statut, v_h.montant;
  END IF;
  INSERT INTO emplois_test_ctx VALUES ('h1', v_h.id);

  BEGIN
    INSERT INTO emploi_heures (emploi_id, user_id, date_travail, heures)
    VALUES (v_emploi, 'f0000000-0000-0000-0000-0000000000a1', current_date + 3, 1);
    RAISE EXCEPTION 'ECHEC : heures futures acceptees';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- Le resident ne s'approuve pas lui-meme.
  UPDATE emploi_heures SET statut = 'approuvee' WHERE id = v_h.id;
  IF (SELECT statut FROM emploi_heures WHERE id = v_h.id) <> 'soumise' THEN
    RAISE EXCEPTION 'ECHEC : le resident a approuve ses heures';
  END IF;

  -- Ni ne se paie.
  BEGIN
    PERFORM emploi_payer_heures(ARRAY[v_h.id], 'solde');
    RAISE EXCEPTION 'ECHEC : le resident a declenche la paie';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'FORBIDDEN' THEN RAISE; END IF;
  END;
END $$;

-- ── 5) L'admin approuve et paie au solde, une seule fois ─────────────
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
DO $$
DECLARE
  v_h   UUID := (SELECT val FROM emplois_test_ctx WHERE cle = 'h1');
  v_r   JSONB;
BEGIN
  UPDATE emploi_heures SET statut = 'approuvee', approuvee_par = auth.uid(), approuvee_le = now()
   WHERE id = v_h;
  v_r := emploi_payer_heures(ARRAY[v_h], 'solde');
  IF (v_r->>'lignes')::INT <> 1 OR (v_r->>'total')::NUMERIC <> 45 THEN
    RAISE EXCEPTION 'ECHEC : paie inattendue %', v_r;
  END IF;
  v_r := emploi_payer_heures(ARRAY[v_h], 'solde');
  IF (v_r->>'lignes')::INT <> 0 THEN
    RAISE EXCEPTION 'ECHEC : les heures ont ete payees deux fois';
  END IF;
  IF (SELECT virtual_balance FROM profiles WHERE id = 'f0000000-0000-0000-0000-0000000000a1') <> 45 THEN
    RAISE EXCEPTION 'ECHEC : solde non credite';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM transactions
                  WHERE user_id = 'f0000000-0000-0000-0000-0000000000a1'
                    AND type = 'emploi_remuneration' AND amount = 45) THEN
    RAISE EXCEPTION 'ECHEC : pas de trace au grand livre';
  END IF;
END $$;

-- ── 6) Se retirer puis repostuler reutilise la ligne ─────────────────
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
UPDATE emplois SET statut = 'ouvert', nb_postes = 2
 WHERE id = (SELECT val FROM emplois_test_ctx WHERE cle = 'poule');

SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000a2","role":"authenticated"}', TRUE);
DO $$
DECLARE
  v_emploi UUID := (SELECT val FROM emplois_test_ctx WHERE cle = 'poule');
  v_c      UUID;
BEGIN
  SELECT id INTO v_c FROM emploi_candidatures WHERE emploi_id = v_emploi;
  PERFORM emploi_retirer_candidature(v_c);
  IF emploi_postuler(v_emploi, 'Finalement oui') <> v_c THEN
    RAISE EXCEPTION 'ECHEC : nouvelle ligne creee au lieu de reactiver';
  END IF;
  IF (SELECT statut FROM emploi_candidatures WHERE id = v_c) <> 'en_attente' THEN
    RAISE EXCEPTION 'ECHEC : candidature non reactivee';
  END IF;
END $$;

-- ── 7) Embauche a la sabloponie : operateur de l'elevage 'sablonponie' ─
SELECT set_config('request.jwt.claims',
  '{"sub":"f0000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);
DO $$
DECLARE v_emploi UUID; v_c UUID;
BEGIN
  INSERT INTO emplois (titre, secteur, niveau, taux_horaire)
  VALUES ('Employé de la sabloponie', 'sabloponie', 'employe', 17)
  RETURNING id INTO v_emploi;
  INSERT INTO emploi_candidatures (emploi_id, user_id, statut)
  VALUES (v_emploi, 'f0000000-0000-0000-0000-0000000000a2', 'retenue');
  IF NOT EXISTS (SELECT 1 FROM elevage_operateurs
                  WHERE user_id = 'f0000000-0000-0000-0000-0000000000a2' AND module = 'sablonponie') THEN
    RAISE EXCEPTION 'ECHEC : l''employe de la sabloponie n''est pas operateur';
  END IF;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'emplois_test : OK'; END $$;

ROLLBACK;
