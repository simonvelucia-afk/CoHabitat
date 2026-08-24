# CoHabitat — appliance autonome

Déploie CoHabitat comme un logiciel installé chez le client : une seule
machine, un réseau fermé, aucune dépendance à un service en ligne. Les
immeubles qui le souhaitent se jumellent ensuite deux à deux à travers
le VPN de l'exploitant, sans passer par une autorité centrale.

---

## Ce que contient la pile

| Service | Rôle | Exposé ? |
|---|---|---|
| `db` | PostgreSQL 16 + PostGIS — toutes les données de l'immeuble | non |
| `auth` | GoTrue — comptes, mots de passe, jetons | non |
| `rest` | PostgREST — l'API que consomme l'interface | non |
| `federation` | Passerelle vers les instances jumelées | non |
| `web` | Caddy — sert l'interface et route tout le reste | **oui** (80/443) |

Un seul port entre dans la machine. La base, l'authentification et l'API
ne sont joignables que depuis le réseau interne de la pile ; les autres
instances CoHabitat passent par la même porte que les usagers.

## Prérequis

- Docker et Docker Compose v2
- 4 Go de RAM, 20 Go de disque (davantage si l'historique est long)
- Un nom d'hôte résolvable sur le réseau de l'immeuble
- Node.js 22 sur la machine, seulement pour les scripts d'installation

## Installation

```bash
cd deploy
cp .env.example .env
$EDITOR .env                    # INSTANCE_ID, SITE_URL, SITE_HOST

# Sur une machine connectée, AVANT de transporter le paquet :
./scripts/fetch-vendor.sh       # librairies tierces en local

./cohabitat init                # secrets + configuration de l'interface
./cohabitat up                  # démarrage
```

`init` fabrique tout ce qui est propre à l'instance : le secret JWT
partagé par GoTrue et PostgREST, les clés `anon` et `service_role`, les
mots de passe Postgres, et la paire de clés Ed25519 qui donne à
l'instance son identité dans la fédération. Rien de tout cela n'entre
dans le dépôt (`.gitignore` de `deploy/`).

### Premier administrateur

L'inscription se fait par l'interface. Ensuite, sur la machine :

```bash
docker compose exec db psql -U postgres cohabitat \
  -c "UPDATE profiles SET role='principal_admin' WHERE email='vous@immeuble.lan';"
```

## Réseau fermé : ce qui change

- **Aucun courriel ne sort.** `MAILER_AUTOCONFIRM=true` confirme les
  comptes à l'inscription, sinon personne ne pourrait se connecter. La
  réinitialisation de mot de passe passe alors par un administrateur.
  Avec un relais SMTP interne, remplir le bloc SMTP et repasser à `false`.
- **Aucune librairie n'est téléchargée.** `OFFLINE_ASSETS=true` fait
  pointer l'interface vers `vendor/`, rempli par `fetch-vendor.sh`. Les
  polices sont facultatives (`--fonts`) ; sans elles, la pile de polices
  système prend le relais.
- **Aucune licence n'est vérifiée.** `CENTRAL_ENABLED=false` court-circuite
  le contrôle de licence et de contrat : c'est indispensable, faute de
  quoi l'absence de réponse de la centrale bloquerait tous les résidents.
- **Les certificats sont internes.** Un nom en `.lan` ne peut pas obtenir
  de certificat public : Caddy émet le sien. Installer sa racine
  (`/data/caddy/pki`) sur les postes, ou rester en `http://` si le réseau
  est déjà de confiance.
- **Le module Machine Lunch et la facturation demandent la centrale** :
  leurs tables et fonctions y vivent. Voir « Se rattacher à une centrale »
  plus bas. Sans elle, les écrans correspondants affichent une erreur de
  chargement — le reste de l'application fonctionne normalement.

## Accès des locataires depuis le réseau de l'immeuble

C'est le mode nominal : un locataire sur le Wi-Fi de l'immeuble ouvre
`https://cohabitat.pointe-est.lan` dans son navigateur — téléphone,
tablette ou ordinateur, sans application à installer — et **aucun octet
ne sort du bâtiment**. Réservations d'espaces, covoiturage, serre,
billets, soldes et transactions : tout est servi par la machine du local
technique.

Trois choses à régler pour que ça marche sur tous les appareils :

**1. Le nom doit se résoudre sur le réseau.** Ajouter un enregistrement
`A` dans le DNS du routeur, pointant `cohabitat.pointe-est.lan` vers
l'IP de la machine. La plupart des routeurs (OPNsense, pfSense, UniFi,
même les box grand public) le permettent. À défaut, servir directement
sur l'adresse IP en mettant cette IP dans `SITE_URL` et `SITE_HOST` —
moins joli, mais ça fonctionne.

