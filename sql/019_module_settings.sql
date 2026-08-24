-- 019_module_settings.sql
-- Rend les trois modules optionnels pilotables depuis l'interface
-- d'administration.
--
-- L'ecran des reglages n'affiche un interrupteur que pour les cles
-- presentes dans system_settings. Or seule module_serre y etait inseree
-- (par la migration 009) : un administrateur ne pouvait donc ni couper
-- l'auto-partage, ni couper la Machine Lunch — les deux etaient toujours
-- actifs, sans moyen de les desactiver.
--
-- Les valeurs par defaut reprennent le comportement actuel, pour qu'une
-- base existante ne change pas d'etat en appliquant cette migration :
-- l'auto-partage reste actif, la Machine Lunch reste inactive (elle
-- depend de la centrale Modulimo).

BEGIN;

INSERT INTO system_settings (key, value, description) VALUES
  ('module_trips', 'true',  'Module Auto-partage : covoiturage, véhicules et demandes de passagers'),
  ('module_lunch', 'false', 'Module Machine Lunch : kiosque et commandes (nécessite la centrale Modulimo)'),
  ('module_serre', 'true',  'Module Serre : zones de culture louées au mois et capteurs')
ON CONFLICT (key) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
