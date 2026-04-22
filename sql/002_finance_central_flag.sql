-- 002_finance_central_flag.sql
-- Feature flag cote CoHabitat pour piloter la bascule lecture du solde
-- vers la centrale Modulimo (Phase 3C).
--
-- Tant que finance_central_enabled = 'false', l'app lit virtual_balance
-- depuis profiles comme avant. Passe a 'true' pour que l'app appelle
-- finance-bridge/get-balance et affiche le solde central. Le flag est
-- cote CoHabitat (pas cote central) pour que l'admin puisse basculer
-- immeuble par immeuble sans coordination.
--
-- A executer sur la DB CoHabitat de l'immeuble cible apres avoir :
--   1. deploye la migration Phase 2 central (modulimo-admin sql/009)
--   2. enregistre l'immeuble dans central.building_registry
--   3. backfille les soldes via scripts/backfill-building.ts
--   4. active dual_write_enabled=true cote central + deploye finance-sync
--   5. observe divergence_log vide pendant au moins 24-48h

INSERT INTO system_settings (key, value, description) VALUES
  ('finance_central_enabled', 'false',
   'Si true, l''UI CoHabitat lit le solde depuis central via finance-bridge au lieu de profiles.virtual_balance. Bascule unidirectionnelle : revenir a false si central injoignable.')
ON CONFLICT (key) DO NOTHING;
