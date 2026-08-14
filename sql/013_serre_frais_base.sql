-- 013_serre_frais_base.sql
-- Frais mensuel de base d'une zone de serre : passe de 1 $ à 0,50 $, et
-- devient une variable modifiable par l'admin (system_settings).
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- Nouveau défaut de colonne
alter table serre_zones     alter column frais_mensuel set default 0.5;
alter table serre_locations alter column frais_mensuel set default 0.5;

-- Réaligne les zones encore à l'ancien tarif de base (1 $) vers 0,50 $
update serre_zones set frais_mensuel = 0.5 where frais_mensuel = 1;

-- Variable globale, modifiable par l'admin depuis le panneau Serre
insert into system_settings (key, value, description)
values ('serre_frais_mensuel', '0.5', 'Frais mensuel de base d''une zone de serre ($ CAD)')
on conflict (key) do nothing;

COMMIT;
