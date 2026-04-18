// ============================================================
// Routes: POST /v1/events/park & /v1/events/depart
// ============================================================
// Park/depart events are low-frequency — direct Supabase writes.
//
// NOTE: PostGIS geometry columns can't be written via plain
// Supabase JS inserts (the REST API doesn't parse WKT).
// We use RPC functions to handle the spatial insert.

import type { Env } from '@curby/shared';
import { ParkEventSchema, DepartEventSchema, getSupabase, encodeGeohash } from '@curby/shared';

export async function handleParkEvent(request: Request, env: Env): Promise<Response> {
  const body = await request.json();
  const parsed = ParkEventSchema.safeParse(body);

  if (!parsed.success) {
    return new Response(
      JSON.stringify({ error: 'Invalid payload', details: parsed.error.flatten() }),
      { status: 400, headers: { 'Content-Type': 'application/json' } },
    );
  }

  const { userId, lat, lng, timestamp } = parsed.data;
  const geohash = encodeGeohash(lat, lng);
  const supabase = getSupabase(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY);

  // Use RPC to insert with PostGIS geometry
  const { error: upsertErr } = await supabase.rpc('upsert_active_park', {
    p_user_id: userId,
    p_lat: lat,
    p_lng: lng,
    p_geohash: geohash,
    p_parked_at: timestamp,
  });

  if (upsertErr) {
    console.error('active_parks upsert error:', upsertErr);
    return new Response(
      JSON.stringify({ error: 'Database error', detail: upsertErr.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }

  // Append to parking_events log
  const { error: insertErr } = await supabase.rpc('insert_parking_event', {
    p_user_id: userId,
    p_event_type: 'parked',
    p_lat: lat,
    p_lng: lng,
    p_geohash: geohash,
    p_recorded_at: timestamp,
  });

  if (insertErr) {
    console.error('parking_events insert error:', insertErr);
    // Non-fatal — the active_parks upsert already succeeded
  }

  return new Response(null, { status: 201 });
}

export async function handleDepartEvent(request: Request, env: Env): Promise<Response> {
  const body = await request.json();
  const parsed = DepartEventSchema.safeParse(body);

  if (!parsed.success) {
    return new Response(
      JSON.stringify({ error: 'Invalid payload', details: parsed.error.flatten() }),
      { status: 400, headers: { 'Content-Type': 'application/json' } },
    );
  }

  const { userId, timestamp } = parsed.data;
  const supabase = getSupabase(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY);

  // Use RPC to handle depart (deletes from active_parks + logs event)
  const { data, error } = await supabase.rpc('handle_depart', {
    p_user_id: userId,
    p_recorded_at: timestamp,
  });

  if (error) {
    console.error('handle_depart error:', error);
    // If user wasn't found, return 404
    if (error.message?.includes('not found')) {
      return new Response(
        JSON.stringify({ error: 'No active park found for this user' }),
        { status: 404, headers: { 'Content-Type': 'application/json' } },
      );
    }
    return new Response(
      JSON.stringify({ error: 'Database error', detail: error.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }

  return new Response(null, { status: 200 });
}
