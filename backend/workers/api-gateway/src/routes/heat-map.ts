// ============================================================
// Route: GET /v1/parking-heat-map
// ============================================================
// Returns the parking heat map (Easy/Medium/Hard polygon tiles) for
// an area around a given lat/lng. Cached in KV at a quantized key so
// many users querying the same neighborhood share one compute.

import type { Env } from '@curby/shared';
import {
  computeHeatMap,
  getConfig,
  getSupabase,
  type HeatMapResponse,
} from '@curby/shared';

const KV_KEY_PREFIX = 'heat-map:v1:';
/**
 * Quantization step for the cache key, in meters. 50m keeps users
 * panning around a destination sharing the same cache slot while
 * distinct destinations across the city stay separated.
 */
const ANCHOR_QUANTIZATION_M = 50;
const RADIUS_QUANTIZATION_M = 50;

export async function handleParkingHeatMap(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);

  const lat = parseFloat(url.searchParams.get('lat') ?? '');
  const lng = parseFloat(url.searchParams.get('lng') ?? '');
  const radiusParam = url.searchParams.get('radiusM');

  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    return badRequest('lat is required and must be in [-90, 90]');
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    return badRequest('lng is required and must be in [-180, 180]');
  }

  const config = await getConfig(env.CURBY_CONFIG);
  const cfg = config.heatMap;

  const requestedRadius = radiusParam !== null ? parseFloat(radiusParam) : cfg.defaultRadiusMeters;
  if (!Number.isFinite(requestedRadius) || requestedRadius <= 0) {
    return badRequest('radiusM must be a positive number');
  }
  const radiusM = Math.min(requestedRadius, cfg.maxRadiusMeters);

  const anchor = { lat, lng };
  const cacheKey = buildCacheKey(anchor, radiusM);

  // 1. KV cache lookup.
  const cached = await env.CURBY_CONFIG.get(cacheKey, { type: 'json' }).catch(() => null);
  if (cached) {
    return jsonResponse(cached, { 'X-Curby-Cache': 'HIT' });
  }

  // 2. Compute fresh.
  const supabase = getSupabase(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY);
  let response: HeatMapResponse;
  try {
    response = await computeHeatMap({
      anchor,
      radiusM,
      mapboxToken: env.MAPBOX_ACCESS_TOKEN,
      supabase,
      cfg,
    });
  } catch (err) {
    // Aggressive diagnostic capture — the Workers runtime drops stack
    // on some thrown values, so collect every shred of context we can
    // get and put it in the response body. Pull this back once the bug
    // is squashed.
    const message = err instanceof Error
      ? err.message
      : typeof err === 'string'
        ? err
        : 'heat-map compute failed';
    const stack = err instanceof Error ? (err.stack ?? null) : null;
    const errorType = err instanceof Error
      ? (err.constructor?.name ?? 'Error')
      : typeof err;
    const ownProps: Record<string, unknown> = {};
    if (err && typeof err === 'object') {
      for (const k of Object.getOwnPropertyNames(err)) {
        try {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          ownProps[k] = (err as any)[k];
        } catch {
          // skip
        }
      }
    }
    console.error('heat-map compute error:', message, '\n', stack, '\n', ownProps);
    return new Response(
      JSON.stringify({
        error: message,
        errorType,
        stack,
        props: ownProps,
        rawString: String(err),
      }),
      {
        status: 502,
        headers: { 'Content-Type': 'application/json' },
      },
    );
  }

  // 3. Write through to KV with the configured TTL. Don't block on this.
  //    Using `ctx.waitUntil` would be ideal but we don't have it here;
  //    a deliberate non-awaited fire-and-forget is fine since the next
  //    cache read after this finishes will just trigger another compute.
  void env.CURBY_CONFIG.put(cacheKey, JSON.stringify(response), {
    expirationTtl: Math.max(60, cfg.cacheTtlSec),
  }).catch((e) => {
    console.error('heat-map cache write failed:', e);
  });

  return jsonResponse(response, { 'X-Curby-Cache': 'MISS' });
}

function buildCacheKey(anchor: { lat: number; lng: number }, radiusM: number): string {
  const latStep = ANCHOR_QUANTIZATION_M / 111_320;
  const lngStep = ANCHOR_QUANTIZATION_M / (111_320 * Math.cos((anchor.lat * Math.PI) / 180));
  const qLat = Math.round(anchor.lat / latStep) * latStep;
  const qLng = Math.round(anchor.lng / lngStep) * lngStep;
  const qRadius = Math.round(radiusM / RADIUS_QUANTIZATION_M) * RADIUS_QUANTIZATION_M;
  return `${KV_KEY_PREFIX}${qLat.toFixed(5)}_${qLng.toFixed(5)}_${qRadius}`;
}

function badRequest(message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status: 400,
    headers: { 'Content-Type': 'application/json' },
  });
}

function jsonResponse(body: unknown, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'public, max-age=30',
      ...extraHeaders,
    },
  });
}
