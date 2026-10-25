-- 036_emplois.sql
-- Emplois de l'immeuble.
--
-- La serre, le poulailler, le covoiturage, la Machine Lunch : l'immeuble a du
-- travail a confier, et des residents prets a le faire. Jusqu'ici, rien
-- ne le disait : on cherchait quelqu'un de bouche a oreille, et les
-- heures se notaient sur un bout de papier.
--
-- Un emploi se presente comme une offre : un poste (« Responsable de la
-- serre », « Employe du poulailler », « Responsable de l'unite
-- d'affaires covoiturage »), un secteur, un niveau, ce dont la
-- personne repond (responsabilites) et ce qu'elle fait concretement
-- (taches), un taux horaire. Seuls les administrateurs en publient.
--
-- Le parcours :
--   1. l'admin publie l'offre — elle s'affiche au babillard ;
--   2. le resident postule depuis son profil ;
--   3. l'admin retient (ou refuse) la candidature ;
--   4. la personne retenue declare ses heures depuis son profil ;
--   5. l'admin approuve les heures, puis les remunere — au solde de
--      l'application, ou en dehors (cheque, virement) avec trace.
--
-- Tables creees :
--   * emplois               : les offres.
--   * emploi_candidatures   : une par personne et par offre.
--   * emploi_heures         : les heures declarees, avec le taux fige au
--                             moment de la declaration.
--
-- RLS : tout le monde lit les offres (elles sont affichees au babillard).
-- Candidatures et heures sont privees : chacun voit les siennes, l'admin
-- voit tout. Les transitions sensibles (postuler, se retirer, payer)
-- passent par des fonctions qui verifient l'etat, plutot que par des
-- politiques d'ecriture qu'il faudrait borner colonne par colonne.
--
-- Idempotente : peut etre rejouee sans erreur.

BEGIN;

-- ============================================================
-- 1) Offres
-- ============================================================
-- `responsabilites` et `taches` : une par ligne, en texte libre. Une
-- table de lignes serait plus « propre », mais l'admin les ecrit d'un
-- trait comme dans une vraie offre, et le client les met en liste.
--
-- `secteur` rattache l'emploi a une unite d'affaires de l'immeuble :
-- serre, poulailler, sabloponie, mobilite partagee (covoiturage et
-- vehicules), Machine Lunch, entretien. Pour le
-- poulailler et la sabloponie, il ouvre les droits d'operateur de
-- l'elevage a la personne retenue (voir section 5).
CREATE TABLE IF NOT EXISTS emplois (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  titre            TEXT NOT NULL,
  secteur          TEXT NOT NULL DEFAULT 'autre'
                   CHECK (secteur IN ('serre','poulailler','sabloponie','mobilite','lunch',
                                     'entretien','autre')),
  niveau           TEXT NOT NULL DEFAULT 'employe'
                   CHECK (niveau IN ('responsable','employe')),
  description      TEXT,
  responsabilites  TEXT,
  taches           TEXT,
  taux_horaire     NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (taux_horaire >= 0),
  heures_semaine   NUMERIC(5,2) CHECK (heures_semaine IS NULL OR heures_semaine > 0),
  nb_postes        INT NOT NULL DEFAULT 1 CHECK (nb_postes BETWEEN 1 AND 50),
  date_debut       DATE,
  statut           TEXT NOT NULL DEFAULT 'ouvert'
                   CHECK (statut IN ('ouvert','pourvu','ferme')),
  created_by       UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT emplois_titre_len  CHECK (char_length(titre) BETWEEN 3 AND 160),
  CONSTRAINT emplois_descr_len  CHECK (description     IS NULL OR char_length(description)     <= 4000),
  CONSTRAINT emplois_resp_len   CHECK (responsabilites IS NULL OR char_length(responsabilites) <= 4000),
  CONSTRAINT emplois_taches_len CHECK (taches          IS NULL OR char_length(taches)          <= 4000)
);

CREATE INDEX IF NOT EXISTS emplois_statut_idx ON emplois (statut, created_at DESC);

