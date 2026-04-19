-- ============================================================
-- Curby Backend — Initial Database Schema
-- Supabase (PostgreSQL + PostGIS)
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- PostGIS creates public.spatial_ref_sys which is extension-owned by
-- supabase_admin. We CANNOT enable RLS on it (42501: must be owner).
-- The REVOKE blocks anon/authenticated access, which is the real fix.
-- The Security Advisor warning is a known false positive for extension tables.
-- https://github.com/supabase/supabase/issues/29122
REVOKE ALL PRIVILEGES ON TABLE public.spatial_ref_sys FROM anon, authenticated;

-- ============================================================
-- Table: active_parks — The Live Occupancy Map
-- ============================================================
-- Every currently-parked Curby user has a row here.
-- When they leave, the row is deleted.
-- This table IS the crowdsourced occupancy data.

CREATE TABLE IF NOT EXISTS active_parks (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    uuid NOT NULL,
  location   geometry(Point, 4326) NOT NULL,
  geohash    text NOT NULL,
  parked_at  timestamptz NOT NULL,

  CONSTRAINT uq_active_parks_user UNIQUE (user_id)
);

COMMENT ON TABLE active_parks IS 'Live occupancy map — one row per currently parked Curby user.';

-- ============================================================
-- Table: parking_events — Historical Log (Algorithm Training Data)
-- ============================================================
-- Immutable append-only log of every park/depart event.
-- Used for historical pattern analysis and algorithm training.

CREATE TABLE IF NOT EXISTS parking_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid NOT NULL,
  event_type  text NOT NULL CHECK (event_type IN ('parked', 'departed')),
  location    geometry(Point, 4326) NOT NULL,
  geohash     text NOT NULL,
  recorded_at timestamptz NOT NULL,
  ingested_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE parking_events IS 'Immutable log of park/depart events for pattern analysis.';

-- ============================================================
-- Table: routing_sessions — Recommendation Audit Log
-- ============================================================
-- Tracks every parking recommendation the system makes.
-- Used for analytics, algorithm evaluation, and debugging.

CREATE TABLE IF NOT EXISTS routing_sessions (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           uuid NOT NULL,
  destination       geometry(Point, 4326) NOT NULL,
  search_radius_m   integer NOT NULL,
  recommended_area  jsonb NOT NULL,
  alternatives      jsonb,
  route_geometry    jsonb,
  eta_seconds       integer,
  score             real,
  status            text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'arrived', 'cancelled', 'expired')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz
);

COMMENT ON TABLE routing_sessions IS 'Audit log of every parking recommendation for analytics.';

-- ============================================================
-- Indexes
-- ============================================================

-- Spatial indexes (critical for occupancy queries)
CREATE INDEX IF NOT EXISTS idx_active_parks_location
  ON active_parks USING GIST (location);

CREATE INDEX IF NOT EXISTS idx_active_parks_geohash
  ON active_parks (geohash);

CREATE INDEX IF NOT EXISTS idx_events_location
  ON parking_events USING GIST (location);

CREATE INDEX IF NOT EXISTS idx_events_geohash_time
  ON parking_events (geohash, ingested_at DESC);

-- Lookup indexes
CREATE INDEX IF NOT EXISTS idx_active_parks_user
  ON active_parks (user_id);

CREATE INDEX IF NOT EXISTS idx_sessions_user_status
  ON routing_sessions (user_id, status);

-- ============================================================
-- Functions
-- ============================================================

-- Count parked cars within a radius of a point
CREATE OR REPLACE FUNCTION count_parked_nearby(
  lat double precision,
  lng double precision,
  radius_m integer DEFAULT 200
)
RETURNS bigint AS $$
  SELECT COUNT(*) FROM active_parks
  WHERE ST_DWithin(
    location::geography,
    ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography,
    radius_m
  );
$$ LANGUAGE sql STABLE;

-- Batch occupancy: count parked cars near multiple points at once
CREATE OR REPLACE FUNCTION batch_occupancy(
  points jsonb,
  radius_m integer DEFAULT 200
)
RETURNS TABLE(idx integer, parked_count bigint) AS $$
  SELECT
    (ordinality::integer - 1) AS idx,
    (SELECT COUNT(*) FROM active_parks
     WHERE ST_DWithin(
       location::geography,
       ST_SetSRID(ST_MakePoint(
         (point->>'lng')::double precision,
         (point->>'lat')::double precision
       ), 4326)::geography,
       radius_m
     )
    ) AS parked_count
  FROM jsonb_array_elements(points) WITH ORDINALITY AS t(point, ordinality);
