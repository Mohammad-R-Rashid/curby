// ============================================================
// Route: GET /v1/park (WebSocket Upgrade)
// ============================================================
// Computes region geohash from destination, then forwards
// the WebSocket upgrade to the appropriate RegionCoordinatorDO.

import type { Env } from '@curby/shared';
import { regionGeohash } from '@curby/shared';

export async function handleWebSocketUpgrade(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const lat = Number(url.searchParams.get('lat'));
  const lng = Number(url.searchParams.get('lng'));

  if (isNaN(lat) || isNaN(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    return new Response(
      JSON.stringify({ error: 'Invalid lat/lng query parameters' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } },
    );
  }

  // Compute region geohash (precision 4 ≈ 20km) — this determines which DO instance handles the request
  const region = regionGeohash(lat, lng);
  const doId = env.REGION_COORDINATOR.idFromName(region);
  const stub = env.REGION_COORDINATOR.get(doId);

  // Forward the WebSocket upgrade to the Durable Object
  return stub.fetch(request);
}
