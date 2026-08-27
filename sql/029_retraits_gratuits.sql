-- 029_retraits_gratuits.sql
-- Rendre possible — et visible — le retrait sans prix a la machine lunch.
--
-- CE QUI NE MARCHAIT PAS
--
-- Le kiosque ecrit une trace dans lunch_transactions quand une case est
-- prise sans prix (price = 0). Or la 001 a active RLS sur cette table et
-- n'y a pose qu'une seule politique, en SELECT. Aucune politique INSERT :
-- toute ecriture directe est donc refusee.
--
--   ERROR: new row violates row-level security policy for table
--          "lunch_transactions"
--
-- Le kiosque avalait l'erreur dans un console.error. Resultat : chaque
-- retrait gratuit echouait sans bruit, et l'historique n'a jamais existe.
--
-- La 001 disait « seul le RPC lunch_purchase (SECURITY DEFINER) y insere ».
-- C'est vrai des ACHATS, et ce doit le rester : un resident ne doit pas
-- pouvoir se fabriquer une ligne d'achat. Mais un retrait gratuit ne passe
-- par aucun RPC — il n'a rien a debiter.
--
-- CE QUE CETTE MIGRATION AUTORISE
--
-- Une insertion, et une seule forme d'insertion : la sienne, sans prix,
-- sans lien vers le ledger. Tout le reste continue de passer par le RPC.
--
-- CE QU'ELLE REND VISIBLE
--
-- La 001 limite la lecture a ses propres lignes (les admins voient tout).
-- C'est juste pour un achat : ce qu'un voisin mange ne regarde personne.
--
-- Mais la production de l'immeuble est distribuee, pas vendue, et la
-- PR precedente en avait fait un principe : une distribution opaque
-- invite au soupcon, une distribution visible se regule d'elle-meme.
-- Les retraits SANS PRIX deviennent donc lisibles par tous ; les achats
-- restent prives. La ligne est nette et tient dans une condition :
-- price = 0.
--
-- Idempotente : peut etre rejouee sans erreur.

BEGIN;

-- ============================================================
-- Consigner son propre retrait sans prix
-- ============================================================
-- price = 0        : aucun achat ne peut etre forge par cette voie.
-- ledger_tx_id NULL: aucune ligne ne peut se rattacher au ledger financier.
-- user_id = uid    : personne ne consigne un retrait au nom d'un autre.
--
-- Le kiosque doit donc appeler l'API avec le JETON DE SESSION du resident,
-- pas avec la cle anon : en role `anon`, auth.uid() est NULL et cette
-- politique refuse — ce qui est exactement ce qui se passait.
drop policy if exists lunch_tx_insert_gratuit on lunch_transactions;
create policy lunch_tx_insert_gratuit on lunch_transactions
  for insert to authenticated
  with check (
    price = 0
    and ledger_tx_id is null
    and user_id = auth.uid()
  );

-- ============================================================
-- Lire les retraits sans prix
-- ============================================================
-- Politique SUPPLEMENTAIRE : les politiques permissives s'additionnent
-- par OU. lunch_tx_select_own continue de couvrir les achats ; celle-ci
-- n'ouvre que les lignes a prix nul.
drop policy if exists lunch_tx_select_gratuit on lunch_transactions;
create policy lunch_tx_select_gratuit on lunch_transactions
  for select to authenticated
  using (price = 0);

-- Un retrait consigne par erreur doit pouvoir etre repris — par la
-- personne elle-meme, comme pour elevage_retraits (028). Les achats ne
-- s'effacent pas : ils ont une contrepartie au ledger.
drop policy if exists lunch_tx_delete_gratuit on lunch_transactions;
create policy lunch_tx_delete_gratuit on lunch_transactions
  for delete to authenticated
  using (price = 0 and ledger_tx_id is null and user_id = auth.uid());

-- Sans ces droits de table, les politiques ne sont jamais consultees.
grant select, insert, delete on lunch_transactions to authenticated;

-- ============================================================
-- Le numero de case, celui qui est ecrit sur la machine
-- ============================================================
-- slot_id porte l'identifiant de lunch_slots sur la base CENTRALE — un
-- « db-3 » que personne ne lit jamais sur la porte. CoHabitat ne peut pas
-- le traduire : la table qui ferait la correspondance est sur l'autre
-- base. Sans ce numero, relier une offre a sa case demanderait a
-- l'operateur de connaitre une cle technique.
--
-- La machine l'a sous la main : c'est le numero qu'elle affiche. Elle le
-- consigne desormais, et la jointure se fait sur ce que tout le monde
-- peut verifier en regardant la porte.
alter table lunch_transactions
  add column if not exists slot_num integer;

comment on column lunch_transactions.slot_num is
  'Numero de case visible sur la machine. slot_id porte l''identifiant technique de lunch_slots, sur la base centrale.';

-- Lire l'historique d'une case demande de filtrer dessus.
create index if not exists idx_lunch_tx_slot_gratuit
  on lunch_transactions(slot_num, created_at desc)
  where price = 0;

-- ============================================================
-- Relier une offre a la case qui la porte
-- ============================================================
-- Reference VOLONTAIREMENT MOLLE (TEXT, sans cle etrangere) : lunch_slots
-- vit sur la base CENTRALE, partagee entre immeubles, tandis que
-- elevage_offres vit sur la base de cet immeuble. Une contrainte ne peut
-- pas traverser deux bases. lunch_transactions.slot_id est deja de ce
-- type, et pour la meme raison.
alter table elevage_offres
  add column if not exists machine_id text,
  add column if not exists slot_num   integer;

comment on column elevage_offres.slot_num is
  'Numero de case de la machine lunch qui porte cette offre — celui qui est ecrit sur la porte. Reference molle : lunch_slots vit sur la base centrale, aucune cle etrangere ne peut la traverser.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- ROLLBACK (manuel)
-- ============================================================
-- BEGIN;
-- drop policy if exists lunch_tx_insert_gratuit on lunch_transactions;
-- drop policy if exists lunch_tx_select_gratuit on lunch_transactions;
-- drop policy if exists lunch_tx_delete_gratuit on lunch_transactions;
-- drop index if exists idx_lunch_tx_slot_gratuit;
-- alter table elevage_offres drop column if exists machine_id, drop column if exists slot_num;
-- alter table lunch_transactions drop column if exists slot_num;
-- COMMIT;
