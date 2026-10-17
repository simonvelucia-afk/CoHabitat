-- energie_test.sql — verifie ce que chaque compte voit et peut ecrire dans
-- le module Energie et confort (migration 035), sur une base fraichement
-- migree. A jouer dans une transaction que l'on annule a la fin : aucune
-- trace laissee.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/energie_test.sql
--
-- Les politiques RLS ne s'appliquent qu'au role `authenticated` : chaque
-- etape bascule donc dans ce role, avec les claims qu'aurait pose
-- PostgREST, avant de verifier. Chaque etape leve une exception si
-- l'invariant attendu est faux.

BEGIN;

-- ── Contexte ─────────────────────────────────────────────────────────
-- Quatre logements, un admin, un compte appareil. Le trigger
-- on_auth_user_created cree les lignes profiles.
INSERT INTO auth.users (id, email) VALUES
  ('e0000000-0000-0000-0000-0000000000a1', 'resident.b204@test.local'),
  ('e0000000-0000-0000-0000-0000000000a2', 'conjoint.b204@test.local'),
  ('e0000000-0000-0000-0000-0000000000a3', 'resident.a101@test.local'),
  ('e0000000-0000-0000-0000-0000000000ad', 'admin@test.local'),
  ('e0000000-0000-0000-0000-0000000000de', 'capteurs@device.local');
UPDATE profiles SET unit = 'B-204' WHERE id IN ('e0000000-0000-0000-0000-0000000000a1',
                                                'e0000000-0000-0000-0000-0000000000a2');
UPDATE profiles SET unit = 'A-101' WHERE id = 'e0000000-0000-0000-0000-0000000000a3';
UPDATE profiles SET role = 'admin' WHERE id = 'e0000000-0000-0000-0000-0000000000ad';

-- Les admins deja presents dans la base (demo, comptes reels) recoivent
-- aussi les alertes d'immeuble : on les compte avant de verifier.
CREATE TEMP TABLE energie_test_ctx AS
SELECT COUNT(*) AS admins FROM profiles
WHERE role IN ('admin', 'principal_admin') AND COALESCE(is_active, TRUE)
  AND LOWER(email) NOT LIKE '%@device.local';
GRANT SELECT ON energie_test_ctx TO authenticated;

-- ── 1) Le compte appareil publie mesures, compteurs et alertes ───────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-0000-0000-0000000000de","role":"authenticated"}', TRUE);

INSERT INTO immeuble_etat (mode, niveau, message) VALUES ('normal', 'vert', NULL);
INSERT INTO energie_lectures (solaire_kw, solaire_kwh_jour, batterie_pct, reseau_kw, reservoir_temp, eau_chaude_couverture_pct)
VALUES (3.2, 18.4, 92, -0.4, 61, 95);
INSERT INTO eau_chaude_compteurs (jour, unit, litres) VALUES
  (CURRENT_DATE, 'B-204', 120), (CURRENT_DATE, 'A-101', 80),
  (CURRENT_DATE, 'C-310', 100), (CURRENT_DATE, 'C-311', 60);
INSERT INTO immeuble_alertes (type, gravite, unit, titre, message)
VALUES ('fuite', 'urgence', 'B-204', 'Fuite sous le chauffe-eau', 'La vanne est fermée.'),
       ('gel', 'attention', NULL, 'Risque de gel au garage', NULL),
       ('panne', 'info', 'A-101', 'Thermostat injoignable', NULL);

RESET ROLE;

-- ── 2) La bonne personne est prevenue, pas tout l'immeuble ───────────
DO $$
DECLARE v INT; v_admins INT;
BEGIN
  SELECT admins INTO v_admins FROM energie_test_ctx;

  SELECT nb_notifies INTO v FROM immeuble_alertes WHERE titre = 'Fuite sous le chauffe-eau';
  IF v <> 2 THEN RAISE EXCEPTION 'fuite B-204 : 2 residants attendus, % notifies', v; END IF;

  SELECT COUNT(*) INTO v FROM notifications n JOIN immeuble_alertes a ON a.id = n.reference_id
  WHERE a.titre = 'Fuite sous le chauffe-eau' AND n.type = 'error'
    AND n.user_id IN ('e0000000-0000-0000-0000-0000000000a1', 'e0000000-0000-0000-0000-0000000000a2');
  IF v <> 2 THEN RAISE EXCEPTION 'fuite B-204 : notifications des residants absentes (%)', v; END IF;

  SELECT nb_notifies INTO v FROM immeuble_alertes WHERE titre = 'Risque de gel au garage';
  IF v <> v_admins THEN RAISE EXCEPTION 'gel immeuble : % admins attendus, % notifies', v_admins, v; END IF;

  SELECT COUNT(*) INTO v FROM notifications n JOIN profiles p ON p.id = n.user_id
  WHERE n.reference_type = 'immeuble_alerte' AND LOWER(p.email) LIKE '%@device.local';
  IF v <> 0 THEN RAISE EXCEPTION 'le compte appareil ne doit jamais etre notifie'; END IF;
END $$;

-- ── 3) Un residant ne voit que son logement ──────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);