**2. Le certificat doit être accepté.** Un nom en `.lan` ne peut pas
obtenir de certificat public : Caddy émet le sien, que les navigateurs
signalent comme inconnu. Deux issues :

- installer la racine de Caddy (`/data/caddy/pki/authorities/local/root.crt`,
  récupérable avec `docker compose cp web:/data/caddy/pki/authorities/local/root.crt .`)
  sur les appareils des locataires — propre, mais une manipulation par appareil ;
- ou servir en `http://` sur un réseau déjà de confiance, en mettant
  `SITE_URL=http://...`. Les mots de passe circulent alors en clair sur
  le réseau local : acceptable sur un VLAN dédié, pas sur un Wi-Fi
  invité partagé.

Si l'immeuble possède un vrai domaine et que la machine peut sortir le
temps d'un renouvellement, Let's Encrypt avec un challenge DNS donne un
certificat reconnu partout sans exposer le serveur.

**3. Les appareils doivent atteindre la machine.** Un VLAN « résidents »
avec une seule règle vers l'IP du serveur suffit, et vaut mieux qu'un
réseau plat.

### Accès depuis l'extérieur

Un locataire en déplacement passe par le VPN de l'immeuble : une fois le
tunnel monté, il voit exactement le même site à la même adresse. C'est le
même tunnel que celui du jumelage entre immeubles — rien de plus à
installer côté serveur.

### Ce qui a encore besoin d'Internet

| Fonction | Dépendance |
|---|---|
| Réservations, covoiturage, serre, billets, soldes | **aucune** |
| Transactions entre immeubles jumelés | le VPN (pas Internet en soi) |
| Accès des locataires hors du bâtiment | le VPN |
| Courriels (mot de passe oublié, avis) | un relais SMTP, ou rien si `MAILER_AUTOCONFIRM=true` |
| Machine Lunch et facturation | la centrale Modulimo, jointe par le VPN si elle est ailleurs |

Autrement dit : en fonctionnement normal, la seule dépendance sortante
est le VPN, et uniquement pour ce qui traverse réellement les murs.

## Jumeler deux instances

Le VPN est fourni par l'exploitant (WireGuard, Tailscale, tunnel
opérateur) : l'appliance suppose seulement que le pair est joignable à
une URL. Le jumelage n'échange **que des clés publiques** ; aucun secret
ne circule, et un pair reste inerte tant qu'un administrateur ne lui a
pas accordé de droits.

Sur l'immeuble A :

```bash
./cohabitat peer add https://cohabitat.immeuble-b.lan
```

A lit l'identité de B, l'enregistre `pending`, puis présente la sienne à
B — qui l'enregistre `pending` de son côté. Ensuite, **chaque
administrateur autorise l'autre**, en choisissant ce qu'il ouvre :

```bash
# sur A                                        # sur B
./cohabitat peer allow immeuble-b \            ./cohabitat peer allow immeuble-a \
    --reservations --finance --limit 200           --reservations --limit 0
```

| Réglage | Effet |
|---|---|
| `--reservations` | les usagers du pair peuvent réserver les espaces **explicitement partagés** |
| `--finance` | les soldes peuvent circuler entre les deux instances |
| `--limit N` | exposition nette maximale acceptée vis-à-vis de ce pair, en dollars |

