-- 035_energie.sql
-- Module « Énergie et confort » : l'écran de l'immotique dans CoHabitat.
--
-- L'immeuble mesure son énergie, son eau chaude et ses incidents ; cette
-- migration donne une place à ces mesures et décide qui les voit.
-- L'application affiche, elle ne pilote rien : aucune table ici ne sert à
-- commander un équipement.
--
-- Quatre tables, alimentées par le compte appareil de l'immeuble
-- (@device.local, même convention que la serre, voir
-- serre_is_capteur() dans la migration 014) ou par un admin :
--
--   immeuble_etat         l'état de l'immeuble (normal, panne Hydro,
--                         panne internet, exercice) et son niveau
--                         (vert, bleu, orange). La ligne la plus récente
--                         fait foi.
--   energie_lectures      les mesures de l'immeuble : solaire, batterie,
--                         réseau, réservoir d'eau chaude.
--   eau_chaude_compteurs  la consommation d'eau chaude de chaque
--                         logement, un total par jour.
--   immeuble_alertes      fuite, gel, panne… pour un logement ou pour
--                         l'immeuble entier.
--
-- Ce que voit qui :
--   · l'état et les mesures de l'immeuble sont des données de bâtiment,
--     lisibles par tout compte authentifié ;
--   · les compteurs d'un logement ne sont lisibles que par ses résidants
--     et par les admins. Un voisin n'y a jamais accès ; la comparaison
--     passe par eau_chaude_moyenne(), qui ne renvoie que des moyennes ;
--   · une alerte de logement n'est lisible que par ce logement et les
--     admins ; une alerte d'immeuble par tous.
--
-- Une alerte prévient la bonne personne : les résidants du logement
-- concerné, ou les admins pour une alerte d'immeuble. Le déclencheur
-- immeuble_alertes_notifier() écrit dans notifications.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ---------------------------------------------------------------------
-- 0) Aides
-- ---------------------------------------------------------------------
-- Le logement du compte connecté. SECURITY DEFINER : les politiques
-- ci-dessous s'en servent sans dépendre de celles de profiles.
CREATE OR REPLACE FUNCTION energie_mon_logement()
RETURNS TEXT AS $$
  SELECT NULLIF(TRIM(unit), '') FROM profiles WHERE id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;

-- Admin, ou compte appareil de l'immeuble (pont des capteurs).
CREATE OR REPLACE FUNCTION energie_peut_ecrire()
RETURNS BOOLEAN AS $$
  SELECT get_my_role() IN ('admin', 'principal_admin') OR serre_is_capteur();
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;

-- ---------------------------------------------------------------------
-- 1) État de l'immeuble
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS immeuble_etat (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  horodatage TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mode TEXT NOT NULL DEFAULT 'normal'
    CHECK (mode IN ('normal', 'panne_hydro', 'panne_internet', 'exercice')),
  niveau TEXT NOT NULL DEFAULT 'vert'
    CHECK (niveau IN ('vert', 'bleu', 'orange')),
  message TEXT,
  created_by UUID REFERENCES profiles(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_immeuble_etat_horodatage ON immeuble_etat(horodatage DESC);

-- ---------------------------------------------------------------------
-- 2) Mesures de l'immeuble
-- ---------------------------------------------------------------------
-- Toutes les colonnes sont facultatives : un immeuble sans batterie ou
-- sans réservoir solaire publie simplement les mesures qu'il a.
CREATE TABLE IF NOT EXISTS energie_lectures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  horodatage TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  solaire_kw NUMERIC,              -- production instantanée
  solaire_kwh_jour NUMERIC,        -- production cumulée depuis minuit
  batterie_pct NUMERIC CHECK (batterie_pct IS NULL OR batterie_pct BETWEEN 0 AND 100),
  reseau_kw NUMERIC,               -- puissance tirée du réseau (négatif = injection)
  reservoir_temp NUMERIC,          -- réservoir d'eau chaude solaire (°C)
  eau_chaude_couverture_pct NUMERIC
    CHECK (eau_chaude_couverture_pct IS NULL OR eau_chaude_couverture_pct BETWEEN 0 AND 100),
  created_by UUID REFERENCES profiles(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_energie_lectures_horodatage ON energie_lectures(horodatage DESC);

-- ---------------------------------------------------------------------
-- 3) Eau chaude par logement
-- ---------------------------------------------------------------------
-- Un total par logement et par jour. Le logement est désigné comme dans
-- profiles.unit (« B-204 ») : c'est ce qui relie un compteur à ses
-- résidants sans stocker de nom.
CREATE TABLE IF NOT EXISTS eau_chaude_compteurs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  jour DATE NOT NULL,
  unit TEXT NOT NULL,
  litres NUMERIC NOT NULL CHECK (litres >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (jour, unit)
);
CREATE INDEX IF NOT EXISTS idx_eau_chaude_unit_jour ON eau_chaude_compteurs(unit, jour DESC);

-- Moyenne de l'immeuble par logement, sur une période. Ne renvoie que des
-- agrégats, et rien du tout sous trois logements mesurés : avec deux
-- logements, la moyenne et sa propre consommation donneraient celle du
-- voisin.
CREATE OR REPLACE FUNCTION eau_chaude_moyenne(p_debut DATE, p_fin DATE)
RETURNS TABLE (litres_moyens NUMERIC, nb_logements INT) AS $$
  WITH par_logement AS (
    SELECT unit, SUM(litres) AS total
    FROM eau_chaude_compteurs
    WHERE jour BETWEEN p_debut AND p_fin
    GROUP BY unit
  )
  SELECT ROUND(AVG(total), 1), COUNT(*)::INT
  FROM par_logement
  HAVING COUNT(*) >= 3;
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;

-- ---------------------------------------------------------------------
-- 4) Alertes
-- ---------------------------------------------------------------------
-- unit NULL = alerte d'immeuble (gel d'un local commun, panne générale).
CREATE TABLE IF NOT EXISTS immeuble_alertes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  horodatage TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  type TEXT NOT NULL CHECK (type IN ('fuite', 'gel', 'panne', 'autre')),
  gravite TEXT NOT NULL DEFAULT 'attention' CHECK (gravite IN ('info', 'attention', 'urgence')),
  unit TEXT,
  titre TEXT NOT NULL,
  message TEXT,
  nb_notifies INT NOT NULL DEFAULT 0,  -- personnes prévenues, posé par le déclencheur
  resolue_le TIMESTAMPTZ,
  created_by UUID REFERENCES profiles(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_immeuble_alertes_horodatage ON immeuble_alertes(horodatage DESC);
CREATE INDEX IF NOT EXISTS idx_immeuble_alertes_unit ON immeuble_alertes(unit);

-- Prévenir la bonne personne, pas tout l'immeuble : les résidants actifs
-- du logement, ou les admins pour une alerte d'immeuble. Les comptes
-- appareil (@device.local) ne sont jamais destinataires.
CREATE OR REPLACE FUNCTION immeuble_alertes_notifier()
RETURNS TRIGGER AS $$
DECLARE
  v_type TEXT := CASE NEW.gravite WHEN 'urgence' THEN 'error'
                                  WHEN 'attention' THEN 'warning'
                                  ELSE 'info' END;
  v_nb INT;
BEGIN
  INSERT INTO notifications (user_id, title, message, type, reference_id, reference_type)
  SELECT p.id, NEW.titre, COALESCE(NEW.message, NEW.titre), v_type, NEW.id, 'immeuble_alerte'
  FROM profiles p
  WHERE COALESCE(p.is_active, TRUE)
    AND LOWER(p.email) NOT LIKE '%@device.local'
    AND CASE WHEN NEW.unit IS NULL
             THEN p.role IN ('admin', 'principal_admin')
             ELSE NULLIF(TRIM(p.unit), '') = NEW.unit END;
  GET DIAGNOSTICS v_nb = ROW_COUNT;
  NEW.nb_notifies := v_nb;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_immeuble_alertes_notifier ON immeuble_alertes;
CREATE TRIGGER trg_immeuble_alertes_notifier
  BEFORE INSERT ON immeuble_alertes
  FOR EACH ROW EXECUTE FUNCTION immeuble_alertes_notifier();

-- ---------------------------------------------------------------------
-- 5) Politiques
-- ---------------------------------------------------------------------
ALTER TABLE immeuble_etat        ENABLE ROW LEVEL SECURITY;
ALTER TABLE energie_lectures     ENABLE ROW LEVEL SECURITY;
ALTER TABLE eau_chaude_compteurs ENABLE ROW LEVEL SECURITY;
ALTER TABLE immeuble_alertes     ENABLE ROW LEVEL SECURITY;

