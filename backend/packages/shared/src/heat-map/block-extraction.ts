// ============================================================
// Block extraction
// ============================================================
// Turn road linestrings into block polygons (the planar faces of the
// road graph), filter to the query area, and compute the adjacency
// graph that clustering will operate on.

import polygonize from '@turf/polygonize';
import area from '@turf/area';
import centroid from '@turf/centroid';
import distance from '@turf/distance';
import { featureCollection, lineString } from '@turf/helpers';

import type { Block, GeoJSONPolygon, RoadSegment } from './types.js';
import type { LatLng } from '../types.js';

/**
 * Extract blocks (planar faces) inside the query radius.
 *
 * Each returned `Block` has its polygon, centroid, area, and a stable
 * `id` index used as the node id in the adjacency graph. Score and
 * cluster id are zero-initialized and filled in by later passes.
 */
export function extractBlocks(
  roads: RoadSegment[],
  anchor: LatLng,
  radiusM: number,
): Block[] {
  if (roads.length < 3) return [];

  const lines = roads
    .filter((r) => r.geometry.coordinates.length >= 2)
    .map((r) => lineString(r.geometry.coordinates));

  const fc = featureCollection(lines);
  const polygons = polygonize(fc);

  const radiusKm = radiusM / 1000;
  const anchorPt = { type: 'Point' as const, coordinates: [anchor.lng, anchor.lat] };

  const out: Block[] = [];
  let id = 0;

  for (const feat of polygons.features) {
    if (feat.geometry.type !== 'Polygon') continue;

    const coords = feat.geometry.coordinates as [number, number][][];
    if (!coords[0] || coords[0].length < 4) continue;

    const cFeat = centroid(feat);
    const cLng = cFeat.geometry.coordinates[0];
    const cLat = cFeat.geometry.coordinates[1];

    const distKm = distance(anchorPt, cFeat.geometry, { units: 'kilometers' });
    if (distKm > radiusKm) continue;

    const polygon: GeoJSONPolygon = {
      type: 'Polygon',
      coordinates: coords,
    };

    out.push({
      id: id++,
      polygon,
      centroid: { lat: cLat, lng: cLng },
      areaSqM: area(feat),
      score: 0,
      scoreInputs: {
        congestion: 0,
        activeParks: 0,
        recentDepartures: 0,
        parksPerHectare: 0,
      },
      clusterId: -1,
    });
  }

  return out;
}

// ─── Adjacency graph ────────────────────────────────────────

/**
 * For each block id, the set of block ids that share at least one
 * edge with it. Symmetric. Used by clustering to enforce spatial
 * contiguity (two non-adjacent clusters are never merged).
 */
export type AdjacencyMap = Map<number, Set<number>>;

export function buildAdjacency(blocks: Block[]): AdjacencyMap {
  // Map of canonical edge string → first block that has it. When a second
  // block lays claim, we record the adjacency in both directions.
  const edgeOwner = new Map<string, number>();
  const adj: AdjacencyMap = new Map();
  for (const b of blocks) adj.set(b.id, new Set());

  for (const b of blocks) {
    for (const ring of b.polygon.coordinates) {
      for (let i = 0; i < ring.length - 1; i++) {
        const key = canonicalEdge(ring[i], ring[i + 1]);
        const owner = edgeOwner.get(key);
        if (owner === undefined) {
          edgeOwner.set(key, b.id);
        } else if (owner !== b.id) {
          adj.get(b.id)!.add(owner);
          adj.get(owner)!.add(b.id);
        }
      }
    }
  }

  return adj;
}

/**
 * Canonicalize a road edge so the two directions of the same edge
 * produce the same key. Round to 6 decimals (~0.1 m) so floating-point
 * jitter from tile decoding doesn't fragment the graph.
 */
function canonicalEdge(a: [number, number], b: [number, number]): string {
  const round = (n: number) => Math.round(n * 1e6) / 1e6;
  const aKey = `${round(a[0])},${round(a[1])}`;
  const bKey = `${round(b[0])},${round(b[1])}`;
  return aKey < bKey ? `${aKey}|${bKey}` : `${bKey}|${aKey}`;
}
