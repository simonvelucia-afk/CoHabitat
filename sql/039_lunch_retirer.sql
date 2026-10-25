-- 039_lunch_retirer.sql
-- Retirer une Machine Lunch de l'immeuble.
--
-- Une machine revendue, déménagée ou hors service quitte l'immeuble : sa
-- fiche, ses zones et ses cases sont supprimées, et son numéro de série
-- redevient libre — la même machine pourra être ajoutée de nouveau, ici
-- ou ailleurs.
--
-- Ce qui reste : l'historique des achats (lunch_transactions) et leurs
-- lignes au grand livre. Ils ne référencent la machine que par son
-- identifiant texte, sans clé étrangère : les relevés des résidents ne
-- perdent rien. La bibliothèque de menus, partagée entre les machines de
-- l'immeuble, reste aussi.
--
-- Garde-fou : une machine qui contient encore des plats n'est retirée
-- que si l'on confirme (p_forcer) — ce qui reste dans les cases est
-- perdu pour l'application, pas pour l'argent : rien n'a été payé pour
-- un plat encore dans sa case.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

CREATE OR REPLACE FUNCTION lunch_machine_retirer(p_machine_id TEXT, p_forcer BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pleines INT;
  v_numero  TEXT;
BEGIN
  IF get_my_role() NOT IN ('admin','principal_admin') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  SELECT numero_serie INTO v_numero FROM lunch_machines WHERE id = p_machine_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MACHINE_INTROUVABLE'; END IF;

  v_pleines := (SELECT COUNT(*) FROM lunch_slots
                 WHERE machine_id = p_machine_id
                   AND (COALESCE(description, '') <> '' OR COALESCE(price, 0) > 0));
  IF v_pleines > 0 AND NOT COALESCE(p_forcer, FALSE) THEN
    -- Rendu, pas levé : l'interface demande confirmation avec ce nombre.
    RETURN jsonb_build_object('retiree', FALSE, 'cases_pleines', v_pleines);
  END IF;

  -- Zones et cases suivent (ON DELETE CASCADE, 037).
  DELETE FROM lunch_machines WHERE id = p_machine_id;
  DELETE FROM lunch_pin_essais WHERE machine_id = p_machine_id;

  RETURN jsonb_build_object('retiree', TRUE, 'cases_pleines', v_pleines, 'numero_serie', v_numero);
END;
$$;

REVOKE ALL ON FUNCTION lunch_machine_retirer(TEXT, BOOLEAN) FROM public, anon;
GRANT EXECUTE ON FUNCTION lunch_machine_retirer(TEXT, BOOLEAN) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