-- Données de bâtiment : lisibles par tous les comptes authentifiés.
DROP POLICY IF EXISTS immeuble_etat_select ON immeuble_etat;
CREATE POLICY immeuble_etat_select ON immeuble_etat
  FOR SELECT TO authenticated USING (TRUE);
DROP POLICY IF EXISTS energie_lectures_select ON energie_lectures;
CREATE POLICY energie_lectures_select ON energie_lectures
  FOR SELECT TO authenticated USING (TRUE);

-- Compteurs : son propre logement seulement, ou tout pour un admin.
DROP POLICY IF EXISTS eau_chaude_select ON eau_chaude_compteurs;
CREATE POLICY eau_chaude_select ON eau_chaude_compteurs
  FOR SELECT TO authenticated
  USING (unit = energie_mon_logement() OR get_my_role() IN ('admin', 'principal_admin'));

-- Alertes : son logement et l'immeuble, ou tout pour un admin.
DROP POLICY IF EXISTS immeuble_alertes_select ON immeuble_alertes;
CREATE POLICY immeuble_alertes_select ON immeuble_alertes
  FOR SELECT TO authenticated
  USING (unit IS NULL OR unit = energie_mon_logement()
         OR get_my_role() IN ('admin', 'principal_admin'));

-- Écriture : admins et compte appareil, sur les quatre tables.
-- La suppression reste aux admins : le compte appareil ajoute, il n'efface
-- pas l'historique.
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['immeuble_etat', 'energie_lectures', 'eau_chaude_compteurs', 'immeuble_alertes'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_insert', t);
    EXECUTE format('CREATE POLICY %I ON %I FOR INSERT TO authenticated WITH CHECK (energie_peut_ecrire())',
                   t || '_insert', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_update', t);
    EXECUTE format('CREATE POLICY %I ON %I FOR UPDATE TO authenticated USING (energie_peut_ecrire()) WITH CHECK (energie_peut_ecrire())',
                   t || '_update', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_delete', t);
    EXECUTE format('CREATE POLICY %I ON %I FOR DELETE TO authenticated USING (get_my_role() IN (''admin'', ''principal_admin''))',
                   t || '_delete', t);
  END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION eau_chaude_moyenne(DATE, DATE) TO authenticated;

-- ---------------------------------------------------------------------
-- 6) Interrupteur du module, coupé par défaut
-- ---------------------------------------------------------------------
INSERT INTO system_settings (key, value, description) VALUES
  ('module_energie', 'false', 'Module Énergie et confort : état de l''immeuble, eau chaude par logement et alertes')
ON CONFLICT (key) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
