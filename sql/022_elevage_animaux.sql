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
  statut        text not null default 'present'
                check (statut in ('present', 'parti', 'mort')),
  notes         text,
  created_by    uuid references profiles(id) on delete set null,
  created_at    timestamptz default now()
);

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
