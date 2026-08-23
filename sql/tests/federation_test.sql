-- federation_test.sql — verifie le comportement des RPC de federation
-- sur une base fraichement migree. A jouer dans une transaction que l'on
-- annule a la fin : aucune trace laissee.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/federation_test.sql
--
-- Chaque etape leve une exception si l'invariant attendu est faux.

BEGIN;

DO $$
DECLARE
  v_peer     UUID;
  v_profile  UUID := '11111111-1111-1111-1111-111111111111';
  v_space    UUID;
  v_r1       JSONB;
  v_r2       JSONB;
  v_t1       JSONB;
  v_t2       JSONB;
  v_count    INT;
  v_balance  NUMERIC;
BEGIN
  -- Contexte : un pair actif, autorise sur les deux capacites, plafond 100 $.
  INSERT INTO federation_peers (instance_id, display_name, base_url, public_key,
                                status, allow_reservations, allow_finance, finance_credit_limit)
  VALUES ('test-pair', 'Immeuble test', 'https://10.8.0.2', 'cle-publique-test',
          'active', TRUE, TRUE, 100)
  RETURNING id INTO v_peer;

  -- Le trigger on_auth_user_created cree deja la ligne profiles ; on ne
  -- fait que la marquer comme profil ombre du pair.
  INSERT INTO auth.users (id, email) VALUES (v_profile, 'invite@test.local');
  UPDATE profiles SET full_name = 'Invite du pair', origin_peer_id = v_peer WHERE id = v_profile;
  INSERT INTO federation_guests (peer_id, remote_user_id, profile_id, display_name)
  VALUES (v_peer, 'usager-distant-1', v_profile, 'Invite du pair');

  INSERT INTO common_spaces (name, capacity) VALUES ('Salle test', 10) RETURNING id INTO v_space;

  -- 1) Reservation entrante
  v_r1 := federation_reserve_space(v_peer, 'cle-1', v_profile, v_space,
                                   NOW() + INTERVAL '1 day', NOW() + INTERVAL '1 day 2 hours', 8, 20);
  IF NOT (v_r1->>'ok')::BOOLEAN THEN
    RAISE EXCEPTION 'reservation refusee: %', v_r1;
  END IF;

  -- 2) Rejeu de la meme cle : meme reponse, pas de doublon
  v_r2 := federation_reserve_space(v_peer, 'cle-1', v_profile, v_space,
                                   NOW() + INTERVAL '1 day', NOW() + INTERVAL '1 day 2 hours', 8, 20);
  IF v_r1->>'reservation_id' IS DISTINCT FROM v_r2->>'reservation_id' THEN
    RAISE EXCEPTION 'idempotence cassee: % vs %', v_r1, v_r2;
  END IF;
  SELECT COUNT(*) INTO v_count FROM space_reservations WHERE origin_peer_id = v_peer;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'attendu 1 reservation, trouve %', v_count;
  END IF;

  -- 3) Creneau deja pris : refus explicite, pas d'exception
  IF (federation_reserve_space(v_peer, 'cle-2', v_profile, v_space,
        NOW() + INTERVAL '1 day 1 hour', NOW() + INTERVAL '1 day 3 hours', 8, 20)->>'error')
     IS DISTINCT FROM 'space_unavailable' THEN
    RAISE EXCEPTION 'le chevauchement aurait du etre refuse';
  END IF;

  -- 4) Le grand livre porte la creance sur le pair
  SELECT COALESCE(SUM(amount), 0) INTO v_balance FROM federation_ledger WHERE peer_id = v_peer;
  IF v_balance <> 20 THEN
    RAISE EXCEPTION 'grand livre attendu 20, trouve %', v_balance;
  END IF;

  -- 5) Transfert entrant sous le plafond (20 deja engages + 50 = 70 <= 100)
  v_t1 := federation_apply_transfer(v_peer, 'cle-tr-1', v_profile, 50, 'admin_credit', 'Credit test');
  IF NOT (v_t1->>'ok')::BOOLEAN THEN
    RAISE EXCEPTION 'transfert refuse: %', v_t1;
  END IF;
  SELECT virtual_balance INTO v_balance FROM profiles WHERE id = v_profile;
  IF v_balance <> 50 THEN
    RAISE EXCEPTION 'solde attendu 50, trouve %', v_balance;
  END IF;

  -- 6) Rejeu du transfert : aucun double credit
  v_t2 := federation_apply_transfer(v_peer, 'cle-tr-1', v_profile, 50, 'admin_credit', 'Credit test');
  SELECT virtual_balance INTO v_balance FROM profiles WHERE id = v_profile;
  IF v_balance <> 50 THEN
    RAISE EXCEPTION 'double credit detecte, solde %', v_balance;
  END IF;
  IF v_t1->>'balance_after' IS DISTINCT FROM v_t2->>'balance_after' THEN
    RAISE EXCEPTION 'reponse de rejeu differente: % vs %', v_t1, v_t2;
  END IF;

  -- 7) Depassement du plafond : refus (70 engages + 50 = 120 > 100)
  IF (federation_apply_transfer(v_peer, 'cle-tr-2', v_profile, 50, 'admin_credit', 'Trop')->>'error')
     IS DISTINCT FROM 'credit_limit_exceeded' THEN
    RAISE EXCEPTION 'le plafond aurait du bloquer le transfert';
  END IF;

  -- 8) Pair suspendu : plus aucune operation acceptee
  UPDATE federation_peers SET status = 'suspended' WHERE id = v_peer;
  IF (federation_apply_transfer(v_peer, 'cle-tr-3', v_profile, 5, 'admin_credit', NULL)->>'error')
     IS DISTINCT FROM 'peer_not_allowed' THEN
    RAISE EXCEPTION 'un pair suspendu ne doit rien pouvoir faire';
  END IF;

  -- 9) Annulation entrante : remboursement inscrit au grand livre
  UPDATE federation_peers SET status = 'active' WHERE id = v_peer;
  IF NOT (federation_cancel_reservation(v_peer, 'cle-an-1',
            (v_r1->>'reservation_id')::UUID, 'Test', 20)->>'ok')::BOOLEAN THEN
    RAISE EXCEPTION 'annulation refusee';
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_balance FROM federation_ledger WHERE peer_id = v_peer;
  IF v_balance <> 50 THEN
    RAISE EXCEPTION 'grand livre apres annulation attendu 50, trouve %', v_balance;
  END IF;

  -- 10) Cote sortant : engagement puis echec definitif = solde rendu
  DECLARE
    v_out    JSONB;
    v_before NUMERIC;
  BEGIN
    SELECT virtual_balance INTO v_before FROM profiles WHERE id = v_profile;
    v_out := federation_begin_outbound(v_peer, 'cle-out-1', 'reservation.create', v_profile, 30,
               jsonb_build_object('user_id', v_profile, 'space_id', 'distant'));
    IF NOT (v_out->>'ok')::BOOLEAN THEN
      RAISE EXCEPTION 'engagement sortant refuse: %', v_out;
    END IF;
    SELECT virtual_balance INTO v_balance FROM profiles WHERE id = v_profile;
    IF v_balance <> v_before - 30 THEN
      RAISE EXCEPTION 'debit sortant attendu %, trouve %', v_before - 30, v_balance;
    END IF;

    -- Rejeu de la meme cle : aucun second debit
    PERFORM federation_begin_outbound(v_peer, 'cle-out-1', 'reservation.create', v_profile, 30,
              jsonb_build_object('user_id', v_profile));
    SELECT virtual_balance INTO v_balance FROM profiles WHERE id = v_profile;
    IF v_balance <> v_before - 30 THEN
      RAISE EXCEPTION 'double debit sortant, solde %', v_balance;
    END IF;

    -- Echec definitif : le locataire est rembourse et la creance disparait
    PERFORM federation_settle_outbound((v_out->>'request_id')::UUID, 'failed', NULL, 'pair injoignable');
    SELECT virtual_balance INTO v_balance FROM profiles WHERE id = v_profile;
    IF v_balance <> v_before THEN
      RAISE EXCEPTION 'remboursement attendu %, trouve %', v_before, v_balance;
    END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_balance
      FROM federation_ledger WHERE request_id = (v_out->>'request_id')::UUID;
    IF v_balance <> 0 THEN
      RAISE EXCEPTION 'le grand livre devait revenir a 0, trouve %', v_balance;
    END IF;

    -- Second solde sur la meme requete : sans effet
    PERFORM federation_settle_outbound((v_out->>'request_id')::UUID, 'failed', NULL, 'rejeu');
    SELECT virtual_balance INTO v_balance FROM profiles WHERE id = v_profile;
    IF v_balance <> v_before THEN
      RAISE EXCEPTION 'double remboursement, solde %', v_balance;
    END IF;
  END;

  RAISE NOTICE 'federation_test : 13 verifications passees';
END $$;

ROLLBACK;
