-- ============================================================
-- Curby Backend — RPC Execution Permissions
-- ============================================================
-- Existing deployments created the write RPCs without SECURITY DEFINER,
-- which causes permission failures when the API worker tries to write
-- through Supabase RPC. Apply this migration after 001 on live databases.

ALTER FUNCTION upsert_active_park(uuid, double precision, double precision, text, timestamptz)
  SECURITY DEFINER
  SET search_path = public;

ALTER FUNCTION insert_parking_event(uuid, text, double precision, double precision, text, timestamptz)
  SECURITY DEFINER
  SET search_path = public;

ALTER FUNCTION handle_depart(uuid, timestamptz)
  SECURITY DEFINER
  SET search_path = public;

ALTER FUNCTION insert_routing_session(uuid, uuid, double precision, double precision, integer, jsonb, jsonb, jsonb, integer, real)
  SECURITY DEFINER
  SET search_path = public;

REVOKE ALL ON FUNCTION upsert_active_park(uuid, double precision, double precision, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION insert_parking_event(uuid, text, double precision, double precision, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION handle_depart(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION insert_routing_session(uuid, uuid, double precision, double precision, integer, jsonb, jsonb, jsonb, integer, real)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION upsert_active_park(uuid, double precision, double precision, text, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION insert_parking_event(uuid, text, double precision, double precision, text, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION handle_depart(uuid, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION insert_routing_session(uuid, uuid, double precision, double precision, integer, jsonb, jsonb, jsonb, integer, real)
  TO service_role;
