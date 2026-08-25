-- 021_lunch_local.sql
-- Configuration de la Machine Lunch, pilotable depuis l'ecran
-- d'administration plutot que par un redeploiement.
--
--   lunch_mode       demo | local | central
--   lunch_local_url  l'adresse de la machine, employee en mode local.
--
--   demo     donnees fictives, aucune transaction, aucun lien requis.
--   local    la machine est sur le reseau du batiment, a l'adresse
--            ci-dessus. Joignable par VPN depuis l'exterieur.
--   central  l'adresse livree avec l'instance sert, et la liaison a la
--            centrale Modulimo est requise pour acheter.
--
-- L'etat de la liaison ne figure pas ici : il ne se choisit pas, il se
-- constate. L'interface l'affiche a partir de sa propre sonde.
--
-- Le solde vit sur la centrale en mode local comme en mode central : le
-- mode local rend le kiosque joignable sans internet, il ne rend pas les
-- achats autonomes.
--
-- Seul l'administrateur principal peut ecrire ici — voir les politiques
-- settings_admin* de la migration 020.

BEGIN;

INSERT INTO system_settings (key, value, description) VALUES
  ('lunch_mode', 'central',
   'Configuration de la Machine Lunch : demo, local ou central'),
  ('lunch_local_url', '',
   'Adresse du kiosque sur le réseau du bâtiment (ex. https://lunch.immeuble.lan/)')
ON CONFLICT (key) DO NOTHING;

-- Une version anterieure de cette migration posait un booleen lunch_local.
-- Le convertir plutot que de le laisser trainer sans lecteur.
UPDATE system_settings SET value = 'local'
 WHERE key = 'lunch_mode'
   AND value = 'central'
   AND EXISTS (SELECT 1 FROM system_settings WHERE key = 'lunch_local' AND value = 'true');
DELETE FROM system_settings WHERE key = 'lunch_local';

COMMIT;

NOTIFY pgrst, 'reload schema';
