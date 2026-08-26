-- 026_sablonponie_lots.sql
-- Suivre la croissance et la récolte des poissons, par lot.
--
-- Les poissons ne se suivent pas comme les poules. On ne nomme pas
-- quarante truites : on met un LOT en bassin à une date, il grossit, et
-- on le récolte en plusieurs fois. C'est exactement le cycle des
-- cultures de la serre — semis, croissance, production, récolte — et
-- cette table en est l'équivalent pour l'eau.
--
-- Stades, du plus jeune au sortant :
--
--   alevin        vient d'être mis en bassin
--   juvenile      grossit, pas encore récoltable
--   croissance    prend son poids de marché
--   marchand      taille atteinte — récoltable
--   reproduction  gardé comme géniteur : ce lot ne se récolte pas, il
--                 fournit les alevins suivants
--   epuise        le lot est sorti
--
-- « reproduction » n'est pas une étape du chemin vers la récolte, c'est
-- une bifurcation : un lot qu'on y place en sort du circuit de production.
-- L'écran ne lui demande donc pas de date de récolte prévue.
--
-- Le SEXE ne se note qu'à ce moment-là. Un lot d'engraissement est mixte
-- et personne ne le trie ; des géniteurs se séparent au contraire par
-- sexe, en bassins distincts. D'où une colonne à trois valeurs plutôt
-- que deux compteurs : on ne compte pas les mâles d'un lot mixte, on
-- constitue un lot de mâles.
--
-- `poids_moyen_g` est saisi à la main, comme les conditions de la serre :
-- on pèse quelques individus et on reporte. Nullable — un lot qu'on n'a
-- pas encore pesé n'est pas un lot sans poids, c'est un lot non mesuré,
-- et le distinguer de zéro évite d'afficher une mesure inventée.
--
-- La récolte reste dans elevage_historique (type_evenement = 'recolte',
-- quantite en kg) : rien de ce qui existe ne change de sens. La colonne
-- lot_id la rattache au lot d'où les poissons sortent — ou la laisse
-- collective si l'on ne sait plus.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

create table if not exists elevage_lots (
  id                  uuid primary key default gen_random_uuid(),
  module              text not null default 'sablonponie'
                      check (module in ('poulailler', 'sablonponie')),
  espece              text not null,
  date_mise_en_bassin date not null default current_date,
  quantite_initiale   integer not null check (quantite_initiale >= 0),
  stade               text not null default 'alevin',
  sexe                text not null default 'mixte',
  poids_moyen_g       numeric check (poids_moyen_g is null or poids_moyen_g >= 0),
  date_recolte_prevue date,
  notes               text,
  created_by          uuid references profiles(id) on delete set null,
  created_at          timestamptz default now()
);

-- En DROP/ADD : une base ayant reçu une version antérieure doit pouvoir
-- accueillir la liste de stades courante.
alter table elevage_lots add column if not exists sexe text not null default 'mixte';

alter table elevage_lots drop constraint if exists elevage_lots_stade_check;
alter table elevage_lots
  add constraint elevage_lots_stade_check
  check (stade in ('alevin', 'juvenile', 'croissance', 'marchand', 'reproduction', 'epuise'));

alter table elevage_lots drop constraint if exists elevage_lots_sexe_check;
alter table elevage_lots
  add constraint elevage_lots_sexe_check
  check (sexe in ('mixte', 'male', 'femelle'));

create index if not exists idx_elevage_lots_module
  on elevage_lots(module, stade, date_mise_en_bassin desc);

-- ON DELETE SET NULL, comme animal_id : supprimer un lot ne doit pas
-- effacer les récoltes qu'il a données. Elles ont eu lieu.
alter table elevage_historique
  add column if not exists lot_id uuid references elevage_lots(id) on delete set null;

create index if not exists idx_elevage_historique_lot
  on elevage_historique(lot_id) where lot_id is not null;

-- ============================================================
-- ROW-LEVEL SECURITY — écriture aux admins, lecture aux résidents,
-- comme elevage_animaux depuis la migration 025.
-- ============================================================
alter table elevage_lots enable row level security;

drop policy if exists elevage_lots_admin on elevage_lots;
create policy elevage_lots_admin on elevage_lots
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

drop policy if exists elevage_lots_lecture on elevage_lots;
create policy elevage_lots_lecture on elevage_lots
  for select to authenticated
  using (true);

-- ── Qualifier la récolte ────────────────────────────────────────────────
-- Comme les œufs (migration 024), une récolte gagne à être détaillée : un
-- total en kilos ne dit pas si l'on a sorti dix gros poissons ou trente
-- petits.
--
-- Mais l'unité diffère, et c'est important : un œuf se compte, un poisson
-- se compte AUSSI mais la récolte se PÈSE. Les calibres sont donc en
-- PIÈCES tandis que `quantite` reste en kilos — les deux ne s'additionnent
-- pas, et l'écran ne doit surtout pas déduire l'un de l'autre.
--
--   recolte_petit / moyen / gros   pièces, par calibre
--   recolte_rejet                  pièces impropres — non consommées
--
-- L'intérêt du croisement : kilos ÷ pièces donne le poids moyen réel de
-- la récolte, qui se compare au `poids_moyen_g` estimé du lot. Deux
-- mesures indépendantes qui se contrôlent l'une l'autre.
--
-- Nullables, comme les paniers d'œufs : une récolte entrée en bloc reste
-- parfaitement valide, et un calibre vide n'est pas un calibre à zéro.
alter table elevage_historique
  add column if not exists recolte_petit integer,
  add column if not exists recolte_moyen integer,
  add column if not exists recolte_gros  integer,
  add column if not exists recolte_rejet integer;

do $$
declare c text;
begin
  foreach c in array array['recolte_petit','recolte_moyen','recolte_gros','recolte_rejet']
  loop
    execute format('alter table elevage_historique drop constraint if exists eh_%s_positif', c);
    execute format('alter table elevage_historique add constraint eh_%s_positif check (%I is null or %I >= 0)', c, c, c);
  end loop;
end $$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- alter table elevage_historique drop column if exists lot_id;
-- drop table if exists elevage_lots;
-- COMMIT;