Le jumelage n'est pas symétrique : B peut accepter les réservations de A
sans jamais accepter de mouvement d'argent.

Partager un espace, côté propriétaire :

```sql
UPDATE common_spaces SET federation_shared = TRUE WHERE name = 'Atelier';
```

Par défaut, **rien** ne sort de l'immeuble.

État du lien et des créances :

```bash
./cohabitat peer list      # statut, droits, plafond, dernier contact
./cohabitat peer ledger    # solde net par pair
./cohabitat doctor         # santé des services + identité publiée
```

Couper un lien : `./cohabitat peer suspend <id>` (réversible) ou
`revoke <id>`.

## Brancher une caméra

La page Espaces peut afficher le flux d'une caméra entre la grille des
espaces et la serre. **Affichage seulement** : le pilotage PTZ reste dans
l'outil du serveur caméra, auquel on se connecte directement. Un ordre de
mouvement mal arrêté fait pivoter une caméra indéfiniment, et ce risque
n'a pas sa place dans une application que tous les locataires ouvrent.

L'application n'émet donc aucune requête vers le serveur caméra : elle
pointe l'iframe, rien de plus. Le flux ne transite jamais par CoHabitat
et rien n'est enregistré côté application.

```js
cameras: {
  enabled:    true,
  visibility: 'admin',       // ou 'tenants'
  baseUrl:    '',            // vide = même origine (recommandé)
  streamPath: '/stream/stream.html?src=',
  camera:     'cam1',
  label:      'Caméra — entrée principale'
}
```

### Qui voit l'image

`visibility` vaut `'admin'` par défaut : la section n'existe alors pas du
tout pour un locataire, ni image ni cadre.

Le choix mérite réflexion selon ce que filme la caméra. Une salle
commune, un atelier, une terrasse : diffuser le flux aux locataires a une
utilité claire — savoir si l'espace est libre — pour un coût faible en
vie privée. Une **entrée principale ou un stationnement**, c'est autre
chose : le flux montre les allées et venues de personnes identifiables,
leurs visiteurs et leurs horaires. Surveiller l'entrée est défendable ;
la diffuser en direct à tout l'immeuble l'est beaucoup moins, et
l'objectif de sécurité ne l'exige pas.

Si vous ouvrez malgré tout une caméra d'entrée aux locataires : affichage
réglementaire à l'entrée, mention dans la politique de confidentialité,
et politique de conservation explicite côté enregistreur. La Commission
d'accès à l'information a publié des orientations sur la vidéosurveillance
en immeuble résidentiel.

### Montage réseau

**Laisser `baseUrl` vide et faire servir le serveur caméra par le même
reverse proxy** est fortement recommandé. Une URL `http://` explicite
fonctionne tant que CoHabitat est lui aussi en `http`, mais le navigateur
la bloquera dès le passage en `https` — contenu mixte, sans message
clair, juste un cadre noir.

Dans le `Caddyfile`, en supposant go2rtc sur 1984 :

```
handle /stream/* {
	uri strip_prefix /stream
	reverse_proxy 192.168.0.118:1984
}
```

## Se rattacher à une centrale

Une centrale Modulimo peut servir à la fois des immeubles hébergés et des
instances installées chez le client. Pour cette instance-ci, le
rattachement se fait par le VPN, en deux gestes :

```bash
# sur la centrale, une fois le tunnel monté
./modulimo building enroll https://cohabitat.pointe-est.lan "Pointe-Est"
```

```bash
# ici : CENTRAL_ENABLED=true et CENTRAL_URL dans .env, puis
./cohabitat init && ./cohabitat up
```

L'`enroll` lit `/federation/v1/identity` et enregistre la **clé publique**
de cette instance. Aucun secret ne change de main.

### Ce que fait la passerelle

Les jetons de vos résidents sont signés en HS256 avec un secret qui ne
sort jamais d'ici : la centrale ne peut donc pas les vérifier. L'interface
n'appelle plus la centrale directement — elle appelle la passerelle
locale, qui vérifie le jeton du résident sur place, puis signe une
assertion de 60 secondes avec la clé privée de fédération. La centrale
vérifie cette assertion avec la clé publique qu'elle a reçue à
l'enregistrement.