CREATE OR REPLACE FUNCTION trg_emplois_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_emplois_updated_at ON emplois;
CREATE TRIGGER trigger_emplois_updated_at
  BEFORE UPDATE ON emplois
  FOR EACH ROW EXECUTE FUNCTION trg_emplois_touch_updated_at();

-- ============================================================
-- 2) Candidatures
-- ============================================================
-- Une seule ligne par personne et par offre. Se retirer puis repostuler
-- reutilise la ligne (statut remis a en_attente) plutot que d'en creer
-- une seconde.
CREATE TABLE IF NOT EXISTS emploi_candidatures (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  emploi_id    UUID NOT NULL REFERENCES emplois(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  message      TEXT,
  statut       TEXT NOT NULL DEFAULT 'en_attente'
               CHECK (statut IN ('en_attente','retenue','refusee','retiree')),
  note_admin   TEXT,
  decided_by   UUID REFERENCES profiles(id) ON DELETE SET NULL,
  decided_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT emploi_cand_message_len CHECK (message    IS NULL OR char_length(message)    <= 2000),
  CONSTRAINT emploi_cand_note_len    CHECK (note_admin IS NULL OR char_length(note_admin) <= 2000),
  CONSTRAINT emploi_cand_unique UNIQUE (emploi_id, user_id)
);

CREATE INDEX IF NOT EXISTS emploi_candidatures_user_idx ON emploi_candidatures (user_id, created_at DESC);

DROP TRIGGER IF EXISTS trigger_emploi_candidatures_updated_at ON emploi_candidatures;
CREATE TRIGGER trigger_emploi_candidatures_updated_at
  BEFORE UPDATE ON emploi_candidatures
  FOR EACH ROW EXECUTE FUNCTION trg_emplois_touch_updated_at();

-- ============================================================
-- 3) Heures
-- ============================================================
-- Le taux est fige a la declaration : si l'admin revise le taux de
-- l'offre plus tard, les heures deja faites restent payees au taux
-- convenu a l'epoque. Le montant en decoule, il n'est jamais saisi.
--
-- Cycle : soumise -> approuvee -> payee
--                 \-> refusee
CREATE TABLE IF NOT EXISTS emploi_heures (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  emploi_id      UUID NOT NULL REFERENCES emplois(id) ON DELETE RESTRICT,
  user_id        UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  date_travail   DATE NOT NULL,
  heures         NUMERIC(5,2) NOT NULL CHECK (heures > 0 AND heures <= 24),
  description    TEXT,
  taux_horaire   NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (taux_horaire >= 0),
  montant        NUMERIC(10,2) GENERATED ALWAYS AS (round(heures * taux_horaire, 2)) STORED,
  statut         TEXT NOT NULL DEFAULT 'soumise'
                 CHECK (statut IN ('soumise','approuvee','refusee','payee')),
  motif_refus    TEXT,
  approuvee_par  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  approuvee_le   TIMESTAMPTZ,
  mode_paiement  TEXT CHECK (mode_paiement IS NULL OR mode_paiement IN ('solde','externe')),
  payee_par      UUID REFERENCES profiles(id) ON DELETE SET NULL,
  payee_le       TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT emploi_heures_descr_len CHECK (description IS NULL OR char_length(description) <= 1000),
  CONSTRAINT emploi_heures_motif_len CHECK (motif_refus IS NULL OR char_length(motif_refus) <= 1000)
);

CREATE INDEX IF NOT EXISTS emploi_heures_user_idx   ON emploi_heures (user_id, date_travail DESC);
CREATE INDEX IF NOT EXISTS emploi_heures_statut_idx ON emploi_heures (statut, date_travail);

