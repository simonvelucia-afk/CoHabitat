-- 010_serre_reservoir_temps.sql
-- Module Serre — chaque réservoir a désormais sa propre TEMPÉRATURE
-- (en plus de son niveau %). Remplace la « température de l'eau » unique.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

alter table serre_lectures add column if not exists reservoir1_temp numeric;
alter table serre_lectures add column if not exists reservoir2_temp numeric;
alter table serre_lectures add column if not exists reservoir3_temp numeric;

COMMIT;