Conséquence utile : une centrale compromise ne peut pas se faire passer
pour un de vos résidents, et le rattachement se coupe d'un seul côté en
retirant l'entrée du registre.

### Quand le lien tombe

L'instance continue de servir l'immeuble. Seuls les écrans qui dépendent
de la centrale se dégradent — solde central, Machine Lunch, facturation —
et la bannière hors-ligne s'affiche. Les opérations financières déjà
engagées repartent avec la même clé d'idempotence au retour du lien : pas
de double débit.

L'adresse VPN doit rester stable : elle est enregistrée comme émetteur
(`jwt_issuer`) au moment de l'`enroll`. En changer invalide
l'enregistrement, qu'il faut alors refaire.

## Ce qui garantit la cohérence de l'argent

Une réservation croisée touche deux bases que rien ne synchronise. Trois
règles tiennent l'ensemble :

1. **Le prix fait foi chez le propriétaire.** L'instance qui possède
   l'espace recalcule le coût et refuse (`price_mismatch`) si le montant
   annoncé diffère. Un pair compromis ne fixe pas ses propres tarifs.
2. **On engage avant d'appeler.** Le débit du locataire et la créance
   sur le pair sont écrits dans la même transaction, *avant* l'appel
   réseau. Si le VPN tombe ensuite, l'opération reste en file et sera
   rejouée avec la même clé d'idempotence — le pair ne créera jamais deux
   réservations. Après épuisement des tentatives, l'argent est rendu au
   locataire et la créance annulée, toujours dans la même transaction.
3. **Le plafond borne la casse.** `finance_credit_limit` refuse tout
   mouvement entrant qui porterait l'exposition nette au-delà de ce qui a
   été accepté.

Ces règles sont vérifiées par `sql/tests/federation_test.sql` (13
assertions sur une vraie base) et par les tests du service :

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ../sql/tests/federation_test.sql
cd federation && npm test        # 32 tests, aucune dépendance
```

## Sauvegarde

```bash
./cohabitat backup /mnt/sauvegardes
```

Produit deux fichiers : le dump de la base et une archive des secrets.
**Les deux sont nécessaires** — sans `JWT_SECRET`, les jetons émis ne
sont plus vérifiables et personne ne peut se reconnecter ; sans la clé
privée de fédération, les pairs ne reconnaissent plus l'instance.
Conserver l'archive des secrets ailleurs que le dump.

Restauration : `./cohabitat restore <fichier.sql.gz>`, puis remettre en
place `.env`, `.env.secrets` et `secrets/`.

## Mises à jour

```bash
git pull
./cohabitat migrate     # n'applique que les migrations nouvelles
./cohabitat up
```

Chaque fichier SQL appliqué est inscrit avec l'empreinte de son contenu.
Un fichier déjà appliqué est ignoré ; un fichier modifié après coup
**arrête** la migration plutôt que de rejouer un script qui n'est pas
rejouable. Une correction se fait donc par une nouvelle migration.

## Diagnostic

| Symptôme | Piste |
|---|---|
| `./cohabitat up` puis page blanche | `docker compose logs web rest` ; vérifier que `SITE_HOST` correspond au nom utilisé dans le navigateur |
| Connexion refusée à l'inscription | `MAILER_AUTOCONFIRM` à `false` sans SMTP joignable |
| `401` sur toutes les requêtes de données | `.env.secrets` régénéré après coup : `JWT_SECRET` ne correspond plus aux clés servies dans `generated/config.js` — relancer `./cohabitat init` puis `up` |
| Espaces du pair absents | `./cohabitat peer list` (statut `active` ?), `federation_shared` côté pair, VPN debout |
| Réservation « part dès le retour du lien » | normal : le pair était injoignable, la file rejouera |
| `db-migrate` s'arrête sur un fichier modifié | comportement voulu — créer une nouvelle migration |