-- Le resident ne choisit ni son taux ni son statut : on les impose a
-- l'insertion, quoi que le client ait envoye. L'admin, lui, peut saisir
-- des heures pour quelqu'un (feuille papier rattrapee) ; le taux de
-- l'offre s'applique aussi.
CREATE OR REPLACE FUNCTION trg_emploi_heures_avant_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  SELECT taux_horaire INTO NEW.taux_horaire FROM emplois WHERE id = NEW.emploi_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOI_INTROUVABLE'; END IF;
  IF get_my_role() NOT IN ('admin','principal_admin') THEN
    NEW.statut        := 'soumise';
    NEW.motif_refus   := NULL;
    NEW.approuvee_par := NULL;
    NEW.approuvee_le  := NULL;
    NEW.mode_paiement := NULL;
    NEW.payee_par     := NULL;
    NEW.payee_le      := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_emploi_heures_avant_insert ON emploi_heures;
CREATE TRIGGER trigger_emploi_heures_avant_insert
  BEFORE INSERT ON emploi_heures
  FOR EACH ROW EXECUTE FUNCTION trg_emploi_heures_avant_insert();

-- ============================================================
-- 4) RLS
-- ============================================================
ALTER TABLE emplois             ENABLE ROW LEVEL SECURITY;
ALTER TABLE emploi_candidatures ENABLE ROW LEVEL SECURITY;
ALTER TABLE emploi_heures       ENABLE ROW LEVEL SECURITY;

-- Offres : lecture pour tous, ecriture admin.
DROP POLICY IF EXISTS emplois_lecture ON emplois;
CREATE POLICY emplois_lecture ON emplois
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS emplois_admin ON emplois;
CREATE POLICY emplois_admin ON emplois
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','principal_admin'))
  WITH CHECK (get_my_role() IN ('admin','principal_admin'));

-- Candidatures : chacun lit les siennes ; l'ecriture du resident passe
-- par emploi_postuler() / emploi_retirer_candidature().
DROP POLICY IF EXISTS emploi_candidatures_lecture ON emploi_candidatures;
CREATE POLICY emploi_candidatures_lecture ON emploi_candidatures
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR get_my_role() IN ('admin','principal_admin'));

DROP POLICY IF EXISTS emploi_candidatures_admin ON emploi_candidatures;
CREATE POLICY emploi_candidatures_admin ON emploi_candidatures
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','principal_admin'))
  WITH CHECK (get_my_role() IN ('admin','principal_admin'));

-- Heures : chacun lit les siennes. Le resident declare des heures
-- seulement sur un emploi ou il est retenu, jamais dans le futur, et ne
-- peut retirer qu'une declaration pas encore traitee.
DROP POLICY IF EXISTS emploi_heures_lecture ON emploi_heures;
CREATE POLICY emploi_heures_lecture ON emploi_heures
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR get_my_role() IN ('admin','principal_admin'));

DROP POLICY IF EXISTS emploi_heures_declarer ON emploi_heures;
CREATE POLICY emploi_heures_declarer ON emploi_heures
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND date_travail <= current_date
    AND EXISTS (
      SELECT 1 FROM emploi_candidatures c
       WHERE c.emploi_id = emploi_heures.emploi_id
         AND c.user_id   = auth.uid()
         AND c.statut    = 'retenue'
    )
  );

DROP POLICY IF EXISTS emploi_heures_retirer ON emploi_heures;
CREATE POLICY emploi_heures_retirer ON emploi_heures
  FOR DELETE TO authenticated
  USING (user_id = auth.uid() AND statut = 'soumise');

DROP POLICY IF EXISTS emploi_heures_admin ON emploi_heures;
CREATE POLICY emploi_heures_admin ON emploi_heures
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin','principal_admin'))
  WITH CHECK (get_my_role() IN ('admin','principal_admin'));

-- ============================================================
-- 5) Embauche : postes pourvus et droits d'operateur
-- ============================================================
-- Quand une candidature devient « retenue » :
--   * l'offre passe a « pourvu » des que tous ses postes sont occupes —
--     elle quitte le babillard d'elle-meme ;
--   * pour le poulailler et la sabloponie, la personne devient
--     operatrice de l'elevage (027) : un employe du poulailler doit
--     pouvoir noter les oeufs ramasses sans etre administrateur.
-- Le droit d'operateur n'est PAS retire automatiquement si la
-- candidature change ensuite : il a pu etre accorde a la main avant
-- l'embauche, et le retirer serait une surprise. L'admin le revoque au
-- volet Production.
CREATE OR REPLACE FUNCTION trg_emploi_candidature_embauche()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_emploi  emplois%ROWTYPE;
  v_retenus INT;
