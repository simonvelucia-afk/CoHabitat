-- 034_mobilite_couts.sql
-- Frais d'exploitation du parc, et le calcul qui protege la marge.
--
-- Les tarifs de la mobilite partagee doivent couvrir les frais et laisser
-- une marge de securite au batiment. Jusqu'ici rien ne permettait de le
-- verifier : les frais n'etaient nulle part, on reglait les tarifs au
-- jugement. La serre et les elevages ont leur table de couts depuis la
-- migration 011 ; le parc n'en avait pas.
--
-- Cette migration ajoute la table, puis une fonction qui repond a la
-- seule question qui compte : au rythme actuel, les tarifs tiennent-ils
-- la marge visee, et sinon, quels tarifs la tiendraient ?
--
-- Le resultat est reserve aux admins. Le residant voit ce que son tarif
-- couvre — l'accordeon de la page Mobilite le lui dit — jamais la marge
-- ni la politique de prix derriere.

BEGIN;

-- ---------------------------------------------------------------------
-- 1) Les frais
-- ---------------------------------------------------------------------
-- `vehicle_id` NULL = frais de flotte, qui ne s'attribuent a aucun
-- vehicule : l'entretien des bornes de recharge, l'assurance groupee.
--
-- `nature` est la cle du calcul. Un frais fixe court avec le temps, que
-- le vehicule roule ou non ; un frais variable suit les kilometres. Les
-- confondre ramenerait au probleme que la migration 032 a corrige — un
-- seul tarif pour deux natures de couts.
CREATE TABLE IF NOT EXISTS vehicle_couts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id  UUID REFERENCES vehicles(id) ON DELETE CASCADE,
  date_cout   DATE NOT NULL DEFAULT CURRENT_DATE,
  categorie   TEXT NOT NULL,
  nature      TEXT NOT NULL DEFAULT 'fixe' CHECK (nature IN ('fixe', 'variable')),
  montant     NUMERIC(10,2) NOT NULL CHECK (montant >= 0),
  description TEXT,
  created_by  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS vehicle_couts_date_idx    ON vehicle_couts (date_cout DESC);
CREATE INDEX IF NOT EXISTS vehicle_couts_vehicle_idx ON vehicle_couts (vehicle_id, date_cout DESC);

COMMENT ON TABLE vehicle_couts IS
  'Frais d''exploitation du parc. nature=fixe : ce qui court avec le temps
  (assurance, amortissement, stationnement, entretien du reseau de
  recharge). nature=variable : ce qui suit les kilometres (electricite de
  recharge, pneus, freins, entretien mecanique).';
COMMENT ON COLUMN vehicle_couts.vehicle_id IS
  'NULL = frais de flotte, non attribuable a un vehicule (bornes de
  recharge, assurance groupee).';

ALTER TABLE vehicle_couts ENABLE ROW LEVEL SECURITY;

-- Reserve aux admins, en lecture comme en ecriture : ce sont les chiffres
-- d'exploitation du batiment, pas une information de residant.
DROP POLICY IF EXISTS vehicle_couts_admin ON vehicle_couts;
CREATE POLICY vehicle_couts_admin ON vehicle_couts
  FOR ALL TO authenticated
  USING (get_my_role() IN ('admin', 'principal_admin'))
  WITH CHECK (get_my_role() IN ('admin', 'principal_admin'));

