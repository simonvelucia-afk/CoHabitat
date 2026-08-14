-- 011_elevages.sql
-- Module Élevages — CoHabitat
-- Suivi (admin) du poulailler (poules) et de la sablonponie (poissons) :
--   * historique des événements (ajouts, pertes, ponte/récolte, santé, notes)
--   * coûts d'exploitation
-- Les faits saillants sont publiés au babillard côté application
-- (insertion dans bulletin_board par l'admin qui saisit l'événement).
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- ============================================================
-- Historique des élevages (poules / poissons)
-- ============================================================
create table if not exists elevage_historique (
  id uuid primary key default gen_random_uuid(),
  module text not null check (module in ('poulailler', 'sablonponie')),
  date_evenement date not null default current_date,
  type_evenement text not null
    check (type_evenement in ('ajout', 'perte', 'ponte', 'recolte', 'sante', 'note')),
  quantite numeric,                 -- nb d'animaux (ajout/perte) ou œufs/kg (ponte/récolte)
  description text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index if not exists idx_elevage_historique_module
  on elevage_historique(module, date_evenement desc);

-- ============================================================
-- Coûts d'exploitation
-- ============================================================
create table if not exists elevage_couts (
  id uuid primary key default gen_random_uuid(),
  module text not null check (module in ('poulailler', 'sablonponie')),
  date_cout date not null default current_date,
  categorie text not null,          -- nourriture, equipement, veterinaire, litiere, energie, autre
  montant numeric not null,
  description text,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index if not exists idx_elevage_couts_module
  on elevage_couts(module, date_cout desc);

-- ============================================================
-- ROW-LEVEL SECURITY — réservé aux admins
-- ============================================================
alter table elevage_historique enable row level security;
alter table elevage_couts      enable row level security;

drop policy if exists elevage_historique_admin on elevage_historique;
create policy elevage_historique_admin on elevage_historique
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

drop policy if exists elevage_couts_admin on elevage_couts;
create policy elevage_couts_admin on elevage_couts
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

COMMIT;

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- drop table if exists elevage_couts;
-- drop table if exists elevage_historique;
-- COMMIT;
