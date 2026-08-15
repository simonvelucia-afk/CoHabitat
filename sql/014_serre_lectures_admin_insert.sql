-- 014_serre_lectures_admin_insert.sql
-- Conditions de la serre : la saisie manuelle devient réservée aux admins.
--
-- Avant : tout locataire authentifié pouvait insérer une lecture
--         (with check created_by = auth.uid()).
-- Après : SELECT reste ouvert à tous les authentifiés (vue locataire en
--         lecture seule), INSERT restreint au rôle admin — au niveau de la
--         table, pas seulement masqué dans l'UI.
--
-- Note : le pont IoT (serre-iot/, Raspberry Pi + MQTT) écrit avec un compte
-- « appareil » dédié (@device.local) qui n'est pas admin. Une exception
-- explicite lui est donc conservée, sinon l'acquisition automatique cesse.
--
-- Idempotente : peut être rejouée sans erreur.

BEGIN;

-- Le compte appareil est identifié par le suffixe d'e-mail @device.local
-- (même convention que les listes de résidents, qui l'excluent déjà).
create or replace function serre_is_capteur()
returns boolean as $$
  select coalesce(
    (select lower(email) like '%@device.local' from profiles where id = auth.uid()),
    false
  );
$$ language sql security definer stable;

-- ── SELECT : ouvert à tous les authentifiés (inchangé) ──────────
drop policy if exists serre_lectures_select on serre_lectures;
create policy serre_lectures_select on serre_lectures
  for select to authenticated using (true);

-- ── INSERT : admins uniquement (+ compte capteur pour le pont IoT) ──
drop policy if exists serre_lectures_insert on serre_lectures;
create policy serre_lectures_insert on serre_lectures
  for insert to authenticated
  with check (
    get_my_role() in ('admin', 'principal_admin')
    or serre_is_capteur()
  );

-- ── UPDATE / DELETE : admins uniquement (inchangé) ──────────────
drop policy if exists serre_lectures_admin on serre_lectures;
create policy serre_lectures_admin on serre_lectures
  for all to authenticated
  using (get_my_role() in ('admin', 'principal_admin'))
  with check (get_my_role() in ('admin', 'principal_admin'));

COMMIT;

-- ============================================================
-- ROLLBACK (rétablit la saisie par tout locataire)
-- ============================================================
-- BEGIN;
-- drop policy if exists serre_lectures_insert on serre_lectures;
-- create policy serre_lectures_insert on serre_lectures
--   for insert to authenticated
--   with check (created_by = auth.uid() or get_my_role() in ('admin', 'principal_admin'));
-- drop function if exists serre_is_capteur();
-- COMMIT;
