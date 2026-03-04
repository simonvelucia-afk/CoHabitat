-- ============================================================
-- SCHEMA SUPABASE — Système de gestion de ressources communes
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis"; -- pour les coordonnées GPS (optionnel)

-- ============================================================
-- TABLES DE BASE
-- ============================================================

-- Profils utilisateurs (liés à auth.users)
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  full_name TEXT NOT NULL,
  unit TEXT, -- unité résidentielle
  role TEXT NOT NULL DEFAULT 'tenant' CHECK (role IN ('principal_admin', 'admin', 'tenant', 'demo')),
  is_approved_driver BOOLEAN DEFAULT FALSE,
  virtual_balance DECIMAL(10,2) DEFAULT 0.00,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Compte virtuel de démonstration (inséré manuellement ou via trigger)
INSERT INTO profiles (id, email, full_name, unit, role, is_approved_driver, virtual_balance)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'demo@demo.local',
  'Utilisateur Démo',
  'DEMO',
  'demo',
  FALSE,
  0.00
) ON CONFLICT DO NOTHING;

-- ============================================================
-- PARAMÈTRES SYSTÈME (gérés par admin principal)
-- ============================================================
CREATE TABLE system_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  description TEXT,
  updated_by UUID REFERENCES profiles(id),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO system_settings (key, value, description) VALUES
  ('driver_cancel_hours', '24', 'Heures avant départ pour annulation chauffeur sans frais'),
  ('passenger_cancel_minutes', '60', 'Minutes avant départ pour annulation passager sans frais'),
  ('slot_duration_minutes', '15', 'Durée minimale de réservation en minutes'),
  ('demo_mode_enabled', 'true', 'Activer le mode démo'),
  ('currency_name', 'crédits', 'Nom de la monnaie virtuelle'),
  ('currency_symbol', '₡', 'Symbole de la monnaie virtuelle');

