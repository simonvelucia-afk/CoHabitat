-- 020_system_settings_insert.sql
-- Corrige l'erreur « new row violates row-level security policy » sur les
-- interrupteurs de modules.
--
-- schema.sql ne cree que deux politiques sur system_settings :
--   settings_select  FOR SELECT  (tous les authentifies)
--   settings_admin   FOR UPDATE  (principal_admin)
--
-- Aucune politique ne couvre INSERT. Tant que la ligne existait deja, un
-- UPDATE suffisait ; mais une base qui n'a pas applique la migration 019
-- n'a pas les lignes module_trips / module_lunch, et la creation de la
-- ligne au premier basculement etait refusee par RLS (403).
--
-- On ajoute donc la politique INSERT manquante, reservee a l'administrateur
-- principal comme l'UPDATE, et la politique DELETE correspondante pour que
-- la table soit entierement administrable par le meme role.

BEGIN;

DROP POLICY IF EXISTS "settings_admin_insert" ON system_settings;
CREATE POLICY "settings_admin_insert" ON system_settings
  FOR INSERT WITH CHECK (get_my_role() = 'principal_admin');

DROP POLICY IF EXISTS "settings_admin_delete" ON system_settings;
CREATE POLICY "settings_admin_delete" ON system_settings
  FOR DELETE USING (get_my_role() = 'principal_admin');

-- Les lignes des trois modules, au cas ou la migration 019 n'aurait pas
-- ete appliquee : sans elles, chaque basculement doit creer la ligne.
INSERT INTO system_settings (key, value, description) VALUES
  ('module_trips', 'true',  'Module Auto-partage : covoiturage, véhicules et demandes de passagers'),
  ('module_lunch', 'false', 'Module Machine Lunch : kiosque et commandes (nécessite la centrale Modulimo)'),
  ('module_serre', 'true',  'Module Serre : zones de culture louées au mois et capteurs')
ON CONFLICT (key) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
