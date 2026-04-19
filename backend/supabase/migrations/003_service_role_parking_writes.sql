-- ============================================================
-- Curby Backend — Service role access for parking writes
-- ============================================================
-- Park/depart flows call SECURITY DEFINER RPCs from the API
-- worker using the Supabase secret (`sb_secret_*`) JWT. Inserts
-- run as the **function owner**, not as the caller role; missing
-- table/sequence privileges for that owner (or missing EXECUTE
-- for service_role) can produce 500s and empty tables.
--
-- This migration:
-- 1) Grants explicit DML + sequence usage to `service_role`
--    (PostgREST direct access + defensive consistency).
-- 2) Ensures write RPCs are owned by `postgres` so DEFINER
--    execution matches typical Supabase ownership.
-- 3) Re-applies EXECUTE grants for `service_role` (idempotent).

GRANT USAGE ON SCHEMA public TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.active_parks TO service_role;
GRANT SELECT, INSERT ON TABLE public.parking_events TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.routing_sessions TO service_role;

-- Identity column `parking_events.id` — INSERT must be able to advance the sequence.
DO $$
DECLARE
  seq_fqn text;
BEGIN
  seq_fqn := pg_get_serial_sequence('public.parking_events', 'id');
  IF seq_fqn IS NOT NULL THEN
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO service_role', seq_fqn);
  END IF;
END;
$$;

ALTER FUNCTION public.upsert_active_park(uuid, double precision, double precision, text, timestamptz)
  OWNER TO postgres;
ALTER FUNCTION public.insert_parking_event(uuid, text, double precision, double precision, text, timestamptz)
  OWNER TO postgres;
ALTER FUNCTION public.handle_depart(uuid, timestamptz)
  OWNER TO postgres;
ALTER FUNCTION public.insert_routing_session(uuid, uuid, double precision, double precision, integer, jsonb, jsonb, jsonb, integer, real)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.upsert_active_park(uuid, double precision, double precision, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.insert_parking_event(uuid, text, double precision, double precision, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.handle_depart(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.insert_routing_session(uuid, uuid, double precision, double precision, integer, jsonb, jsonb, jsonb, integer, real)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.upsert_active_park(uuid, double precision, double precision, text, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.insert_parking_event(uuid, text, double precision, double precision, text, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.handle_depart(uuid, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.insert_routing_session(uuid, uuid, double precision, double precision, integer, jsonb, jsonb, jsonb, integer, real)
  TO service_role;