-- ============================================================
-- ESPACES COMMUNS
-- ============================================================
CREATE TABLE common_spaces (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  description TEXT,
  capacity INT DEFAULT 1,
  location TEXT,
  is_available BOOLEAN DEFAULT TRUE,
  image_url TEXT,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tarification des espaces communs
CREATE TABLE space_pricing (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  space_id UUID NOT NULL REFERENCES common_spaces(id) ON DELETE CASCADE,
  price_per_slot DECIMAL(10,2) NOT NULL, -- par tranche de 15 min
  valid_from TIMESTAMPTZ DEFAULT NOW(),
  valid_to TIMESTAMPTZ,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Réservations d'espaces communs
CREATE TABLE space_reservations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  space_id UUID NOT NULL REFERENCES common_spaces(id),
  tenant_id UUID NOT NULL REFERENCES profiles(id),
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  total_slots INT NOT NULL, -- nombre de tranches de 15 min
  total_cost DECIMAL(10,2) NOT NULL,
  status TEXT DEFAULT 'confirmed' CHECK (status IN ('pending', 'confirmed', 'cancelled', 'completed')),
  is_demo BOOLEAN DEFAULT FALSE,
  cancelled_at TIMESTAMPTZ,
  cancel_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- VÉHICULES
-- ============================================================
CREATE TABLE vehicles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  model TEXT NOT NULL,
  license_plate TEXT UNIQUE NOT NULL,
  seat_count INT NOT NULL DEFAULT 4,
  cargo_capacity_m3 DECIMAL(5,2) DEFAULT 0, -- en m³
  is_available BOOLEAN DEFAULT TRUE,
  image_url TEXT,
  color TEXT,
  year INT,
  notes TEXT,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tarification des véhicules
CREATE TABLE vehicle_pricing (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehicle_id UUID NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  price_per_minute DECIMAL(10,4) NOT NULL,
  price_per_km DECIMAL(10,4) NOT NULL,
  price_per_cargo_slot DECIMAL(10,4) DEFAULT 0, -- par tranche de 10%
  valid_from TIMESTAMPTZ DEFAULT NOW(),
  valid_to TIMESTAMPTZ,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Trajets publiés par les chauffeurs
CREATE TABLE trips (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehicle_id UUID NOT NULL REFERENCES vehicles(id),
  driver_id UUID NOT NULL REFERENCES profiles(id),
  title TEXT NOT NULL,
  description TEXT,
  departure_point TEXT NOT NULL,
  departure_lat DECIMAL(10,7),
  departure_lng DECIMAL(10,7),
  destination TEXT NOT NULL,
  destination_lat DECIMAL(10,7),
  destination_lng DECIMAL(10,7),
  departure_time TIMESTAMPTZ NOT NULL,
  estimated_arrival TIMESTAMPTZ,
  estimated_distance_km DECIMAL(10,2),
  available_seats INT NOT NULL,
  cargo_available_pct INT DEFAULT 100 CHECK (cargo_available_pct BETWEEN 0 AND 100),
  status TEXT DEFAULT 'published' CHECK (status IN ('draft', 'published', 'in_progress', 'completed', 'cancelled')),
  cancel_reason TEXT,
  cancelled_at TIMESTAMPTZ,
  replaced_by_driver UUID REFERENCES profiles(id),
  is_demo BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Arrêts intermédiaires des trajets
CREATE TABLE trip_stops (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
  stop_order INT NOT NULL,
  location TEXT NOT NULL,
  lat DECIMAL(10,7),
  lng DECIMAL(10,7),
  estimated_arrival TIMESTAMPTZ,
  actual_arrival TIMESTAMPTZ,
  actual_departure TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Réservations de trajets (passagers)
CREATE TABLE trip_bookings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trip_id UUID NOT NULL REFERENCES trips(id),
  passenger_id UUID NOT NULL REFERENCES profiles(id),
  pickup_stop_id UUID REFERENCES trip_stops(id),
  dropoff_stop_id UUID REFERENCES trip_stops(id),
  pickup_location TEXT NOT NULL,
  dropoff_location TEXT NOT NULL,
  pickup_lat DECIMAL(10,7),
  pickup_lng DECIMAL(10,7),
  dropoff_lat DECIMAL(10,7),
  dropoff_lng DECIMAL(10,7),
  seats_requested INT NOT NULL DEFAULT 1,
  cargo_pct_requested INT DEFAULT 0 CHECK (cargo_pct_requested BETWEEN 0 AND 100),
  detour_km DECIMAL(10,2) DEFAULT 0,
  detour_cost DECIMAL(10,2) DEFAULT 0,
  total_cost DECIMAL(10,2),
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected', 'cancelled', 'completed')),
  is_dependent BOOLEAN DEFAULT FALSE, -- passager à charge du chauffeur
  passenger_accepted_cost BOOLEAN DEFAULT FALSE,
  cancelled_at TIMESTAMPTZ,
  cancel_reason TEXT,
  charged_despite_cancel BOOLEAN DEFAULT FALSE,
  replaced_by_passenger UUID REFERENCES profiles(id),
  is_demo BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sièges utilisés par les passagers à charge du chauffeur
CREATE TABLE driver_dependent_seats (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trip_id UUID NOT NULL REFERENCES trips(id),
  driver_id UUID NOT NULL REFERENCES profiles(id),
  dependent_name TEXT NOT NULL,
  seat_number INT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Utilisation cargo par le chauffeur pour un trajet
CREATE TABLE trip_cargo_usage (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  trip_id UUID NOT NULL REFERENCES trips(id),
  user_id UUID NOT NULL REFERENCES profiles(id),
  cargo_pct INT NOT NULL CHECK (cargo_pct BETWEEN 0 AND 100),
  is_driver BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- TRANSACTIONS FINANCIÈRES
-- ============================================================
CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id),
  amount DECIMAL(10,2) NOT NULL, -- positif = crédit, négatif = débit
  balance_after DECIMAL(10,2) NOT NULL,
  type TEXT NOT NULL CHECK (type IN (
    'admin_credit',        -- admin crédite un paiement réel
    'space_reservation',   -- débit réservation espace
    'space_cancel_refund', -- remboursement annulation espace
    'trip_booking',        -- débit réservation trajet passager
    'trip_cancel_refund',  -- remboursement annulation trajet
    'trip_cancel_charge',  -- frais annulation tardive
    'trip_driver_earning', -- gains chauffeur
    'trip_driver_charge',  -- charge chauffeur si annulation tardive
    'demo'                 -- transaction démo
  )),
  reference_id UUID, -- ID de la réservation ou du trajet concerné
  reference_type TEXT, -- 'space_reservation', 'trip_booking', 'trip'
  description TEXT,
  created_by UUID REFERENCES profiles(id), -- si fait par admin
  is_demo BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Paiements réels enregistrés par admin
CREATE TABLE real_payments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id UUID NOT NULL REFERENCES profiles(id),
  amount_real DECIMAL(10,2) NOT NULL, -- montant en devise réelle
  amount_virtual DECIMAL(10,2) NOT NULL, -- montant en crédits alloués
  payment_method TEXT, -- 'cash', 'transfer', 'cheque', etc.
  notes TEXT,
  recorded_by UUID NOT NULL REFERENCES profiles(id),
  transaction_id UUID REFERENCES transactions(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- DEMANDES DE RÉSERVATION (log des actions démo aussi)
-- ============================================================
CREATE TABLE reservation_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id),
  resource_type TEXT NOT NULL CHECK (resource_type IN ('space', 'trip', 'vehicle')),
  resource_id UUID NOT NULL,
  action TEXT NOT NULL, -- 'view', 'request', 'cancel', 'book'
  details JSONB,
  is_demo BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- NOTIFICATIONS
-- ============================================================
CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  type TEXT DEFAULT 'info' CHECK (type IN ('info', 'success', 'warning', 'error')),
  is_read BOOLEAN DEFAULT FALSE,
  reference_id UUID,
  reference_type TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- FONCTIONS ET TRIGGERS
-- ============================================================

-- Fonction: mettre à jour updated_at automatiquement
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_trips_updated_at
  BEFORE UPDATE ON trips
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_trip_bookings_updated_at
  BEFORE UPDATE ON trip_bookings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Fonction: créer un profil automatiquement à l'inscription
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id, email, full_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', 'Nouvel utilisateur'),
    'tenant'
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- Fonction: débiter/créditer le solde d'un utilisateur
CREATE OR REPLACE FUNCTION adjust_balance(
  p_user_id UUID,
  p_amount DECIMAL,
  p_type TEXT,
  p_reference_id UUID DEFAULT NULL,
  p_reference_type TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_created_by UUID DEFAULT NULL,
  p_is_demo BOOLEAN DEFAULT FALSE
)
RETURNS DECIMAL AS $$
DECLARE
  v_new_balance DECIMAL;
BEGIN
  UPDATE profiles
  SET virtual_balance = virtual_balance + p_amount
  WHERE id = p_user_id
  RETURNING virtual_balance INTO v_new_balance;

  INSERT INTO transactions (
    user_id, amount, balance_after, type,
    reference_id, reference_type, description,
    created_by, is_demo
  ) VALUES (
    p_user_id, p_amount, v_new_balance, p_type,
    p_reference_id, p_reference_type, p_description,
    p_created_by, p_is_demo
  );

  RETURN v_new_balance;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction: vérifier disponibilité espace (pas de chevauchement)
CREATE OR REPLACE FUNCTION check_space_availability(
  p_space_id UUID,
  p_start TIMESTAMPTZ,
  p_end TIMESTAMPTZ,
  p_exclude_id UUID DEFAULT NULL
)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN NOT EXISTS (
    SELECT 1 FROM space_reservations
    WHERE space_id = p_space_id
      AND status IN ('confirmed', 'pending')
      AND id != COALESCE(p_exclude_id, uuid_nil())
      AND (start_time, end_time) OVERLAPS (p_start, p_end)
  );
END;
$$ LANGUAGE plpgsql;

-- Fonction: calculer coût réservation espace
CREATE OR REPLACE FUNCTION calculate_space_cost(
  p_space_id UUID,
  p_start TIMESTAMPTZ,
  p_end TIMESTAMPTZ
)
RETURNS DECIMAL AS $$
DECLARE
  v_price_per_slot DECIMAL;
  v_slots INT;
  v_minutes INT;
BEGIN
  SELECT price_per_slot INTO v_price_per_slot
  FROM space_pricing
  WHERE space_id = p_space_id
    AND valid_from <= NOW()
    AND (valid_to IS NULL OR valid_to > NOW())
  ORDER BY valid_from DESC
  LIMIT 1;

  IF v_price_per_slot IS NULL THEN
    RETURN 0;
  END IF;

  v_minutes := EXTRACT(EPOCH FROM (p_end - p_start)) / 60;
  v_slots := CEIL(v_minutes / 15.0);

  RETURN v_slots * v_price_per_slot;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE common_spaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE space_pricing ENABLE ROW LEVEL SECURITY;
ALTER TABLE space_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_pricing ENABLE ROW LEVEL SECURITY;
ALTER TABLE trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_stops ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE real_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_dependent_seats ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_cargo_usage ENABLE ROW LEVEL SECURITY;

-- Helper function: get current user role
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS TEXT AS $$
  SELECT role FROM profiles WHERE id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Profiles: chacun voit son propre profil, admins voient tout
CREATE POLICY "profiles_self" ON profiles FOR SELECT USING (id = auth.uid());
CREATE POLICY "profiles_admin" ON profiles FOR ALL USING (get_my_role() IN ('admin', 'principal_admin'));

-- Espaces communs: tous les authentifiés voient, admins modifient
CREATE POLICY "spaces_select" ON common_spaces FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "spaces_admin" ON common_spaces FOR ALL USING (get_my_role() IN ('admin', 'principal_admin'));

-- Tarification: visible par tous authentifiés
CREATE POLICY "pricing_select" ON space_pricing FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "pricing_admin" ON space_pricing FOR ALL USING (get_my_role() IN ('admin', 'principal_admin'));

-- Réservations espaces: propriétaire ou admin
CREATE POLICY "space_res_select" ON space_reservations FOR SELECT USING (
  tenant_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);
CREATE POLICY "space_res_insert" ON space_reservations FOR INSERT WITH CHECK (
  tenant_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);
CREATE POLICY "space_res_update" ON space_reservations FOR UPDATE USING (
  tenant_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);

-- Véhicules: tous authentifiés voient
CREATE POLICY "vehicles_select" ON vehicles FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "vehicles_admin" ON vehicles FOR ALL USING (get_my_role() IN ('admin', 'principal_admin'));

-- Tarification véhicules
CREATE POLICY "vprice_select" ON vehicle_pricing FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "vprice_admin" ON vehicle_pricing FOR ALL USING (get_my_role() IN ('admin', 'principal_admin'));

-- Trajets: tous voient les publiés, chauffeur voit ses propres, admin voit tout
CREATE POLICY "trips_select" ON trips FOR SELECT USING (
  status = 'published' OR driver_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);
CREATE POLICY "trips_driver_insert" ON trips FOR INSERT WITH CHECK (
  driver_id = auth.uid() AND (SELECT is_approved_driver FROM profiles WHERE id = auth.uid())
);
CREATE POLICY "trips_driver_update" ON trips FOR UPDATE USING (
  driver_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);

-- Arrêts: visibles par tous authentifiés
CREATE POLICY "stops_select" ON trip_stops FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "stops_driver" ON trip_stops FOR ALL USING (
  EXISTS (SELECT 1 FROM trips WHERE id = trip_id AND driver_id = auth.uid())
  OR get_my_role() IN ('admin', 'principal_admin')
);

-- Réservations trajets
CREATE POLICY "bookings_select" ON trip_bookings FOR SELECT USING (
  passenger_id = auth.uid()
  OR EXISTS (SELECT 1 FROM trips WHERE id = trip_id AND driver_id = auth.uid())
  OR get_my_role() IN ('admin', 'principal_admin')
);
CREATE POLICY "bookings_insert" ON trip_bookings FOR INSERT WITH CHECK (passenger_id = auth.uid());
CREATE POLICY "bookings_update" ON trip_bookings FOR UPDATE USING (
  passenger_id = auth.uid()
  OR EXISTS (SELECT 1 FROM trips WHERE id = trip_id AND driver_id = auth.uid())
  OR get_my_role() IN ('admin', 'principal_admin')
);

-- Transactions: propriétaire ou admin
CREATE POLICY "tx_select" ON transactions FOR SELECT USING (
  user_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);

-- Paiements réels: admins seulement
CREATE POLICY "payments_admin" ON real_payments FOR ALL USING (get_my_role() IN ('admin', 'principal_admin'));

-- Notifications: propriétaire seulement
CREATE POLICY "notif_select" ON notifications FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "notif_update" ON notifications FOR UPDATE USING (user_id = auth.uid());

-- Paramètres système: lecture pour tous, écriture admin principal
CREATE POLICY "settings_select" ON system_settings FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "settings_admin" ON system_settings FOR UPDATE USING (get_my_role() = 'principal_admin');

-- Logs de demandes
CREATE POLICY "req_select" ON reservation_requests FOR SELECT USING (
  user_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);
CREATE POLICY "req_insert" ON reservation_requests FOR INSERT WITH CHECK (user_id = auth.uid());

-- Dépendants chauffeur
CREATE POLICY "deps_driver" ON driver_dependent_seats FOR ALL USING (
  driver_id = auth.uid() OR get_my_role() IN ('admin', 'principal_admin')
);

-- Cargo usage
CREATE POLICY "cargo_select" ON trip_cargo_usage FOR SELECT USING (
  user_id = auth.uid()
  OR EXISTS (SELECT 1 FROM trips WHERE id = trip_id AND driver_id = auth.uid())
  OR get_my_role() IN ('admin', 'principal_admin')
);
CREATE POLICY "cargo_insert" ON trip_cargo_usage FOR INSERT WITH CHECK (user_id = auth.uid());

-- ============================================================
-- VUES PRATIQUES
-- ============================================================

-- Vue: espaces avec disponibilité actuelle et tarif
CREATE OR REPLACE VIEW spaces_with_availability AS
SELECT
  cs.*,
  sp.price_per_slot,
  NOT EXISTS (
    SELECT 1 FROM space_reservations sr
    WHERE sr.space_id = cs.id
      AND sr.status IN ('confirmed', 'pending')
      AND sr.start_time <= NOW()
      AND sr.end_time >= NOW()
  ) AS currently_available
FROM common_spaces cs
LEFT JOIN space_pricing sp ON sp.space_id = cs.id
  AND sp.valid_from <= NOW()
  AND (sp.valid_to IS NULL OR sp.valid_to > NOW());

-- Vue: trajets avec infos chauffeur et réservations
CREATE OR REPLACE VIEW trips_with_details AS
SELECT
  t.*,
  p.full_name AS driver_name,
  p.unit AS driver_unit,
  v.model AS vehicle_model,
  v.license_plate,
  v.seat_count AS vehicle_seats,
  v.cargo_capacity_m3,
  vp.price_per_minute,
  vp.price_per_km,
  vp.price_per_cargo_slot,
  COALESCE((
    SELECT SUM(tb.seats_requested)
    FROM trip_bookings tb
    WHERE tb.trip_id = t.id AND tb.status = 'accepted'
  ), 0) AS booked_seats,
  COALESCE((
    SELECT SUM(tb.cargo_pct_requested)
    FROM trip_bookings tb
    WHERE tb.trip_id = t.id AND tb.status = 'accepted'
  ), 0) AS booked_cargo_pct
FROM trips t
JOIN profiles p ON p.id = t.driver_id
JOIN vehicles v ON v.id = t.vehicle_id
LEFT JOIN vehicle_pricing vp ON vp.vehicle_id = t.vehicle_id
  AND vp.valid_from <= NOW()
  AND (vp.valid_to IS NULL OR vp.valid_to > NOW());

-- ============================================================
-- DONNÉES D'EXEMPLE (à supprimer en production)
-- ============================================================

-- Espaces communs exemples
INSERT INTO common_spaces (name, description, capacity, location) VALUES
  ('Salle communautaire A', 'Grande salle pour événements, projections et réunions', 50, 'Rez-de-chaussée, aile Est'),
  ('Terrasse rooftop', 'Espace extérieur avec vue panoramique', 30, 'Toit, accès par ascenseur'),
  ('Salle de sport', 'Équipements fitness: tapis, vélos, poids', 10, 'Sous-sol'),
  ('Salle de réunion B', 'Petite salle équipée projecteur et whiteboard', 8, '2e étage'),
  ('Barbecue & Patio', 'Zone BBQ couverte avec tables de pique-nique', 20, 'Cour arrière');

-- Tarification espaces (prix par tranche 15 min)
INSERT INTO space_pricing (space_id, price_per_slot)
SELECT id, 
  CASE name
    WHEN 'Salle communautaire A' THEN 5.00
    WHEN 'Terrasse rooftop' THEN 3.00
    WHEN 'Salle de sport' THEN 2.00
    WHEN 'Salle de réunion B' THEN 4.00
    WHEN 'Barbecue & Patio' THEN 2.50
  END
FROM common_spaces;

-- Véhicule exemple
INSERT INTO vehicles (model, license_plate, seat_count, cargo_capacity_m3, color, year) VALUES
  ('Toyota Sienna 2022', 'ABC-1234', 7, 2.5, 'Gris Argent', 2022),
  ('Ford Transit Connect', 'XYZ-5678', 5, 4.0, 'Blanc', 2021),
  ('Tesla Model Y', 'EV-0001', 5, 1.0, 'Noir', 2023);

-- Tarification véhicules
INSERT INTO vehicle_pricing (vehicle_id, price_per_minute, price_per_km, price_per_cargo_slot)
SELECT id,
  CASE model
    WHEN 'Toyota Sienna 2022' THEN 0.25
    WHEN 'Ford Transit Connect' THEN 0.20
    WHEN 'Tesla Model Y' THEN 0.30
  END,
  CASE model
    WHEN 'Toyota Sienna 2022' THEN 0.18
    WHEN 'Ford Transit Connect' THEN 0.15
    WHEN 'Tesla Model Y' THEN 0.22
  END,
  0.50
FROM vehicles;

-- ============================================================
-- INDEXES POUR PERFORMANCE
-- ============================================================
CREATE INDEX idx_space_reservations_space_id ON space_reservations(space_id);
CREATE INDEX idx_space_reservations_tenant_id ON space_reservations(tenant_id);
CREATE INDEX idx_space_reservations_times ON space_reservations(start_time, end_time);
CREATE INDEX idx_trips_driver_id ON trips(driver_id);
CREATE INDEX idx_trips_departure_time ON trips(departure_time);
CREATE INDEX idx_trips_status ON trips(status);
CREATE INDEX idx_trip_bookings_trip_id ON trip_bookings(trip_id);
CREATE INDEX idx_trip_bookings_passenger_id ON trip_bookings(passenger_id);
CREATE INDEX idx_transactions_user_id ON transactions(user_id);
CREATE INDEX idx_notifications_user_id ON notifications(user_id, is_read);
