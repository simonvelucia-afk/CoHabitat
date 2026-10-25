-- 037_lunch_immeuble.sql
-- La Machine Lunch dans l'immeuble.
--
-- Jusqu'ici la machine, ses zones, ses cases et ses menus vivaient sur la
-- centrale Modulimo, et chaque achat y debitait un solde central. Le
-- solde des residents vit desormais dans l'immeuble : la machine l'y
-- rejoint. Le kiosque n'a plus besoin de la centrale pour vendre.
--
-- Ce que cette migration ajoute :
--
--   1. les tables de la machine : lunch_machines, lunch_zones,
--      lunch_slots, lunch_menus — memes colonnes que sur la centrale,
--      que le kiosque connait deja ;
--   2. lunch_acheter() : l'achat, en UNE transaction — la case est
--      verrouillee, le prix lu en base (jamais celui du client), le solde
--      verifie et debite, la case videe. Deux residents ne peuvent pas
--      acheter la meme case ;
--   3. lunch_rembourser() : si le robot n'a pas pu livrer, le payeur est
--      recredite une fois, et la case retrouve son contenu ;
--   4. lunch_mon_solde() : le solde du resident connecte, ou d'un de ses
--      dependants ;
--   5. lunch_kiosque_ecrire() : les ecritures d'administration du
--      kiosque (cases, menus, reglages), permises a un administrateur, a
--      la personne embauchee a la Machine Lunch (036), ou a qui connait le
--      PIN de la machine ;
--
-- Ce qu'elle ferme : lunch_purchase() et lunch_get_balance() (001)
-- etaient ouvertes a la cle anon et prenaient le payeur et le montant du
-- client — n'importe qui pouvait debiter n'importe qui, du montant de son
-- choix, et lire tous les soldes. Elles ne servent plus (le kiosque
-- passait par la centrale) et perdent leurs droits.
--
-- Le PIN de la machine n'est plus lisible : la colonne est retiree des
-- droits de lecture, la verification se fait en base.
--
-- Idempotente : peut etre rejouee sans erreur.

BEGIN;

-- ============================================================
-- 1) Tables de la machine
-- ============================================================
-- CREATE puis ADD COLUMN : certaines bases d'immeuble ont garde une
-- ancienne copie de lunch_slots (cf. 001) ; on la complete plutot que de
-- la recreer.
CREATE TABLE IF NOT EXISTS lunch_machines (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL
);
ALTER TABLE lunch_machines
  ADD COLUMN IF NOT EXISTS pin               TEXT,
  ADD COLUMN IF NOT EXISTS building_id       UUID,
  ADD COLUMN IF NOT EXISTS active            BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS box_max           INT     NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS box_count         INT     NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS gantry_auto_speed INT     NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS color_ranges      JSONB   NOT NULL DEFAULT
    '{"blue":{"min":-10,"max":10},"violet":{"min":11,"max":25},"orange":{"min":26,"max":55},"red":{"min":56,"max":100}}'::jsonb,
  ADD COLUMN IF NOT EXISTS created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE TABLE IF NOT EXISTS lunch_zones (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id  TEXT NOT NULL REFERENCES lunch_machines(id) ON DELETE CASCADE,
  zone_key    TEXT NOT NULL
);
ALTER TABLE lunch_zones
  ADD COLUMN IF NOT EXISTS name         TEXT,
  ADD COLUMN IF NOT EXISTS setpoint     NUMERIC(5,1),
  ADD COLUMN IF NOT EXISTS setpoint_min NUMERIC(5,1),
  ADD COLUMN IF NOT EXISTS setpoint_max NUMERIC(5,1),
  ADD COLUMN IF NOT EXISTS actual       NUMERIC(5,1),
  ADD COLUMN IF NOT EXISTS slot_count   INT NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS lunch_zones_machine_zone ON lunch_zones (machine_id, zone_key);

