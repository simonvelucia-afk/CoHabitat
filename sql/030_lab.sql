-- 030_lab.sql
-- LAB — amelioration continue.
--
-- Le LAB vit sous le Babillard : le babillard sert a la vie de
-- l'immeuble, le LAB sert a la vie de l'application elle-meme. Les
-- residents y notent les fonctions existantes, expliquent ce qui les
-- gene, et proposent ce qui manque. Ce qui remonte alimente directement
-- les prochaines versions : l'app reste en amelioration continue.
--
-- Tables creees :
--   * lab_evaluations       : une note (1-5) + commentaire par personne
--                             et par fonction. Une seule ligne par couple
--                             (user_id, fonction) : reevaluer met a jour.
--   * lab_idees             : amelioration ou nouvelle fonction a
--                             brainstormer. Cycle : nouveau -> a_l_etude
--                             -> planifie -> en_cours -> livre / ecarte.
--   * lab_idee_votes        : un vote par personne et par idee.
--   * lab_idee_commentaires : discussion sous une idee.
--
-- RLS : tout le monde lit tout (c'est un espace collectif, comme le
-- babillard), chacun n'ecrit que ses propres lignes, l'admin arbitre les
-- statuts et peut faire le menage.

BEGIN;

-- ============================================================
-- 1) Evaluations des fonctions existantes
-- ============================================================
-- `fonction` est une cle courte cote client (LAB_FONCTIONS dans
-- index.html) plutot qu'une table de reference : la liste des fonctions
-- suit le code de l'app, pas les donnees. Une fonction retiree du code
-- laisse simplement ses evaluations orphelines, sans casser la table.
CREATE TABLE IF NOT EXISTS lab_evaluations (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  fonction     TEXT NOT NULL,
  note         SMALLINT NOT NULL CHECK (note BETWEEN 1 AND 5),
  commentaire  TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT lab_eval_fonction_len    CHECK (char_length(fonction) BETWEEN 1 AND 60),
  CONSTRAINT lab_eval_commentaire_len CHECK (commentaire IS NULL OR char_length(commentaire) <= 2000),
  CONSTRAINT lab_eval_unique UNIQUE (user_id, fonction)
);

CREATE INDEX IF NOT EXISTS lab_evaluations_fonction_idx ON lab_evaluations (fonction);

CREATE OR REPLACE FUNCTION trg_lab_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_lab_evaluations_updated_at ON lab_evaluations;
CREATE TRIGGER trigger_lab_evaluations_updated_at
  BEFORE UPDATE ON lab_evaluations
  FOR EACH ROW EXECUTE FUNCTION trg_lab_touch_updated_at();

-- ============================================================
-- 2) Idees (ameliorations et nouvelles fonctions)
-- ============================================================
CREATE TABLE IF NOT EXISTS lab_idees (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  type         TEXT NOT NULL DEFAULT 'amelioration' CHECK (type IN ('amelioration','nouveaute')),
  fonction     TEXT,                 -- fonction visee, NULL si l'idee n'en cible aucune
  titre        TEXT NOT NULL,
  description  TEXT NOT NULL,
  statut       TEXT NOT NULL DEFAULT 'nouveau'
               CHECK (statut IN ('nouveau','a_l_etude','planifie','en_cours','livre','ecarte')),
  reponse      TEXT,                 -- mot de l'admin : pourquoi planifie, pourquoi ecarte
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT lab_idees_titre_len  CHECK (char_length(titre) BETWEEN 3 AND 160),
  CONSTRAINT lab_idees_descr_len  CHECK (char_length(description) BETWEEN 1 AND 4000),
  CONSTRAINT lab_idees_reponse_len CHECK (reponse IS NULL OR char_length(reponse) <= 2000)
);

CREATE INDEX IF NOT EXISTS lab_idees_statut_idx ON lab_idees (statut, created_at DESC);
CREATE INDEX IF NOT EXISTS lab_idees_user_idx   ON lab_idees (user_id, created_at DESC);

DROP TRIGGER IF EXISTS trigger_lab_idees_updated_at ON lab_idees;
CREATE TRIGGER trigger_lab_idees_updated_at
  BEFORE UPDATE ON lab_idees
  FOR EACH ROW EXECUTE FUNCTION trg_lab_touch_updated_at();

-- ============================================================
-- 3) Votes
-- ============================================================
-- Une idee qui recolte des voix passe devant : c'est la seule
-- priorisation dont dispose la communaute.
CREATE TABLE IF NOT EXISTS lab_idee_votes (
  idee_id     UUID NOT NULL REFERENCES lab_idees(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (idee_id, user_id)
);

CREATE INDEX IF NOT EXISTS lab_idee_votes_user_idx ON lab_idee_votes (user_id);

-- ============================================================
-- 4) Commentaires
-- ============================================================
CREATE TABLE IF NOT EXISTS lab_idee_commentaires (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  idee_id     UUID NOT NULL REFERENCES lab_idees(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  contenu     TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT lab_commentaires_len CHECK (char_length(contenu) BETWEEN 1 AND 2000)
);

CREATE INDEX IF NOT EXISTS lab_idee_commentaires_idee_idx ON lab_idee_commentaires (idee_id, created_at);

-- ============================================================
-- 5) RLS
-- ============================================================
ALTER TABLE lab_evaluations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE lab_idees             ENABLE ROW LEVEL SECURITY;
ALTER TABLE lab_idee_votes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE lab_idee_commentaires ENABLE ROW LEVEL SECURITY;

