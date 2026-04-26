-- 004_export_client_data.sql
-- Conformite Loi 25 (Quebec) : permettre a un resident d'obtenir une copie
-- complete de ses donnees personnelles avant anonymisation. La RPC retourne
-- un JSONB structure couvrant TOUTES les tables ou il a une trace.
--
-- Securite :
--   * SECURITY DEFINER pour contourner les RLS : un resident peut etre
--     bloque sur sa propre row par certaines policies (ex: profile inactif)
--     mais a quand meme droit a ses donnees au sens Loi 25.
--   * Verification au debut : le caller DOIT etre soit le sujet lui-meme
--     (auth.uid() = p_user_id) soit un admin (role principal_admin / admin).
--     Sinon EXCEPTION privilege_violation.
--   * Le retour est volontairement gros (peut contenir des annees
--     d'historique). L'appelant cote client streame en download.
--
-- Usage :
--   const { data, error } = await sb.rpc('export_client_data',
--     { p_user_id: currentUser.id });
--   downloadAsJson(data, 'mes-donnees-' + Date.now() + '.json');

BEGIN;

CREATE OR REPLACE FUNCTION export_client_data(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller_role TEXT;
  v_result      JSONB;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id requis' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Auth check : le caller doit etre le sujet ou un admin.
  IF auth.uid() IS DISTINCT FROM p_user_id THEN
    SELECT role INTO v_caller_role FROM profiles WHERE id = auth.uid();
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin','principal_admin') THEN
      RAISE EXCEPTION 'access_denied : seul le sujet ou un admin peut exporter ces donnees'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- Construction du dump. Chaque section est une cle JSON ; les tables
  -- vides retournent un tableau vide (ne pas omettre — le rapport doit
  -- etre exhaustif et auditable).
  SELECT jsonb_build_object(
    'exported_at',           now(),
    'subject_user_id',       p_user_id,
    'exported_by',           auth.uid(),
    'schema_version',        '1.0'::text,

    'profile', (
      SELECT to_jsonb(p) FROM profiles p WHERE p.id = p_user_id
    ),

    'dependents', COALESCE((
      SELECT jsonb_agg(to_jsonb(d) ORDER BY d.created_at)
      FROM dependents d WHERE d.parent_id = p_user_id
    ), '[]'::jsonb),

    'transactions', COALESCE((
      SELECT jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC)
      FROM transactions t WHERE t.user_id = p_user_id
    ), '[]'::jsonb),

    'space_reservations', COALESCE((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.start_time DESC)
      FROM space_reservations r WHERE r.tenant_id = p_user_id
    ), '[]'::jsonb),

    'trips_as_driver', COALESCE((
      SELECT jsonb_agg(to_jsonb(t) ORDER BY t.departure_time DESC)
      FROM trips t WHERE t.driver_id = p_user_id
    ), '[]'::jsonb),

    'trip_bookings', COALESCE((
      SELECT jsonb_agg(to_jsonb(b) ORDER BY b.created_at DESC)
      FROM trip_bookings b WHERE b.passenger_id = p_user_id
    ), '[]'::jsonb),

    'trip_cargo_usage', COALESCE((
      SELECT jsonb_agg(to_jsonb(c) ORDER BY c.created_at DESC)
      FROM trip_cargo_usage c WHERE c.user_id = p_user_id
    ), '[]'::jsonb),

    'driver_dependent_seats', COALESCE((
      SELECT jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC)
      FROM driver_dependent_seats s WHERE s.driver_id = p_user_id
    ), '[]'::jsonb),

    'real_payments_received', COALESCE((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
      FROM real_payments r WHERE r.tenant_id = p_user_id
    ), '[]'::jsonb),

    'reservation_requests', COALESCE((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
      FROM reservation_requests r WHERE r.user_id = p_user_id
    ), '[]'::jsonb),

    'notifications', COALESCE((
      SELECT jsonb_agg(to_jsonb(n) ORDER BY n.created_at DESC)
      FROM notifications n WHERE n.user_id = p_user_id
    ), '[]'::jsonb),

    'lunch_transactions', COALESCE((
      SELECT jsonb_agg(to_jsonb(lt) ORDER BY lt.created_at DESC)
      FROM lunch_transactions lt WHERE lt.user_id = p_user_id
    ), '[]'::jsonb),

    'deletion_requests', COALESCE((
      SELECT jsonb_agg(to_jsonb(dr) ORDER BY dr.created_at DESC)
      FROM deletion_requests dr WHERE dr.user_id = p_user_id
    ), '[]'::jsonb)
  ) INTO v_result;

  -- Note : les tables qui n'existent pas sur certaines instances (ex:
  -- migrations partiellement appliquees) declencheraient une erreur ici.
  -- En cas d'erreur, la transaction tout entiere rollback et le caller
  -- recoit une erreur claire — c'est le comportement souhaite (un
  -- export incomplet serait pire qu'un echec).

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION export_client_data(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION export_client_data(UUID) TO authenticated;

COMMENT ON FUNCTION export_client_data(UUID) IS
  'Loi 25 / RGPD : retourne en JSONB toutes les donnees personnelles d''un
  resident pour respecter le droit d''acces. Le caller doit etre soit le
  sujet (auth.uid() = p_user_id) soit un admin.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ROLLBACK :
--   DROP FUNCTION IF EXISTS export_client_data(UUID);
