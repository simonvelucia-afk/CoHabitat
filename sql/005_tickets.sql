-- 005_tickets.sql
-- Systeme de billets (tickets) pour les requetes des locataires.
--
-- Cycle de resolution : open -> in_progress -> resolved -> closed
--
-- Roles :
--   * tenant         : cree des billets, voit/commente uniquement les siens
--   * concierge      : NOUVEAU role. Traite tous les billets (assigner,
--                      changer statut, repondre). N'a aucun autre privilege
--                      admin (pas d'acces aux locataires, vehicules,
--                      paiements, parametres, etc.).
--   * admin /
--     principal_admin: gardent tous leurs privileges existants. Voient et
--                      peuvent traiter les billets en plus du concierge.
--
-- Tables creees :
--   * tickets          : un billet par requete
--   * ticket_messages  : fil de discussion (locataire <-> concierge)
--
-- RLS : un locataire ne voit que ses propres billets et messages.
-- Concierge / admin / principal_admin voient tout.

BEGIN;

-- ============================================================
-- 1) Ajouter le role 'concierge' a la table profiles
-- ============================================================
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('principal_admin', 'admin', 'concierge', 'tenant', 'demo'));

-- ============================================================
-- 2) Table tickets
-- ============================================================
CREATE TABLE IF NOT EXISTS tickets (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  category        TEXT NOT NULL CHECK (category IN ('maintenance','noise','cleanliness','security','suggestion','billing','other')),
  subject         TEXT NOT NULL,
  description     TEXT NOT NULL,
  priority        TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('low','normal','high','urgent')),
  status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','resolved','closed')),
  assigned_to     UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at     TIMESTAMPTZ,
  closed_at       TIMESTAMPTZ,
  CONSTRAINT tickets_subject_len CHECK (char_length(subject) BETWEEN 3 AND 200),
  CONSTRAINT tickets_descr_len   CHECK (char_length(description) BETWEEN 1 AND 4000)
);

CREATE INDEX IF NOT EXISTS tickets_user_idx        ON tickets (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS tickets_status_idx      ON tickets (status, created_at DESC);
CREATE INDEX IF NOT EXISTS tickets_assigned_idx    ON tickets (assigned_to) WHERE assigned_to IS NOT NULL;

-- Trigger updated_at (utilise le pattern existant)
CREATE OR REPLACE FUNCTION trg_tickets_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  -- Marquer resolved_at / closed_at automatiquement quand on bascule le statut.
  IF NEW.status = 'resolved' AND OLD.status IS DISTINCT FROM 'resolved' THEN
    NEW.resolved_at := now();
  END IF;
  IF NEW.status = 'closed' AND OLD.status IS DISTINCT FROM 'closed' THEN
    NEW.closed_at := now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_tickets_updated_at ON tickets;
CREATE TRIGGER trigger_tickets_updated_at
  BEFORE UPDATE ON tickets
  FOR EACH ROW EXECUTE FUNCTION trg_tickets_touch_updated_at();

-- ============================================================
-- 3) Table ticket_messages
-- ============================================================
CREATE TABLE IF NOT EXISTS ticket_messages (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id    UUID NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  body         TEXT NOT NULL,
  is_internal  BOOLEAN NOT NULL DEFAULT false,  -- note interne concierge, invisible au locataire
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ticket_messages_body_len CHECK (char_length(body) BETWEEN 1 AND 4000)
);

CREATE INDEX IF NOT EXISTS ticket_messages_ticket_idx ON ticket_messages (ticket_id, created_at);

-- Touch tickets.updated_at quand un message est ajoute.
CREATE OR REPLACE FUNCTION trg_ticket_messages_touch_ticket()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  UPDATE tickets SET updated_at = now() WHERE id = NEW.ticket_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_ticket_messages_touch ON ticket_messages;
CREATE TRIGGER trigger_ticket_messages_touch
  AFTER INSERT ON ticket_messages
  FOR EACH ROW EXECUTE FUNCTION trg_ticket_messages_touch_ticket();

-- ============================================================
-- 4) RLS
-- ============================================================
ALTER TABLE tickets         ENABLE ROW LEVEL SECURITY;
ALTER TABLE ticket_messages ENABLE ROW LEVEL SECURITY;

