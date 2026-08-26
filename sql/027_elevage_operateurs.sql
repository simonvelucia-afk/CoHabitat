-- 027_elevage_operateurs.sql
-- Confier un élevage à un résident.
--
-- Le poulailler et la sablonponie demandent quelqu'un qui s'en occupe au
-- quotidien : ramasser les œufs, noter une boiterie, peser un lot. Ce
-- n'est pas un travail d'administrateur — c'est un résident qui a pris
-- l'élevage en charge.
--
-- Jusqu'ici il fallait le nommer administrateur pour qu'il puisse saisir
-- quoi que ce soit, ce qui lui ouvrait au passage les locataires, les
-- paiements et les réglages de l'immeuble. Un droit trop large accordé
-- faute d'un droit juste.
--
-- Une table plutôt que resource_access : celle-ci est verrouillée sur
-- ('space','vehicle') et s'appuie sur un resource_id UUID. Un élevage
-- n'est pas une ligne, c'est un module — 'poulailler', 'sablonponie'.
-- L'y forcer demanderait un identifiant bidon.
--
-- Ce que l'opérateur PEUT : les bêtes, les lots, les événements — le
-- vivant.
-- Ce qu'il ne peut PAS : les coûts d'exploitation (elevage_couts) et le
-- nombre permis (system_settings). Ce que l'immeuble dépense et ce que le
-- règlement autorise restent au conseil.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

create table if not exists elevage_operateurs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  module     text not null check (module in ('poulailler', 'sablonponie')),
  granted_by uuid references profiles(id) on delete set null,
  created_at timestamptz default now()
);

create unique index if not exists elevage_operateurs_unique
  on elevage_operateurs(user_id, module);

alter table elevage_operateurs enable row level security;

-- Seul un administrateur nomme ou revoque.
drop policy if exists elevage_operateurs_admin on elevage_operateurs;
create policy elevage_operateurs_admin on elevage_operateurs
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

-- Chacun voit qui s'occupe de quoi : savoir a qui parler d'une poule
-- malade n'est pas une information sensible.
drop policy if exists elevage_operateurs_lecture on elevage_operateurs;
create policy elevage_operateurs_lecture on elevage_operateurs
  for select to authenticated
  using (true);

-- ============================================================
-- Le droit d'ecriture, en une fonction
-- ============================================================
-- SECURITY DEFINER : la politique interroge elevage_operateurs, qui est
-- elle-meme sous RLS. Sans cela, la lecture depuis l'interieur d'une
-- politique se heurterait a la politique de l'autre table.
create or replace function peut_gerer_elevage(p_module text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select get_my_role() in ('admin', 'principal_admin')
      or exists (
           select 1 from elevage_operateurs
            where user_id = auth.uid() and module = p_module
         );
$$;

revoke all on function peut_gerer_elevage(text) from public;
grant execute on function peut_gerer_elevage(text) to authenticated;

-- ============================================================
-- Les trois tables du vivant s'ouvrent a l'operateur de LEUR module
-- ============================================================
-- La lecture reste ouverte a tous (migrations 025 et 026) ; ces
-- politiques ne portent que sur l'ecriture, et seulement sur le module
-- confie : l'operateur du poulailler ne touche pas aux poissons.
drop policy if exists elevage_historique_operateur on elevage_historique;
create policy elevage_historique_operateur on elevage_historique
  for all to authenticated
  using (peut_gerer_elevage(module))
  with check (peut_gerer_elevage(module));

drop policy if exists elevage_animaux_operateur on elevage_animaux;
create policy elevage_animaux_operateur on elevage_animaux
  for all to authenticated
  using (peut_gerer_elevage(module))
  with check (peut_gerer_elevage(module));

drop policy if exists elevage_lots_operateur on elevage_lots;
create policy elevage_lots_operateur on elevage_lots
  for all to authenticated
  using (peut_gerer_elevage(module))
  with check (peut_gerer_elevage(module));

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- drop policy if exists elevage_historique_operateur on elevage_historique;
-- drop policy if exists elevage_animaux_operateur    on elevage_animaux;
-- drop policy if exists elevage_lots_operateur       on elevage_lots;
-- drop function if exists peut_gerer_elevage(text);
-- drop table if exists elevage_operateurs;
-- COMMIT;
