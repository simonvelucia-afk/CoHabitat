# CoHabitat — Guide d'installation

## 1. Créer votre projet Supabase

1. Allez sur [supabase.com](https://supabase.com) → Nouveau projet
2. Dans **SQL Editor**, collez et exécutez tout le contenu de `schema.sql`
3. Récupérez vos clés: **Project Settings → API**
   - `Project URL` (ex: `https://abcxyz.supabase.co`)
   - `anon public` key

## 2. Configurer index.html

Ouvrez `index.html` et remplacez à la ligne ~610 :
```js
const SUPABASE_URL = 'https://VOTRE_PROJECT_ID.supabase.co';
const SUPABASE_ANON_KEY = 'VOTRE_ANON_KEY';
```

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
- Chaque zone se divise en **3 sections indépendantes** numérotées depuis l'allée — codage **R1C4S2** (Rangée 1, Colonne 4, Section 2)
- Chaque section a **sa propre culture, irrigation et fertilisation** (plantes et traitements différents), pour une seule location par zone
- **Plan visuel de la serre** (orientation **verticale** uniquement) : les 2 rangées forment 2 **colonnes** de 10 zones, séparées par l'**allée principale** (bande verticale centrale) et encadrées par les 2 **tunnels à poules** (bandes verticales de bordure). Chaque zone affiche **3 chips colorés** — un par section — dont la couleur donne le statut de culture (**neutre** = vide, **vert** = en croissance, **ambre** = récolté) et l'emoji ce qui pousse : l'état se lit sans cliquer. Le plan occupe la **pleine largeur** : chaque section affiche l'**icône de la plante** et son **stade** en clair. Chaque zone montre **qui la loue** (prénom + initiale) et la **période**, en version courte ; ces informations et le stade apparaissent dès que la colonne est assez large — sur mobile, pivoter l'appareil suffit. **Clic sur une section** → le formulaire de cette section (locataire et admin) ou le résumé de la zone (autres) ; **clic sur l'en-tête** → demande de location si la zone est libre, libération si c'est la vôtre. Bouton **« Plan seul »** : masque le header/nav pour donner tout l'écran au plan (`100svh`, sans `requestFullscreen()`). Clic sur une zone → détails + historique
- Suivi par section : culture, semis, récolte, statut, rendement, irrigation (fréquence/système), fertilisation, notes
- Historique des cultures **par section** + export CSV (une ligne par section)
- Suivi des conditions : température de l'air + **niveau et température propres à chacun des 3 réservoirs**. **Acquisition automatique** via un Raspberry Pi 5 + MQTT (voir `serre-iot/`) ; la **saisie manuelle vit uniquement dans le panneau admin** (onglet 🌱 Serre) — sur la page Espaces, le bloc est en **lecture seule pour tout le monde** (même composant `ConditionsSerre`, prop `readOnly`), et la restriction est appliquée **au niveau de la table** par la RLS `serre_lectures_insert`, pas seulement masquée dans l'UI
- **Panneau admin** (onglet 🌱 Serre) : **saisie manuelle des conditions** (dépannage si un capteur est HS) + **frais mensuel de base modifiable** (appliqué à toutes les zones) + attribution des zones aux locataires (revenu mensuel, zones occupées) + **frais d'exploitation** de la serre (semences, terreau, eau, électricité…)
- Activable/désactivable par l'admin (module optionnel `module_serre`)
- Migrations : `sql/009_serre.sql`, `sql/010_serre_reservoir_temps.sql`, `sql/012_serre_couts_module.sql`, `sql/013_serre_frais_base.sql`, `sql/014_serre_lectures_admin_insert.sql`, `sql/015_serre_plan_locataire.sql`

### Administration
- Gestion des locataires et unités
- Gestion des espaces communs + tarification
- Gestion des véhicules + tarification
- Enregistrement des paiements réels → crédits virtuels
- **Élevages** (onglets 🐔 Poulailler et 🐟 Poissons) : historique des poules/poissons (ajouts, pertes, ponte/récolte, santé) + coûts d'exploitation, avec cheptel courant et total des coûts. Les faits saillants (ajout, ponte/récolte) sont **publiés automatiquement au babillard**. Migration : `sql/011_elevages.sql`
- Paramètres système (délais annulation, etc.)
- Logs de toutes les actions (dont mode démo)

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
| `serre_fertilisations` | Applications de fertilisant par section |
| `serre_irrigation_config` | Config d'irrigation par section (zone_id, section) |
| `serre_reservoirs` | Réservoirs d'eau de la serre |
| `serre_lectures` | Lectures de capteurs (températures, niveaux) |
| `elevage_historique` | Historique poulailler / sablonponie (événements) |
| `elevage_couts` | Coûts d'exploitation serre / poulailler / sablonponie |
