-- 021_lunch_local.sql
-- Deux reglages pour la Machine Lunch, pilotables depuis l'ecran
-- d'administration plutot que par un redeploiement.
--
--   lunch_local      la machine est-elle sur le reseau du batiment ?
--   lunch_local_url  son adresse, quand c'est le cas.
--
-- Quand lunch_local vaut false, l'instance emploie l'adresse livree dans
-- sa configuration et la connexion a la centrale Modulimo est requise.
--
-- Le mode local rend le kiosque joignable sans internet — par le VPN
-- depuis l'exterieur — mais ne rend pas les achats autonomes pour autant :
-- le solde vit sur la centrale dans les deux cas.

BEGIN;

INSERT INTO system_settings (key, value, description) VALUES
  ('lunch_local', 'false',
   'Machine Lunch sur le réseau local : utilise l''adresse ci-dessous au lieu de celle livrée'),
  ('lunch_local_url', '',
   'Adresse du kiosque sur le réseau du bâtiment (ex. https://lunch.immeuble.lan/)')
ON CONFLICT (key) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
