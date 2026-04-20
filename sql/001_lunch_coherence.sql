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
  slot_id     TEXT,               -- reference vers lunch_slots.id (peut etre UUID, INT ou TEXT selon la base centrale)
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
  ADD COLUMN IF NOT EXISTS slot_id      TEXT,
  ADD COLUMN IF NOT EXISTS buyer_name   TEXT,
  ADD COLUMN IF NOT EXISTS price        NUMERIC(8,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS user_id      UUID,
  ADD COLUMN IF NOT EXISTS dep_id       UUID,
  ADD COLUMN IF NOT EXISTS ledger_tx_id UUID,
  ADD COLUMN IF NOT EXISTS created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Si slot_id n'est pas deja TEXT, le convertir. Les ID de slot peuvent
-- etre UUID, INT ou TEXT selon comment lunch_slots a ete cree sur la base
-- centrale ; on uniformise sur TEXT pour ne plus jamais avoir de mismatch.
--
-- Note importante : on commence par DROP toute FK existante sur slot_id.
-- Une ancienne migration aurait pu creer lunch_transactions_slot_id_fkey
-- vers une table lunch_slots locale (cas Pointe Est ou la table existait
-- en double), mais la base centrale et CoHabitat sont distinctes : un
-- slot_id est un simple champ d'audit, pas une vraie reference
-- referentielle. La FK doit donc disparaitre.
DO $do_slot$
DECLARE
  v_type   TEXT;
  v_fkname TEXT;
BEGIN
  -- Drop toute FK posee sur lunch_transactions.slot_id
  FOR v_fkname IN
    SELECT conname FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
     WHERE c.contype = 'f'
       AND c.conrelid = 'public.lunch_transactions'::regclass
       AND a.attname = 'slot_id'
  LOOP
    EXECUTE 'ALTER TABLE lunch_transactions DROP CONSTRAINT ' || quote_ident(v_fkname);
  END LOOP;

  -- Convertir le type si necessaire. Affectation par sous-requete scalaire
  -- plutot que SELECT INTO pour ne pas se faire piger par le parser du
  -- SQL Editor de Supabase qui interprete "SELECT ... INTO v_type" comme
  -- une creation de table v_type (cf. meme bug avec v_current dans la
  -- RPC plus haut).
  v_type := (SELECT data_type FROM information_schema.columns
              WHERE table_schema='public' AND table_name='lunch_transactions' AND column_name='slot_id');
  IF v_type IS NOT NULL AND v_type <> 'text' THEN
    EXECUTE 'ALTER TABLE lunch_transactions ALTER COLUMN slot_id TYPE TEXT USING slot_id::TEXT';
  END IF;
END $do_slot$;

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
-- p_slot_db_id en TEXT pour s'adapter a n'importe quel type d'ID dans
-- lunch_slots (UUID, INT, TEXT). Le DROP est necessaire car CREATE OR REPLACE
-- ne change pas les types d'arguments d'une fonction existante.
DROP FUNCTION IF EXISTS lunch_purchase(UUID, UUID, TEXT, UUID, TEXT, NUMERIC);

CREATE OR REPLACE FUNCTION lunch_purchase(
  p_user_id     UUID,
  p_dep_id      UUID,
  p_machine_id  TEXT,
  p_slot_db_id  TEXT,
  p_buyer_name  TEXT,
  p_amount      NUMERIC
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn_lunch$
#variable_conflict use_variable
DECLARE
  v_current  NUMERIC;
  v_new      NUMERIC;
  v_audit_id UUID;
  v_ledger   UUID;
  v_desc     TEXT;
  v_balance_after NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'Montant invalide';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id requis';
  END IF;

  -- 1. Verrouiller + verifier + debiter le bon compte.
  --    On utilise une affectation par sous-requete scalaire (FOR UPDATE pose
  --    quand meme le verrou sur la ligne) pour eviter que le SQL Editor de
  --    Supabase confonde "SELECT INTO v_current" avec une creation de table.
  IF p_dep_id IS NOT NULL THEN
    v_current := (SELECT virtual_balance FROM dependents WHERE id = p_dep_id FOR UPDATE);
    IF v_current IS NULL THEN
      RAISE EXCEPTION 'Dependant introuvable';
    END IF;
    IF v_current < p_amount THEN
      RAISE EXCEPTION 'Solde insuffisant (% requis, % disponible)', p_amount, v_current;
    END IF;
    v_new := v_current - p_amount;
    UPDATE dependents SET virtual_balance = v_new WHERE id = p_dep_id;
    -- Pour le ledger du parent, on enregistre son solde courant inchange
    v_balance_after := (SELECT virtual_balance FROM profiles WHERE id = p_user_id);
    v_desc := 'Achat ' || p_machine_id || ' (dep) : ' || COALESCE(p_buyer_name,'');
  ELSE
    v_current := (SELECT virtual_balance FROM profiles WHERE id = p_user_id FOR UPDATE);
    IF v_current IS NULL THEN
      RAISE EXCEPTION 'Profil introuvable';
    END IF;
    IF v_current < p_amount THEN
      RAISE EXCEPTION 'Solde insuffisant (% requis, % disponible)', p_amount, v_current;
    END IF;
    v_new := v_current - p_amount;
    UPDATE profiles SET virtual_balance = v_new WHERE id = p_user_id;
    v_balance_after := v_new;
    v_desc := 'Achat ' || p_machine_id || ' : ' || COALESCE(p_buyer_name,'');
  END IF;

  -- 2. Audit machine-centric
  INSERT INTO lunch_transactions (machine_id, slot_id, buyer_name, price, user_id, dep_id)
  VALUES (p_machine_id, p_slot_db_id, COALESCE(p_buyer_name,''), p_amount, p_user_id, p_dep_id)
  RETURNING id INTO v_audit_id;

  -- 3. Ledger financier resident-centric (visible dans CoHabitat > Mon profil)
  --    Les depenses des dependants sont enregistrees sur le parent (seul lien
  --    au ledger), mais le debit reel a bien touche le dependant.
  INSERT INTO transactions (user_id, amount, balance_after, type, reference_id, reference_type, description)
  VALUES (p_user_id, -p_amount, v_balance_after, 'lunch_purchase', v_audit_id, 'lunch_transaction', v_desc)
  RETURNING id INTO v_ledger;

  -- 4. Relier l'audit au ledger pour la tracabilite
  UPDATE lunch_transactions SET ledger_tx_id = v_ledger WHERE id = v_audit_id;

  RETURN v_audit_id;
END;
$fn_lunch$;

-- Autoriser l'appel par anon + authenticated (le kiosque utilise l'anon key
-- apres auto-login chsession). La fonction reste sure car elle verifie les
-- soldes et est atomique.
GRANT EXECUTE ON FUNCTION lunch_purchase(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC)
  TO anon, authenticated;


-- =========================================================================
-- D) RPC lunch_get_balance : lecture du solde virtuel sans exposer profiles
--    a anon (RLS bloque la lecture directe de virtual_balance par la cle
--    anon). SECURITY DEFINER + GRANT a anon. Retourne NULL si l'id n'existe
--    pas. La securite repose sur le fait que les UUID ne sont pas devinables.
-- =========================================================================
CREATE OR REPLACE FUNCTION lunch_get_balance(
  p_user_id UUID,
  p_dep_id  UUID
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn_balance$
BEGIN
  IF p_dep_id IS NOT NULL THEN
    RETURN (SELECT virtual_balance FROM dependents WHERE id = p_dep_id);
  END IF;
  IF p_user_id IS NULL THEN RETURN NULL; END IF;
  RETURN (SELECT virtual_balance FROM profiles WHERE id = p_user_id);
END;
$fn_balance$;

GRANT EXECUTE ON FUNCTION lunch_get_balance(UUID, UUID) TO anon, authenticated;


-- =========================================================================
-- E) Policies lunch_queue : le kiosque (cle anon) doit pouvoir inscrire un
--    resident dans la file, lire la file, et la mettre a jour (status,
--    expires_at). Pas de check restrictif puisque l'utilisation est limitee
--    aux machines deja authentifiees via chsession.
-- =========================================================================
DO $do_lq$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='lunch_queue') THEN
    EXECUTE 'ALTER TABLE lunch_queue ENABLE ROW LEVEL SECURITY';

    -- SELECT pour anon (le kiosque doit voir la file pour afficher le rang)
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lunch_queue' AND policyname='lunch_queue_select_anon') THEN
      EXECUTE 'CREATE POLICY lunch_queue_select_anon ON lunch_queue FOR SELECT TO anon USING (TRUE)';
    END IF;
    -- INSERT pour anon (le kiosque ajoute le resident en file)
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lunch_queue' AND policyname='lunch_queue_insert_anon') THEN
      EXECUTE 'CREATE POLICY lunch_queue_insert_anon ON lunch_queue FOR INSERT TO anon WITH CHECK (TRUE)';
    END IF;
    -- UPDATE pour anon (status: waiting -> active, etc.)
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lunch_queue' AND policyname='lunch_queue_update_anon') THEN
      EXECUTE 'CREATE POLICY lunch_queue_update_anon ON lunch_queue FOR UPDATE TO anon USING (TRUE) WITH CHECK (TRUE)';
    END IF;
    -- DELETE pour anon (queueLeave appelle DELETE)
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lunch_queue' AND policyname='lunch_queue_delete_anon') THEN
      EXECUTE 'CREATE POLICY lunch_queue_delete_anon ON lunch_queue FOR DELETE TO anon USING (TRUE)';
    END IF;
  END IF;
END $do_lq$;


-- Forcer PostgREST a recharger son schema cache pour exposer les nouvelles
-- RPC immediatement (sinon il faut attendre un cycle ou redemarrer).
NOTIFY pgrst, 'reload schema';