CREATE TABLE IF NOT EXISTS lunch_slots (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id  TEXT NOT NULL REFERENCES lunch_machines(id) ON DELETE CASCADE,
  slot_num    INT  NOT NULL
);
ALTER TABLE lunch_slots
  ADD COLUMN IF NOT EXISTS zone_key    TEXT,
  ADD COLUMN IF NOT EXISTS description TEXT,
  ADD COLUMN IF NOT EXISTS price       NUMERIC(8,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS photo_url   TEXT,
  ADD COLUMN IF NOT EXISTS chef        TEXT,
  ADD COLUMN IF NOT EXISTS prep_date   TEXT,
  ADD COLUMN IF NOT EXISTS exp_date    DATE,
  ADD COLUMN IF NOT EXISTS ingredients TEXT,
  ADD COLUMN IF NOT EXISTS allergens   JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS calories    NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS proteines   NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS glucides    NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS lipides     NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS reserved    BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS reserved_by TEXT,
  ADD COLUMN IF NOT EXISTS updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW();
CREATE UNIQUE INDEX IF NOT EXISTS lunch_slots_machine_num ON lunch_slots (machine_id, slot_num);

-- La bibliotheque de menus est celle de l'immeuble, partagee entre ses
-- machines. id TEXT : le kiosque le genere (m_<horodatage>) pour pouvoir
-- creer un menu hors ligne.
CREATE TABLE IF NOT EXISTS lunch_menus (
  id          TEXT PRIMARY KEY,
  machine_id  TEXT,
  description TEXT NOT NULL DEFAULT ''
);
ALTER TABLE lunch_menus
  ADD COLUMN IF NOT EXISTS price       NUMERIC(8,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS photo       TEXT,
  ADD COLUMN IF NOT EXISTS chef        TEXT,
  ADD COLUMN IF NOT EXISTS ingredients TEXT,
  ADD COLUMN IF NOT EXISTS allergens   JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS calories    NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS proteines   NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS glucides    NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS lipides     NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS exp_date    DATE,
  ADD COLUMN IF NOT EXISTS active      BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ADD COLUMN IF NOT EXISTS updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- L'achat garde de quoi rendre la case si le robot echoue, et sa cle
-- d'idempotence : un kiosque qui renvoie la meme demande apres une
-- coupure ne debite pas deux fois.
ALTER TABLE lunch_transactions
  ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
  ADD COLUMN IF NOT EXISTS description     TEXT,
  ADD COLUMN IF NOT EXISTS exp_date        DATE,
  ADD COLUMN IF NOT EXISTS rembourse_le    TIMESTAMPTZ;
CREATE UNIQUE INDEX IF NOT EXISTS lunch_tx_idempotency
  ON lunch_transactions (idempotency_key) WHERE idempotency_key IS NOT NULL;

-- Tentatives de PIN : dix erreurs en dix minutes bloquent la machine
-- pour le reste de la fenetre. Un PIN a quatre chiffres se devine en
-- dix mille essais ; sans frein, un script y arrive en une minute.
CREATE TABLE IF NOT EXISTS lunch_pin_essais (
  machine_id TEXT NOT NULL,
  essai_le   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS lunch_pin_essais_idx ON lunch_pin_essais (machine_id, essai_le DESC);

-- ============================================================
-- 2) Droits de lecture
-- ============================================================
-- Le kiosque affiche la machine et ses cases avant toute connexion :
-- lecture ouverte, y compris a anon. Le PIN, lui, ne se lit pas.
ALTER TABLE lunch_machines   ENABLE ROW LEVEL SECURITY;
ALTER TABLE lunch_zones      ENABLE ROW LEVEL SECURITY;
ALTER TABLE lunch_slots      ENABLE ROW LEVEL SECURITY;
ALTER TABLE lunch_menus      ENABLE ROW LEVEL SECURITY;
ALTER TABLE lunch_pin_essais ENABLE ROW LEVEL SECURITY;   -- aucune politique : fonctions seulement

DO $pol$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['lunch_machines','lunch_zones','lunch_slots','lunch_menus'] LOOP
    -- Les politiques d'ecriture ouvertes d'anciennes copies sont retirees :
    -- toute ecriture passe par les fonctions ci-dessous.
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_lecture', t);
    EXECUTE format('CREATE POLICY %I ON %I FOR SELECT TO anon, authenticated USING (TRUE)', t || '_lecture', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_admin', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR ALL TO authenticated
                      USING (get_my_role() IN ('admin','principal_admin'))
                      WITH CHECK (get_my_role() IN ('admin','principal_admin'))$f$, t || '_admin', t);
  END LOOP;
END $pol$;

REVOKE SELECT ON lunch_machines FROM anon, authenticated;
GRANT SELECT (id, name, building_id, active, box_max, box_count, gantry_auto_speed, color_ranges, created_at)
  ON lunch_machines TO anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON lunch_machines, lunch_zones, lunch_slots, lunch_menus FROM anon;

-- ============================================================
-- 3) Qui peut administrer une machine
-- ============================================================
-- Un administrateur de l'immeuble, la personne embauchee a la Machine
-- Lunch (emplois, secteur 'lunch', 036), ou qui presente le bon PIN.
CREATE OR REPLACE FUNCTION lunch_peut_gerer(p_machine_id TEXT, p_pin TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pin    TEXT;
  v_echecs INT;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF get_my_role() IN ('admin','principal_admin') THEN RETURN TRUE; END IF;
    IF to_regclass('public.emploi_candidatures') IS NOT NULL THEN
      IF EXISTS (SELECT 1 FROM emploi_candidatures c JOIN emplois e ON e.id = c.emploi_id
                  WHERE c.user_id = auth.uid() AND c.statut = 'retenue' AND e.secteur = 'lunch') THEN
        RETURN TRUE;
      END IF;
    END IF;
  END IF;

  IF p_pin IS NULL OR p_pin = '' THEN RETURN FALSE; END IF;

  v_echecs := (SELECT COUNT(*) FROM lunch_pin_essais
                WHERE machine_id = p_machine_id AND essai_le > now() - interval '10 minutes');
  IF v_echecs >= 10 THEN RAISE EXCEPTION 'PIN_BLOQUE'; END IF;

  v_pin := (SELECT pin FROM lunch_machines WHERE id = p_machine_id);
  IF v_pin IS NOT NULL AND v_pin = p_pin THEN RETURN TRUE; END IF;

  INSERT INTO lunch_pin_essais (machine_id) VALUES (p_machine_id);
  DELETE FROM lunch_pin_essais WHERE essai_le < now() - interval '1 day';
  RETURN FALSE;
END;
$$;

-- Verification du PIN a l'ecran d'administration du kiosque. Le RAISE
-- de lunch_peut_gerer annulerait l'essai consigne : on l'attrape ici pour
-- renvoyer un statut lisible.
CREATE OR REPLACE FUNCTION lunch_pin_valide(p_machine_id TEXT, p_pin TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_pin IS NULL OR p_pin = '' THEN RETURN 'invalide'; END IF;
  RETURN CASE WHEN lunch_peut_gerer(p_machine_id, p_pin) THEN 'ok' ELSE 'invalide' END;
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM = 'PIN_BLOQUE' THEN RETURN 'bloque'; END IF;
  RAISE;
END;
$$;

-- ============================================================
-- 4) Ecritures d'administration du kiosque
-- ============================================================
-- Une seule porte, pour que le kiosque n'ait qu'un appel a connaitre.
--   'case'           : p_donnees = une case (slot_num obligatoire)
--   'zone'           : p_donnees = une zone (zone_key obligatoire)
--   'machine'        : reglages (box_max, box_count, gantry_auto_speed,
--                      color_ranges, pin, name) — seuls les champs
--                      fournis changent
--   'menu'           : p_donnees = un menu (id obligatoire)
--   'menu_supprimer' : p_donnees = { "id": ... }
CREATE OR REPLACE FUNCTION lunch_kiosque_ecrire(p_machine_id TEXT, p_pin TEXT, p_cible TEXT, p_donnees JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d    JSONB := COALESCE(p_donnees, '{}'::jsonb);
  v_id UUID;
  n    NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM lunch_machines WHERE id = p_machine_id) THEN
    RAISE EXCEPTION 'MACHINE_INTROUVABLE';
  END IF;
  -- Refus RENDU, pas leve : une exception annulerait l'essai consigne
  -- par lunch_peut_gerer, et cette porte servirait a deviner le PIN sans
  -- limite.
  IF NOT lunch_peut_gerer(p_machine_id, p_pin) THEN
    RETURN jsonb_build_object('erreur', 'FORBIDDEN');
  END IF;

  IF p_cible = 'case' THEN
    IF (d->>'slot_num') IS NULL THEN RAISE EXCEPTION 'CASE_SANS_NUMERO'; END IF;
    INSERT INTO lunch_slots AS s (machine_id, slot_num, zone_key, description, price, photo_url, chef,
                                  prep_date, exp_date, ingredients, allergens, calories, proteines,
                                  glucides, lipides, reserved, reserved_by, updated_at)
    VALUES (p_machine_id, (d->>'slot_num')::INT, d->>'zone_key', COALESCE(d->>'description',''),
            COALESCE(NULLIF(d->>'price','')::NUMERIC, 0), NULLIF(d->>'photo_url',''), NULLIF(d->>'chef',''),
            NULLIF(d->>'prep_date',''), NULLIF(d->>'exp_date','')::DATE, NULLIF(d->>'ingredients',''),
            COALESCE(d->'allergens', '[]'::jsonb),
            NULLIF(d->>'calories','')::NUMERIC, NULLIF(d->>'proteines','')::NUMERIC,
            NULLIF(d->>'glucides','')::NUMERIC, NULLIF(d->>'lipides','')::NUMERIC,
            COALESCE((d->>'reserved')::BOOLEAN, FALSE), NULLIF(d->>'reserved_by',''), now())
    ON CONFLICT (machine_id, slot_num) DO UPDATE SET
      zone_key = EXCLUDED.zone_key, description = EXCLUDED.description, price = EXCLUDED.price,
      photo_url = EXCLUDED.photo_url, chef = EXCLUDED.chef, prep_date = EXCLUDED.prep_date,
      exp_date = EXCLUDED.exp_date, ingredients = EXCLUDED.ingredients, allergens = EXCLUDED.allergens,
      calories = EXCLUDED.calories, proteines = EXCLUDED.proteines, glucides = EXCLUDED.glucides,
      lipides = EXCLUDED.lipides, reserved = EXCLUDED.reserved, reserved_by = EXCLUDED.reserved_by,
      updated_at = now()
    RETURNING s.id INTO v_id;
    RETURN jsonb_build_object('id', v_id);

  ELSIF p_cible = 'zone' THEN
    IF (d->>'zone_key') IS NULL THEN RAISE EXCEPTION 'ZONE_SANS_CLE'; END IF;
    INSERT INTO lunch_zones (machine_id, zone_key, name, setpoint, setpoint_min, setpoint_max, actual, slot_count)
    VALUES (p_machine_id, d->>'zone_key', d->>'name', NULLIF(d->>'setpoint','')::NUMERIC,
            NULLIF(d->>'setpoint_min','')::NUMERIC, NULLIF(d->>'setpoint_max','')::NUMERIC,
            NULLIF(d->>'actual','')::NUMERIC, COALESCE(NULLIF(d->>'slot_count','')::INT, 0))
    ON CONFLICT (machine_id, zone_key) DO UPDATE SET
      name = EXCLUDED.name, setpoint = EXCLUDED.setpoint, setpoint_min = EXCLUDED.setpoint_min,
      setpoint_max = EXCLUDED.setpoint_max, actual = EXCLUDED.actual, slot_count = EXCLUDED.slot_count;
    RETURN jsonb_build_object('ok', TRUE);

  ELSIF p_cible = 'machine' THEN
    IF d ? 'pin' AND (d->>'pin') !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'PIN_INVALIDE'; END IF;
    UPDATE lunch_machines SET
      name              = CASE WHEN d ? 'name'              THEN COALESCE(NULLIF(d->>'name',''), name) ELSE name END,
      pin               = CASE WHEN d ? 'pin'               THEN d->>'pin' ELSE pin END,
      box_max           = CASE WHEN d ? 'box_max'           THEN (d->>'box_max')::INT ELSE box_max END,
      box_count         = CASE WHEN d ? 'box_count'         THEN (d->>'box_count')::INT ELSE box_count END,
      gantry_auto_speed = CASE WHEN d ? 'gantry_auto_speed' THEN (d->>'gantry_auto_speed')::INT ELSE gantry_auto_speed END,
      color_ranges      = CASE WHEN d ? 'color_ranges'      THEN d->'color_ranges' ELSE color_ranges END
    WHERE id = p_machine_id;
    RETURN jsonb_build_object('ok', TRUE);

  ELSIF p_cible = 'menu' THEN
    IF COALESCE(d->>'id','') = '' THEN RAISE EXCEPTION 'MENU_SANS_ID'; END IF;
    INSERT INTO lunch_menus AS m (id, machine_id, description, price, photo, chef, ingredients, allergens,
                                  calories, proteines, glucides, lipides, exp_date, active, updated_at)
    VALUES (d->>'id', p_machine_id, COALESCE(d->>'description',''), COALESCE(NULLIF(d->>'price','')::NUMERIC, 0),
            NULLIF(d->>'photo',''), NULLIF(d->>'chef',''), NULLIF(d->>'ingredients',''),
            COALESCE(d->'allergens', '[]'::jsonb),
            NULLIF(d->>'calories','')::NUMERIC, NULLIF(d->>'proteines','')::NUMERIC,
            NULLIF(d->>'glucides','')::NUMERIC, NULLIF(d->>'lipides','')::NUMERIC,
            NULLIF(d->>'exp_date','')::DATE, COALESCE((d->>'active')::BOOLEAN, TRUE), now())
    ON CONFLICT (id) DO UPDATE SET
      description = EXCLUDED.description, price = EXCLUDED.price, photo = EXCLUDED.photo, chef = EXCLUDED.chef,
      ingredients = EXCLUDED.ingredients, allergens = EXCLUDED.allergens, calories = EXCLUDED.calories,
      proteines = EXCLUDED.proteines, glucides = EXCLUDED.glucides, lipides = EXCLUDED.lipides,
      exp_date = EXCLUDED.exp_date, active = EXCLUDED.active, updated_at = now();
    RETURN jsonb_build_object('ok', TRUE);

  ELSIF p_cible = 'menu_supprimer' THEN
    DELETE FROM lunch_menus WHERE id = d->>'id';
    RETURN jsonb_build_object('ok', TRUE);
  END IF;

  RAISE EXCEPTION 'CIBLE_INCONNUE';
END;
$$;

-- ============================================================
-- 5) Solde du resident connecte
-- ============================================================
CREATE OR REPLACE FUNCTION lunch_mon_solde(p_dep_id UUID DEFAULT NULL)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_dep_id IS NULL THEN (SELECT virtual_balance FROM profiles WHERE id = auth.uid())
    ELSE (SELECT virtual_balance FROM dependents WHERE id = p_dep_id AND parent_id = auth.uid())
  END;
$$;

-- ============================================================
-- 6) Achat
-- ============================================================
-- Retour : { achat_id, prix, virtual_balance, rejeu? }
--   achat_id NULL pour un retrait sans prix (la trace s'ecrit a la
--   cueillette, cf. 029) ;
--   virtual_balance : le solde du payeur apres l'achat.
CREATE OR REPLACE FUNCTION lunch_acheter(
  p_machine_id TEXT,
  p_slot_num   INT,
  p_dep_id     UUID DEFAULT NULL,
  p_buyer_name TEXT DEFAULT NULL,
  p_cle        TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_case   lunch_slots%ROWTYPE;
  v_prix   NUMERIC;
  v_solde  NUMERIC;
  v_achat  UUID;
  v_ledger UUID;
  v_desc   TEXT;
  v_prec   lunch_transactions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'SESSION_REQUISE'; END IF;
  IF get_my_role() = 'demo' THEN RAISE EXCEPTION 'DEMO'; END IF;

  -- Rejeu de la meme demande : on rend le resultat deja obtenu.
  IF p_cle IS NOT NULL THEN
    SELECT * INTO v_prec FROM lunch_transactions WHERE idempotency_key = p_cle;
    IF FOUND THEN
      IF v_prec.user_id IS DISTINCT FROM v_uid THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
      RETURN jsonb_build_object('achat_id', v_prec.id, 'prix', v_prec.price, 'rejeu', TRUE,
                                'virtual_balance', lunch_mon_solde(v_prec.dep_id));
    END IF;
  END IF;

  IF p_dep_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM dependents WHERE id = p_dep_id AND parent_id = v_uid AND allow_lunch) THEN
    RAISE EXCEPTION 'DEPENDANT_INVALIDE';
  END IF;

  SELECT * INTO v_case FROM lunch_slots
   WHERE machine_id = p_machine_id AND slot_num = p_slot_num
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CASE_INTROUVABLE'; END IF;
  IF COALESCE(v_case.description, '') = '' AND COALESCE(v_case.price, 0) = 0 THEN
    RAISE EXCEPTION 'CASE_VIDE';
  END IF;

  v_prix := COALESCE(v_case.price, 0);

  IF v_prix > 0 THEN
    IF p_dep_id IS NOT NULL THEN
      v_solde := (SELECT virtual_balance FROM dependents WHERE id = p_dep_id FOR UPDATE);
      IF COALESCE(v_solde, 0) < v_prix THEN RAISE EXCEPTION 'SOLDE_INSUFFISANT'; END IF;
      UPDATE dependents SET virtual_balance = virtual_balance - v_prix WHERE id = p_dep_id
        RETURNING virtual_balance INTO v_solde;
      v_desc := 'Machine Lunch (dépendant) : ' || COALESCE(NULLIF(v_case.description,''), 'case ' || p_slot_num);
    ELSE
      v_solde := (SELECT virtual_balance FROM profiles WHERE id = v_uid FOR UPDATE);
      IF COALESCE(v_solde, 0) < v_prix THEN RAISE EXCEPTION 'SOLDE_INSUFFISANT'; END IF;
      UPDATE profiles SET virtual_balance = virtual_balance - v_prix WHERE id = v_uid
        RETURNING virtual_balance INTO v_solde;
      v_desc := 'Machine Lunch : ' || COALESCE(NULLIF(v_case.description,''), 'case ' || p_slot_num);
    END IF;

    INSERT INTO lunch_transactions (machine_id, slot_id, slot_num, buyer_name, price, user_id, dep_id,
                                    idempotency_key, description, exp_date)
    VALUES (p_machine_id, v_case.id::TEXT, p_slot_num, COALESCE(p_buyer_name, ''), v_prix, v_uid, p_dep_id,
            p_cle, v_case.description, v_case.exp_date)
    RETURNING id INTO v_achat;

    -- Au grand livre du resident, meme quand c'est un dependant qui paie
    -- (cf. 001) : c'est le seul lien du dependant au ledger.
    INSERT INTO transactions (user_id, amount, balance_after, type, reference_id, reference_type, description)
    VALUES (v_uid, -v_prix, (SELECT virtual_balance FROM profiles WHERE id = v_uid),
            'lunch_purchase', v_achat, 'lunch_transaction', v_desc)
    RETURNING id INTO v_ledger;
    UPDATE lunch_transactions SET ledger_tx_id = v_ledger WHERE id = v_achat;
  ELSE
    v_solde := lunch_mon_solde(p_dep_id);
  END IF;

  -- La case est videe dans la meme transaction : personne d'autre ne
  -- peut l'acheter entre le debit et le depart du robot.
  UPDATE lunch_slots
     SET description = '', price = 0, reserved = FALSE, reserved_by = NULL, exp_date = NULL, updated_at = now()
   WHERE id = v_case.id;
  UPDATE lunch_machines SET box_count = GREATEST(box_count - 1, 0) WHERE id = p_machine_id;

  RETURN jsonb_build_object('achat_id', v_achat, 'prix', v_prix, 'virtual_balance', v_solde);