-- Helper : le caller est-il admin ? Inline plutot que get_my_role(), pour
-- la meme raison que is_ticket_staff() dans 005_tickets.sql.
CREATE OR REPLACE FUNCTION is_lab_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND role IN ('admin','principal_admin')
  );
$$;
REVOKE ALL ON FUNCTION is_lab_admin() FROM public, anon;
GRANT  EXECUTE ON FUNCTION is_lab_admin() TO authenticated;

-- lab_evaluations : tout le monde lit (les moyennes n'ont de sens qu'a
-- l'echelle du groupe), chacun n'ecrit que sa propre note.
DROP POLICY IF EXISTS lab_eval_select ON lab_evaluations;
CREATE POLICY lab_eval_select ON lab_evaluations
  FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS lab_eval_insert ON lab_evaluations;
CREATE POLICY lab_eval_insert ON lab_evaluations
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS lab_eval_update ON lab_evaluations;
CREATE POLICY lab_eval_update ON lab_evaluations
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS lab_eval_delete ON lab_evaluations;
CREATE POLICY lab_eval_delete ON lab_evaluations
  FOR DELETE TO authenticated
  USING (user_id = auth.uid() OR is_lab_admin());

-- lab_idees : lecture ouverte. L'auteur corrige son texte tant que
-- personne n'a statue dessus (statut 'nouveau') ; passe ce point, c'est
-- l'admin qui tient le statut et la reponse.
DROP POLICY IF EXISTS lab_idees_select ON lab_idees;
CREATE POLICY lab_idees_select ON lab_idees
  FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS lab_idees_insert ON lab_idees;
CREATE POLICY lab_idees_insert ON lab_idees
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND statut = 'nouveau');

DROP POLICY IF EXISTS lab_idees_update ON lab_idees;
CREATE POLICY lab_idees_update ON lab_idees
  FOR UPDATE TO authenticated
  USING (is_lab_admin() OR (user_id = auth.uid() AND statut = 'nouveau'))
  WITH CHECK (is_lab_admin() OR (user_id = auth.uid() AND statut = 'nouveau'));

DROP POLICY IF EXISTS lab_idees_delete ON lab_idees;
CREATE POLICY lab_idees_delete ON lab_idees
  FOR DELETE TO authenticated
  USING (user_id = auth.uid() OR is_lab_admin());

-- lab_idee_votes : un vote se donne et se retire, jamais au nom d'un autre.
DROP POLICY IF EXISTS lab_votes_select ON lab_idee_votes;
CREATE POLICY lab_votes_select ON lab_idee_votes
  FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS lab_votes_insert ON lab_idee_votes;
CREATE POLICY lab_votes_insert ON lab_idee_votes
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS lab_votes_delete ON lab_idee_votes;
CREATE POLICY lab_votes_delete ON lab_idee_votes
  FOR DELETE TO authenticated USING (user_id = auth.uid());

-- lab_idee_commentaires : pas d'UPDATE (le fil reste tel qu'ecrit).
DROP POLICY IF EXISTS lab_comm_select ON lab_idee_commentaires;
CREATE POLICY lab_comm_select ON lab_idee_commentaires
  FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS lab_comm_insert ON lab_idee_commentaires;
CREATE POLICY lab_comm_insert ON lab_idee_commentaires
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS lab_comm_delete ON lab_idee_commentaires;
CREATE POLICY lab_comm_delete ON lab_idee_commentaires
  FOR DELETE TO authenticated
  USING (user_id = auth.uid() OR is_lab_admin());

-- ============================================================
-- 6) Commentaires de table
-- ============================================================
COMMENT ON TABLE lab_evaluations IS
  'LAB : note 1-5 et commentaire d''un resident sur une fonction de
  l''app. Une ligne par (user_id, fonction) ; reevaluer met a jour.';

COMMENT ON TABLE lab_idees IS
  'LAB : amelioration demandee ou nouvelle fonction a brainstormer.
  Cycle nouveau -> a_l_etude -> planifie -> en_cours -> livre / ecarte.';

COMMENT ON TABLE lab_idee_votes IS
  'LAB : appui d''un resident a une idee. Sert a la priorisation.';

COMMENT ON TABLE lab_idee_commentaires IS
  'LAB : fil de discussion (brainstorm) sous une idee.';

COMMIT;

NOTIFY pgrst, 'reload schema';
