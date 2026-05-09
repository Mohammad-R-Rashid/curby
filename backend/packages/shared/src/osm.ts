// ============================================================
// OpenStreetMap — Overpass API (companion parking discovery)
// ============================================================
// Fetches parking-related ways/nodes/relations near a destination.
// Results are normalized into MapboxParkingArea-shaped candidates so the
// existing Matrix + scoring pipeline can treat them like Mapbox POIs.
//
// Public Overpass endpoints are rate-limited; for production load, run your
// own Overpass instance and point `overpassInterpreterUrl` in remote config.

import type { LatLng, MapboxParkingArea } from './types.js';
import { distanceMeters } from './geo.js';

/** Primary + mirrors — public Overpass is best-effort (504/timeouts are common). */
const DEFAULT_OVERPASS_MIRRORS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
] as const;

type OverpassElement = {
  type: 'node' | 'way' | 'relation';
  id: number;
  lat?: number;
  lon?: number;
  center?: { lat?: number; lon?: number };
  tags?: Record<string, string>;
};

function elementCenter(el: OverpassElement): LatLng | null {
  if (typeof el.lat === 'number' && typeof el.lon === 'number') {
    return { lat: el.lat, lng: el.lon };
  }
  const c = el.center;
  if (c && typeof c.lat === 'number' && typeof c.lon === 'number') {
    return { lat: c.lat, lng: c.lon };
  }
  return null;
}

/**
 * Map OSM tags to Curby categories (aligned with Mapbox naming heuristics).
 */
export function classifyOsmParkingCategory(tags: Record<string, string>): string {
  const parking = (tags.parking || '').toLowerCase();
  const amenity = (tags.amenity || '').toLowerCase();

  if (tags['parking:lane:left'] || tags['parking:lane:right'] || tags['parking:lane:both']) {
    return 'parking_meter';
  }
  if (parking === 'lane' || parking === 'street_side' || parking === 'on_street' || parking === 'onstreet') {
    return 'parking_meter';
  }
  if (tags.building || parking === 'multi-storey' || parking === 'underground') {
    return 'parking_garage';
  }
  if (parking === 'surface' || parking === 'lot' || parking === 'carports') {
    return 'parking_lot';
  }
  if (amenity === 'parking_space') {
    return 'parking_meter';
  }
  return 'parking';
}

function humanName(tags: Record<string, string>, osmId: string): string {
  const n = (tags.name || '').trim();
  if (n) return n;
  const ref = (tags.ref || '').trim();
  if (ref) return `Parking ${ref}`;
  const street =
    (tags['addr:street'] || tags['addr:full'] || '').trim();
  if (street) return `Parking · ${street}`;
  return `OSM parking · ${osmId}`;
}

function buildOverpassQuery(lat: number, lng: number, radiusM: number): string {
  // Keep radius and clause count modest — large `parking:lane` pulls often time out on public instances.
  const r = Math.max(350, Math.min(Math.round(radiusM), 900));
  return `
[out:json][timeout:12];
(
  nwr["amenity"="parking"](around:${r},${lat},${lng});
  nwr["amenity"="parking_space"](around:${r},${lat},${lng});
);
out center tags;
`.trim();
}

async function postOverpass(
  interpreterUrl: string,
  query: string,
  signal?: AbortSignal,
): Promise<Response> {
  return fetch(interpreterUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
      'User-Agent': 'CurbyBackend/1.0 (parking-discovery)',
    },
    body: `data=${encodeURIComponent(query)}`,
    signal,
  });
}

/**
 * Query Overpass for parking features and return Curby-shaped candidates.
 * Never throws — returns [] on network/parse errors (caller logs).
 *
 * Uses **one** interpreter URL per call (custom from config, else primary public).
 * Chaining mirrors was doubling worst-case latency for `find_parking`.
 */
export async function searchOsmParkingAreas(
  destination: LatLng,
  radiusMeters: number,
  interpreterUrl?: string,
  signal?: AbortSignal,
): Promise<MapboxParkingArea[]> {


  const query = buildOverpassQuery(destination.lat, destination.lng, radiusMeters);
  const preferred = interpreterUrl?.trim();
  const url = preferred && preferred.length > 0 ? preferred : DEFAULT_OVERPASS_MIRRORS[0];

  try {
    const attempt = await postOverpass(url, query, signal);
    if (!attempt.ok) {
      const snippet = (await attempt.text()).slice(0, 160);
      console.warn(`Overpass ${url} -> HTTP ${attempt.status} ${snippet}`);
      return [];
    }
    const res = attempt;

    const data = (await res.json()) as { elements?: OverpassElement[] };
    const elements = data.elements ?? [];

    const out: MapboxParkingArea[] = [];
    const seen = new Set<string>();

    for (const el of elements) {
      const center = elementCenter(el);
      if (!center) continue;

      const d = distanceMeters(destination, center);
      if (d > radiusMeters + 35) continue;

      const tags = el.tags ?? {};

      // Only surface OSM areas that have a real human-readable name. The
      // fallback "OSM parking · osm/way/123" was leaking into recommendation
      // cards and the user-facing list. Mapbox already covers named lots
      // for the same area; named-only OSM acts as a useful supplement
      // without polluting the UI.
      const trimmedName = (tags.name || '').trim();
      const trimmedRef = (tags.ref || '').trim();
      const trimmedStreet = (tags['addr:street'] || tags['addr:full'] || '').trim();
      if (!trimmedName && !trimmedRef && !trimmedStreet) continue;

      const id = `osm/${el.type}/${el.id}`;
      if (seen.has(id)) continue;
      seen.add(id);

      out.push({
        id,
        name: humanName(tags, id),
        center,
        category: classifyOsmParkingCategory(tags),
        dataSource: 'osm',
      });

      if (out.length >= 48) break;
    }

    return out.sort((a, b) => distanceMeters(destination, a.center) - distanceMeters(destination, b.center));
  } catch (e) {
    if (e instanceof Error && e.name === 'AbortError') {
      return [];
    }
    console.warn('Overpass fetch failed:', e);
    return [];
  }
}
