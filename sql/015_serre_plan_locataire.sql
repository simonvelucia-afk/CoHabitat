-- 015_serre_plan_locataire.sql
-- Plan de la serre : afficher sur chaque zone qui la loue et pour quelle
-- période, et mémoriser la date de fin *envisagée* d'une location.
--
-- 1. serre_locations.date_fin_prevue : date de fin envisagée, saisie à la
--    location. Toujours facultative — une location peut n'avoir aucune fin
--    prévue (reconduite au mois, « peut-être jamais »). À ne pas confondre
--    avec date_fin, qui n'est renseignée qu'à la libération réelle.
--
-- 2. serre_occupancy() renvoie en plus le nom *abrégé* du locataire et les
--    dates de la location. La policy serre_locations_select limite la lecture
--    aux locations du demandeur ; la fonction étant security definer, elle
--    expose de façon contrôlée le strict nécessaire à l'affichage du plan.
--    Volontairement : prénom + initiale (« Maude D. »), jamais le nom complet
--    ni l'e-mail ni l'unité.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

alter table serre_locations add column if not exists date_fin_prevue date;

comment on column serre_locations.date_fin_prevue is
  'Date de fin envisagée par le locataire, facultative. date_fin, elle, est la fin réelle.';

-- Le type de retour change : create or replace ne suffit pas, il faut recréer.
drop function if exists serre_occupancy();

create function serre_occupancy()
returns table(
  zone_id uuid,
  is_occupied boolean,
  is_mine boolean,
  frais_mensuel numeric,
  locataire_court text,
  date_debut date,
  date_fin_prevue date
)
language sql
security definer
set search_path = public
as $$
  select
    z.id,
    (l.id is not null) as is_occupied,
    coalesce(l.tenant_id = auth.uid(), false) as is_mine,
    z.frais_mensuel,
    case
      when p.full_name is null then null
      -- « Maude Dussault » → « Maude D. » ; un prénom seul reste tel quel.
      when position(' ' in btrim(p.full_name)) = 0 then btrim(p.full_name)
      else split_part(btrim(p.full_name), ' ', 1) || ' '
           || upper(left(split_part(btrim(p.full_name), ' ', 2), 1)) || '.'
    end as locataire_court,
    l.date_debut,
    l.date_fin_prevue
  from serre_zones z
  left join serre_locations l on l.zone_id = z.id and l.statut = 'active'
  left join profiles p on p.id = l.tenant_id
  where z.is_active;
$$;

grant execute on function serre_occupancy() to authenticated;

COMMIT;

-- ============================================================
-- ROLLBACK (revient à la version sans locataire ni dates)
-- ============================================================
-- BEGIN;
-- drop function if exists serre_occupancy();
-- create function serre_occupancy()
-- returns table(zone_id uuid, is_occupied boolean, is_mine boolean, frais_mensuel numeric)
-- language sql security definer set search_path = public
-- as $$
--   select z.id, (l.id is not null), coalesce(l.tenant_id = auth.uid(), false), z.frais_mensuel
--   from serre_zones z
--   left join serre_locations l on l.zone_id = z.id and l.statut = 'active'
--   where z.is_active;
-- $$;
-- grant execute on function serre_occupancy() to authenticated;
-- alter table serre_locations drop column if exists date_fin_prevue;
-- COMMIT;
