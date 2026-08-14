-- 012_serre_couts_module.sql
-- Permet de comptabiliser les frais d'exploitation de la SERRE dans la
-- même table que les élevages (elevage_couts), via module = 'serre'.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

alter table elevage_couts drop constraint if exists elevage_couts_module_check;
alter table elevage_couts
  add constraint elevage_couts_module_check
  check (module in ('serre', 'poulailler', 'sablonponie'));

COMMIT;
