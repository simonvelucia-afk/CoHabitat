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
- Réservation d'un véhicule ou d'un vélomobile à l'heure, et demande de covoiturage
- Historique des transactions

### Emplois de l'immeuble

L'immeuble a du travail à confier — la serre, le poulailler, la sablonponie, le covoiturage, la Machine Lunch, l'entretien — et des résidents prêts à le faire. Migration : `sql/036_emplois.sql` (test : `sql/tests/emplois_test.sql`).

- **Offres publiées par l'administration** (Admin → 💼 Emplois) et rédigées comme une offre d'emploi : titre du poste (« Responsable de la serre », « Employé·e du poulailler », « Responsable de l'unité d'affaires covoiturage »…), secteur, niveau (responsable ou employé·e), description, **responsabilités** et **tâches** (une par ligne), taux horaire, heures par semaine, nombre de postes, date d'entrée en fonction
- **Affichées au babillard** tant qu'elles sont ouvertes ; une offre passe d'elle-même à « pourvu » quand tous ses postes sont occupés
- **Candidature depuis le profil** (Mon profil → Emplois de l'immeuble), avec un message facultatif ; l'admin embauche ou refuse
- **Heures déclarées par la personne embauchée**, depuis son profil, puis approuvées ou refusées par l'admin. Le taux est figé à la déclaration et le montant en découle — le résident ne le saisit jamais
- **Rémunération** des heures approuvées, par personne : **créditée au solde** de l'application (transaction `emploi_remuneration` au grand livre) ou **payée hors application** (chèque, virement) avec trace. Une même heure ne peut pas être payée deux fois. Avec la finance centralisée, seul le paiement hors application est proposé, pour ne pas créer d'écart avec le solde de la centrale
- Embaucher quelqu'un au **poulailler** ou à la **sablonponie** lui donne les droits d'opérateur de l'élevage (migration 027), sans le nommer administrateur

### Mobilité partagée (MaaS)

L'ancien module « Auto-partage » devient **Mobilité partagée** — *MaaS, Mobility as a Service* : les véhicules du bâtiment, les vélomobiles et le covoiturage entre résidents sont réunis dans une seule offre, sous le même onglet.

- **Réservation directe d'un véhicule** (onglet 🚲 *Réserver un véhicule*, affiché en premier) : un véhicule, un créneau, un coût **en deux temps** — la durée du créneau (`price_per_minute`) débitée à la réservation, puis les **kilomètres déclarés au retour** (`price_per_km`). Le créneau est retenu qu'il serve ou non, comme une salle commune ; les kilomètres, eux, ne sont connus qu'au retour. Ce partage n'est pas cosmétique : les frais d'exploitation d'un véhicule (énergie, entretien, pneus, amortissement) suivent les kilomètres bien plus que les heures, et facturer le temps seul ferait fondre la marge précisément sur les longs trajets C'est ce qui rend les **vélomobiles du bâtiment** réservables : on en prend un pour une heure, seul, sans annoncer où l'on va — ce que le covoiturage, qui suppose un chauffeur approuvé et des passagers, ne permettait pas
- **Flotte multimodale** : chaque véhicule porte un type (`vehicle_type` : automobile, vélomobile, vélo, autre) et un drapeau `is_reservable`. Décoché, le véhicule reste dans la flotte mais n'est accessible que par un trajet publié. La liste est groupée par mode, avec une pastille de disponibilité (libre / occupé jusqu'à…)
- **Les deux usages se voient l'un l'autre** : `check_vehicle_availability()` regarde les réservations **et** les trajets publiés, si bien qu'un vélomobile engagé sur un covoiturage n'apparaît pas libre sur ce créneau. Un trajet sans heure d'arrivée estimée réserve le véhicule deux heures
- **Créneaux déjà pris** affichés dans la fenêtre de réservation (`vehicle_busy_slots()`), bornes seulement — jamais qui a réservé
- **Ce que le tarif couvre, dit aux résidents** : un accordéon « 💡 Que couvre le tarif ? » en tête de l'onglet explique les deux natures de frais — le tarif à la minute pour ce qui court avec le temps (assurance, amortissement, stationnement, entretien du réseau de recharge, qui coûte la même chose qu'on l'utilise ou non), le tarif au kilomètre pour ce qui court avec la distance (électricité consommée à la recharge, pneus, freins, entretien mécanique). Un rappel d'une ligne accompagne le montant dans les deux fenêtres, réservation et retour
- **Prise et retour, au compteur** : le résident relève le compteur deux fois. **À la prise**, il confirme le relevé laissé par la personne précédente — un écart est conservé en base (`km_ecart`) et signalé à l'administration, sans affecter sa facturation. **Au retour**, la saisie du compteur **arrête le temps facturé** : la durée court de la prise au retour, pas jusqu'à la fin du créneau, et la distance est la différence des deux relevés. Rendre tôt coûte moins cher et libère le véhicule
- **Réconciliation** : un acompte calculé sur le créneau est débité à la réservation ; le retour ajuste — complément à payer ou différence remboursée. Les deux étapes passent par les RPC `vehicle_pickup()` et `vehicle_return()` : le compteur vit sur `vehicles`, que les résidents lisent sans l'écrire, et la durée comme la distance ne doivent pas dépendre de l'horloge du navigateur
- **Annulation** : remboursement de la part temps si elle a lieu plus de 2 h avant le début du créneau, comme pour les espaces communs ; passé ce délai le créneau reste facturé, et l'écran le dit avant de confirmer
- **Frais d'exploitation et marge (administration seulement)** : onglet ⚙️ Admin → Véhicules. On y saisit les frais du parc en distinguant leur nature — **fixe**, ce qui court avec le temps (assurance, amortissement, stationnement, entretien du réseau de recharge), et **variable**, ce qui suit les kilomètres (électricité de recharge, pneus, freins, entretien mécanique). La fonction `vehicle_marge()` rapproche revenus et frais sur une période et calcule **les tarifs qui auraient tenu la marge visée**, chaque nature rapportée à son assiette : les frais fixes aux minutes facturées, les variables aux kilomètres. Ce sont des moyennes de flotte — un véhicule tarifé sous la cible est porté par les autres, et l'écran le dit. **Rien de tout cela n'est visible côté résident** : il voit ce que son tarif couvre, jamais la marge ni la politique de prix
- Migrations : `sql/031_mobilite_partagee.sql`, `sql/032_mobilite_km.sql`, `sql/033_mobilite_compteur.sql`, `sql/034_mobilite_couts.sql`
- ⚠️ **Sur une installation branchée à la centrale Modulimo**, ajoutez `vehicle_reservation` et `vehicle_reservation_refund` à la liste blanche de types de `finance-bridge` (elle vit dans le projet central, hors de ce dépôt). Sans cela le débit est refusé et la réservation s'annule d'elle-même. Une instance autonome n'est pas concernée : elle passe par `adjust_balance()`, que la migration suffit à débloquer

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

