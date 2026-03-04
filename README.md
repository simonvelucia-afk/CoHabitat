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

### Administration
- Gestion des locataires et unités
- Gestion des espaces communs + tarification
- Gestion des véhicules + tarification
- Enregistrement des paiements réels → crédits virtuels
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
