-- 028_elevage_distribution.sql
-- Répartir la production entre les occupants — sans argent.
--
-- Volontairement SANS PRIX ni débit de solde. Vendre des œufs ou du
-- poisson au Québec touche à des régimes distincts — production et
-- classement des œufs, permis d'aquaculture, statut du lieu de vente — et
-- la question se pose au MAPAQ avant de se poser au logiciel.
--
-- Distribuer n'est pas vendre. Un immeuble qui répartit sa propre
-- production entre ses occupants, sans contrepartie, ne fait pas
-- commerce. Cette migration s'en tient là.
--
-- Si la vente devient permise, un prix s'ajoute par-dessus : les
-- contenants, le stock et le suivi existent déjà. Si elle ne l'est pas,
-- rien n'est perdu — savoir qui a eu des œufs cette semaine vaut par
-- soi-même.
--
--   elevage_offres    ce qui est mis à disposition, en CONTENANTS
--   elevage_retraits  qui a pris quoi
--
-- Le contenant est l'unité : « 6 gros œufs », « Truite ~540 g ». Un œuf
-- seul ne se distribue pas, et le calibre distingue les offres.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

create table if not exists elevage_offres (
  id          uuid primary key default gen_random_uuid(),
  module      text not null check (module in ('poulailler', 'sablonponie')),
  libelle     text not null,
  contenants  integer not null check (contenants > 0),
  date_offre  date not null default current_date,
  -- La récolte d'où cela vient, quand on la connaît. ON DELETE SET NULL :
  -- effacer une récolte ne doit pas effacer ce qui en a été distribué.
  source_id   uuid references elevage_historique(id) on delete set null,
  notes       text,
  created_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz default now()
);

create index if not exists idx_elevage_offres_module
  on elevage_offres(module, date_offre desc);

create table if not exists elevage_retraits (
  id         uuid primary key default gen_random_uuid(),
  offre_id   uuid not null references elevage_offres(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  contenants integer not null default 1 check (contenants > 0),
  retire_at  timestamptz default now()
);

create index if not exists idx_elevage_retraits_offre on elevage_retraits(offre_id);
create index if not exists idx_elevage_retraits_user  on elevage_retraits(user_id, retire_at desc);

-- ============================================================
-- On ne prend pas ce qui n'est plus là
-- ============================================================
-- Une vérification côté écran ne suffit pas : deux résidents qui
-- ouvrent la page au même moment verraient tous deux le dernier
-- contenant disponible. C'est la base qui doit trancher.
create or replace function elevage_retrait_verifie()
returns trigger
language plpgsql
as $$
declare
  v_offerts integer;
  v_pris    integer;
begin
  select contenants into v_offerts from elevage_offres where id = NEW.offre_id;
  if v_offerts is null then
    raise exception 'Offre introuvable';
  end if;
  select coalesce(sum(contenants), 0) into v_pris
    from elevage_retraits
   where offre_id = NEW.offre_id
     and (TG_OP = 'INSERT' or id <> NEW.id);
  if v_pris + NEW.contenants > v_offerts then
    raise exception 'Il ne reste que % contenant(s) sur cette offre', v_offerts - v_pris
      using errcode = 'check_violation';
  end if;
  return NEW;
end $$;

drop trigger if exists elevage_retrait_verifie_t on elevage_retraits;
create trigger elevage_retrait_verifie_t
  before insert or update on elevage_retraits
  for each row execute function elevage_retrait_verifie();

-- ============================================================
-- ROW-LEVEL SECURITY
-- ============================================================
alter table elevage_offres   enable row level security;
alter table elevage_retraits enable row level security;

-- Mettre à disposition : administrateur ou opérateur de CE module,
-- comme le reste du vivant (migration 027).
drop policy if exists elevage_offres_gestion on elevage_offres;
create policy elevage_offres_gestion on elevage_offres
  for all to authenticated
  using (peut_gerer_elevage(module))
  with check (peut_gerer_elevage(module));

drop policy if exists elevage_offres_lecture on elevage_offres;
create policy elevage_offres_lecture on elevage_offres
  for select to authenticated using (true);

-- Chacun prend pour SOI. Un résident ne se sert pas au nom d'un autre.
drop policy if exists elevage_retraits_soi on elevage_retraits;
create policy elevage_retraits_soi on elevage_retraits
  for insert to authenticated
  with check (user_id = auth.uid());

-- Et il peut annuler son propre retrait — reposer le contenant.
drop policy if exists elevage_retraits_annuler on elevage_retraits;
create policy elevage_retraits_annuler on elevage_retraits
  for delete to authenticated
  using (user_id = auth.uid());

-- Qui a pris quoi se lit par tous : c'est ce qui rend la répartition
-- honnête sans surveillance. Une distribution opaque invite au
-- soupçon ; une distribution visible se régule d'elle-même.
drop policy if exists elevage_retraits_lecture on elevage_retraits;
create policy elevage_retraits_lecture on elevage_retraits
  for select to authenticated using (true);

-- Correction : l'administration ou l'opérateur peut retirer une ligne
-- erronée, sans quoi une saisie fautive resterait indefiniment.
drop policy if exists elevage_retraits_gestion on elevage_retraits;
create policy elevage_retraits_gestion on elevage_retraits
  for delete to authenticated
  using (exists (select 1 from elevage_offres o
                  where o.id = offre_id and peut_gerer_elevage(o.module)));

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- drop trigger if exists elevage_retrait_verifie_t on elevage_retraits;
-- drop function if exists elevage_retrait_verifie();
-- drop table if exists elevage_retraits;
-- drop table if exists elevage_offres;
-- COMMIT;