END;
$$;

-- ============================================================
-- 7) Remboursement (le robot n'a pas livre)
-- ============================================================
CREATE OR REPLACE FUNCTION lunch_rembourser(p_achat_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_achat lunch_transactions%ROWTYPE;
  v_solde NUMERIC;
BEGIN
  SELECT * INTO v_achat FROM lunch_transactions WHERE id = p_achat_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ACHAT_INTROUVABLE'; END IF;
  IF auth.uid() IS DISTINCT FROM v_achat.user_id AND NOT lunch_peut_gerer(v_achat.machine_id, NULL) THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;
  IF v_achat.rembourse_le IS NOT NULL THEN
    RETURN jsonb_build_object('deja', TRUE, 'virtual_balance', lunch_mon_solde(v_achat.dep_id));
  END IF;
  IF v_achat.price <= 0 THEN RAISE EXCEPTION 'RIEN_A_REMBOURSER'; END IF;

  IF v_achat.dep_id IS NOT NULL THEN
    UPDATE dependents SET virtual_balance = virtual_balance + v_achat.price WHERE id = v_achat.dep_id
      RETURNING virtual_balance INTO v_solde;
  ELSE
    UPDATE profiles SET virtual_balance = virtual_balance + v_achat.price WHERE id = v_achat.user_id
      RETURNING virtual_balance INTO v_solde;
  END IF;

  INSERT INTO transactions (user_id, amount, balance_after, type, reference_id, reference_type, description)
  VALUES (v_achat.user_id, v_achat.price, (SELECT virtual_balance FROM profiles WHERE id = v_achat.user_id),
          'lunch_cancel_refund', v_achat.id, 'lunch_transaction',
          'Machine Lunch — remboursement, livraison annulée');

  UPDATE lunch_transactions SET rembourse_le = now() WHERE id = v_achat.id;

  -- Le plateau est revenu dans sa case : elle retrouve son contenu, si
  -- personne ne l'a remplie entre-temps.
  UPDATE lunch_slots
     SET description = v_achat.description, price = v_achat.price, exp_date = v_achat.exp_date, updated_at = now()
   WHERE machine_id = v_achat.machine_id AND slot_num = v_achat.slot_num
     AND COALESCE(description, '') = '' AND COALESCE(price, 0) = 0;
  UPDATE lunch_machines SET box_count = LEAST(box_count + 1, box_max) WHERE id = v_achat.machine_id;

  RETURN jsonb_build_object('ok', TRUE, 'virtual_balance', v_solde);
END;
$$;

-- ============================================================
-- 8) Droits d'execution
-- ============================================================
REVOKE ALL ON FUNCTION lunch_peut_gerer(TEXT, TEXT)                  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION lunch_pin_valide(TEXT, TEXT)                  FROM public;
REVOKE ALL ON FUNCTION lunch_kiosque_ecrire(TEXT, TEXT, TEXT, JSONB) FROM public;
REVOKE ALL ON FUNCTION lunch_mon_solde(UUID)                         FROM public, anon;
REVOKE ALL ON FUNCTION lunch_acheter(TEXT, INT, UUID, TEXT, TEXT)    FROM public, anon;
REVOKE ALL ON FUNCTION lunch_rembourser(UUID)                        FROM public, anon;

-- Le kiosque en mode PIN n'a pas de session : PIN et ecritures
-- d'administration restent ouverts a anon, la fonction verifie le PIN.
GRANT EXECUTE ON FUNCTION lunch_pin_valide(TEXT, TEXT)                  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION lunch_kiosque_ecrire(TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION lunch_mon_solde(UUID)                         TO authenticated;
GRANT EXECUTE ON FUNCTION lunch_acheter(TEXT, INT, UUID, TEXT, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION lunch_rembourser(UUID)                        TO authenticated;

-- Les anciennes portes (001) se ferment.
DO $old$
BEGIN
  IF to_regprocedure('lunch_purchase(uuid,uuid,text,text,text,numeric)') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION lunch_purchase(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC) FROM public, anon, authenticated;
  END IF;
  IF to_regprocedure('lunch_get_balance(uuid,uuid)') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION lunch_get_balance(UUID, UUID) FROM public, anon, authenticated;
  END IF;
END $old$;

-- ============================================================
-- 9) Ledger : le remboursement d'un achat Lunch
-- ============================================================
-- Liste de 036, augmentee de 'lunch_cancel_refund'.
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
      'lunch_cancel_refund',
      'vehicle_reservation',
      'vehicle_reservation_refund',
      'emploi_remuneration',
      'demo'
    ));
END $ck$;

COMMIT;

NOTIFY pgrst, 'reload schema';
