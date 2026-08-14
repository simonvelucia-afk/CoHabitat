-- 009_serre.sql
-- Module Serre — CoHabitat (projet uwyhrdjlwetcbtskijrs)
--
-- Zones de culture d'une serre communautaire, louables aux locataires
-- contre un petit frais mensuel, avec suivi des cultures, de l'irrigation,
-- de la fertilisation, des capteurs (températures / réservoirs) et de
-- l'historique de rendement par locataire.
--
-- Adapté du prototype « moduleserrecohabitat.sql » :
--   * les locations référencent profiles(id) (et non une table locataires)
--   * RLS activé sur toutes les tables (alerte Supabase rls_disabled_in_public)
--   * ajout d'un frais_mensuel par zone + suivi de facturation par location
--
-- Idempotente : peut être rejouée sans erreur.
-- Retrograde : ROLLBACK en bas du fichier.

BEGIN;

-- ============================================================
-- 1. Zones physiques de la serre (fixes)
-- ============================================================
create table if not exists serre_zones (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,            -- ex: 'P1-Z1'
  planche int not null,                 -- 1 ou 2
  position int not null,                -- 1 à 10
  largeur_pi numeric default 2,
  longueur_pi numeric default 3,
  frais_mensuel numeric not null default 1,  -- petit frais mensuel de location ($ CAD)
  is_active boolean not null default true,
  created_at timestamptz default now()
);

-- ============================================================
-- 2. Périodes de location d'une zone par un locataire
-- ============================================================
create table if not exists serre_locations (
  id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references serre_zones(id) on delete cascade,
  tenant_id uuid not null references profiles(id) on delete restrict,
  date_debut date not null default current_date,
  date_fin date,
  frais_mensuel numeric not null default 1,  -- snapshot du tarif au moment de la location
  derniere_facturation date,                 -- dernier mois facturé (1er du mois)
  statut text not null default 'active'
    check (statut in ('active', 'terminee', 'annulee')),
  created_at timestamptz default now()
);
create index if not exists idx_serre_locations_tenant on serre_locations(tenant_id);
create index if not exists idx_serre_locations_zone on serre_locations(zone_id);
-- Une seule location active par zone à la fois
create unique index if not exists uniq_serre_location_active
  on serre_locations(zone_id) where statut = 'active';

