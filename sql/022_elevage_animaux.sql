-- 022_elevage_animaux.sql
-- Fiche individuelle par animal — CoHabitat, module Élevages.
--
-- Jusqu'ici un élevage n'existait qu'en masse : un cheptel calculé à
-- partir des quantités d'ajout et de perte. On savait qu'il y avait cinq
-- poules, jamais lesquelles. Cette migration donne un nom, une photo et
-- une histoire à chacune.
--
-- La photo est une URL, pas un fichier. C'est délibéré : un service de
-- stockage n'existe pas sur une instance auto-hébergée, et une image en
-- base64 ferait enfler la table et les sauvegardes. Un champ texte laisse
-- essayer les fiches tout de suite ; si l'usage prend, le stockage se
-- remplace sans toucher au reste du schéma.
--
-- La table couvre les deux élevages : rien n'interdit de nommer un
-- poisson, même si l'usage s'y prête moins qu'un poulailler.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

create table if not exists elevage_animaux (
  id            uuid primary key default gen_random_uuid(),
  module        text not null check (module in ('poulailler', 'sablonponie')),
  nom           text not null,
  race          text,
  photo_url     text,
  date_arrivee  date,
  date_sortie   date,
  statut        text not null default 'adulte',
  notes         text,
  created_by    uuid references profiles(id) on delete set null,
  created_at    timestamptz default now()
);

-- Six etats : trois bandes d'age dans l'elevage, trois facons d'en
-- sortir.
--
--   DANS L'ELEVAGE — toutes pondent
--     jeune    pond souvent, petits oeufs
--     adulte   pleine ponte
--     age      pond moins souvent, gros oeufs
--
--   SORTIES
--     reforme  fin de carriere : ne pond plus, quitte l'elevage
--     parti    donne, vendu, transfere
--     mort
--
-- Les trois bandes sont un gradient, pas une hierarchie : le calibre de
-- l'oeuf augmente avec l'age pendant que le rythme diminue. Une jeune
-- poule et une vieille produisent toutes les deux, differemment. C'est
-- pourquoi le cheptel les additionne sans distinction — elles occupent
-- une place au regard du reglement, coutent a nourrir, et pondent.
--
-- « age » et « reforme » ne se confondent pas, et la difference n'est pas
-- de degre : l'une est encore la et produit, l'autre est sortie. Une bete
-- agee comptee comme reformee disparaitrait du cheptel alors qu'elle
-- donne encore des oeufs — et des gros.
--
-- Contrainte posee en DROP/ADD plutot qu'en `check` inline, et conversion
-- des valeurs d'une version anterieure de cette migration : une base deja
-- migree doit pouvoir accueillir les nouveaux etats.
-- L'ordre compte : convertir avant d'avoir retire l'ancienne contrainte
-- echouerait, celle-ci n'admettant pas les nouvelles valeurs. On leve la
-- contrainte, on convertit, puis on repose la contrainte elargie.
alter table elevage_animaux drop constraint if exists elevage_animaux_statut_check;
update elevage_animaux set statut = 'adulte' where statut = 'present';
alter table elevage_animaux alter column statut set default 'adulte';
alter table elevage_animaux
  add constraint elevage_animaux_statut_check
  check (statut in ('jeune', 'adulte', 'age', 'reforme', 'parti', 'mort'));

create index if not exists idx_elevage_animaux_module
  on elevage_animaux(module, statut, nom);

-- Un événement d'historique peut viser un animal précis — « Gertrude a
-- couvé », « mortalité : Blanchette » — ou rester collectif, comme la
-- ponte hebdomadaire du troupeau. D'où une colonne nullable.
--
-- ON DELETE SET NULL et non CASCADE : supprimer une fiche ne doit pas
-- effacer l'historique de l'élevage. L'événement a eu lieu, il reste ;
-- il redevient simplement collectif.
alter table elevage_historique
  add column if not exists animal_id uuid references elevage_animaux(id) on delete set null;

create index if not exists idx_elevage_historique_animal
  on elevage_historique(animal_id) where animal_id is not null;

-- ============================================================
-- ROW-LEVEL SECURITY — mêmes règles que le reste du module
-- ============================================================
alter table elevage_animaux enable row level security;

drop policy if exists elevage_animaux_admin on elevage_animaux;
create policy elevage_animaux_admin on elevage_animaux
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- alter table elevage_historique drop column if exists animal_id;
-- drop table if exists elevage_animaux;
-- COMMIT;
