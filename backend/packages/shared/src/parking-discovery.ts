// ============================================================
// Parking discovery — Mapbox + OSM companion merge
// ============================================================

import type { CurbyRemoteConfig } from './config.js';
import type { LatLng, MapboxParkingArea } from './types.js';
import { distanceMeters } from './geo.js';
import { searchParkingAreas } from './mapbox.js';
import { searchOsmParkingAreas } from './osm.js';

/** Minimum separation between two candidate centers (dedupe Mapbox vs OSM overlap). */
const DEDUP_SEPARATION_M = 44;

/** Default cap so Overpass never blocks the full recommendation on slow public servers. */
const DEFAULT_OSM_FETCH_TIMEOUT_MS = 1500;

function mergeCandidates(
  mapbox: MapboxParkingArea[],
  osm: MapboxParkingArea[],
  destination: LatLng,
  radiusMeters: number,
  maxCandidates: number,
): MapboxParkingArea[] {
  const tagged: MapboxParkingArea[] = [
    ...mapbox.map((a) => ({ ...a, dataSource: (a.dataSource ?? 'mapbox') as 'mapbox' | 'osm' })),
    ...osm.map((a) => ({ ...a, dataSource: 'osm' as const })),
  ];

  tagged.sort((a, b) => {
    const da = distanceMeters(destination, a.center);
    const db = distanceMeters(destination, b.center);
    if (Math.abs(da - db) < 8) {
      if (a.dataSource === 'mapbox' && b.dataSource === 'osm') return -1;
      if (a.dataSource === 'osm' && b.dataSource === 'mapbox') return 1;
    }
    return da - db;
  });

  const chosen: MapboxParkingArea[] = [];

  for (const area of tagged) {
    const d = distanceMeters(destination, area.center);
    if (d > radiusMeters + 30) continue;

    const tooClose = chosen.some(
      (c) => distanceMeters(c.center, area.center) < DEDUP_SEPARATION_M,
    );
    if (tooClose) continue;

    chosen.push(area);
    if (chosen.length >= maxCandidates) break;
  }

  return chosen;
}

/**
 * Load parking candidates for the load balancer: Mapbox Search Box POIs plus,
 * when enabled, OSM Overpass parking features (street-side, lots, garages).
 * Same 7-factor scoring applies; OSM mainly improves street coverage.
 */
export async function discoverParkingAreas(
  destination: LatLng,
  radiusMeters: number,
  maxCandidates: number,
  mapboxAccessToken: string,
  search: CurbyRemoteConfig['search'],
): Promise<MapboxParkingArea[]> {
  const osmOn = search.osmCompanionSearch !== false;
  const osmBudgetMs = search.osmFetchTimeoutMs ?? DEFAULT_OSM_FETCH_TIMEOUT_MS;

  const mapboxPromise = searchParkingAreas(
    destination,
    radiusMeters,
    maxCandidates,
    mapboxAccessToken,
  );

  const osmPromise = osmOn
    ? (async () => {
        const ac = new AbortController();
        const t = setTimeout(() => ac.abort(), osmBudgetMs);
        try {
          return await searchOsmParkingAreas(
            destination,
            radiusMeters,
            search.overpassInterpreterUrl,
            ac.signal,
          );
        } finally {
          clearTimeout(t);
        }
      })()
    : Promise.resolve([] as MapboxParkingArea[]);

  const [mapboxAreas, osmAreas] = await Promise.all([mapboxPromise, osmPromise]);

  return mergeCandidates(mapboxAreas, osmAreas, destination, radiusMeters, Math.min(maxCandidates, 9));
}
