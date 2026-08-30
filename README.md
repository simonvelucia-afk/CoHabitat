# CoHabitat — Guide d'installation

Deux façons de déployer, à partir du même code :

- **Hébergé** — interface sur GitHub Pages, base sur Supabase. C'est le
  mode décrit ci-dessous.
- **Appliance autonome** — tout tourne sur une machine de l'immeuble, en
  réseau fermé, sans dépendance à un service en ligne, avec jumelage
  facultatif entre immeubles par VPN. Voir **[`deploy/README.md`](deploy/README.md)**.

Aucune URL ni clé n'est écrite dans `index.html` : tout ce qui change
d'un déploiement à l'autre vit dans **`config.js`**.

## Ajouter un immeuble

Chaque immeuble est une instance séparée : sa propre base, ses propres
comptes, ses propres données. Rien n'est partagé entre immeubles — c'est
ce qui permet d'en vendre un sans toucher aux autres.

Le seul fichier qui diffère d'un immeuble à l'autre est **`config.js`**.
Tout le reste du code est identique.

### En hébergé (GitHub Pages + Supabase)

```bash
node deploy/scripts/new-building.mjs \
  --id pointe-est --nom "Pointe-Est" \
  --site https://cohabitat.pointe-est.com \
  --supabase https://abcxyz.supabase.co \
  --cle eyJhbGciOi... > config.js
```

Le script produit le `config.js` de l'immeuble et rappelle les cinq
étapes restantes : appliquer le schéma au nouveau projet Supabase,
régler les URL d'authentification, publier le dépôt, promouvoir le
premier administrateur, enregistrer l'immeuble à la centrale.

**Un dépôt par immeuble**, parce que GitHub Pages ne sert qu'un seul
site par dépôt et qu'un domaine personnalisé y est attaché. La façon la
moins pénible de tenir plusieurs dépôts à jour :

```bash
# une fois, dans le dépôt de l'immeuble
git remote add upstream https://github.com/simonvelucia-afk/CoHabitat.git

# à chaque mise à jour
git fetch upstream && git merge upstream/main
git checkout --ours config.js && git add config.js   # garder sa config
```

Comme `config.js` est le seul fichier propre à l'immeuble, c'est le seul
conflit possible, et il se résout toujours de la même façon.

> Si le nombre d'immeubles devient inconfortable, un hébergeur statique
> qui accepte plusieurs domaines par site (Cloudflare Pages, Netlify)
> permet de revenir à un seul dépôt, `config.js` choisissant l'instance
> d'après `window.location.hostname`. GitHub Pages ne le permet pas.

### En appliance (réseau fermé)

Pas de dépôt ni d'URL à créer : le même checkout sert tous les
immeubles, et `deploy/scripts/render-config.mjs` génère `config.js` à
partir du `.env` de la machine. Voir [`deploy/README.md`](deploy/README.md).

## 1. Créer votre projet Supabase