-- ============================================================
-- 3. Cycles de culture (une ligne par plantation)
-- ============================================================
create table if not exists serre_cultures (
  id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references serre_zones(id) on delete cascade,
  location_id uuid references serre_locations(id) on delete set null,
  section int not null default 1 check (section between 1 and 3),  -- sous-section de la zone (1 à 3, depuis l'allée)
  culture text,
  date_semis date,
  date_recolte_prevue date,
  date_recolte_reelle date,
  statut text not null default 'vide'
    check (statut in ('vide', 'croissance', 'recolte')),
  rendement_qty numeric,
  rendement_unite text,                 -- kg, lb, unités, bottes
  notes text,
  created_at timestamptz default now()
);
-- Colonne section pour installs antérieures (create table if not exists n'ajoute rien)
alter table serre_cultures add column if not exists section int not null default 1;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'serre_cultures_section_check') then
    alter table serre_cultures add constraint serre_cultures_section_check check (section between 1 and 3);
  end if;
end $$;
create index if not exists idx_serre_cultures_zone on serre_cultures(zone_id);
create index if not exists idx_serre_cultures_location on serre_cultures(location_id);
create index if not exists idx_serre_cultures_loc_section on serre_cultures(location_id, section);

-- ============================================================
-- 4. Fertilisation (compost / backwash sandponique)
-- ============================================================
create table if not exists serre_fertilisations (
  id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references serre_zones(id) on delete cascade,
  culture_id uuid references serre_cultures(id) on delete set null,
  type text not null
    check (type in ('compost', 'backwash_sandponique', 'compost_backwash', 'autre')),
  date_application date not null default current_date,
  notes text,
  created_at timestamptz default now()
);
create index if not exists idx_serre_fertilisations_zone on serre_fertilisations(zone_id);

-- ============================================================
-- 5. Config d'irrigation par zone
-- ============================================================
create table if not exists serre_irrigation_config (
  zone_id uuid primary key references serre_zones(id) on delete cascade,
  frequence text,     -- quotidien, aux 2 jours, 2x/semaine, etc.
  systeme text,       -- goutte-à-goutte, aspersion, manuel, sandponique
  updated_at timestamptz default now()
);

-- ============================================================
-- 6. Réservoirs d'eau (3 réservoirs distincts)
-- ============================================================
create table if not exists serre_reservoirs (
  id uuid primary key default gen_random_uuid(),
  nom text not null,               -- 'Réservoir 1', 'Réservoir 2', 'Réservoir 3'
  capacite_litres numeric,
  ordre int,
  created_at timestamptz default now()
);

-- ============================================================
-- 7. Lectures de capteurs (température air/eau, niveaux réservoirs)
-- ============================================================
create table if not exists serre_lectures (
  id uuid primary key default gen_random_uuid(),
  horodatage timestamptz not null default now(),
  temp_air numeric,
  temp_eau numeric,
  reservoir1_pct numeric,
  reservoir2_pct numeric,
  reservoir3_pct numeric,
  created_by uuid references profiles(id) on delete set null
);
create index if not exists idx_serre_lectures_horodatage on serre_lectures(horodatage desc);

-- ============================================================
-- Vue : historique de location + rendement par locataire
-- ============================================================
create or replace view serre_historique_locataire as
select
  loc.tenant_id,
  z.code as zone_code,
  loc.date_debut,
  loc.date_fin,
  loc.statut as statut_location,
  c.section,
  c.culture,
  c.date_semis,
  c.date_recolte_reelle,
  c.rendement_qty,
  c.rendement_unite,
  c.statut as statut_culture
from serre_locations loc
join serre_zones z on z.id = loc.zone_id
left join serre_cultures c on c.location_id = loc.id
order by loc.tenant_id, loc.date_debut desc;

-- ============================================================
-- Vue : récapitulatif de rendement total par locataire
-- ============================================================
create or replace view serre_rendement_total_locataire as
select
  loc.tenant_id,
  c.rendement_unite,
  sum(c.rendement_qty) as total_recolte,
  count(distinct c.id) as nb_recoltes,
  count(distinct loc.zone_id) as nb_zones_utilisees
from serre_locations loc
join serre_cultures c on c.location_id = loc.id
where c.rendement_qty is not null
group by loc.tenant_id, c.rendement_unite;

-- ============================================================
-- Helper : la zone est-elle actuellement louée par l'utilisateur courant ?
-- (SECURITY DEFINER pour éviter la récursion RLS)
-- ============================================================
create or replace function serre_zone_louee_par_moi(p_zone_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from serre_locations
    where zone_id = p_zone_id
      and tenant_id = auth.uid()
      and statut = 'active'
  );
$$;

-- ============================================================
-- Fonction : carte d'occupation des zones sans fuite d'identité.
-- Renvoie, pour chaque zone, si elle est occupée et si c'est MOI qui
-- la loue — sans exposer le nom des autres locataires (que RLS masque).
-- ============================================================
create or replace function serre_occupancy()
returns table(zone_id uuid, is_occupied boolean, is_mine boolean, frais_mensuel numeric)
language sql
security definer
set search_path = public
as $$
  select
    z.id,
    (l.id is not null) as is_occupied,
    coalesce(l.tenant_id = auth.uid(), false) as is_mine,
    z.frais_mensuel
  from serre_zones z
  left join serre_locations l on l.zone_id = z.id and l.statut = 'active'
  where z.is_active;
$$;
grant execute on function serre_occupancy() to authenticated;

-- ============================================================
-- Données de départ : 20 zones fixes + 3 réservoirs
-- ============================================================
insert into serre_zones (code, planche, position)
select 'P' || p || '-Z' || z, p, z
from generate_series(1, 2) as p, generate_series(1, 10) as z
on conflict (code) do nothing;

-- Tarif mensuel de base : 1 $ CAD par zone.
-- Idempotent : réaligne aussi le défaut si une version antérieure (5 $) a été jouée.
alter table serre_zones     alter column frais_mensuel set default 1;
alter table serre_locations alter column frais_mensuel set default 1;
update serre_zones set frais_mensuel = 1 where frais_mensuel = 5;

insert into serre_reservoirs (nom, ordre)
values ('Réservoir 1', 1), ('Réservoir 2', 2), ('Réservoir 3', 3)
on conflict do nothing;

-- Réglage d'activation du module (toggle admin, comme module_trips/module_lunch)
insert into system_settings (key, value, description)
values ('module_serre', 'true', 'Module Serre — zones de culture louables au mois')
on conflict (key) do nothing;

-- ============================================================
-- ROW-LEVEL SECURITY
-- ============================================================
alter table serre_zones             enable row level security;
alter table serre_locations         enable row level security;
alter table serre_cultures          enable row level security;
alter table serre_fertilisations    enable row level security;
alter table serre_irrigation_config enable row level security;
alter table serre_reservoirs        enable row level security;
alter table serre_lectures          enable row level security;

-- ── serre_zones : lecture publique, écriture admin ──────────
drop policy if exists serre_zones_select on serre_zones;
create policy serre_zones_select on serre_zones
  for select to authenticated using (true);

drop policy if exists serre_zones_admin on serre_zones;
create policy serre_zones_admin on serre_zones
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

-- ── serre_locations : le locataire voit/gère les siennes, admin tout ──
drop policy if exists serre_locations_select on serre_locations;
create policy serre_locations_select on serre_locations
  for select to authenticated
  using (tenant_id = auth.uid() or get_my_role() in ('admin', 'principal_admin'));

drop policy if exists serre_locations_insert on serre_locations;
create policy serre_locations_insert on serre_locations
  for insert to authenticated
  with check (tenant_id = auth.uid() or get_my_role() in ('admin', 'principal_admin'));

drop policy if exists serre_locations_update on serre_locations;
create policy serre_locations_update on serre_locations
  for update to authenticated
  using (tenant_id = auth.uid() or get_my_role() in ('admin', 'principal_admin'))
  with check (tenant_id = auth.uid() or get_my_role() in ('admin', 'principal_admin'));

drop policy if exists serre_locations_delete on serre_locations;
create policy serre_locations_delete on serre_locations
  for delete to authenticated
  using (get_my_role() in ('admin', 'principal_admin'));

-- ── serre_cultures : lecture publique, écriture par le locataire de la zone ou admin ──
drop policy if exists serre_cultures_select on serre_cultures;
create policy serre_cultures_select on serre_cultures
  for select to authenticated using (true);

drop policy if exists serre_cultures_write on serre_cultures;
create policy serre_cultures_write on serre_cultures
  for all to authenticated
  using (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'))
  with check (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'));

-- ── serre_fertilisations : idem cultures ──
drop policy if exists serre_fertilisations_select on serre_fertilisations;
create policy serre_fertilisations_select on serre_fertilisations
  for select to authenticated using (true);

drop policy if exists serre_fertilisations_write on serre_fertilisations;
create policy serre_fertilisations_write on serre_fertilisations
  for all to authenticated
  using (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'))
  with check (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'));

-- ── serre_irrigation_config : idem cultures ──
drop policy if exists serre_irrigation_select on serre_irrigation_config;
create policy serre_irrigation_select on serre_irrigation_config
  for select to authenticated using (true);

drop policy if exists serre_irrigation_write on serre_irrigation_config;
create policy serre_irrigation_write on serre_irrigation_config
  for all to authenticated
  using (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'))
  with check (serre_zone_louee_par_moi(zone_id) or get_my_role() in ('admin', 'principal_admin'));

-- ── serre_reservoirs : lecture publique, écriture admin ──
drop policy if exists serre_reservoirs_select on serre_reservoirs;
create policy serre_reservoirs_select on serre_reservoirs
  for select to authenticated using (true);

drop policy if exists serre_reservoirs_admin on serre_reservoirs;
create policy serre_reservoirs_admin on serre_reservoirs
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

-- ── serre_lectures : lecture publique, saisie par tout locataire, gestion admin ──
drop policy if exists serre_lectures_select on serre_lectures;
create policy serre_lectures_select on serre_lectures
  for select to authenticated using (true);

drop policy if exists serre_lectures_insert on serre_lectures;
create policy serre_lectures_insert on serre_lectures
  for insert to authenticated
  with check (created_by = auth.uid() or get_my_role() in ('admin', 'principal_admin'));

drop policy if exists serre_lectures_admin on serre_lectures;
create policy serre_lectures_admin on serre_lectures
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

COMMIT;

-- ============================================================
-- ROLLBACK (à exécuter manuellement pour retirer le module)
-- ============================================================
-- BEGIN;
-- drop view if exists serre_rendement_total_locataire;
-- drop view if exists serre_historique_locataire;
-- drop function if exists serre_zone_louee_par_moi(uuid);
-- drop table if exists serre_lectures;
-- drop table if exists serre_reservoirs;
-- drop table if exists serre_irrigation_config;
-- drop table if exists serre_fertilisations;
-- drop table if exists serre_cultures;
-- drop table if exists serre_locations;
-- drop table if exists serre_zones;
-- COMMIT;
