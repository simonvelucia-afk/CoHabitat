-- 001_lunch_coherence.sql
-- A deployer sur le Supabase CoHabitat de l'immeuble (ex : Pointe Est =
-- uwyhrdjlwetcbtskijrs) ou les profiles/dependents et donc les soldes vivent.
--
-- Contexte : le kiosque LunchMachine et modulimo-admin stockaient les
-- lunch_transactions sur la base centrale (bpxscgrbxjscicpnheep) alors que les
-- soldes vivent ici. Resultat : aucun debit reel apres un achat. Cette
-- migration rapatrie la partie "resident" (audit + ledger + RPC atomique)
-- sur la meme base que les profiles, pour que tout soit coherent.
--
-- Restent sur la base centrale : lunch_machines, lunch_zones, lunch_slots,
-- lunch_menus (configuration machine, partagee entre buildings).

-- =========================================================================
-- A) Audit : journal machine-centric (quelle machine / quel slot / quel prix)
-- =========================================================================
CREATE TABLE IF NOT EXISTS lunch_transactions (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  machine_id  TEXT NOT NULL,
  slot_id     UUID,               -- reference vers lunch_slots.id (sur central)
  buyer_name  TEXT NOT NULL,
  price       NUMERIC(8,2) NOT NULL DEFAULT 0,
  user_id     UUID REFERENCES profiles(id)   ON DELETE SET NULL,
  dep_id      UUID REFERENCES dependents(id) ON DELETE SET NULL,
  ledger_tx_id UUID,              -- lien vers transactions.id (ledger financier)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Filet de securite : si une ancienne version de la table a ete creee sans
-- ces colonnes (premier run partiel, version LunchMachine differente, etc.),
-- on les rajoute ici plutot que de faire planter les CREATE INDEX / POLICY
-- qui les referencent.
ALTER TABLE lunch_transactions
  ADD COLUMN IF NOT EXISTS machine_id   TEXT,
  ADD COLUMN IF NOT EXISTS slot_id      UUID,
  ADD COLUMN IF NOT EXISTS buyer_name   TEXT,
  ADD COLUMN IF NOT EXISTS price        NUMERIC(8,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS user_id      UUID,
  ADD COLUMN IF NOT EXISTS dep_id       UUID,
  ADD COLUMN IF NOT EXISTS ledger_tx_id UUID,
  ADD COLUMN IF NOT EXISTS created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Ajouter les FK si manquantes (un ADD COLUMN IF NOT EXISTS ne les inclut pas
-- quand la colonne pre-existait sans reference).
DO $do_fk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lunch_transactions_user_id_fkey') THEN
    BEGIN
      ALTER TABLE lunch_transactions
        ADD CONSTRAINT lunch_transactions_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
    EXCEPTION WHEN others THEN NULL; -- si profiles manque ou donnees incoherentes, on n'interrompt pas
    END;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lunch_transactions_dep_id_fkey') THEN
    BEGIN
      ALTER TABLE lunch_transactions
        ADD CONSTRAINT lunch_transactions_dep_id_fkey
        FOREIGN KEY (dep_id) REFERENCES dependents(id) ON DELETE SET NULL;
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
END $do_fk$;

CREATE INDEX IF NOT EXISTS idx_lunch_tx_user    ON lunch_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_lunch_tx_dep     ON lunch_transactions(dep_id);
CREATE INDEX IF NOT EXISTS idx_lunch_tx_machine ON lunch_transactions(machine_id, created_at DESC);

ALTER TABLE lunch_transactions ENABLE ROW LEVEL SECURITY;

-- Lecture : le resident voit ses propres achats, les admins voient tout
DROP POLICY IF EXISTS lunch_tx_select_own ON lunch_transactions;
CREATE POLICY lunch_tx_select_own ON lunch_transactions
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid()
               AND p.role IN ('principal_admin','admin'))
  );

-- Ecriture directe interdite : seul le RPC lunch_purchase (SECURITY DEFINER) y insere.