1. Allez sur [supabase.com](https://supabase.com) → Nouveau projet
2. Dans **SQL Editor**, exécutez `schema.sql`, puis les fichiers de
   `sql/` dans l'ordre de leur numéro (`000_` en premier)
3. Récupérez vos clés: **Project Settings → API**
   - `Project URL` (ex: `https://abcxyz.supabase.co`)
   - `anon public` key

## 2. Configurer config.js

Ouvrez `config.js` et renseignez :
```js
supabaseUrl:     'https://VOTRE_PROJECT_ID.supabase.co',
supabaseAnonKey: 'VOTRE_ANON_KEY',
siteUrl:         'https://votre-domaine',
```
Le même fichier porte l'URL de la centrale Modulimo (`central`), la
Machine Lunch, l'analytique et l'emplacement des librairies tierces.
Mettre `central.enabled` à `false` rend l'instance entièrement autonome :
plus aucune requête ne sort, la finance reste locale et le contrôle de
licence est court-circuité.

## 3. Héberger sur GitHub Pages

1. Créez un repo GitHub (ex: `cohabitat`)
2. Déposez `index.html` à la racine
3. **Settings → Pages → Source: Deploy from branch → main**
4. Votre site sera disponible à `https://votre-user.github.io/cohabitat`

## 4. Configurer Supabase Auth

Dans Supabase → **Authentication → URL Configuration**:
- **Site URL**: `https://votre-user.github.io/cohabitat`
- **Redirect URLs**: `https://votre-user.github.io/cohabitat`

## 5. Créer le premier admin principal

1. Inscrivez-vous via le site
2. Dans Supabase → **Table Editor → profiles**
3. Trouvez votre ligne et changez `role` → `principal_admin`

---

## Fonctionnalités incluses

### Locataires
- Tableau de bord avec solde et réservations
- **Résumé « Ma serre »** sur le tableau de bord : zones louées et cultures en cours (par section, avec stade et dates), récoltes passées avec rendement cumulé par unité, et locations terminées
- Réservation d'espaces communs par tranches de 15 min
- Consultation et demande de covoiturage
- Historique des transactions

### Chauffeurs approuvés
- Publication de trajets avec arrêts intermédiaires
- Gestion des passagers (accepter/refuser)
- Déclaration des personnes à charge
- Sélection de l'espace cargo utilisé

### Passagers
- Demande d'embarquement sur un trajet
- Sélection point d'embarquement et de dépôt
- Réservation de cargo disponible
- Annulation avec règles configurables

### Serre communautaire
- Section dédiée en bas de la page **Espaces communs**
- Serre commune : **2 rangées × 10 colonnes = 20 zones** (2 × 3 pi), attribuables et louables **au mois** ; à la location, une **date de fin envisagée** peut être indiquée — toujours facultative, la location se reconduisant au mois jusqu'à libération (frais de base **0,50 $/mois** par zone, **modifiable par l'admin** via la variable `serre_frais_mensuel`, débité via le solde virtuel)
- **Stades de culture** : Vide → Semis → En croissance → **En production** → Terminé, plus une case **« un plant conservé pour la semence »** (porte-graine) indépendante du stade — une section peut produire et porter graine en même temps
- **Journal de cueillettes** : la plupart des légumes de serre (tomate, concombre, laitue, poivron…) donnent en continu ; chaque passage se note à part (date + quantité), et le cumul s'affiche sur le plan, dans la section et au tableau de bord. Seul le radis est traité comme une récolte unique (liste `SERRE_CULTURES_UNIQUES`)
- Chaque zone se divise en **3 sections indépendantes** numérotées depuis l'allée — codage **R1C4S2** (Rangée 1, Colonne 4, Section 2)
- Chaque section a **sa propre culture, irrigation et fertilisation** (plantes et traitements différents), pour une seule location par zone
- **Plan visuel de la serre** (orientation **verticale** uniquement) : les 2 rangées forment 2 **colonnes** de 10 zones, séparées par l'**allée principale** (bande verticale centrale) et encadrées par les 2 **tunnels à poules** (bandes verticales de bordure). Chaque zone affiche **3 chips colorés** — un par section — dont la couleur donne le statut de culture (**neutre** = vide, **vert** = en croissance, **ambre** = récolté) et l'emoji ce qui pousse : l'état se lit sans cliquer. Le plan occupe la **pleine largeur** : chaque section affiche l'**icône de la plante** et son **stade** en clair. Chaque zone montre **qui la loue** (prénom + initiale) et la **période**, en version courte ; ces informations et le stade apparaissent dès que la colonne est assez large — sur mobile, pivoter l'appareil suffit. **Clic sur une section** → le formulaire de cette section (locataire et admin) ou le résumé de la zone (autres) ; **clic sur l'en-tête** → demande de location si la zone est libre, libération si c'est la vôtre. Bouton **« Plan seul »** : masque le header/nav pour donner tout l'écran au plan (`100svh`, sans `requestFullscreen()`). Clic sur une zone → détails + historique
- Suivi par section : culture, semis, récolte, statut, rendement, irrigation (fréquence/système), fertilisation, notes
- Historique des cultures **par section** + export CSV (une ligne par section)
- Suivi des conditions : température de l'air + **niveau et température propres à chacun des 3 réservoirs**. **Acquisition automatique** via un Raspberry Pi 5 + MQTT (voir `serre-iot/`) ; la **saisie manuelle vit uniquement dans le panneau admin** (onglet 🌱 Serre) — sur la page Espaces, le bloc est en **lecture seule pour tout le monde** (même composant `ConditionsSerre`, prop `readOnly`), et la restriction est appliquée **au niveau de la table** par la RLS `serre_lectures_insert`, pas seulement masquée dans l'UI
- **Panneau admin** (onglet 🌱 Serre) : **saisie manuelle des conditions** (dépannage si un capteur est HS) + **frais mensuel de base modifiable** (appliqué à toutes les zones) + attribution des zones aux locataires (revenu mensuel, zones occupées) + **frais d'exploitation** de la serre (semences, terreau, eau, électricité…)
- Activable/désactivable par l'admin (module optionnel `module_serre`)
- Migrations : `sql/009_serre.sql`, `sql/010_serre_reservoir_temps.sql`, `sql/012_serre_couts_module.sql`, `sql/013_serre_frais_base.sql`, `sql/014_serre_lectures_admin_insert.sql`, `sql/015_serre_plan_locataire.sql`, `sql/016_serre_recoltes_stades.sql`