### Énergie et confort — l'écran de l'immotique
- Sous-menu **⚡ Énergie et confort** du Tableau de bord. Module optionnel `module_energie`, **coupé par défaut** : l'admin l'active dans les réglages quand l'immeuble publie ses mesures
- **État de l'immeuble** : normal, panne Hydro (sur batterie, délestage), panne internet (mode local) ou exercice, avec son niveau **vert / bleu / orange** et un message. Les admins le publient depuis l'écran ; le compte appareil de l'immeuble peut aussi le faire
- **Mon eau chaude** : la consommation du logement aujourd'hui, sur 7 et sur 30 jours, comparée à la **moyenne de l'immeuble**. Un résident ne voit jamais les compteurs d'un voisin (RLS) ; la moyenne vient de la fonction `eau_chaude_moyenne()`, qui ne renvoie que des agrégats et **rien sous trois logements mesurés**
- **Énergie de l'immeuble** : production solaire du jour et part d'eau chaude couverte pour tous ; production instantanée, batterie, réseau et réservoir en plus pour les admins (et en démonstration)
- **Alertes** (fuite, gel, panne) : le résident voit celles de son logement et de l'immeuble, l'admin toutes, avec le nombre de personnes prévenues, et peut les marquer résolues. À l'insertion, un déclencheur écrit une **notification** aux résidents du logement concerné, ou aux admins pour une alerte d'immeuble — la bonne personne, pas tout l'immeuble
- **L'application affiche, elle ne pilote rien** : aucune table ne commande un équipement
- **Alimentation** : les mesures arrivent par le **compte appareil** de l'immeuble (e-mail en `@device.local`, même convention que la serre), qui peut écrire dans les quatre tables mais pas les effacer. Le pont MQTT de l'immotique viendra avec le matériel ; d'ici là, n'importe quel script peut publier par l'API REST :

  ```bash
  curl -X POST "$SUPABASE_URL/rest/v1/eau_chaude_compteurs" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JETON_APPAREIL" \
    -H "Content-Type: application/json" -H "Prefer: resolution=merge-duplicates" \
    -d '{"jour":"2026-10-17","unit":"B-204","litres":118}'
  ```

  Le logement est désigné comme dans `profiles.unit`. Un compteur se republie sans doublon (`UNIQUE (jour, unit)`)
