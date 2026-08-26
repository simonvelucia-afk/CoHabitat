-- 024_ponte_calibres.sql
-- Calibrer les œufs d'une cueillette.
--
-- Un compte seul ne dit pas grand-chose d'un poulailler. Le calibre suit
-- l'âge de la poule — une jeune pond souvent et petit, une vieille moins
-- souvent mais gros — et ce sont deux informations différentes que le
-- total confond.
--
-- Cinq paniers, exclusifs, dont la somme fait la cueillette :
--
--   petit / moyen / gros   œufs sains, par calibre
--   defaut_comestible      fêlé, sale, difforme — consommé sur place,
--                          pas vendu ni distribué
--   defaut_rejet           cassé, souillé, douteux — jeté
--
-- Le champ `quantite` de elevage_historique reste le total et demeure la
-- source des cumuls. Les cinq colonnes le détaillent quand la saisie l'a
-- permis ; une cueillette entrée en bloc les laisse à NULL et reste
-- parfaitement valide. Aucun écran ne doit exiger le détail.
--
-- Colonnes nullables et sans contrainte de somme : imposer
-- petit+moyen+gros+defauts = quantite bloquerait une correction partielle
-- au milieu d'une saisie. La cohérence se vérifie à l'affichage, où elle
-- peut se signaler sans rien empêcher.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

alter table elevage_historique
  add column if not exists ponte_petit             integer,
  add column if not exists ponte_moyen             integer,
  add column if not exists ponte_gros              integer,
  add column if not exists ponte_defaut_comestible integer,
  add column if not exists ponte_defaut_rejet      integer;

-- Un panier négatif n'a pas de sens ; zéro et NULL en ont un, et ils
-- diffèrent : zéro veut dire « compté, aucun », NULL « pas détaillé ».
do $$
declare c text;
begin
  foreach c in array array['ponte_petit','ponte_moyen','ponte_gros',
                           'ponte_defaut_comestible','ponte_defaut_rejet']
  loop
    execute format(
      'alter table elevage_historique drop constraint if exists eh_%s_positif', c);
    execute format(
      'alter table elevage_historique add constraint eh_%s_positif check (%I is null or %I >= 0)', c, c, c);
  end loop;
end $$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- alter table elevage_historique
--   drop column if exists ponte_petit, drop column if exists ponte_moyen,
--   drop column if exists ponte_gros, drop column if exists ponte_defaut_comestible,
--   drop column if exists ponte_defaut_rejet;
-- COMMIT;