### LAB — amélioration continue
- Sous-menu **🧪 LAB** du Babillard : le babillard sert à la vie de l'immeuble, le LAB à celle de l'application
- **Qualifier les fonctions** : une note de 1 à 5 par fonction (babillard, tableau de bord, espaces, serre, auto-partage, Machine Lunch, billets, transactions, profil, multilingue, usage mobile, et le LAB lui-même) avec un commentaire libre. Moyenne communautaire, répartition des notes et commentaires reçus s'affichent sur chaque carte ; on peut revenir modifier sa note à tout moment. Les fonctions des modules désactivés n'apparaissent pas
- **Idées à brainstormer** : proposer une amélioration ou une nouvelle fonction, appuyer les idées des autres (un vote par personne) et en discuter dans un fil. Filtres par statut et par type, tri par appuis ou par date
- **Suivi par l'admin** : cycle `nouveau → à l'étude → planifié → en cours → livré / écarté`, avec un mot de l'équipe visible par tout le monde sous l'idée
- **Tout est stocké en base** (tables `lab_*`), pas dans le navigateur : c'est la matière première des prochaines versions
- Traduit en français, anglais, espagnol et chinois ; consultable en mode démo (contributions réservées aux comptes)
- Migration : `sql/030_lab.sql`

### Administration
- Gestion des locataires et unités
- Gestion des espaces communs + tarification
- Gestion des véhicules + tarification
- Enregistrement des paiements réels → crédits virtuels
- **Élevages** (onglets 🐔 Poulailler et 🐟 Poissons) : historique des poules/poissons (ajouts, pertes, ponte/récolte, santé) + coûts d'exploitation, avec cheptel courant et total des coûts. Les faits saillants (ajout, ponte/récolte) sont **publiés automatiquement au babillard**. Migration : `sql/011_elevages.sql`
- Paramètres système (délais annulation, etc.)
- Logs de toutes les actions (dont mode démo)

### Traductions

L'interface est disponible en **français, anglais et espagnol** (sélecteur dans la barre de navigation). Le module serre est entièrement traduit : libellés, stades, noms de cultures, unités, systèmes d'irrigation et fertilisants. Les **valeurs stockées en base restent en français** (`serre_cultures.culture`, `rendement_unite`…) — seul l'affichage est traduit, pour ne pas casser les données existantes ni les clés d'icônes.

### Mode démo
- Accès sans compte via bouton "Démo"
- Consultation complète sans restriction
- Toutes les actions sont loggées pour analyse
- Aucune réservation réelle n'est créée

---

## Architecture de la base de données

| Table | Description |
|-------|-------------|
| `profiles` | Utilisateurs (liés à auth.users) |
| `common_spaces` | Espaces communs |
| `space_pricing` | Tarification des espaces |
| `space_reservations` | Réservations d'espaces |
| `vehicles` | Véhicules |
| `vehicle_pricing` | Tarification des véhicules |
| `trips` | Trajets publiés par chauffeurs |
| `trip_stops` | Arrêts intermédiaires |
| `trip_bookings` | Demandes passagers |
| `driver_dependent_seats` | Personnes à charge chauffeur |
| `trip_cargo_usage` | Utilisation cargo |
| `transactions` | Toutes les transactions financières |
| `real_payments` | Paiements réels enregistrés par admins |
| `reservation_requests` | Log de toutes les actions |
| `notifications` | Notifications utilisateurs |
| `system_settings` | Paramètres configurables |
| `serre_zones` | Zones de culture de la serre (fixes) |
| `serre_locations` | Locations mensuelles d'une zone par un locataire |
| `serre_cultures` | Cycles de culture par section (1-3) d'une zone |
| `serre_recoltes` | Journal des cueillettes : une ligne par passage (cultures continues) |
| `serre_fertilisations` | Applications de fertilisant par section |
| `serre_irrigation_config` | Config d'irrigation par section (zone_id, section) |
| `serre_reservoirs` | Réservoirs d'eau de la serre |
| `serre_lectures` | Lectures de capteurs (températures, niveaux) |
| `elevage_historique` | Historique poulailler / sablonponie (événements) |
| `elevage_couts` | Coûts d'exploitation serre / poulailler / sablonponie |
| `lab_evaluations` | LAB : note 1-5 + commentaire d'un résident sur une fonction |
| `lab_idees` | LAB : améliorations et nouvelles fonctions proposées |
| `lab_idee_votes` | LAB : appuis à une idée (un par personne) |
| `lab_idee_commentaires` | LAB : fil de discussion sous une idée |