- Traduit en français, anglais, espagnol et chinois ; consultable en mode démo (données fictives, aucune écriture)
- Migration : `sql/035_energie.sql` — test des règles d'accès : `sql/tests/energie_test.sql`

### LAB — amélioration continue
- Sous-menu **🧪 LAB** du Babillard : le babillard sert à la vie de l'immeuble, le LAB à celle de l'application
- **Qualifier les fonctions** : une note de 1 à 5 par fonction (babillard, tableau de bord, espaces, serre, mobilité partagée, Machine Lunch, billets, transactions, profil, multilingue, usage mobile, et le LAB lui-même) avec un commentaire libre. Moyenne communautaire, répartition des notes et commentaires reçus s'affichent sur chaque carte ; on peut revenir modifier sa note à tout moment. Les fonctions des modules désactivés n'apparaissent pas
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

L'interface est disponible en **français, anglais, espagnol et chinois** (sélecteur dans la barre de navigation). Les **conditions d'utilisation** sont traduites dans les quatre langues. Le module serre est entièrement traduit : libellés, stades, noms de cultures, unités, systèmes d'irrigation et fertilisants. Les **valeurs stockées en base restent en français** (`serre_cultures.culture`, `rendement_unite`…) — seul l'affichage est traduit, pour ne pas casser les données existantes ni les clés d'icônes.

### Mesure d'usage (analytics)

`trackFeature(catégorie, action, détails)` écrit dans deux canaux : **Google Analytics 4** (uniquement après consentement explicite, Loi 25) et la table **`usage_logs`** de Supabase, lisible par les seuls administrateurs. `user_type` (`demo` / `resident`), la langue et l'horodatage sont posés par la fonction elle-même — un appelant n'a à fournir que ce qui est propre à son événement.

Une catégorie = un module, en anglais snake_case ; l'action nomme ce qui vient de se passer. Le catalogue complet vit en commentaire au-dessus de `trackFeature()` dans `index.html`, et fait foi :

| Catégorie | Actions |
|-----------|---------|
| `platform` | `resident_login`, `demo_login`, `language_select` |
| `landing` | `landing_view`, `plan_hover`, `contact_click` |
| `navigation` | `page_view` |
| `shared_spaces` | `space_reserved` |
| `shared_mobility` | `vehicle_reserved`, `vehicle_reservation_cancelled`, `trip_published`, `trip_cancelled`, `trip_seat_requested`, `trip_booking_cancelled`, `driver_offer_sent` |
| `greenhouse` | `zone_rented`, `zone_released`, `harvest_logged`, `culture_saved` |
| `lunch` | `kiosk_opened`, `queue_joined`, `queue_left` |
| `bulletin_board` | `post_published`, `post_deleted` |
| `tickets` | `ticket_created`, `ticket_message_sent`, `ticket_status_changed` |
| `lab` | `rate_feature`, `submit_idea`, `vote_idea`, `unvote_idea`, `comment_idea`, `set_idea_status`, `idea_deleted`, `switch_tab` |
| `network` | `network_space_booked` |
| `federation` | `federated_space_booked` |

La catégorie `covoiturage` a disparu au profit de `shared_mobility` : depuis que le module s'appelle Mobilité partagée, le covoiturage et la réservation de véhicule sont deux façons d'utiliser la même flotte et n'ont pas à se compter séparément. Les lignes déjà écrites dans `usage_logs` gardent l'ancien nom — c'est le prix d'un renommage, à retenir en lisant l'historique.

Deux choses ne sont volontairement pas mesurées, faute d'écran correspondant : **l'annulation d'une réservation d'espace**, qui n'existe pas côté locataire (le remboursement se fait depuis Modulimo Admin), et **l'achat lunch**, qui se déroule dans le kiosque — une autre application, avec son propre suivi. CoHabitat ne voit du lunch que l'ouverture du kiosque et la file d'attente.

