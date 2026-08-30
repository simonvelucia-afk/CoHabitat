-- 032_mobilite_km.sql
-- Facturer les kilometres d'une reservation de vehicule.
--
-- La reservation directe ne facturait que le temps : duree du creneau x
-- tarif a la minute. Ce tarif venait de la formule du covoiturage, ou le
-- cout est (minutes x tarif/min) + (km x tarif/km), ensuite partage entre
-- passagers. N'en garder que la moitie produisait deux distorsions
-- opposees : quelqu'un qui reserve une heure et roule 200 km payait
-- l'heure seule — l'energie et l'usure sortaient de la marge du batiment
-- au lieu d'etre couvertes ; quelqu'un qui garde le vehicule huit heures
-- pour deplacer un meuble payait huit heures de stationnement.
--
-- Le parc n'est pas offert : il est exploite avec une marge de 15 % APRES
-- frais d'exploitation. Or ces frais ont deux natures, et c'est
-- exactement pourquoi il faut deux tarifs :
--
--   * ce qui court avec le temps, que le vehicule roule ou non —
--     assurance, amortissement, stationnement, et l'entretien du reseau
--     de recharge lui-meme, qui coute la meme chose qu'on l'utilise
--     beaucoup ou peu. Le tarif a la minute couvre cette part : reserver,
--     c'est immobiliser le vehicule pour soi ;
--
--   * ce qui court avec la distance — l'electricite reellement consommee
--     a la recharge, les pneus, les freins, l'entretien mecanique. Le
--     tarif au kilometre couvre celle-la.
--
-- Facturer le temps seul revenait a faire porter les deux au meme tarif :
-- on surfacturait le vehicule gare et on offrait l'electricite et l'usure
-- de celui qui roule. La marge s'evaporait donc precisement sur les longs
-- trajets, la ou elle devrait etre la plus grande.
--
-- Les taux eux-memes restent regles par l'admin (tarif/min et tarif/km) :
-- c'est la qu'on loge les frais et la marge, pas dans le code. Encore
-- faut-il que les deux soient reellement factures.
--
-- Les kilometres ne sont connus qu'au retour. La reservation gagne donc
-- une etape : le residant rend le vehicule, declare les km parcourus, et
-- le supplement est debite a ce moment-la. Le temps, lui, reste facture a
-- la reservation — le creneau est retenu qu'il soit utilise ou non, comme
-- une salle commune.
--
-- Aucun nouveau type de transaction : le supplement kilometrique est un
-- 'vehicle_reservation' de plus, avec sa propre cle d'idempotence. La
-- liste blanche de finance-bridge n'a donc pas a rebouger.

BEGIN;

-- ---------------------------------------------------------------------
-- Ce que le retour ajoute a une reservation
-- ---------------------------------------------------------------------
-- total_cost porte le total facture, temps + kilometres. time_cost garde
-- la part temps, deja debitee a la reservation : sans elle, on ne saurait
-- plus quoi rembourser en cas d'annulation, ni distinguer un supplement
-- de zero km d'un retour jamais fait.
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS time_cost   DECIMAL(10,2);
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS total_km    NUMERIC(10,2);
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS km_cost     DECIMAL(10,2);
ALTER TABLE vehicle_reservations ADD COLUMN IF NOT EXISTS returned_at TIMESTAMPTZ;

-- Les lignes creees avant cette migration n'ont paye que le temps : leur
-- total_cost EST leur part temps.
UPDATE vehicle_reservations SET time_cost = total_cost WHERE time_cost IS NULL;

ALTER TABLE vehicle_reservations DROP CONSTRAINT IF EXISTS vehicle_resv_km_positif;
ALTER TABLE vehicle_reservations
  ADD CONSTRAINT vehicle_resv_km_positif
  CHECK (total_km IS NULL OR (total_km >= 0 AND total_km <= 5000));

COMMENT ON COLUMN vehicle_reservations.time_cost IS
  'Part temps du cout, debitee des la reservation (duree du creneau x
  tarif a la minute). C''est elle qui est remboursee a l''annulation.';
COMMENT ON COLUMN vehicle_reservations.total_km IS
  'Kilometres declares par le residant au retour du vehicule.';
COMMENT ON COLUMN vehicle_reservations.km_cost IS
  'Supplement kilometrique, debite au retour (total_km x tarif/km).';
COMMENT ON COLUMN vehicle_reservations.returned_at IS
  'Horodatage du retour. NULL tant que le vehicule n''est pas rendu.';

-- ---------------------------------------------------------------------
-- Un vehicule rendu libere son creneau
-- ---------------------------------------------------------------------
-- check_vehicle_availability et vehicle_busy_slots ne regardent que les
-- statuts 'confirmed' et 'pending' : une reservation passee a 'completed'
-- cesse d'occuper le vehicule des le retour, ce qui rend au parc les
-- heures qu'on lui rend. Rien a changer dans ces fonctions, c'est deja
-- leur comportement.

COMMIT;

NOTIFY pgrst, 'reload schema';