-- Helper : le caller est-il staff (concierge/admin/principal_admin) ?
-- On ne s'appuie pas uniquement sur get_my_role() (defini dans schema.sql)
-- pour eviter une dependance circulaire si l'helper change ; on inline.
CREATE OR REPLACE FUNCTION is_ticket_staff()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND role IN ('concierge','admin','principal_admin')
  );
$$;
REVOKE ALL ON FUNCTION is_ticket_staff() FROM public, anon;
GRANT  EXECUTE ON FUNCTION is_ticket_staff() TO authenticated;

-- tickets : SELECT
DROP POLICY IF EXISTS tickets_select_self_or_staff ON tickets;
CREATE POLICY tickets_select_self_or_staff ON tickets
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_ticket_staff());

-- tickets : INSERT (uniquement pour soi-meme ; staff peut creer pour qqn aussi)
DROP POLICY IF EXISTS tickets_insert_self ON tickets;
CREATE POLICY tickets_insert_self ON tickets
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() OR is_ticket_staff());

-- tickets : UPDATE
-- Le locataire peut updater son propre billet uniquement pour le fermer
-- (status -> closed) ou tant qu'il est en 'open' (corriger sujet/description).
-- Le staff peut tout updater.
DROP POLICY IF EXISTS tickets_update_owner_or_staff ON tickets;
CREATE POLICY tickets_update_owner_or_staff ON tickets
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR is_ticket_staff())
  WITH CHECK (user_id = auth.uid() OR is_ticket_staff());

-- tickets : DELETE (admin/principal_admin uniquement, pas concierge)
DROP POLICY IF EXISTS tickets_delete_admin ON tickets;
CREATE POLICY tickets_delete_admin ON tickets
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid() AND role IN ('admin','principal_admin')
    )
  );

-- ticket_messages : SELECT
-- Le locataire voit les messages NON internes de ses propres billets.
-- Le staff voit tous les messages (y compris internes).
DROP POLICY IF EXISTS tm_select ON ticket_messages;
CREATE POLICY tm_select ON ticket_messages
  FOR SELECT TO authenticated
  USING (
    is_ticket_staff()
    OR (
      NOT is_internal
      AND EXISTS (SELECT 1 FROM tickets t WHERE t.id = ticket_id AND t.user_id = auth.uid())
    )
  );

-- ticket_messages : INSERT
-- Le locataire peut repondre sur ses propres billets (jamais en interne).
-- Le staff peut ajouter n'importe quel message.
DROP POLICY IF EXISTS tm_insert ON ticket_messages;
CREATE POLICY tm_insert ON ticket_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND (
      is_ticket_staff()
      OR (
        NOT is_internal
        AND EXISTS (SELECT 1 FROM tickets t WHERE t.id = ticket_id AND t.user_id = auth.uid())
      )
    )
  );

-- ticket_messages : pas de UPDATE/DELETE (audit trail). Si besoin futur,
-- exposer des RPC dediees plutot que d'ouvrir des policies larges.

-- ============================================================
-- 5) RPC : compteur de billets ouverts (pour le badge admin)
-- ============================================================
CREATE OR REPLACE FUNCTION count_open_tickets()
RETURNS INTEGER LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COUNT(*)::INTEGER FROM tickets
  WHERE status IN ('open','in_progress')
    AND EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid()
        AND role IN ('concierge','admin','principal_admin')
    );
$$;
REVOKE ALL ON FUNCTION count_open_tickets() FROM public, anon;
GRANT  EXECUTE ON FUNCTION count_open_tickets() TO authenticated;

COMMENT ON TABLE tickets IS
  'Requetes (billets) des locataires traitees sous un cycle de resolution
  open -> in_progress -> resolved -> closed. Traitees par le role concierge
  (et par admin/principal_admin par extension).';

COMMENT ON TABLE ticket_messages IS
  'Fil de discussion d''un billet. is_internal=true = note privee staff,
  jamais visible au locataire.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ROLLBACK :
--   DROP TABLE IF EXISTS ticket_messages;
--   DROP TABLE IF EXISTS tickets;
--   DROP FUNCTION IF EXISTS is_ticket_staff();
--   DROP FUNCTION IF EXISTS count_open_tickets();
--   DROP FUNCTION IF EXISTS trg_tickets_touch_updated_at();
--   DROP FUNCTION IF EXISTS trg_ticket_messages_touch_ticket();
--   ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
--   ALTER TABLE profiles ADD  CONSTRAINT profiles_role_check
--     CHECK (role IN ('principal_admin','admin','tenant','demo'));
