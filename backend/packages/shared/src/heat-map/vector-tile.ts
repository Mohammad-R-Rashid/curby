// ============================================================
// Mapbox Vector Tile fetch + decode
// ============================================================
// We need the road graph (Mapbox Streets v8 / `road` layer) and live
// congestion (Mapbox traffic-v1 / `traffic` layer) for the query area.
//
// Both come as MVT (protobuf) tiles. We decode them inline and convert
// to plain GeoJSON LineStrings, then hand off to polygonize/scoring.

import { VectorTile } from '@mapbox/vector-tile';
import Protobuf from 'pbf';

import type { LatLng } from '../types.js';
import type { GeoJSONLineString, RoadSegment, TrafficSegment } from './types.js';

// ─── Constants ──────────────────────────────────────────────

/**
 * Tile zoom for both fetches. z=14 is the highest zoom where Mapbox
 * Streets v8's `road` layer carries the full local-street network and
 * is the zoom at which Mapbox traffic-v1 is densest. At z=14 each tile
 * is ~2.4 km wide at lat ~30, so a 640 m query radius almost always
 * fits inside 1–4 tiles.
 */
const TILE_ZOOM = 14;

const STREETS_TILESET = 'mapbox.mapbox-streets-v8';
const TRAFFIC_TILESET = 'mapbox.mapbox-traffic-v1';

/**
 * OSM road classes that *can* form block boundaries. We deliberately
 * exclude:
 *
 *   - service / footway / parking aisles → produce "blocks" inside
 *     parking lots that wreck clustering.
 *   - motorway / trunk and *all* `_link` ramp classes → these are
 *     grade-separated highways whose tile geometry is full of self-
 *     touching curves (overpasses, cloverleaf ramps) that crash
 *     turf.polygonize internally with "LinearRing must have 4 or
 *     more Positions" before any of our output guards can fire.
 *
 * What's left is the normal street network — primary arterials and
 * below — which is precisely the surface where parking actually
 * happens anyway.
 */
const BLOCK_FORMING_ROAD_CLASSES = new Set([
  'primary',
  'secondary',
  'tertiary',
  'street',
  'street_limited',
  'residential',
  'living_street',
  'pedestrian',
]);

// ─── Public API ─────────────────────────────────────────────

export interface TileCoord {
  x: number;
  y: number;
  z: number;
}

/**
 * Fetch both road and traffic tiles for the query bbox, decode them,
 * and return clean GeoJSON segments ready for downstream work.
 *
 * Network: 1–4 road tile fetches + 1–4 traffic tile fetches, all in
 * parallel. Mapbox CDNs cache aggressively so repeat queries from the
 * same neighborhood are effectively free.
 */
export async function fetchRoadAndTrafficSegments(
  anchor: LatLng,
  radiusM: number,
  accessToken: string,
): Promise<{ roads: RoadSegment[]; traffic: TrafficSegment[] }> {
  const tiles = tilesCoveringRadius(anchor, radiusM, TILE_ZOOM);

  const [roadTiles, trafficTiles] = await Promise.all([
    Promise.all(tiles.map((t) => fetchTile(STREETS_TILESET, t, accessToken))),
    Promise.all(tiles.map((t) => fetchTile(TRAFFIC_TILESET, t, accessToken))),
  ]);

  const roads: RoadSegment[] = [];
  const traffic: TrafficSegment[] = [];

  for (let i = 0; i < tiles.length; i++) {
    const tile = tiles[i];
    const roadBuf = roadTiles[i];
    if (roadBuf) {
      roads.push(...decodeRoads(roadBuf, tile));
    }
    const trafficBuf = trafficTiles[i];
    if (trafficBuf) {
      traffic.push(...decodeTraffic(trafficBuf, tile));
    }
  }

  // Mapbox vector tiles include a buffer zone around each tile (~64px)
  // where features from neighboring tiles bleed in. That's intentional
  // for seamless map rendering but means a road near a tile boundary
  // appears in 2–4 tiles' worth of decoded output. The duplicates blow
  // up polygonize's planar graph (1600+ "roads" for a 1km radius is way
  // too many), so dedupe by canonical endpoint pair before returning.
  return {
    roads: dedupeLinestringsByEndpoints(roads, (r) => r.geometry.coordinates),
    traffic: dedupeLinestringsByEndpoints(traffic, (t) => t.geometry.coordinates),
  };
}