$$ LANGUAGE sql STABLE;

-- Batch departures: count recent departures near multiple points
CREATE OR REPLACE FUNCTION batch_departures(
  points jsonb,
  radius_m integer DEFAULT 200,
  window_min integer DEFAULT 15
)
RETURNS TABLE(idx integer, departure_count bigint) AS $$
  SELECT
    (ordinality::integer - 1) AS idx,
    (SELECT COUNT(*) FROM parking_events
     WHERE event_type = 'departed'
       AND ingested_at > now() - (window_min || ' minutes')::interval
       AND ST_DWithin(
         location::geography,
         ST_SetSRID(ST_MakePoint(
           (point->>'lng')::double precision,
           (point->>'lat')::double precision
         ), 4326)::geography,
         radius_m
       )
    ) AS departure_count
  FROM jsonb_array_elements(points) WITH ORDINALITY AS t(point, ordinality);
$$ LANGUAGE sql STABLE;

-- Batch durations: get park durations (in minutes) of all cars near each point
CREATE OR REPLACE FUNCTION batch_durations(
  points jsonb,
  radius_m integer DEFAULT 200
)
RETURNS TABLE(idx integer, durations_min double precision[]) AS $$
  SELECT
    (ordinality::integer - 1) AS idx,
    (SELECT COALESCE(
       array_agg(EXTRACT(EPOCH FROM (now() - parked_at)) / 60.0),
       '{}'::double precision[]
     )
     FROM active_parks
     WHERE ST_DWithin(
       location::geography,
       ST_SetSRID(ST_MakePoint(
         (point->>'lng')::double precision,
         (point->>'lat')::double precision
       ), 4326)::geography,
       radius_m
     )
    ) AS durations_min
  FROM jsonb_array_elements(points) WITH ORDINALITY AS t(point, ordinality);
$$ LANGUAGE sql STABLE;

-- Batch confidence: count unique contributing users near each point (24h)
CREATE OR REPLACE FUNCTION batch_confidence(
  points jsonb,
  radius_m integer DEFAULT 200
)
RETURNS TABLE(idx integer, unique_users bigint) AS $$
  SELECT
    (ordinality::integer - 1) AS idx,
    (SELECT COUNT(DISTINCT user_id) FROM parking_events
     WHERE ingested_at > now() - interval '24 hours'
       AND ST_DWithin(
         location::geography,
         ST_SetSRID(ST_MakePoint(
           (point->>'lng')::double precision,
           (point->>'lat')::double precision
         ), 4326)::geography,
         radius_m
       )
    ) AS unique_users
  FROM jsonb_array_elements(points) WITH ORDINALITY AS t(point, ordinality);
$$ LANGUAGE sql STABLE;

-- Historical occupancy pattern for a geohash
CREATE OR REPLACE FUNCTION occupancy_pattern(
  target_geohash text,
  lookback_days integer DEFAULT 30
)
RETURNS TABLE(
  hour_of_day integer,
  day_of_week integer,
  avg_parked numeric,
  avg_departed numeric
) AS $$
  SELECT
    EXTRACT(HOUR FROM recorded_at)::integer AS hour_of_day,
    EXTRACT(DOW FROM recorded_at)::integer AS day_of_week,
    COUNT(*) FILTER (WHERE event_type = 'parked')::numeric
      / GREATEST(lookback_days / 7, 1) AS avg_parked,
    COUNT(*) FILTER (WHERE event_type = 'departed')::numeric
      / GREATEST(lookback_days / 7, 1) AS avg_departed
  FROM parking_events
  WHERE geohash LIKE target_geohash || '%'
    AND ingested_at > now() - (lookback_days || ' days')::interval
  GROUP BY 1, 2
  ORDER BY 2, 1;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- Write Functions (called from Supabase JS via RPC)
-- ============================================================
-- The REST API can't write PostGIS geometry columns directly,
-- so we use these functions to construct geometry server-side.

