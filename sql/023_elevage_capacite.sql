-- 023_elevage_capacite.sql
-- Nombre d'animaux permis par élevage.
--
-- Un poulailler résidentiel n'accueille pas le troupeau qu'on veut : la
-- plupart des règlements municipaux le plafonnent, souvent à quatre
-- poules, et sans coq. Le nombre est donc une donnée de l'immeuble, pas
-- une constante du logiciel — il change d'une ville à l'autre.
--
--   elevage_capacite_poulailler   4 par défaut
--   elevage_capacite_sablonponie  vide = aucune limite
--
-- Une valeur vide signifie « pas de plafond » : la sablonponie n'est
-- généralement pas réglementée au nombre de poissons, et afficher un
-- ratio là où il n'y a pas de règle serait inventer une contrainte.
--
-- Seul l'administrateur principal peut écrire ici — voir les politiques
-- settings_admin* de la migration 020.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

INSERT INTO system_settings (key, value, description) VALUES
  ('elevage_capacite_poulailler', '4',
   'Nombre de poules permis au poulailler (règlement municipal). Vide = aucune limite.'),
  ('elevage_capacite_sablonponie', '',
   'Nombre de poissons permis dans le bassin. Vide = aucune limite.')
ON CONFLICT (key) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- DELETE FROM system_settings WHERE key IN
--   ('elevage_capacite_poulailler', 'elevage_capacite_sablonponie');
-- COMMIT;