### Mode démo
- Accès sans compte via bouton "Démo"
- Consultation complète sans restriction
- **Réservation de véhicule jouable de bout en bout** : choix du créneau, refus si le véhicule est déjà pris (par une réservation ou par un covoiturage), débit du solde, apparition dans « Mes réservations », annulation avec remboursement. Tout vit dans le jeu de données local — rien ne sort du navigateur, rien n'est facturé, et un rechargement de la page remet tout à zéro. Les lignes créées portent la mention « fictive »
- Toutes les actions sont loggées pour analyse
- Aucune réservation réelle n'est créée

---

## Page de vente et mesure de la promotion

`cohabitat.modulimo.com` sert aussi de vitrine : un visiteur qui ne s'est
jamais connecté sur l'appareil arrive sur la page de vente (fonctions,
captures, forfaits, prise de contact) plutôt que sur le formulaire de
connexion. C'est l'option `vitrine.enabled` de `config.js` ;
`new-building.mjs` et `render-config.mjs` la désactivent pour les
immeubles, dont les visiteurs sont des résidants.

| Adresse | Effet |
|---|---|
| `/` | Page de vente (visiteur), connexion (résidant déjà venu sur l'appareil) |
| `/#essai` | Démo ouverte directement — lien public des pages de promotion |
| `/#demo` | Démo pour une tablette de présentation (panneau des modules) |
| `/#connexion` | Formulaire de connexion, même pour un nouveau visiteur |

La page présentée en détail, avec le formulaire de demande de
présentation, vit sur [modulimo.com/cohabitat](https://www.modulimo.com/cohabitat/)
(dépôt `modulimo-home`). Les demandes arrivent dans la table
`leads_pointe_est` de la centrale, `source_page` = `/cohabitat/`, et par
courriel à info@modulimo.com.

### Mesurer

Les événements de la page de vente sont écrits dans `usage_logs` (module
`landing`), avec ou sans consentement à Google Analytics : ce sont des
compteurs anonymes, sans identifiant de visiteur.

| Action | Quand |
|---|---|
| `landing_view` | Page de vente affichée (`metadata.origin` : `accueil` ou `login`) |
| `demo_click` | Entrée en démo (`metadata.place` : `hero`, `apercu`, `lien_essai`) |
| `booking_click` | Clic vers la réservation d'un créneau (agenda de rendez-vous Google) |
| `contact_click` | Clic vers le formulaire de présentation |
| `email_click` | Clic sur info@modulimo.com |
| `plan_hover` | Survol d'un forfait plus d'une seconde |

Entonnoir des 30 derniers jours, dans le SQL Editor de la base de l'instance :

```sql
select action,
       metadata->>'place' as endroit,
       count(*) as nombre
  from usage_logs
 where module = 'landing'
   and created_at > now() - interval '30 days'
 group by 1, 2
 order by 1, 3 desc;
```

À rapprocher des demandes reçues :

```sql
-- base centrale
select date_trunc('week', created_at) as semaine, count(*)
  from leads_pointe_est
 where source_page like '%/cohabitat/%'
 group by 1 order by 1 desc;
```

## Architecture de la base de données

| Table | Description |
|-------|-------------|
| `profiles` | Utilisateurs (liés à auth.users) |
| `common_spaces` | Espaces communs |
| `space_pricing` | Tarification des espaces |
| `space_reservations` | Réservations d'espaces |
| `vehicles` | Véhicules |
| `vehicle_pricing` | Tarification des véhicules |
| `vehicle_reservations` | Réservation directe d'un véhicule, relevés de compteur à la prise et au retour |
| `vehicle_couts` | Frais d'exploitation du parc, séparés en fixes et variables (admin) |
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
| `immeuble_etat` | Énergie et confort : état de l'immeuble (mode + niveau), la ligne la plus récente fait foi |
| `energie_lectures` | Énergie et confort : mesures de l'immeuble (solaire, batterie, réseau, réservoir) |
| `eau_chaude_compteurs` | Énergie et confort : eau chaude par logement et par jour (lisible par son logement et les admins) |
| `immeuble_alertes` | Énergie et confort : fuite, gel, panne — d'un logement ou de l'immeuble |
| `lab_evaluations` | LAB : note 1-5 + commentaire d'un résident sur une fonction |
| `lab_idees` | LAB : améliorations et nouvelles fonctions proposées |
| `lab_idee_votes` | LAB : appuis à une idée (un par personne) |
| `lab_idee_commentaires` | LAB : fil de discussion sous une idée |