DO $$
DECLARE v INT; v_moy NUMERIC; v_nb INT;
BEGIN
  SELECT COUNT(*) INTO v FROM eau_chaude_compteurs;
  IF v <> 1 THEN RAISE EXCEPTION 'residant B-204 : 1 compteur visible attendu, %', v; END IF;
  SELECT COUNT(*) INTO v FROM eau_chaude_compteurs WHERE unit <> 'B-204';
  IF v <> 0 THEN RAISE EXCEPTION 'residant B-204 : voit les compteurs d''un voisin'; END IF;

  -- Son alerte et celle de l'immeuble, pas celle de A-101.
  SELECT COUNT(*) INTO v FROM immeuble_alertes;
  IF v <> 2 THEN RAISE EXCEPTION 'residant B-204 : 2 alertes visibles attendues, %', v; END IF;
  SELECT COUNT(*) INTO v FROM immeuble_alertes WHERE unit = 'A-101';
  IF v <> 0 THEN RAISE EXCEPTION 'residant B-204 : voit l''alerte d''un voisin'; END IF;

  -- Les donnees de batiment sont lisibles par tous.
  SELECT COUNT(*) INTO v FROM energie_lectures;
  IF v < 1 THEN RAISE EXCEPTION 'residant : mesures de l''immeuble invisibles'; END IF;
  SELECT COUNT(*) INTO v FROM immeuble_etat;
  IF v < 1 THEN RAISE EXCEPTION 'residant : etat de l''immeuble invisible'; END IF;

  -- La moyenne passe malgre la RLS, et seulement en agregat :
  -- (120 + 80 + 100 + 60) / 4 = 90.
  SELECT litres_moyens, nb_logements INTO v_moy, v_nb FROM eau_chaude_moyenne(CURRENT_DATE, CURRENT_DATE);
  IF v_moy IS DISTINCT FROM 90.0 OR v_nb <> 4 THEN
    RAISE EXCEPTION 'moyenne attendue 90 sur 4 logements, trouve % sur %', v_moy, v_nb;
  END IF;
END $$;

-- Un residant n'ecrit rien : ni mesure, ni etat, ni alerte.
DO $$
BEGIN
  BEGIN
    INSERT INTO energie_lectures (solaire_kw) VALUES (99);
    RAISE EXCEPTION 'residant : insertion d''une mesure acceptee';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO immeuble_etat (mode, niveau) VALUES ('panne_hydro', 'orange');
    RAISE EXCEPTION 'residant : changement d''etat accepte';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO eau_chaude_compteurs (jour, unit, litres) VALUES (CURRENT_DATE - 1, 'B-204', 0);
    RAISE EXCEPTION 'residant : ecriture de son propre compteur acceptee';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- Aucune ligne modifiee en douce non plus : un UPDATE hors politique ne
-- touche rien.
UPDATE immeuble_alertes SET resolue_le = NOW() WHERE unit = 'B-204';

RESET ROLE;

DO $$
DECLARE v INT;
BEGIN
  SELECT COUNT(*) INTO v FROM immeuble_alertes WHERE resolue_le IS NOT NULL;
  IF v <> 0 THEN RAISE EXCEPTION 'residant : a pu marquer une alerte resolue'; END IF;
END $$;

-- ── 4) Sous trois logements mesures, aucune moyenne ──────────────────
-- Avec deux logements, la moyenne et sa propre consommation donneraient
-- celle du voisin.
INSERT INTO eau_chaude_compteurs (jour, unit, litres) VALUES
  (CURRENT_DATE - 10, 'B-204', 100), (CURRENT_DATE - 10, 'A-101', 50);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-0000-0000-0000000000a1","role":"authenticated"}', TRUE);

DO $$
DECLARE v INT;
BEGIN
  SELECT COUNT(*) INTO v FROM eau_chaude_moyenne(CURRENT_DATE - 10, CURRENT_DATE - 10);
  IF v <> 0 THEN RAISE EXCEPTION 'moyenne sur 2 logements : rien attendu, % ligne(s)', v; END IF;
END $$;

RESET ROLE;

-- ── 5) L'admin voit tout et resout une alerte ────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"sub":"e0000000-0000-0000-0000-0000000000ad","role":"authenticated"}', TRUE);

DO $$
DECLARE v INT;
BEGIN
  SELECT COUNT(*) INTO v FROM eau_chaude_compteurs WHERE jour = CURRENT_DATE;
  IF v <> 4 THEN RAISE EXCEPTION 'admin : 4 compteurs attendus, %', v; END IF;
  SELECT COUNT(*) INTO v FROM immeuble_alertes;
  IF v <> 3 THEN RAISE EXCEPTION 'admin : 3 alertes attendues, %', v; END IF;
END $$;

UPDATE immeuble_alertes SET resolue_le = NOW() WHERE titre = 'Fuite sous le chauffe-eau';
-- NOW() est fige pour toute la transaction : on date l'etat explicitement
-- pour qu'il soit bien le plus recent.
INSERT INTO immeuble_etat (horodatage, mode, niveau, message)
VALUES (NOW() + INTERVAL '1 minute', 'exercice', 'bleu', 'Exercice annoncé à 14 h.');

RESET ROLE;

DO $$
DECLARE v INT; v_mode TEXT;
BEGIN
  SELECT COUNT(*) INTO v FROM immeuble_alertes WHERE resolue_le IS NOT NULL;
  IF v <> 1 THEN RAISE EXCEPTION 'admin : la resolution n''a pas ete enregistree'; END IF;
  SELECT mode INTO v_mode FROM immeuble_etat ORDER BY horodatage DESC, id LIMIT 1;
  IF v_mode IS DISTINCT FROM 'exercice' THEN RAISE EXCEPTION 'admin : etat non publie (%)', v_mode; END IF;
END $$;

-- ── 6) Le module est coupe par defaut ────────────────────────────────
DO $$
DECLARE v TEXT;
BEGIN
  SELECT value INTO v FROM system_settings WHERE key = 'module_energie';
  IF v IS DISTINCT FROM 'false' THEN RAISE EXCEPTION 'module_energie attendu false, trouve %', v; END IF;
END $$;

SELECT 'energie_test : tous les invariants tiennent' AS resultat;

ROLLBACK;