/**
 * Group lineStrings by the canonical pair of their first / last
 * positions (rounded to 6 decimals — ~0.1m). Two lineStrings with the
 * same endpoint pair are almost certainly the same road segment from
 * overlapping tile buffers.
 */
function dedupeLinestringsByEndpoints<T>(
  items: T[],
  coordsOf: (item: T) => [number, number][],
): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  for (const item of items) {
    const coords = coordsOf(item);
    if (coords.length < 2) continue;
    const a = coords[0];
    const b = coords[coords.length - 1];
    const round = (n: number) => Math.round(n * 1e6) / 1e6;
    const aKey = `${round(a[0])},${round(a[1])}`;
    const bKey = `${round(b[0])},${round(b[1])}`;
    // Key by canonical endpoint pair only — *not* by point count. Two
    // lineStrings going A→B with slightly different curves between
    // them form a "lens" face that polygonize can't close, so we keep
    // only one representative per edge. For block-extraction purposes
    // the exact curve doesn't matter; only the endpoint topology does.
    const key = aKey < bKey ? `${aKey}|${bKey}` : `${bKey}|${aKey}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(item);
  }
  return out;
}

// ─── Tile coverage math ─────────────────────────────────────

/**
 * Enumerate the (x, y, z) tile coords needed to cover a circle of
 * `radiusM` meters around `anchor`. Tiny — typically 1 tile, at most
 * 4 if the query straddles tile boundaries at z=14.
 */
export function tilesCoveringRadius(
  anchor: LatLng,
  radiusM: number,
  z: number,
): TileCoord[] {
  const dLat = radiusM / 111_320; // meters per degree latitude, near-constant
  const dLng = radiusM / (111_320 * Math.cos((anchor.lat * Math.PI) / 180));

  const minLat = anchor.lat - dLat;
  const maxLat = anchor.lat + dLat;
  const minLng = anchor.lng - dLng;
  const maxLng = anchor.lng + dLng;

  const [xMin, yMax] = lngLatToTile(minLng, minLat, z);
  const [xMax, yMin] = lngLatToTile(maxLng, maxLat, z);

  const out: TileCoord[] = [];
  for (let x = xMin; x <= xMax; x++) {
    for (let y = yMin; y <= yMax; y++) {
      out.push({ x, y, z });
    }
  }
  return out;
}

function lngLatToTile(lng: number, lat: number, z: number): [number, number] {
  const n = Math.pow(2, z);
  const x = Math.floor(((lng + 180) / 360) * n);
  const latRad = (lat * Math.PI) / 180;
  const y = Math.floor(
    ((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * n,
  );
  return [clampTile(x, z), clampTile(y, z)];
}

function clampTile(v: number, z: number): number {
  const n = Math.pow(2, z);
  return Math.max(0, Math.min(n - 1, v));
}

// ─── Tile fetch ─────────────────────────────────────────────

async function fetchTile(
  tilesetId: string,
  tile: TileCoord,
  accessToken: string,
): Promise<Uint8Array | null> {
  const url = `https://api.mapbox.com/v4/${tilesetId}/${tile.z}/${tile.x}/${tile.y}.mvt?access_token=${encodeURIComponent(accessToken)}`;

  const res = await fetch(url);
  if (res.status === 404) {
    // Tile has no data in this region (very common for traffic).
    return null;
  }
  if (!res.ok) {
    throw new Error(
      `Vector tile fetch failed: ${tilesetId} ${tile.z}/${tile.x}/${tile.y} → ${res.status}`,
    );
  }
  const buf = await res.arrayBuffer();
  return new Uint8Array(buf);
}

// ─── Decode: roads ──────────────────────────────────────────

