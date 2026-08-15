-- 016_serre_recoltes_stades.sql
-- Cultures continues et cycle de vie complet d'une section.
--
-- 1. Journal de cueillettes (serre_recoltes) : une ligne par cueillette.
--    Le modèle précédent ne portait qu'UNE date et UNE quantité par cycle,
--    ce qui convient au radis mais pas à la tomate ou au concombre, qui
--    donnent tous les jours pendant des semaines. serre_cultures.rendement_qty
--    devient le cumul de ces lignes (conservé pour l'historique existant).
--
-- 2. Stades : vide → semis → croissance → production → recolte (« Terminé »).
--    « recolte » est gardé tel quel en base pour ne pas casser les lignes
--    existantes ; c'est son libellé qui change dans l'interface.
--
-- 3. en_germination : une section peut produire ET garder un plant monté en
--    graine pour les semis de l'an prochain. Les deux états sont simultanés,
--    d'où une case à cocher indépendante du stade plutôt qu'un stade de plus.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ── 2. Stades ────────────────────────────────────────────────
-- La contrainte d'origine est anonyme (check inline) : on la retrouve par
-- son contenu plutôt que par un nom qui peut varier d'une install à l'autre.
do $$
declare c text;
begin
  select conname into c
  from pg_constraint
  where conrelid = 'serre_cultures'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%statut%';
  if c is not null then
    execute format('alter table serre_cultures drop constraint %I', c);
  end if;
end $$;

alter table serre_cultures
  add constraint serre_cultures_statut_check
  check (statut in ('vide', 'semis', 'croissance', 'production', 'recolte'));

-- ── 3. Plant conservé pour la semence ────────────────────────
alter table serre_cultures add column if not exists en_germination boolean not null default false;

comment on column serre_cultures.en_germination is
  'Un plant de la section est monté en graine pour les semis suivants. Indépendant du stade : une section peut produire et porter graine en même temps.';

-- ── 1. Journal de cueillettes ────────────────────────────────
create table if not exists serre_recoltes (
  id uuid primary key default gen_random_uuid(),
  culture_id uuid not null references serre_cultures(id) on delete cascade,
  zone_id uuid not null references serre_zones(id) on delete cascade,  -- dénormalisé pour la RLS
  date_recolte date not null default current_date,
  qty numeric,
  unite text,
  notes text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index if not exists idx_serre_recoltes_culture on serre_recoltes(culture_id);
create index if not exists idx_serre_recoltes_date on serre_recoltes(date_recolte desc);

alter table serre_recoltes enable row level security;

-- Mêmes règles que serre_cultures : lecture ouverte, écriture par le
-- locataire de la zone ou un admin.
drop policy if exists serre_recoltes_select on serre_recoltes;
create policy serre_recoltes_select on serre_recoltes
  for select to authenticated using (true);

drop policy if exists serre_recoltes_write on serre_recoltes;
create policy serre_recoltes_write on serre_recoltes
  for all to authenticated
  using (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'))
  with check (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'));

-- Cumul par cycle : le plan et le tableau de bord n'ont besoin que du total,
-- pas des lignes. Sans cette vue il faudrait rapatrier toutes les cueillettes
-- de la serre à chaque affichage (60 sections × une cueillette par jour).
create or replace view serre_recoltes_cumul as
select culture_id, unite,
       sum(qty) as total,
       count(*) as nb,
       max(date_recolte) as derniere
from serre_recoltes
group by culture_id, unite;

grant select on serre_recoltes_cumul to authenticated;

-- Reprise de l'existant : chaque cycle déjà chiffré devient une cueillette.
-- Le garde-fou « not exists » rend l'opération rejouable sans doublon.
insert into serre_recoltes (culture_id, zone_id, date_recolte, qty, unite, notes)
select c.id, c.zone_id,
       coalesce(c.date_recolte_reelle, c.date_recolte_prevue, current_date),
       c.rendement_qty, c.rendement_unite,
       'Reprise de la récolte saisie avant le journal de cueillettes'
from serre_cultures c
where c.rendement_qty is not null
  and not exists (select 1 from serre_recoltes r where r.culture_id = c.id);

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- drop view if exists serre_recoltes_cumul;
-- drop table if exists serre_recoltes;
-- alter table serre_cultures drop column if exists en_germination;
-- alter table serre_cultures drop constraint if exists serre_cultures_statut_check;
-- alter table serre_cultures add constraint serre_cultures_statut_check
--   check (statut in ('vide', 'croissance', 'recolte'));
-- COMMIT;