-- =========================================================================
-- B) Ledger financier : etendre le CHECK de transactions.type pour accepter
--    'lunch_purchase'. Sans cela le ledger rejette l'insert du RPC.
-- =========================================================================
DO $do_ck$
BEGIN
  -- Supprime puis recree la contrainte avec le nouveau type
  ALTER TABLE transactions DROP CONSTRAINT IF EXISTS transactions_type_check;
  ALTER TABLE transactions ADD CONSTRAINT transactions_type_check
    CHECK (type IN (
      'admin_credit',
      'space_reservation',
      'space_cancel_refund',
      'trip_booking',
      'trip_cancel_refund',
      'trip_cancel_charge',
      'trip_driver_earning',
      'trip_driver_charge',
      'lunch_purchase',
      'demo'
    ));
END $do_ck$;

-- =========================================================================
-- C) RPC lunch_purchase : atomique, verifie les fonds, audit + ledger + debit.
--    Appele par le kiosque (anon key apres chsession auto-login).
-- =========================================================================
CREATE OR REPLACE FUNCTION lunch_purchase(
  p_user_id     UUID,
  p_dep_id      UUID,
  p_machine_id  TEXT,
  p_slot_db_id  UUID,
  p_buyer_name  TEXT,
  p_amount      NUMERIC
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn_lunch$
DECLARE
  v_current NUMERIC;
  v_new     NUMERIC;
  v_audit_id  UUID;
  v_ledger_id UUID;
BEGIN
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'Montant invalide';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id requis';
  END IF;

  -- 1. Verrouiller + verifier + debiter le bon compte
  IF p_dep_id IS NOT NULL THEN
    SELECT virtual_balance INTO v_current FROM dependents WHERE id = p_dep_id FOR UPDATE;
    IF v_current IS NULL THEN
      RAISE EXCEPTION 'Dependant introuvable';
    END IF;
    IF v_current < p_amount THEN
      RAISE EXCEPTION 'Solde insuffisant (% requis, % disponible)', p_amount, v_current;
    END IF;
    v_new := v_current - p_amount;
    UPDATE dependents SET virtual_balance = v_new WHERE id = p_dep_id;
  ELSE
    SELECT virtual_balance INTO v_current FROM profiles WHERE id = p_user_id FOR UPDATE;
    IF v_current IS NULL THEN
      RAISE EXCEPTION 'Profil introuvable';
    END IF;
    IF v_current < p_amount THEN
      RAISE EXCEPTION 'Solde insuffisant (% requis, % disponible)', p_amount, v_current;
    END IF;
    v_new := v_current - p_amount;
    UPDATE profiles SET virtual_balance = v_new WHERE id = p_user_id;
  END IF;

  -- 2. Audit machine-centric
  INSERT INTO lunch_transactions (machine_id, slot_id, buyer_name, price, user_id, dep_id)
  VALUES (p_machine_id, p_slot_db_id, COALESCE(p_buyer_name,''), p_amount, p_user_id, p_dep_id)
  RETURNING id INTO v_audit_id;

  -- 3. Ledger financier resident-centric (visible dans CoHabitat > Mon profil)
  --    Note : les depenses des dependants sont enregistrees sur le parent
  --    (seul lien au ledger), mais le debit reel a bien touche le dependant.
  INSERT INTO transactions (user_id, amount, balance_after, type, reference_id, reference_type, description)
  VALUES (
    p_user_id,
    -p_amount,
    CASE WHEN p_dep_id IS NULL THEN v_new ELSE (SELECT virtual_balance FROM profiles WHERE id = p_user_id) END,
    'lunch_purchase',
    v_audit_id,
    'lunch_transaction',
    CASE WHEN p_dep_id IS NULL
      THEN 'Achat ' || p_machine_id || ' : ' || COALESCE(p_buyer_name,'')
      ELSE 'Achat ' || p_machine_id || ' (dep) : ' || COALESCE(p_buyer_name,'')
    END
  )
  RETURNING id INTO v_ledger_id;

  -- 4. Relier l'audit au ledger pour la tracabilite
  UPDATE lunch_transactions SET ledger_tx_id = v_ledger_id WHERE id = v_audit_id;

  RETURN v_audit_id;
END;
$fn_lunch$;

-- Autoriser l'appel par anon + authenticated (le kiosque utilise l'anon key
-- apres auto-login chsession). La fonction reste sure car elle verifie les
-- soldes et est atomique.
GRANT EXECUTE ON FUNCTION lunch_purchase(UUID, UUID, TEXT, UUID, TEXT, NUMERIC)
  TO anon, authenticated;
