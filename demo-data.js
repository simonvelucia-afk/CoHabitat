/* ============================================================
 * CoHabitat — jeu de demonstration autonome
 * ============================================================
 * Permet de faire tourner l'application SANS aucun serveur :
 * ni Supabase, ni appliance, ni reseau. Utilise pour les demos
 * portables (une tablette, hors ligne) et pour developper une
 * page sans monter la pile complete.
 *
 * Deux morceaux :
 *
 *   COHABITAT_DEMO      les donnees, une entree par table, deja
 *                       mises en forme comme PostgREST les
 *                       renverrait — jointures imbriquees
 *                       comprises (`common_spaces: { name }`).
 *                       C'est ce qui evite d'ecrire un moteur de
 *                       jointures : la donnee arrive deja jointe.
 *
 *   createDemoClient()  un client qui imite la partie de l'API
 *                       supabase-js reellement utilisee par
 *                       l'application. Il filtre, trie et borne ;
 *                       il n'ecrit rien (le mode demo est en
 *                       consultation seule).
 *
 * Une table absente du jeu renvoie une liste vide, ce que
 * l'interface affiche comme « Aucune donnee » — jamais une erreur.
 *
 * Charge en <script src> et non par fetch() : une page ouverte
 * en file:// ne peut pas lire un JSON voisin.
 * ============================================================ */