-- ---------------------------------------------------------------------
-- 2) Le tarif qui tient la marge
-- ---------------------------------------------------------------------
-- Sur une periode donnee, la fonction rapproche ce qui est entre de ce
-- qui est sorti, puis calcule les tarifs qu'il aurait fallu pour couvrir
-- les frais ET degager la marge visee.
--
-- Chaque nature de frais se rapporte a son assiette : les frais fixes aux
-- minutes reellement facturees, les variables aux kilometres. Diviser les
-- deux par la meme assiette donnerait un tarif juste en moyenne et faux
-- pour tout le monde — cher pour qui garde le vehicule sans rouler, offert
-- pour qui roule sans le garder.
--
-- Les tarifs renvoyes sont des MOYENNES DE FLOTTE : chaque vehicule a les
-- siens, et l'un d'eux tarife sous la moyenne — un velomobile a 0,02 $/min
-- — est porte par les autres. C'est un choix d'exploitation defendable,
-- mais il explique qu'on puisse rester sous la marge visee alors que
-- chaque tarif pris isolement parait suffisant. La fonction ne tranche
-- pas ce choix, elle le rend visible.
--
-- p_marge_cible : 0.15 pour 15 %. La valeur n'est pas ecrite en dur ici,
-- l'appelant la fournit — c'est une decision d'exploitation, pas une
-- constante de schema.
CREATE OR REPLACE FUNCTION vehicle_marge(
  p_debut       DATE,
  p_fin         DATE,
  p_marge_cible NUMERIC DEFAULT 0.15
)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_revenus   NUMERIC := 0;
  v_fixes     NUMERIC := 0;
  v_variables NUMERIC := 0;
  v_minutes   NUMERIC := 0;
  v_km        NUMERIC := 0;
  v_couts     NUMERIC;
  v_marge     NUMERIC;
BEGIN
  IF get_my_role() NOT IN ('admin', 'principal_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  -- Ce qui est entre, et sur quelle assiette. Seules les reservations
  -- rendues comptent : une reservation en cours n'a pas encore de montant
  -- definitif, et une annulee n'a rien rapporte.
  SELECT COALESCE(SUM(total_cost), 0),
         COALESCE(SUM(total_minutes), 0),
         COALESCE(SUM(total_km), 0)
    INTO v_revenus, v_minutes, v_km
    FROM vehicle_reservations
   WHERE status = 'completed'
     AND returned_at >= p_debut
     AND returned_at <  (p_fin + 1);

  SELECT COALESCE(SUM(montant) FILTER (WHERE nature = 'fixe'), 0),
         COALESCE(SUM(montant) FILTER (WHERE nature = 'variable'), 0)
    INTO v_fixes, v_variables
    FROM vehicle_couts
   WHERE date_cout >= p_debut AND date_cout <= p_fin;

  v_couts := v_fixes + v_variables;
  v_marge := v_revenus - v_couts;

  RETURN jsonb_build_object(
    'revenus',        ROUND(v_revenus, 2),
    'couts_fixes',    ROUND(v_fixes, 2),
    'couts_variables',ROUND(v_variables, 2),
    'couts',          ROUND(v_couts, 2),
    'marge',          ROUND(v_marge, 2),
    -- Marge realisee en part du revenu. Sans revenu, la question n'a pas
    -- de sens : on renvoie NULL plutot qu'un zero trompeur.
    'taux',           CASE WHEN v_revenus > 0 THEN ROUND(v_marge / v_revenus, 4) END,
    'minutes',        v_minutes,
    'km',             ROUND(v_km, 1),
    -- Tarifs qui auraient couvert les frais de leur nature et degage la
    -- marge visee sur la meme periode. NULL quand l'assiette est vide :
    -- sans minutes facturees, aucun tarif a la minute ne peut rien
    -- couvrir, et une division donnerait un chiffre inventé.
    'tarif_min_cible', CASE WHEN v_minutes > 0
                            THEN ROUND(v_fixes / v_minutes / (1 - p_marge_cible), 4) END,
    'tarif_km_cible',  CASE WHEN v_km > 0
                            THEN ROUND(v_variables / v_km / (1 - p_marge_cible), 4) END,
    'marge_cible',     p_marge_cible
  );
END;
$$;
REVOKE ALL ON FUNCTION vehicle_marge(DATE, DATE, NUMERIC) FROM public, anon;
GRANT  EXECUTE ON FUNCTION vehicle_marge(DATE, DATE, NUMERIC) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
