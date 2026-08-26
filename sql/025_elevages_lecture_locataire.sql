-- 025_elevages_lecture_locataire.sql
-- Ouvrir les élevages à la lecture des résidents.
--
-- La migration 011 réservait tout le module aux administrateurs. C'était
-- juste tant que les élevages n'étaient qu'un registre de gestion ; ça
-- ne l'est plus dès qu'ils paraissent sur la page Espaces, à côté de la
-- serre. Les poules sont celles de l'immeuble : ses résidents peuvent
-- savoir comment elles s'appellent et combien d'œufs elles ont donnés.
--
-- Sans cette migration, la page s'affiche mais reste VIDE — la base
-- renvoie zéro ligne, sans erreur. C'est le silence le plus trompeur qui
-- soit, d'où cette migration livrée avec l'écran qui en dépend.
--
--   elevage_animaux      lecture ouverte  — qui vit ici
--   elevage_historique   lecture ouverte  — ce qu'ils ont produit
--   elevage_couts        INCHANGÉE        — moulée, vétérinaire, litière
--
-- Les coûts d'exploitation restent aux administrateurs. C'est de
-- l'information de gestion : ce que l'immeuble dépense en moulée relève
-- du conseil, pas du babillard.
--
-- L'écriture ne bouge pas. Les politiques elevage_*_admin de la 011
-- restent en place, et ces nouvelles ne portent que sur SELECT : un
-- résident lit, il ne saisit rien. Deux politiques permissives se
-- combinent par OU — l'administrateur garde donc son accès complet par
-- la première, le résident obtient la lecture par la seconde.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

drop policy if exists elevage_animaux_lecture on elevage_animaux;
create policy elevage_animaux_lecture on elevage_animaux
  for select to authenticated
  using (true);

drop policy if exists elevage_historique_lecture on elevage_historique;
create policy elevage_historique_lecture on elevage_historique
  for select to authenticated
  using (true);

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- drop policy if exists elevage_animaux_lecture    on elevage_animaux;
-- drop policy if exists elevage_historique_lecture on elevage_historique;
-- COMMIT;