BEGIN
  IF NEW.statut <> 'retenue' OR (TG_OP = 'UPDATE' AND OLD.statut = 'retenue') THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_emploi FROM emplois WHERE id = NEW.emploi_id FOR UPDATE;

  SELECT COUNT(*) INTO v_retenus
    FROM emploi_candidatures
   WHERE emploi_id = NEW.emploi_id AND statut = 'retenue';

  IF v_emploi.statut = 'ouvert' AND v_retenus >= v_emploi.nb_postes THEN
    UPDATE emplois SET statut = 'pourvu' WHERE id = NEW.emploi_id;
  END IF;

  -- L'elevage garde sa cle historique 'sablonponie' (migrations 011 a
  -- 028) ; le secteur, lui, porte l'orthographe juste.
  IF v_emploi.secteur IN ('poulailler','sabloponie') THEN
    INSERT INTO elevage_operateurs (user_id, module, granted_by)
    VALUES (NEW.user_id,
            CASE v_emploi.secteur WHEN 'sabloponie' THEN 'sablonponie' ELSE v_emploi.secteur END,
            COALESCE(NEW.decided_by, auth.uid()))
    ON CONFLICT (user_id, module) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_emploi_candidature_embauche ON emploi_candidatures;
CREATE TRIGGER trigger_emploi_candidature_embauche
  AFTER INSERT OR UPDATE OF statut ON emploi_candidatures
  FOR EACH ROW EXECUTE FUNCTION trg_emploi_candidature_embauche();