(function (global) {
  'use strict';

  var MOI = '00000000-0000-0000-0000-0000000000d1';  // Alex Tremblay
  var jours = function (n) { return new Date(Date.now() + n * 86400000).toISOString(); };
  // Les colonnes date_evenement et date_cout sont de type `date` : elles
  // attendent AAAA-MM-JJ, pas un horodatage complet.
  var jourCourt = function (n) { return jours(n).slice(0, 10); };
  var minutes = function (n) { return new Date(Date.now() + n * 60000).toISOString(); };
  var heures = function (n) { return new Date(Date.now() + n * 3600000).toISOString(); };

  var DEMO = {
    // ── Personnes ────────────────────────────────────────────
    profiles: [
      { id: MOI, email: 'alex.tremblay@modulimo.com', full_name: 'Alex Tremblay',
        unit: 'B-204', role: 'demo', is_approved_driver: false, is_active: true,
        virtual_balance: 47.50, phone: '+1 514 555-0182', resident_plan: 'network',
        logo_bg_color: 'green', created_at: jours(-420) },
      { id: 'p-2', email: 'camille@example.com', full_name: 'Camille Bernard',
        unit: 'A-101', role: 'tenant', is_approved_driver: true, is_active: true,
        virtual_balance: 62.00, created_at: jours(-380) },
      { id: 'p-3', email: 'julien@example.com', full_name: 'Julien Moreau',
        unit: 'C-310', role: 'tenant', is_approved_driver: true, is_active: true,
        virtual_balance: 18.75, created_at: jours(-210) },
    ],

    dependents: [
      { id: 'dep-demo-1', parent_id: MOI, name: 'Léa Tremblay', age: 12, pin: '1234',
        allow_spaces: true, allow_trips: false, allow_lunch: true, virtual_balance: 15.00 },
      { id: 'dep-demo-2', parent_id: MOI, name: 'Noah Tremblay', age: 8, pin: '5678',
        allow_spaces: false, allow_trips: false, allow_lunch: true, virtual_balance: 8.25 },
    ],

    // ── Machine Lunch ────────────────────────────────────────
    // La page Lunch interroge normalement la centrale Modulimo par HTTP
    // et ouvre le kiosque dans un onglet. Rien de tout cela n'est
    // joignable hors ligne : ces trois tables et COHABITAT_DEMO_REST les
    // remplacent, pour que la file d'attente soit reellement utilisable
    // en demonstration.
    lunch_machines: [
      { id: 'demo-lm-1', name: 'Machine — Hall d\u2019entrée', building_id: 'demo', active: true },
      { id: 'demo-lm-2', name: 'Machine — Salle commune',   building_id: 'demo', active: true },
    ],

    // Une machine libre, une occupee avec quelqu'un en attente : les trois
    // etats de la carte sont visibles d'entree de jeu.
    lunch_queue: [
      { id: 'lq-1', machine_id: 'demo-lm-2', user_id: 'p-2', full_name: 'Camille Bernard',
        unit: 'A-101', status: 'active',  joined_at: minutes(-4),
        expires_at: minutes(6) },
      { id: 'lq-2', machine_id: 'demo-lm-2', user_id: 'p-3', full_name: 'Julien Moreau',
        unit: 'C-310', status: 'waiting', joined_at: minutes(-2),
        expires_at: minutes(8) },
    ],

    lunch_sessions: [],

    // ── Espaces communs ──────────────────────────────────────
    common_spaces: [
      { id: 'sp-1', name: 'Salon commun A', description: 'Grande pièce lumineuse, cuisine attenante.',
        capacity: 25, location: 'Rez-de-chaussée, aile A', is_available: true,
        federation_shared: false, space_pricing: [{ price_per_slot: 3.00 }] },
      { id: 'sp-2', name: 'Salle de réunion', description: 'Table de 10, écran, tableau blanc.',
        capacity: 10, location: '2e étage', is_available: true,
        federation_shared: false, space_pricing: [{ price_per_slot: 2.00 }] },
      { id: 'sp-3', name: 'Terrasse sur le toit', description: 'Vue sur le fleuve, BBQ, mobilier.',
        capacity: 30, location: '8e étage', is_available: true,
        federation_shared: true, space_pricing: [{ price_per_slot: 4.00 }] },
      { id: 'sp-4', name: 'Atelier de bricolage', description: 'Établi, outils, imprimante 3D.',
        capacity: 6, location: 'Sous-sol', is_available: true,
        federation_shared: false, space_pricing: [{ price_per_slot: 2.50 }] },
    ],

    space_pricing: [
      { id: 'pr-1', space_id: 'sp-1', price_per_slot: 3.00 },
      { id: 'pr-2', space_id: 'sp-2', price_per_slot: 2.00 },
      { id: 'pr-3', space_id: 'sp-3', price_per_slot: 4.00 },
      { id: 'pr-4', space_id: 'sp-4', price_per_slot: 2.50 },
    ],

    space_reservations: [
      { id: 'rs-1', space_id: 'sp-1', tenant_id: MOI, start_time: heures(30), end_time: heures(33),
        total_slots: 12, total_cost: 36.00, status: 'confirmed', is_demo: false,
        created_at: jours(-2), common_spaces: { name: 'Salon commun A' } },
      { id: 'rs-2', space_id: 'sp-3', tenant_id: MOI, start_time: jours(-6), end_time: jours(-6),
        total_slots: 8, total_cost: 32.00, status: 'completed', is_demo: false,
        created_at: jours(-9), common_spaces: { name: 'Terrasse sur le toit' } },
      { id: 'rs-3', space_id: 'sp-2', tenant_id: 'p-2', start_time: heures(54), end_time: heures(56),
        total_slots: 8, total_cost: 16.00, status: 'confirmed', is_demo: false,
        created_at: jours(-1), common_spaces: { name: 'Salle de réunion' } },
    ],

    // ── Véhicules et trajets ─────────────────────────────────
    vehicles: [
      { id: 'vh-1', model: 'Kia Niro EV', license_plate: 'ABC 123', seats: 5, is_available: true,
        cargo_slots: 3, vehicle_pricing: [{ price_per_minute: 0.20, price_per_km: 0.35, price_per_cargo_slot: 2.00 }] },
      { id: 'vh-2', model: 'Vélomobile partagé', license_plate: 'VM-02', seats: 1, is_available: true,
        cargo_slots: 1, vehicle_pricing: [{ price_per_minute: 0.05, price_per_km: 0.10, price_per_cargo_slot: 0.50 }] },
    ],

    vehicle_pricing: [
      { id: 'vp-1', vehicle_id: 'vh-1', price_per_minute: 0.20, price_per_km: 0.35, price_per_cargo_slot: 2.00 },
      { id: 'vp-2', vehicle_id: 'vh-2', price_per_minute: 0.05, price_per_km: 0.10, price_per_cargo_slot: 0.50 },
    ],

    // Les colonnes suivent celles de la table `trips` et de la vue
    // `trips_with_details` (schema.sql) : available_seats et non
    // seats_available, cargo_available_pct, booked_seats. Les noms
    // employes ici auparavant n'existaient nulle part, si bien que chaque
    // carte affichait « Complet » et « Cargo: NaN% ».
    trips: [
      { id: 'tr-3', title: 'Sortie au parc — Mont-Royal', driver_id: 'p-2', vehicle_id: 'vh-1',
        departure_time: heures(6), available_seats: 4, cargo_available_pct: 100,
        estimated_distance_km: 12.4, status: 'published', is_demo: false,
        departure_point: 'Entrée principale', destination: 'Lac aux Castors' },
      { id: 'tr-1', title: 'Épicerie — Marché Jean-Talon', driver_id: 'p-2', vehicle_id: 'vh-1',
        departure_time: heures(20), available_seats: 4, cargo_available_pct: 100,
        estimated_distance_km: 7.5, status: 'published', is_demo: false,
        departure_point: 'Entrée principale', destination: 'Marché Jean-Talon' },
      { id: 'tr-2', title: 'Centre-ville — bureaux', driver_id: 'p-3', vehicle_id: 'vh-1',
        departure_time: heures(44), available_seats: 4, cargo_available_pct: 100,
        estimated_distance_km: 9.1, status: 'published', is_demo: false,
        departure_point: 'Stationnement B', destination: 'Square Victoria' },
    ],

    // Trois etats differents a l'affichage : presque complet, une place
    // deja reservee par le visiteur, et largement disponible.
    trips_with_details: [
      { id: 'tr-3', title: 'Sortie au parc — Mont-Royal', driver_id: 'p-2',
        driver_name: 'Camille Bernard', driver_unit: 'A-101',
        vehicle_id: 'vh-1', vehicle_model: 'Kia Niro EV', license_plate: 'ABC 123',
        departure_time: heures(6), available_seats: 4, booked_seats: 3,
        cargo_available_pct: 100, booked_cargo_pct: 40, estimated_distance_km: 12.4,
        price_per_minute: 0.20, price_per_km: 0.35, price_per_cargo_slot: 2.00,
        status: 'published', is_demo: false,
        departure_point: 'Entrée principale', destination: 'Lac aux Castors' },
      { id: 'tr-1', title: 'Épicerie — Marché Jean-Talon', driver_id: 'p-2',
        driver_name: 'Camille Bernard', driver_unit: 'A-101',
        vehicle_id: 'vh-1', vehicle_model: 'Kia Niro EV', license_plate: 'ABC 123',
        departure_time: heures(20), available_seats: 4, booked_seats: 1,
        cargo_available_pct: 100, booked_cargo_pct: 20, estimated_distance_km: 7.5,
        price_per_minute: 0.20, price_per_km: 0.35, price_per_cargo_slot: 2.00,
        status: 'published', is_demo: false,
        departure_point: 'Entrée principale', destination: 'Marché Jean-Talon' },
      { id: 'tr-2', title: 'Centre-ville — bureaux', driver_id: 'p-3',
        driver_name: 'Julien Moreau', driver_unit: 'C-310',
        vehicle_id: 'vh-1', vehicle_model: 'Kia Niro EV', license_plate: 'ABC 123',
        departure_time: heures(44), available_seats: 4, booked_seats: 2,
        cargo_available_pct: 100, booked_cargo_pct: 0, estimated_distance_km: 9.1,
        price_per_minute: 0.20, price_per_km: 0.35, price_per_cargo_slot: 2.00,
        status: 'published', is_demo: false,
        departure_point: 'Stationnement B', destination: 'Square Victoria' },
    ],

    trip_bookings: [
      // `status` doit valoir accepted ou pending : renderTripBookings n'offre
      // le bouton Annuler que pour ces deux valeurs, et statusLabel ne
      // connait pas « confirmed ». L'embarque `trips` doit aussi porter la
      // destination, affichee en colonne.
      { id: 'tb-1', trip_id: 'tr-1', passenger_id: MOI, seats_requested: 1, status: 'accepted',
        total_cost: 4.25, is_demo: false, created_at: jours(-1),
        pickup_location: 'Entrée principale',
        trips: { title: 'Épicerie — Marché Jean-Talon', departure_time: heures(20),
                 destination: 'Marché Jean-Talon' },
        profiles: { full_name: 'Alex Tremblay', unit: 'B-204' } },
      { id: 'tb-2', trip_id: 'tr-2', passenger_id: MOI, seats_requested: 2, status: 'pending',
        total_cost: 6.80, is_demo: false, created_at: jours(-2),
        pickup_location: 'Stationnement B',
        trips: { title: 'Centre-ville — bureaux', departure_time: heures(44),
                 destination: 'Square Victoria' },
        profiles: { full_name: 'Alex Tremblay', unit: 'B-204' } },
      // Une course passee, pour que l'onglet montre aussi son historique.
      { id: 'tb-3', trip_id: 'tr-0', passenger_id: MOI, seats_requested: 1, status: 'accepted',
        total_cost: 3.15, is_demo: false, created_at: jours(-9),
        pickup_location: 'Entrée principale',
        trips: { title: 'Pharmacie — Jean Coutu', departure_time: heures(-160),
                 destination: 'Jean Coutu Masson' },
        profiles: { full_name: 'Alex Tremblay', unit: 'B-204' } },
    ],

    trip_stops: [
      { id: 'ts-1', trip_id: 'tr-1', label: 'Coin Papineau / Mont-Royal', stop_order: 1 },
    ],

    passenger_requests: [
      { id: 'pq-1', requester_id: 'p-3', requester_name: 'Julien Moreau', departure_point: 'Immeuble',
        destination: 'Aéroport YUL', desired_datetime: heures(72), seats_requested: 2,
        luggage_ft3: 8, status: 'open', is_demo: false, created_at: jours(-1) },
    ],

    // ── Argent ───────────────────────────────────────────────
    transactions: [
      { id: 'tx-1', user_id: MOI, amount: -12.00, balance_after: 47.50, type: 'space_reservation',
        description: 'Réservation Salon commun A', created_at: jours(-1), is_demo: false },
      { id: 'tx-2', user_id: MOI, amount: 50.00, balance_after: 59.50, type: 'admin_credit',
        description: 'Crédit par administrateur', created_at: jours(-3), is_demo: false },
      { id: 'tx-3', user_id: MOI, amount: -8.50, balance_after: 9.50, type: 'admin_credit',
        description: 'Machine lunch — Case #3 : Poulet rôti', created_at: jours(-5), is_demo: false },
      { id: 'tx-4', user_id: MOI, amount: -6.00, balance_after: 18.00, type: 'space_reservation',
        description: 'Réservation Salle de réunion', created_at: jours(-7), is_demo: false },
      { id: 'tx-5', user_id: MOI, amount: 25.00, balance_after: 24.00, type: 'admin_credit',
        description: 'Crédit par administrateur', created_at: jours(-10), is_demo: false },
    ],

    real_payments: [
      { id: 'rp-1', tenant_id: MOI, amount: 100.00, method: 'virement', created_at: jours(-21),
        note: 'Paiement mensuel', profiles: { id: MOI, full_name: 'Alex Tremblay' } },
    ],

    // ── Vie de l'immeuble ────────────────────────────────────
    bulletin_board: [
      { id: 'bb-1', user_id: 'p-2', content: 'Je donne un vélo d’enfant en bon état, 20 pouces. Écrivez-moi !',
        created_at: jours(-1), profiles: { full_name: 'Camille Bernard' } },
      { id: 'bb-2', user_id: 'p-3', content: 'Corvée de jardin samedi 10 h, on plante les tomates. Café offert.',
        created_at: jours(-3), profiles: { full_name: 'Julien Moreau' } },
      { id: 'bb-3', user_id: MOI, content: 'Merci à qui a rentré mes paquets hier soir 🙏',
        created_at: jours(-4), profiles: { full_name: 'Alex Tremblay' } },
    ],

    tickets: [
      { id: 'tk-1', user_id: MOI, subject: 'Robinet qui goutte — cuisine', category: 'maintenance',
        priority: 'normal', status: 'in_progress', description: 'Depuis lundi, goutte à goutte constant.',
        created_at: jours(-4), updated_at: jours(-2), profiles: { full_name: 'Alex Tremblay' } },
      { id: 'tk-2', user_id: MOI, subject: 'Ampoule grillée — corridor 2e', category: 'maintenance',
        priority: 'low', status: 'resolved', description: 'Deuxième plafonnier en partant de l’ascenseur.',
        created_at: jours(-18), updated_at: jours(-15), resolved_at: jours(-15),
        profiles: { full_name: 'Alex Tremblay' } },
    ],

    ticket_messages: [
      { id: 'tm-1', ticket_id: 'tk-1', user_id: MOI, message: 'Bonjour, toujours pas réglé ce matin.',
        created_at: jours(-2), profiles: { full_name: 'Alex Tremblay' } },
      { id: 'tm-2', ticket_id: 'tk-1', user_id: 'p-2', message: 'Le plombier passe jeudi après-midi.',
        created_at: jours(-1), profiles: { full_name: 'Concierge' } },
    ],

    // ── Serre ────────────────────────────────────────────────
    serre_zones: [
      { id: 'sz-1', code: 'A1', nom: 'Bac A1', surface_m2: 2.0, statut: 'louee' },
      { id: 'sz-2', code: 'A2', nom: 'Bac A2', surface_m2: 2.0, statut: 'libre' },
      { id: 'sz-3', code: 'B1', nom: 'Bac B1', surface_m2: 3.5, statut: 'libre' },
    ],

    serre_locations: [
      { id: 'sl-1', zone_id: 'sz-1', locataire_id: MOI, date_debut: jours(-60), date_fin: jours(120),
        frais_mensuel: 12.00, statut: 'active', serre_zones: { code: 'A1' },
        profiles: { full_name: 'Alex Tremblay' } },
    ],

    serre_cultures: [
      { id: 'sc-1', location_id: 'sl-1', zone_id: 'sz-1', espece: 'Tomate cerise', variete: 'Sungold',
        stade: 'fructification', date_semis: jours(-55), date_repiquage: jours(-35), statut: 'en_cours' },
      { id: 'sc-2', location_id: 'sl-1', zone_id: 'sz-1', espece: 'Basilic', variete: 'Genovese',
        stade: 'recolte_continue', date_semis: jours(-40), statut: 'en_cours' },
    ],

    serre_recoltes: [
      { id: 'sr-1', culture_id: 'sc-1', date_recolte: jours(-6), quantite: 0.8, unite: 'kg' },
      { id: 'sr-2', culture_id: 'sc-2', date_recolte: jours(-2), quantite: 0.12, unite: 'kg' },
    ],

    serre_recoltes_cumul: [
      { culture_id: 'sc-1', espece: 'Tomate cerise', total: 2.4, unite: 'kg' },
      { culture_id: 'sc-2', espece: 'Basilic', total: 0.45, unite: 'kg' },
    ],

    // Noms de colonnes repris de sql/009_serre.sql : horodatage,
    // reservoirN_temp, reservoirN_pct. Le jeu precedent employait
    // mesure_at / temp_reservoir1 / niveau1_pct, qui n'existent pas —
    // les conditions s'affichaient donc vides en demonstration.
    serre_lectures: [
      { id: 'sle-1', horodatage: heures(-1), temp_air: 22.4,
        reservoir1_temp: 18.9, reservoir2_temp: 19.4, reservoir3_temp: 18.2,
        reservoir1_pct: 76, reservoir2_pct: 63, reservoir3_pct: 88 },
      { id: 'sle-2', horodatage: heures(-4), temp_air: 21.1,
        reservoir1_temp: 18.7, reservoir2_temp: 19.1, reservoir3_temp: 18.0,
        reservoir1_pct: 78, reservoir2_pct: 65, reservoir3_pct: 89 },
      { id: 'sle-3', horodatage: heures(-8), temp_air: 19.8,
        reservoir1_temp: 18.5, reservoir2_temp: 18.9, reservoir3_temp: 17.9,
        reservoir1_pct: 80, reservoir2_pct: 67, reservoir3_pct: 90 },
    ],

    // Fiches individuelles. Les portraits sont des SVG embarques :
    // la demonstration doit fonctionner sans reseau, sur la tablette
    // comme ailleurs. Un vrai deploiement y met des adresses web.
    elevage_animaux: [
      { id: 'ea-1', module: 'poulailler', nom: 'Doucette', race: 'Rousse',
        date_arrivee: jourCourt(-300), statut: 'age', notes: 'la plus douce, se laisse prendre sans bouger — la doyenne',
        photo_url: 'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2080%2060%22%3E%3Crect%20width%3D%2280%22%20height%3D%2260%22%20fill%3D%22%232a2622%22/%3E%3Cellipse%20cx%3D%2240%22%20cy%3D%2240%22%20rx%3D%2221%22%20ry%3D%2215%22%20fill%3D%22%23b86134%22/%3E%3Ccircle%20cx%3D%2255%22%20cy%3D%2225%22%20r%3D%229%22%20fill%3D%22%23b86134%22/%3E%3Cpath%20d%3D%22M52%2016c1-4%204-4%204%200%201-4%204-4%204%201%201-3%203-2%203%201z%22%20fill%3D%22%23c0392b%22/%3E%3Cpath%20d%3D%22M56%2032q3%203%200%205-3-2%200-5z%22%20fill%3D%22%23c0392b%22/%3E%3Ccircle%20cx%3D%2258%22%20cy%3D%2224%22%20r%3D%221.6%22%20fill%3D%22%231a1a1a%22/%3E%3Cpath%20d%3D%22M64%2027l6%202-6%202z%22%20fill%3D%22%23e8a33d%22/%3E%3Cpath%20d%3D%22M20%2038q10-8%2018%202-9%206-18-2z%22%20fill%3D%22%238e4726%22/%3E%3Cpath%20d%3D%22M19%2034q-6-3-8%202%205%201%209%202z%22%20fill%3D%22%238e4726%22/%3E%3Cpath%20d%3D%22M24%2052l-2%205M32%2053l-1%205%22%20stroke%3D%22%23e8a33d%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22/%3E%3C/svg%3E' },
      { id: 'ea-2', module: 'poulailler', nom: 'Noisette', race: 'Rousse',
        date_arrivee: jourCourt(-300), statut: 'adulte', notes: 'robe plus claire, couleur noisette',
        photo_url: 'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2080%2060%22%3E%3Crect%20width%3D%2280%22%20height%3D%2260%22%20fill%3D%22%23262a28%22/%3E%3Cellipse%20cx%3D%2240%22%20cy%3D%2240%22%20rx%3D%2221%22%20ry%3D%2215%22%20fill%3D%22%23cd8149%22/%3E%3Ccircle%20cx%3D%2255%22%20cy%3D%2225%22%20r%3D%229%22%20fill%3D%22%23cd8149%22/%3E%3Cpath%20d%3D%22M52%2016c1-4%204-4%204%200%201-4%204-4%204%201%201-3%203-2%203%201z%22%20fill%3D%22%23c0392b%22/%3E%3Cpath%20d%3D%22M56%2032q3%203%200%205-3-2%200-5z%22%20fill%3D%22%23c0392b%22/%3E%3Ccircle%20cx%3D%2258%22%20cy%3D%2224%22%20r%3D%221.6%22%20fill%3D%22%231a1a1a%22/%3E%3Cpath%20d%3D%22M64%2027l6%202-6%202z%22%20fill%3D%22%23e8a33d%22/%3E%3Cpath%20d%3D%22M20%2038q10-8%2018%202-9%206-18-2z%22%20fill%3D%22%23a35f30%22/%3E%3Cpath%20d%3D%22M19%2034q-6-3-8%202%205%201%209%202z%22%20fill%3D%22%23a35f30%22/%3E%3Cpath%20d%3D%22M24%2052l-2%205M32%2053l-1%205%22%20stroke%3D%22%23e8a33d%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22/%3E%3C/svg%3E' },
      { id: 'ea-3', module: 'poulailler', nom: 'Long Bec', race: 'Rousse',
        date_arrivee: jourCourt(-300), statut: 'age', notes: 'bec nettement plus long que les autres — âgée, elle aussi',
        photo_url: 'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2080%2060%22%3E%3Crect%20width%3D%2280%22%20height%3D%2260%22%20fill%3D%22%232a2422%22/%3E%3Cellipse%20cx%3D%2240%22%20cy%3D%2240%22%20rx%3D%2221%22%20ry%3D%2215%22%20fill%3D%22%23a85630%22/%3E%3Ccircle%20cx%3D%2255%22%20cy%3D%2225%22%20r%3D%229%22%20fill%3D%22%23a85630%22/%3E%3Cpath%20d%3D%22M52%2016c1-4%204-4%204%200%201-4%204-4%204%201%201-3%203-2%203%201z%22%20fill%3D%22%23c0392b%22/%3E%3Cpath%20d%3D%22M56%2032q3%203%200%205-3-2%200-5z%22%20fill%3D%22%23c0392b%22/%3E%3Ccircle%20cx%3D%2258%22%20cy%3D%2224%22%20r%3D%221.6%22%20fill%3D%22%231a1a1a%22/%3E%3Cpath%20d%3D%22M64%2027l11%202-11%202z%22%20fill%3D%22%23e8a33d%22/%3E%3Cpath%20d%3D%22M20%2038q10-8%2018%202-9%206-18-2z%22%20fill%3D%22%23833f22%22/%3E%3Cpath%20d%3D%22M19%2034q-6-3-8%202%205%201%209%202z%22%20fill%3D%22%23833f22%22/%3E%3Cpath%20d%3D%22M24%2052l-2%205M32%2053l-1%205%22%20stroke%3D%22%23e8a33d%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22/%3E%3C/svg%3E' },
      { id: 'ea-4', module: 'poulailler', nom: 'Petite Crête', race: 'Rousse',
        date_arrivee: jourCourt(-40), statut: 'jeune', notes: 'crête basse — la dernière arrivée, encore jeune',
        photo_url: 'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2080%2060%22%3E%3Crect%20width%3D%2280%22%20height%3D%2260%22%20fill%3D%22%23282622%22/%3E%3Cellipse%20cx%3D%2240%22%20cy%3D%2240%22%20rx%3D%2221%22%20ry%3D%2215%22%20fill%3D%22%23c47340%22/%3E%3Ccircle%20cx%3D%2255%22%20cy%3D%2225%22%20r%3D%229%22%20fill%3D%22%23c47340%22/%3E%3Cpath%20d%3D%22M53%2019c1-2%203-2%203%200%201-2%203-2%203%201%201-2%202-1%202%201z%22%20fill%3D%22%23c0392b%22/%3E%3Cpath%20d%3D%22M56%2032q3%203%200%205-3-2%200-5z%22%20fill%3D%22%23c0392b%22/%3E%3Ccircle%20cx%3D%2258%22%20cy%3D%2224%22%20r%3D%221.6%22%20fill%3D%22%231a1a1a%22/%3E%3Cpath%20d%3D%22M64%2027l6%202-6%202z%22%20fill%3D%22%23e8a33d%22/%3E%3Cpath%20d%3D%22M20%2038q10-8%2018%202-9%206-18-2z%22%20fill%3D%22%239a5529%22/%3E%3Cpath%20d%3D%22M19%2034q-6-3-8%202%205%201%209%202z%22%20fill%3D%22%239a5529%22/%3E%3Cpath%20d%3D%22M24%2052l-2%205M32%2053l-1%205%22%20stroke%3D%22%23e8a33d%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22/%3E%3C/svg%3E' },
      { id: 'ea-5', module: 'poulailler', nom: 'Coquette', race: 'Rousse',
        date_arrivee: jourCourt(-300), date_sortie: jourCourt(-96), statut: 'mort', notes: 'Prédation — la clôture a été renforcée depuis',
        photo_url: 'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A//www.w3.org/2000/svg%22%20viewBox%3D%220%200%2080%2060%22%3E%3Crect%20width%3D%2280%22%20height%3D%2260%22%20fill%3D%22%23242220%22/%3E%3Cellipse%20cx%3D%2240%22%20cy%3D%2240%22%20rx%3D%2221%22%20ry%3D%2215%22%20fill%3D%22%239c5730%22/%3E%3Ccircle%20cx%3D%2255%22%20cy%3D%2225%22%20r%3D%229%22%20fill%3D%22%239c5730%22/%3E%3Cpath%20d%3D%22M52%2016c1-4%204-4%204%200%201-4%204-4%204%201%201-3%203-2%203%201z%22%20fill%3D%22%23c0392b%22/%3E%3Cpath%20d%3D%22M56%2032q3%203%200%205-3-2%200-5z%22%20fill%3D%22%23c0392b%22/%3E%3Ccircle%20cx%3D%2258%22%20cy%3D%2224%22%20r%3D%221.6%22%20fill%3D%22%231a1a1a%22/%3E%3Cpath%20d%3D%22M64%2027l6%202-6%202z%22%20fill%3D%22%23e8a33d%22/%3E%3Cpath%20d%3D%22M20%2038q10-8%2018%202-9%206-18-2z%22%20fill%3D%22%237a4022%22/%3E%3Cpath%20d%3D%22M19%2034q-6-3-8%202%205%201%209%202z%22%20fill%3D%22%237a4022%22/%3E%3Cpath%20d%3D%22M24%2052l-2%205M32%2053l-1%205%22%20stroke%3D%22%23e8a33d%22%20stroke-width%3D%222%22%20stroke-linecap%3D%22round%22/%3E%3C/svg%3E' },
    ],

    // ── Elevages : poulailler et sablonponie ─────────────────
    // Les deux ecrans etaient vides en demonstration, ce qui donnait a
    // croire que la fonction n'existait pas. Un mois de ponte et deux
    // recoltes suffisent a montrer les totaux et le cout unitaire.
    elevage_historique: [
      // Poulailler : six poules, une perte, la ponte des dernieres semaines.
      { id: 'eh-1', module: 'poulailler', date_evenement: jourCourt(-300), type_evenement: 'ajout', quantite: 4, description: 'Quatre poules rousses' },
      { id: 'eh-10', module: 'poulailler', date_evenement: jourCourt(-40),  type_evenement: 'ajout', quantite: 1, description: 'Petite Crête, en remplacement de Coquette', animal_id: 'ea-4' },
      { id: 'eh-3', module: 'poulailler', date_evenement: jourCourt(-40),  type_evenement: 'ponte', quantite: 88, description: 'Cumul de la semaine' },
      { id: 'eh-4', module: 'poulailler', date_evenement: jourCourt(-26),  type_evenement: 'ponte', quantite: 92, description: 'Cumul de la semaine' },
      { id: 'eh-5', module: 'poulailler', date_evenement: jourCourt(-12),  type_evenement: 'ponte', quantite: 79, description: 'Cumul de la semaine — chaleur',
        ponte_petit: 18, ponte_moyen: 38, ponte_gros: 19, ponte_defaut_comestible: 2, ponte_defaut_rejet: 2 },
      { id: 'eh-6', module: 'poulailler', date_evenement: jourCourt(-4),   type_evenement: 'ponte', quantite: 90, description: 'Cumul de la semaine',
        ponte_petit: 21, ponte_moyen: 44, ponte_gros: 22, ponte_defaut_comestible: 3, ponte_defaut_rejet: 0 },
      { id: 'eh-7', module: 'poulailler', date_evenement: jourCourt(-18),  type_evenement: 'sante', quantite: null, description: 'Traitement antiparasitaire, tout le troupeau' },
      // Deux evenements nominatifs : le reste appartient au troupeau.
      { id: 'eh-8', module: 'poulailler', date_evenement: jourCourt(-96),  type_evenement: 'perte', quantite: 1, description: 'Prédation — renard, clôture renforcée depuis', animal_id: 'ea-5' },
      { id: 'eh-9', module: 'poulailler', date_evenement: jourCourt(-33),  type_evenement: 'sante', quantite: null, description: 'Boiterie légère, rétablie en trois jours', animal_id: 'ea-1' },
      // Un projet se consigne en note : les deux Chantecler n'existent pas
      // encore, leur donner une fiche affirmerait un cheptel faux.
      { id: 'eh-11', module: 'poulailler', date_evenement: jourCourt(-6), type_evenement: 'note', quantite: null,
        description: 'Deux Chantecler prévues au printemps, en remplacement de Doucette et Long Bec (âgées). Le règlement plafonne à 4 : leur départ doit précéder l’arrivée.' },
      // Sablonponie : truites arc-en-ciel, deux recoltes.
      { id: 'ep-1', module: 'sablonponie', date_evenement: jourCourt(-260), type_evenement: 'ajout', quantite: 40, description: 'Alevins de truite arc-en-ciel' },
      { id: 'ep-2', module: 'sablonponie', date_evenement: jourCourt(-190), type_evenement: 'perte', quantite: 3,  description: 'Mortalité à l’acclimatation' },
      { id: 'ep-3', module: 'sablonponie', date_evenement: jourCourt(-70),  type_evenement: 'recolte', quantite: 4.2, description: 'Première récolte — 8 pièces' },
      { id: 'ep-4', module: 'sablonponie', date_evenement: jourCourt(-9),   type_evenement: 'recolte', quantite: 5.6, description: 'Deuxième récolte — 10 pièces' },
      { id: 'ep-5', module: 'sablonponie', date_evenement: jourCourt(-30),  type_evenement: 'note', quantite: null, description: 'Backwash dirigé vers les planches 1 à 3' },
    ],

    elevage_couts: [
      { id: 'ec-1', module: 'poulailler', date_cout: jourCourt(-120), categorie: 'Nourriture', montant: 78.40, description: 'Moulée, 3 sacs' },
      { id: 'ec-2', module: 'poulailler', date_cout: jourCourt(-60),  categorie: 'Nourriture', montant: 52.30, description: 'Moulée, 2 sacs' },
      { id: 'ec-3', module: 'poulailler', date_cout: jourCourt(-45),  categorie: 'Litière',    montant: 24.00, description: 'Copeaux' },
      { id: 'ec-4', module: 'poulailler', date_cout: jourCourt(-18),  categorie: 'Vétérinaire', montant: 40.00, description: 'Antiparasitaire' },
      { id: 'ec-5', module: 'sablonponie', date_cout: jourCourt(-200), categorie: 'Équipement', montant: 210.00, description: 'Pompe de secours' },
      { id: 'ec-6', module: 'sablonponie', date_cout: jourCourt(-85),  categorie: 'Nourriture', montant: 96.75, description: 'Granulés, 25 kg' },
      { id: 'ec-7', module: 'sablonponie', date_cout: jourCourt(-20),  categorie: 'Énergie',    montant: 61.20, description: 'Part de l’aération, relevé trimestriel' },
    ],

    // ── Reglages ─────────────────────────────────────────────
    system_settings: [
      { key: 'elevage_capacite_poulailler', value: '4' },
      { key: 'elevage_capacite_sablonponie', value: '' },
      { key: 'module_trips', value: 'true' },
      { key: 'module_lunch', value: 'true' },
      { key: 'module_serre', value: 'true' },
      { key: 'lunch_mode', value: 'demo',
        description: 'Configuration de la Machine Lunch : demo, local ou central' },
      { key: 'lunch_local_url', value: '',
        description: 'Adresse du kiosque sur le réseau du bâtiment' },
      { key: 'finance_central_enabled', value: 'false' },
      { key: 'federation_enabled', value: 'false' },
      { key: 'building_name', value: 'Immeuble de démonstration' },
    ],

    resource_access: [
      { id: 'ra-1', user_id: MOI, resource_type: 'space', resource_id: 'sp-1' },
      { id: 'ra-2', user_id: MOI, resource_type: 'space', resource_id: 'sp-2' },
      { id: 'ra-3', user_id: MOI, resource_type: 'space', resource_id: 'sp-3' },
      { id: 'ra-4', user_id: MOI, resource_type: 'space', resource_id: 'sp-4' },
      { id: 'ra-5', user_id: MOI, resource_type: 'vehicle', resource_id: 'vh-1' },
      { id: 'ra-6', user_id: MOI, resource_type: 'vehicle', resource_id: 'vh-2' },
    ],

    // Vues d'administration : vides, la demo est cote locataire.
    stats_spaces: [], stats_tenants: [], stats_vehicles: [],
    deletion_requests: [], reservation_requests: [], driver_offers: [],
    notifications: [], usage_logs: [],
  };

  // Reponses des RPC appelees par l'interface. Une RPC absente
  // renvoie null sans erreur : l'appelant traite deja ce cas.
  var RPC = {
    check_space_availability: function () { return true; },
    count_open_tickets: function () { return 1; },
    serre_occupancy: function () { return [{ zone_id: 'sz-1', occupee: true }]; },
    insert_usage_log: function () { return null; },
    adjust_balance: function () { return 47.50; },
    list_client_invoices: function () { return []; },
    get_invoice_detail: function () { return []; },
    export_client_data: function () { return { demo: true }; },
  };

  // ── Client de demonstration ────────────────────────────────
  function compare(a, b) {
    if (a === b) return 0;
    if (a === null || a === undefined) return -1;
    if (b === null || b === undefined) return 1;
    return a < b ? -1 : 1;
  }

  function egal(valeur, attendu) {
    if (valeur === attendu) return true;
    // PostgREST compare des chaines : 'true' == true, '3' == 3.
    return String(valeur) === String(attendu);
  }

  var compteur = 0;
  function idDemo(table) { return 'demo-' + table + '-' + (++compteur); }

  function creerRequete(table, donnees) {
    // On travaille sur une copie pour filtrer, mais les ecritures visent
    // le tableau reel : une reservation creee pendant une demonstration
    // doit apparaitre dans la liste juste apres.
    if (!donnees[table]) donnees[table] = [];
    var source = donnees[table];
    var lignes = source.slice();
    var tris = [];
    var borne = null;
    var mode = null;   // 'single' | 'maybeSingle'
    var op = null;     // ecriture differee : les filtres arrivent APRES
                       // .update()/.delete() dans l'API supabase-js

    var req = {
      // La projection est ignoree : les lignes du jeu portent deja
      // leurs jointures. On garde la methode pour le chainage.
      select: function () { return req; },
      insert: function (rows) { op = { kind: 'insert', rows: rows }; return req; },
      update: function (patch) { op = { kind: 'update', patch: patch }; return req; },
      // onConflict indique la ou les colonnes qui identifient la ligne.
      // Toutes les tables n'ont pas d'id : system_settings est cle par
      // `key`, et un upsert qui ne regarderait que l'id y creerait des
      // doublons au lieu de mettre a jour.
      upsert: function (row, opts) {
        op = {
          kind: 'upsert',
          row: row,
          cles: ((opts && opts.onConflict) || 'id').split(',').map(function (c) { return c.trim(); }),
        };
        return req;
      },
      delete: function () { op = { kind: 'delete' }; return req; },

      eq: function (col, val) { lignes = lignes.filter(function (r) { return egal(r[col], val); }); return req; },
      neq: function (col, val) { lignes = lignes.filter(function (r) { return !egal(r[col], val); }); return req; },
      gt: function (col, val) { lignes = lignes.filter(function (r) { return compare(r[col], val) > 0; }); return req; },
      gte: function (col, val) { lignes = lignes.filter(function (r) { return compare(r[col], val) >= 0; }); return req; },
      lt: function (col, val) { lignes = lignes.filter(function (r) { return compare(r[col], val) < 0; }); return req; },
      lte: function (col, val) { lignes = lignes.filter(function (r) { return compare(r[col], val) <= 0; }); return req; },
      in: function (col, vals) {
        lignes = lignes.filter(function (r) {
          return (vals || []).some(function (v) { return egal(r[col], v); });
        });
        return req;
      },
      is: function (col, val) {
        lignes = lignes.filter(function (r) {
          return val === null ? (r[col] === null || r[col] === undefined) : egal(r[col], val);
        });
        return req;
      },
      contains: function () { return req; },
      or: function () { return req; },      // trop varie pour etre simule fidelement
      like: function () { return req; },
      ilike: function () { return req; },
      not: function () { return req; },
      filter: function (col, op, val) {
        var m = { eq: 'eq', neq: 'neq', gt: 'gt', gte: 'gte', lt: 'lt', lte: 'lte' };
        return m[op] ? req[m[op]](col, val) : req;
      },
      order: function (col, opts) {
        tris.push({ col: col, asc: !opts || opts.ascending !== false });
        return req;
      },
      limit: function (n) { borne = n; return req; },
      range: function (a, b) { borne = (b - a) + 1; return req; },
      single: function () { mode = 'single'; return req.then.call(req); },
      maybeSingle: function () { mode = 'maybeSingle'; return req.then.call(req); },

      then: function (resolve, reject) {
        // Ecritures : elles s'appliquent aux lignes retenues par les
        // filtres accumules, puis retournent ce qu'elles ont touche.
        if (op) {
          var touchees = [];
          if (op.kind === 'insert' || op.kind === 'upsert') {
            var brutes = op.kind === 'insert' ? op.rows : [op.row];
            if (!Array.isArray(brutes)) brutes = [brutes];
            var cles = op.cles || ['id'];
            brutes.forEach(function (r) {
              var existante = null;
              if (r && op.kind === 'upsert' && cles.every(function (c) { return r[c] !== undefined; })) {
                existante = source.find(function (x) {
                  return cles.every(function (c) { return String(x[c]) === String(r[c]); });
                });
              } else if (r && r.id) {
                existante = source.find(function (x) { return String(x.id) === String(r.id); });
              }
              if (existante && op.kind === 'upsert') {
                Object.assign(existante, r);
                touchees.push(existante);
              } else {
                var ligne = Object.assign({ id: (r && r.id) || idDemo(table), created_at: new Date().toISOString() }, r);
                source.push(ligne);
                touchees.push(ligne);
              }
            });
          } else if (op.kind === 'update') {
            lignes.forEach(function (r) { Object.assign(r, op.patch); touchees.push(r); });
          } else if (op.kind === 'delete') {
            lignes.forEach(function (r) {
              var i = source.indexOf(r);
              if (i >= 0) source.splice(i, 1);
              touchees.push(r);
            });
          }
          var reponse = mode === 'single' || mode === 'maybeSingle'
            ? { data: touchees[0] || null, error: null }
            : { data: touchees, error: null };
          var pe = Promise.resolve(reponse);
          return resolve ? pe.then(resolve, reject) : pe;
        }

        var out = lignes.slice();
        tris.forEach(function (t) {
          out.sort(function (a, b) { return (t.asc ? 1 : -1) * compare(a[t.col], b[t.col]); });
        });
        if (borne !== null) out = out.slice(0, borne);

        var res;
        if (mode === 'single') {
          res = out.length ? { data: out[0], error: null }
                           : { data: null, error: { code: 'PGRST116', message: 'Aucune ligne (démo)' } };
        } else if (mode === 'maybeSingle') {
          res = { data: out[0] || null, error: null };
        } else {
          res = { data: out, error: null };
        }
        var p = Promise.resolve(res);
        return resolve ? p.then(resolve, reject) : p;
      },
      catch: function (fn) { return req.then().catch(fn); },
    };
    return req;
  }

  function createDemoClient(donnees) {
    var data = donnees || DEMO;
    return {
      _demo: true,
      from: function (table) { return creerRequete(table, data); },
      rpc: function (nom, args) {
        var f = RPC[nom];
        return Promise.resolve({ data: f ? f(args) : null, error: null });
      },
      functions: { invoke: function () { return Promise.resolve({ data: null, error: null }); } },
      auth: {
        onAuthStateChange: function () { return { data: { subscription: { unsubscribe: function () {} } } }; },
        getSession: function () { return Promise.resolve({ data: { session: null }, error: null }); },
        signInWithPassword: function () { return Promise.resolve({ data: null, error: { message: 'Mode démo' } }); },
        signUp: function () { return Promise.resolve({ data: null, error: { message: 'Mode démo' } }); },
        signOut: function () { return Promise.resolve({ error: null }); },
        updateUser: function () { return Promise.resolve({ error: { message: 'Mode démo' } }); },
        resetPasswordForEmail: function () { return Promise.resolve({ error: null }); },
        stopAutoRefresh: function () { return Promise.resolve(); },
      },
    };
  }

  // ── REST de demonstration ────────────────────────────────
  //
  // La page Lunch n'utilise pas le client supabase-js : elle appelle
  // cohFetch(), qui construit des URL PostgREST a la main. Le client de
  // demonstration ne peut donc rien intercepter. Cette fonction remplace
  // ces appels et couvre exactement la surface employee par cette page :
  // filtres `eq`, `order`, `limit`, `select`, et POST / PATCH / DELETE.
  //
  // Elle ecrit vraiment dans DEMO, contrairement au reste du mode
  // demonstration : rejoindre une file, la quitter et voir la place
  // suivante devenir active n'aurait aucun interet en lecture seule. Les
  // modifications vivent en memoire et disparaissent au rechargement.
  function demoRest(chemin, opts) {
    opts = opts || {};
    var methode = (opts.method || 'GET').toUpperCase();
    var coupe = String(chemin).split('?');
    var table = coupe[0];
    var params = new URLSearchParams(coupe[1] || '');

    if (!Object.prototype.hasOwnProperty.call(DEMO, table)) return Promise.resolve([]);
    var source = DEMO[table];

    // Filtres : seule la forme `colonne=eq.valeur` est employee ici.
    var lignes = source.filter(function (r) {
      var garde = true;
      params.forEach(function (v, k) {
        if (k === 'select' || k === 'order' || k === 'limit') return;
        if (v.indexOf('eq.') === 0 && String(r[k]) !== v.slice(3)) garde = false;
      });
      return garde;
    });

    var tri = params.get('order');
    if (tri) {
      var col = tri.split('.')[0], desc = /\.desc/.test(tri);
      lignes = lignes.slice().sort(function (a, b) {
        var x = a[col], y = b[col];
        return (desc ? -1 : 1) * (x < y ? -1 : x > y ? 1 : 0);
      });
    }
    var borne = params.get('limit');
    if (borne) lignes = lignes.slice(0, parseInt(borne, 10));

    if (methode === 'GET') return Promise.resolve(lignes);

    var corps = null;
    try { corps = opts.body ? JSON.parse(opts.body) : null; } catch (e) { corps = null; }

    if (methode === 'POST') {
      var neuve = Object.assign(
        { id: table + '-' + Math.random().toString(16).slice(2, 8) }, corps);
      source.push(neuve);
      return Promise.resolve([neuve]);
    }
    if (methode === 'PATCH') {
      lignes.forEach(function (r) { Object.assign(r, corps); });
      return Promise.resolve(lignes);
    }
    if (methode === 'DELETE') {
      lignes.forEach(function (r) {
        var i = source.indexOf(r);
        if (i >= 0) source.splice(i, 1);
      });
      return Promise.resolve(lignes);
    }
    return Promise.resolve([]);
  }

  global.COHABITAT_DEMO = DEMO;
  global.createDemoClient = createDemoClient;
  global.demoRest = demoRest;
})(window);
