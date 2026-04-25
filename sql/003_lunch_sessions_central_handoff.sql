-- 003_lunch_sessions_central_handoff.sql
-- Permet a CoHabitat de transmettre au kiosque LunchMachine, dans la row
-- lunch_sessions one-shot creee par openKiosk(), les deux pieces dont le
-- kiosque a besoin pour debiter la centrale au lieu de la base locale :
--   * access_token         JWT du resident, signe par Supabase de l'immeuble.
--                          Necessaire pour appeler finance-bridge (Bearer).
--   * finance_central_enabled  reflete system_settings.finance_central_enabled
--                          au moment de la creation de la session, pour que le
--                          kiosque n'ait pas a relire system_settings (RLS
--                          empeche anon de le faire) ni a deduire l'etat.
--
-- Sans ce relais, le kiosque ouvert via chsession= reste sur la RPC locale
-- lunch_purchase de l'immeuble : le solde central n'est jamais debite, et au
-- prochain syncCentralBalanceToProfile() cote CoHabitat, le pill solde
-- "remonte" a la valeur centrale stale (symptome : "le solde n'est pas a jour
-- apres J'ai termine"). Voir la cause root dans index.html:4641.
--
-- Securite : ces colonnes ne sont peuplees que pour la fenetre 2 minutes de
-- la session (expires_at), et la row est DELETE-d des le premier read par le
-- kiosque (usage unique deja en place — index.html:4664). La fenetre
-- d'exposition est donc strictement inferieure aux 2 minutes du chsession_id
-- existant, qui donne deja un equivalent pratique d'acces anon a la session.

ALTER TABLE lunch_sessions
  ADD COLUMN IF NOT EXISTS access_token            text,
  ADD COLUMN IF NOT EXISTS finance_central_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN lunch_sessions.access_token IS
  'JWT Supabase du resident propage au kiosque pour qu''il puisse appeler
  finance-bridge sur la centrale Modulimo. NULL si pas de session active au
  moment de la creation. Efface avec la row a l''usage unique du chsession.';

COMMENT ON COLUMN lunch_sessions.finance_central_enabled IS
  'Snapshot du flag system_settings.finance_central_enabled au moment de la
  creation. Le kiosque utilise ce flag plutot que de relire system_settings
  (RLS bloque anon). Si true et access_token present, le kiosque debite via
  finance-bridge ; sinon il reste sur la RPC locale lunch_purchase.';

NOTIFY pgrst, 'reload schema';