-- ============================================================
-- 6) Postuler / se retirer
-- ============================================================
CREATE OR REPLACE FUNCTION emploi_postuler(p_emploi_id UUID, p_message TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_statut TEXT;
  v_id     UUID;
  v_cand   emploi_candidatures%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NON_CONNECTE'; END IF;
  IF get_my_role() = 'demo' THEN RAISE EXCEPTION 'DEMO'; END IF;

  SELECT statut INTO v_statut FROM emplois WHERE id = p_emploi_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOI_INTROUVABLE'; END IF;
  IF v_statut <> 'ouvert' THEN RAISE EXCEPTION 'EMPLOI_FERME'; END IF;

  SELECT * INTO v_cand FROM emploi_candidatures
   WHERE emploi_id = p_emploi_id AND user_id = v_uid
   FOR UPDATE;

  IF FOUND THEN
    -- Seule une candidature retiree se reactive ; une candidature en
    -- attente, retenue ou refusee reste ce qu'elle est.
    IF v_cand.statut <> 'retiree' THEN RAISE EXCEPTION 'DEJA_POSTULE'; END IF;
    UPDATE emploi_candidatures
       SET statut = 'en_attente', message = NULLIF(TRIM(p_message), ''),
           note_admin = NULL, decided_by = NULL, decided_at = NULL
     WHERE id = v_cand.id;
    RETURN v_cand.id;
  END IF;

  INSERT INTO emploi_candidatures (emploi_id, user_id, message)
  VALUES (p_emploi_id, v_uid, NULLIF(TRIM(p_message), ''))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION emploi_retirer_candidature(p_candidature_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE emploi_candidatures
     SET statut = 'retiree'
   WHERE id = p_candidature_id
     AND user_id = auth.uid()
     AND statut IN ('en_attente','retenue');
  IF NOT FOUND THEN RAISE EXCEPTION 'CANDIDATURE_INTROUVABLE'; END IF;
END;
$$;

-- ============================================================
-- 7) Remuneration
-- ============================================================
-- Paie un lot d'heures approuvees, en une transaction :
--   * 'solde'   : chaque ligne credite le solde du resident par
--                 adjust_balance(), avec une trace au grand livre ;
--   * 'externe' : l'immeuble paie hors de l'application (cheque,
--                 virement) ; on marque seulement les heures payees.
-- Les lignes qui ne sont pas « approuvee » sont ignorees : rejouer le
-- meme appel ne paie jamais deux fois.
--
-- ATTENTION : sur une installation branchee a la centrale (finance
-- centralisee), le solde de reference vit a la centrale. Le client n'y
-- propose alors que le mode 'externe', pour ne pas creer un ecart entre
-- le solde local et celui de la centrale.
CREATE OR REPLACE FUNCTION emploi_payer_heures(p_ids UUID[], p_mode TEXT DEFAULT 'solde')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row    RECORD;
  v_nb     INT := 0;
  v_total  NUMERIC := 0;
BEGIN
  IF get_my_role() NOT IN ('admin','principal_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;
  IF p_mode NOT IN ('solde','externe') THEN
    RAISE EXCEPTION 'MODE_INVALIDE';
  END IF;

  FOR v_row IN
    SELECT h.id, h.user_id, h.emploi_id, h.heures, h.taux_horaire, h.montant,
           h.date_travail, e.titre
      FROM emploi_heures h
      JOIN emplois e ON e.id = h.emploi_id
     WHERE h.id = ANY(p_ids) AND h.statut = 'approuvee'
     ORDER BY h.user_id, h.date_travail
     FOR UPDATE OF h
  LOOP
    IF p_mode = 'solde' AND v_row.montant > 0 THEN
      PERFORM adjust_balance(
        v_row.user_id, v_row.montant, 'emploi_remuneration',
        v_row.emploi_id, 'emploi',
        v_row.titre || ' — ' || to_char(v_row.date_travail, 'YYYY-MM-DD')
          || ' — ' || v_row.heures || ' h × ' || v_row.taux_horaire || ' $',
        auth.uid(), FALSE);
    END IF;

    UPDATE emploi_heures
       SET statut = 'payee', mode_paiement = p_mode,
           payee_par = auth.uid(), payee_le = now()
     WHERE id = v_row.id;

    v_nb    := v_nb + 1;
    v_total := v_total + v_row.montant;
  END LOOP;

  RETURN jsonb_build_object('lignes', v_nb, 'total', v_total);
END;
$$;

REVOKE ALL ON FUNCTION emploi_postuler(UUID, TEXT)          FROM public, anon;
REVOKE ALL ON FUNCTION emploi_retirer_candidature(UUID)     FROM public, anon;
REVOKE ALL ON FUNCTION emploi_payer_heures(UUID[], TEXT)    FROM public, anon;
GRANT EXECUTE ON FUNCTION emploi_postuler(UUID, TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION emploi_retirer_candidature(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION emploi_payer_heures(UUID[], TEXT) TO authenticated;

-- ============================================================
-- 8) Ledger : accepter le type de la remuneration
-- ============================================================
-- Liste reprise de sql/031_mobilite_partagee.sql, augmentee de
-- 'emploi_remuneration'.
DO $ck$
BEGIN
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
      'vehicle_reservation',
      'vehicle_reservation_refund',
      'emploi_remuneration',
      'demo'
    ));
END $ck$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- drop function if exists emploi_payer_heures(uuid[], text);
-- drop function if exists emploi_retirer_candidature(uuid);
-- drop function if exists emploi_postuler(uuid, text);
-- drop table if exists emploi_heures;
-- drop table if exists emploi_candidatures;
-- drop table if exists emplois;
-- drop function if exists trg_emploi_candidature_embauche();
-- drop function if exists trg_emploi_heures_avant_insert();
-- drop function if exists trg_emplois_touch_updated_at();
-- -- (le CHECK de transactions.type garde 'emploi_remuneration' : sans
-- --  effet tant qu'aucune ligne ne l'utilise)
-- COMMIT;