-- Upsert a park event into active_parks
CREATE OR REPLACE FUNCTION upsert_active_park(
  p_user_id uuid,
  p_lat double precision,
  p_lng double precision,
  p_geohash text,
  p_parked_at timestamptz
)
RETURNS void AS $$
BEGIN
  INSERT INTO active_parks (user_id, location, geohash, parked_at)
  VALUES (
    p_user_id,
    ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326),
    p_geohash,
    p_parked_at
  )
  ON CONFLICT (user_id) DO UPDATE SET
    location = ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326),
    geohash = p_geohash,
    parked_at = p_parked_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Insert a parking event (park or depart)
CREATE OR REPLACE FUNCTION insert_parking_event(
  p_user_id uuid,
  p_event_type text,
  p_lat double precision,
  p_lng double precision,
  p_geohash text,
  p_recorded_at timestamptz
)
RETURNS void AS $$
BEGIN
  INSERT INTO parking_events (user_id, event_type, location, geohash, recorded_at)
  VALUES (
    p_user_id,
    p_event_type,
    ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326),
    p_geohash,
    p_recorded_at
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Handle a depart event: delete from active_parks + log to parking_events
-- Implemented with DELETE…RETURNING in a CTE (no geometry/text DECLARE vars) so
-- Supabase’s SQL linter does not mistake PL/pgSQL variables for new tables.
CREATE OR REPLACE FUNCTION handle_depart(
  p_user_id uuid,
  p_recorded_at timestamptz
)
RETURNS void AS $$
DECLARE
  n int;
BEGIN
  WITH d AS (
    DELETE FROM active_parks
    WHERE user_id = p_user_id
    RETURNING location, geohash
  )
  INSERT INTO parking_events (user_id, event_type, location, geohash, recorded_at)
  SELECT p_user_id, 'departed', location, geohash, p_recorded_at
  FROM d;

  GET DIAGNOSTICS n = ROW_COUNT;

  IF n = 0 THEN
    RAISE EXCEPTION 'No active park not found for user %', p_user_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Insert a routing session (called from session-consumer)
CREATE OR REPLACE FUNCTION insert_routing_session(
  p_id uuid,
  p_user_id uuid,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_search_radius_m integer,
  p_recommended_area jsonb,
  p_alternatives jsonb DEFAULT NULL,
  p_route_geometry jsonb DEFAULT NULL,
  p_eta_seconds integer DEFAULT NULL,
  p_score real DEFAULT NULL
)
RETURNS void AS $$
BEGIN
  INSERT INTO routing_sessions (
    id, user_id, destination, search_radius_m,
    recommended_area, alternatives, route_geometry,
    eta_seconds, score, status
  ) VALUES (
    p_id,
    p_user_id,
    ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326),
    p_search_radius_m,
    p_recommended_area,
    p_alternatives,
    p_route_geometry,
    p_eta_seconds,
    p_score,
    'active'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================================
-- Row-Level Security
-- ============================================================
-- DROP POLICY IF EXISTS keeps this file safe to re-run after partial applies.

ALTER TABLE active_parks ENABLE ROW LEVEL SECURITY;
ALTER TABLE parking_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE routing_sessions ENABLE ROW LEVEL SECURITY;

-- active_parks: public read, secret key write
DROP POLICY IF EXISTS "active_parks_read" ON active_parks;
DROP POLICY IF EXISTS "active_parks_write" ON active_parks;
CREATE POLICY "active_parks_read" ON active_parks
  FOR SELECT USING (true);
CREATE POLICY "active_parks_write" ON active_parks
  FOR ALL USING (true) WITH CHECK (true);

-- parking_events: secret key only (no public access)
DROP POLICY IF EXISTS "parking_events_service" ON parking_events;
CREATE POLICY "parking_events_service" ON parking_events
  FOR ALL USING (true) WITH CHECK (true);

-- routing_sessions: public read filtered by user_id, secret key write
DROP POLICY IF EXISTS "routing_sessions_read" ON routing_sessions;
DROP POLICY IF EXISTS "routing_sessions_write" ON routing_sessions;
CREATE POLICY "routing_sessions_read" ON routing_sessions
  FOR SELECT USING (true);
CREATE POLICY "routing_sessions_write" ON routing_sessions
  FOR ALL USING (true) WITH CHECK (true);

-- RPC execution: API workers call these with the service role key.
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
