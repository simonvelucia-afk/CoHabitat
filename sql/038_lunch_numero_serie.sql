-- 038_lunch_numero_serie.sql
-- Ajouter une Machine Lunch par son numéro de série.
--
-- Quand l'immeuble achète une machine, son administrateur l'ajoute
-- lui-même : Paramètres → Machine Lunch, numéro de série inscrit sur la
-- machine, un nom, un PIN. Rien ne passe par la centrale.
--
-- Le numéro : LM-AAAA-NNNNN-C (année de fabrication, rang dans l'année,
-- clé de contrôle ISO 7064 MOD 37,36). La base recalcule la clé et
-- refuse un numéro mal saisi. La clé repère les fautes de frappe ; elle
-- n'est pas secrète et ne prouve pas qu'une machine a été vendue, ni
-- qu'elle n'est pas déjà déclarée dans un autre immeuble — l'immeuble
-- est seul juge de ce qu'il installe chez lui.
--
-- Les numéros se fabriquent avec deploy/scripts/numero-serie-lunch.mjs,
-- dont l'algorithme doit rester identique à lunch_serie_cle().
--
-- Une machine ajoutée par numéro a ce numéro pour identifiant : c'est
-- lui qu'on passe au kiosque (?machine=LM-...). Une machine qui serait
-- en base sans numéro le reçoit par lunch_machine_associer_serie().
--
-- Aucune machine n'etant encore en service, rien n'est importe de la
-- centrale : une premiere version de 037 portait une fonction d'import,
-- retiree ici si elle a ete creee.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ============================================================
-- 1) La clé de contrôle
-- ============================================================
CREATE OR REPLACE FUNCTION lunch_serie_cle(p_corps TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
  alphabet CONSTANT TEXT := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  p  INT := 36;
  s  INT;
  v  INT;
  ch TEXT;
BEGIN
  FOREACH ch IN ARRAY regexp_split_to_array(upper(p_corps), '') LOOP
    v := strpos(alphabet, ch) - 1;
    IF v < 0 THEN RETURN NULL; END IF;
    s := (p + v) % 36;
    IF s = 0 THEN s := 36; END IF;
    p := (s * 2) % 37;
  END LOOP;
  RETURN substr(alphabet, ((37 - p) % 36) + 1, 1);
END;
$$;

CREATE OR REPLACE FUNCTION lunch_serie_valide(p_numero TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    upper(trim(p_numero)) ~ '^LM-[0-9]{4}-[0-9]{5}-[0-9A-Z]$'
    AND lunch_serie_cle('LM' || substr(upper(trim(p_numero)), 4, 4) || substr(upper(trim(p_numero)), 9, 5))
        = substr(upper(trim(p_numero)), 15, 1),
    FALSE);
$$;

-- ============================================================
-- 2) La machine porte son numéro
-- ============================================================
ALTER TABLE lunch_machines
  ADD COLUMN IF NOT EXISTS numero_serie TEXT,
  ADD COLUMN IF NOT EXISTS ajoutee_le   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ajoutee_par  UUID REFERENCES profiles(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS lunch_machines_numero_serie ON lunch_machines (numero_serie)
  WHERE numero_serie IS NOT NULL;

ALTER TABLE lunch_machines DROP CONSTRAINT IF EXISTS lunch_machines_numero_serie_valide;
ALTER TABLE lunch_machines ADD CONSTRAINT lunch_machines_numero_serie_valide
  CHECK (numero_serie IS NULL OR lunch_serie_valide(numero_serie));

-- Le numéro se lit comme le reste de la machine (pas le PIN).
GRANT SELECT (numero_serie, ajoutee_le) ON lunch_machines TO anon, authenticated;

-- Une machine n'entre plus en base que par son numéro : plus
-- d'insertion directe.
REVOKE INSERT ON lunch_machines FROM authenticated;
DROP FUNCTION IF EXISTS lunch_importer(JSONB);

-- ============================================================
-- 3) Ajouter une machine
-- ============================================================
CREATE OR REPLACE FUNCTION lunch_machine_ajouter(p_numero TEXT, p_nom TEXT, p_pin TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_numero TEXT := upper(trim(p_numero));
BEGIN
  IF get_my_role() NOT IN ('admin','principal_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF NOT lunch_serie_valide(v_numero) THEN RAISE EXCEPTION 'SERIE_INVALIDE'; END IF;
  IF COALESCE(trim(p_nom), '') = '' THEN RAISE EXCEPTION 'NOM_REQUIS'; END IF;
  IF COALESCE(p_pin, '') !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'PIN_INVALIDE'; END IF;
  IF EXISTS (SELECT 1 FROM lunch_machines WHERE numero_serie = v_numero OR id = v_numero) THEN
    RAISE EXCEPTION 'SERIE_DEJA_AJOUTEE';
  END IF;

  INSERT INTO lunch_machines (id, numero_serie, name, pin, active, ajoutee_le, ajoutee_par)
  VALUES (v_numero, v_numero, trim(p_nom), p_pin, TRUE, now(), auth.uid());
  RETURN v_numero;
END;
$$;

-- ============================================================
-- 4) Donner son numéro à une machine déjà en service
-- ============================================================
CREATE OR REPLACE FUNCTION lunch_machine_associer_serie(p_machine_id TEXT, p_numero TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_numero TEXT := upper(trim(p_numero));
BEGIN
  IF get_my_role() NOT IN ('admin','principal_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF NOT lunch_serie_valide(v_numero) THEN RAISE EXCEPTION 'SERIE_INVALIDE'; END IF;
  IF EXISTS (SELECT 1 FROM lunch_machines WHERE (numero_serie = v_numero OR id = v_numero) AND id <> p_machine_id) THEN
    RAISE EXCEPTION 'SERIE_DEJA_AJOUTEE';
  END IF;
  UPDATE lunch_machines
     SET numero_serie = v_numero,
         ajoutee_le = COALESCE(ajoutee_le, now()), ajoutee_par = COALESCE(ajoutee_par, auth.uid())
   WHERE id = p_machine_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MACHINE_INTROUVABLE'; END IF;
  RETURN v_numero;
END;
$$;

REVOKE ALL ON FUNCTION lunch_machine_ajouter(TEXT, TEXT, TEXT)       FROM public, anon;
REVOKE ALL ON FUNCTION lunch_machine_associer_serie(TEXT, TEXT)      FROM public, anon;
GRANT EXECUTE ON FUNCTION lunch_machine_ajouter(TEXT, TEXT, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION lunch_machine_associer_serie(TEXT, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION lunch_serie_valide(TEXT)                   TO anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