function decodeRoads(buf: Uint8Array, tile: TileCoord): RoadSegment[] {
  const vt = new VectorTile(new Protobuf(buf));
  const layer = vt.layers['road'];
  if (!layer) return [];

  const out: RoadSegment[] = [];
  for (let i = 0; i < layer.length; i++) {
    const feature = layer.feature(i);
    const props = feature.properties as Record<string, unknown>;
    const klass = typeof props.class === 'string' ? props.class : undefined;
    if (!klass || !BLOCK_FORMING_ROAD_CLASSES.has(klass)) continue;

    const geo = feature.toGeoJSON(tile.x, tile.y, tile.z) as unknown as {
      type: string;
      geometry: {
        type: 'LineString' | 'MultiLineString';
        coordinates: [number, number][] | [number, number][][];
      };
    };

    if (geo.geometry.type === 'LineString') {
      out.push({
        geometry: {
          type: 'LineString',
          coordinates: snapCoords(geo.geometry.coordinates as [number, number][]),
        },
        klass,
      });
    } else if (geo.geometry.type === 'MultiLineString') {
      for (const line of geo.geometry.coordinates as [number, number][][]) {
        out.push({
          geometry: { type: 'LineString', coordinates: snapCoords(line) },
          klass,
        });
      }
    }
  }
  return out;
}

// ─── Decode: traffic ────────────────────────────────────────

function decodeTraffic(buf: Uint8Array, tile: TileCoord): TrafficSegment[] {
  const vt = new VectorTile(new Protobuf(buf));
  const layer = vt.layers['traffic'];
  if (!layer) return [];

  const out: TrafficSegment[] = [];
  for (let i = 0; i < layer.length; i++) {
    const feature = layer.feature(i);
    const props = feature.properties as Record<string, unknown>;
    const congestion = isCongestion(props.congestion) ? props.congestion : 'unknown';

    const geo = feature.toGeoJSON(tile.x, tile.y, tile.z) as unknown as {
      type: string;
      geometry: {
        type: 'LineString' | 'MultiLineString';
        coordinates: [number, number][] | [number, number][][];
      };
    };

    if (geo.geometry.type === 'LineString') {
      out.push({
        geometry: {
          type: 'LineString',
          coordinates: snapCoords(geo.geometry.coordinates as [number, number][]),
        },
        congestion,
      });
    } else if (geo.geometry.type === 'MultiLineString') {
      for (const line of geo.geometry.coordinates as [number, number][][]) {
        out.push({
          geometry: { type: 'LineString', coordinates: snapCoords(line) },
          congestion,
        });
      }
    }
  }
  return out;
}

function isCongestion(v: unknown): v is TrafficSegment['congestion'] {
  return v === 'low' || v === 'moderate' || v === 'heavy' || v === 'severe' || v === 'unknown';
}

/**
 * Snap lng/lat values to a 6-decimal grid (~11 cm precision). Mapbox
 * vector-tile decoding produces sub-bit floating-point jitter at tile
 * boundaries that defeats turf.polygonize's planar-graph vertex sharing
 * — two physically identical points decode to values differing by
 * 1e-15, so polygonize sees them as distinct vertices and emits
 * degenerate near-zero faces (the source of the "LinearRing must have
 * 4 or more Positions" throw). Snapping forces those almost-identical
 * points to coalesce so the graph is actually planar.
 */
function snapCoords(coords: [number, number][]): [number, number][] {
  const out: [number, number][] = new Array(coords.length);
  for (let i = 0; i < coords.length; i++) {
    const c = coords[i];
    out[i] = [Math.round(c[0] * 1e6) / 1e6, Math.round(c[1] * 1e6) / 1e6];
  }
  return out;
}

// Helper exposed for tests / scoring.
export function congestionLevelToNumber(level: TrafficSegment['congestion']): number {
  switch (level) {
    case 'low':
      return 0.0;
    case 'moderate':
      return 0.4;
    case 'heavy':
      return 0.7;
    case 'severe':
      return 1.0;
    case 'unknown':
    default:
      // No data → treat the same as free-flow. Mapbox traffic-v1 only
      // covers major streets; calling unknown "free-flow" keeps the
      // uncovered residential grid out of the orange/red bucket.
      return 0.0;
  }
}

export function _internal_unused(): GeoJSONLineString {
  // Type assertion helper so unused-import warnings don't fire across modules.
  return { type: 'LineString', coordinates: [] };
}
