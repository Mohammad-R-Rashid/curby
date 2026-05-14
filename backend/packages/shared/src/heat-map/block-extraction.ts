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
  const stats: ExtractStats = {
    inputRoads: roads.length,
    usableLines: 0,
    polygonizeError: undefined,
    badLines: 0,
    rawPolygons: 0,
    notPolygonType: 0,
    droppedDegenerateRing: 0,
    droppedOutsideRadius: 0,
    keptBlocks: 0,
  };

  if (roads.length < 3) {
    logStats(stats, anchor, radiusM);
    lastStats = stats;
    return [];
  }

  // Clip the input to a bounding box just larger than the query radius.
  // Each fetched z=14 tile covers ~6 km² but the radius circle is often
  // < 2 km² — so 70-95% of decoded roads were beyond the area we care
  // about, dominating polygonize's planar graph and giving it more
  // opportunities to fail far from anything the user will ever see.
  const padFactor = 1.15;
  const bbox = bboxForRadius(anchor, radiusM * padFactor);

  const lines = roads
    .map((r) => dedupConsecutive(r.geometry.coordinates))
    .filter(
      (coords) =>
        coords.length >= 2 &&
        hasAnyPointInBbox(coords, bbox) &&
        // Drop tiny stubs (<10 m). They're typically tile-boundary
        // remnants that contribute nothing topologically but each is
        // another chance for polygonize to construct a degenerate face.
        linestringLengthMeters(coords) >= 10,
    )
    .map((coords) => lineString(coords));

  stats.usableLines = lines.length;

  if (lines.length < 2) {
    logStats(stats, anchor, radiusM);
    lastStats = stats;
    return [];
  }

  // polygonize is brittle on real-world urban road networks — a single
  // pathological linestring takes down the whole call with the
  // LinearRing throw. Bisect just to *identify* which lines are bad,
  // then polygonize the full set minus them in one call. That preserves
  // all the inter-line topology so blocks that span what would have
  // been a bisection boundary still form correctly.
  type PolygonFeat = ReturnType<typeof polygonize>['features'][number];
  const polygonFeatures: PolygonFeat[] = [];

  const indices = lines.map((_, i) => i);
  const badIdx = new Set<number>();

  // First pass: try the whole set. If it works, skip the bisection.
  if (!attemptPolygonize(lines, polygonFeatures, stats)) {
    findBadLineIndices(lines, indices, badIdx, stats);
    stats.badLines = badIdx.size;
    const cleanLines = lines.filter((_, i) => !badIdx.has(i));
    // One last attempt with the bad lines removed. If THIS still throws
    // we accept whatever's accumulated (empty in this branch).
    polygonFeatures.length = 0;
    attemptPolygonize(cleanLines, polygonFeatures, stats);
  }

  stats.rawPolygons = polygonFeatures.length;

  const radiusKm = radiusM / 1000;
  const anchorPt = { type: 'Point' as const, coordinates: [anchor.lng, anchor.lat] };

  const out: Block[] = [];
  let id = 0;

  for (const feat of polygonFeatures) {
    if (feat.geometry.type !== 'Polygon') {
      stats.notPolygonType++;
      continue;
    }

    const coords = feat.geometry.coordinates as [number, number][][];
    // Every ring (outer + any holes) must have at least 4 positions to
    // form a valid LinearRing. Earlier we only validated the outer ring,
    // which let polygons with degenerate hole rings reach turf and blow
    // up the whole request with a 502.
    if (coords.length === 0 || coords.some((ring) => !ring || ring.length < 4)) {
      stats.droppedDegenerateRing++;
      continue;
    }

    const cFeat = centroid(feat);
    const cLng = cFeat.geometry.coordinates[0];
    const cLat = cFeat.geometry.coordinates[1];

    const distKm = distance(anchorPt, cFeat.geometry, { units: 'kilometers' });
    if (distKm > radiusKm) {
      stats.droppedOutsideRadius++;
      continue;
    }

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

  stats.keptBlocks = out.length;
  logStats(stats, anchor, radiusM);
  lastStats = stats;
  return out;
}

/**
 * Try polygonize on a set of lines; on success, push features into
 * `out` and return true. On throw, leave `out` untouched and return
 * false (caller decides what to do next).
 */
function attemptPolygonize(
  lines: ReturnType<typeof lineString>[],
  out: Array<ReturnType<typeof polygonize>['features'][number]>,
  stats: ExtractStats,
): boolean {
  if (lines.length < 2) {
    return true;
  }
  try {
    const fc = polygonize(featureCollection(lines));
    for (const f of fc.features) {
      out.push(f);
    }
    return true;
  } catch (e) {
    if (!stats.polygonizeError) {
      stats.polygonizeError = e instanceof Error ? e.message : String(e);
    }
    return false;
  }
}

/**
 * Bisect to find every linestring index that, in isolation, causes
 * polygonize to throw. Used to filter just the pathological inputs and
 * then run a single clean polygonize over the full remainder — which
 * preserves all the inter-line topology that a "polygonize each
 * subset" approach would otherwise destroy at bisection boundaries.
 */
function findBadLineIndices(
  lines: ReturnType<typeof lineString>[],
  indices: number[],
  badIdx: Set<number>,
  stats: ExtractStats,
): void {
  if (lines.length === 0) return;
  // Probe-only: don't accumulate output; we'll do the real polygonize
  // once at the end on the full clean set.
  const sink: Array<ReturnType<typeof polygonize>['features'][number]> = [];
  if (attemptPolygonize(lines, sink, stats)) return;

  if (lines.length === 1) {
    badIdx.add(indices[0]);
    return;
  }
  const mid = Math.floor(lines.length / 2);
  findBadLineIndices(lines.slice(0, mid), indices.slice(0, mid), badIdx, stats);
  findBadLineIndices(lines.slice(mid), indices.slice(mid), badIdx, stats);
}

/** Pure diagnostic; emits a single line we can scan via `wrangler tail`. */
function logStats(stats: ExtractStats, anchor: LatLng, radiusM: number): void {
  console.log(
    `[heat-map extract] anchor=${anchor.lat.toFixed(4)},${anchor.lng.toFixed(4)} r=${radiusM} ` +
    `inputRoads=${stats.inputRoads} usableLines=${stats.usableLines} ` +
    `rawPolygons=${stats.rawPolygons} droppedDegenerateRing=${stats.droppedDegenerateRing} ` +
    `droppedOutsideRadius=${stats.droppedOutsideRadius} notPolygonType=${stats.notPolygonType} ` +
    `keptBlocks=${stats.keptBlocks}` +
    (stats.polygonizeError ? ` polygonizeError="${stats.polygonizeError}"` : '')
  );
}

export interface ExtractStats {
  inputRoads: number;
  usableLines: number;
  polygonizeError?: string;
  /** Number of lineStrings the bisect scan flagged as pathological. */
  badLines: number;
  rawPolygons: number;
  notPolygonType: number;
  droppedDegenerateRing: number;
  droppedOutsideRadius: number;
  keptBlocks: number;
}

/**
 * Module-level latch — last computed stats from extractBlocks. Set as a
 * side effect on each call so the orchestrator can attach the stats to
 * the response without reshaping every signature. Worker isolates are
 * shared across many requests, so reading this only makes sense
 * immediately after extractBlocks() returns within the same async path.
 */
let lastStats: ExtractStats | null = null;

/** Get the stats from the most recent extractBlocks invocation. */
export function consumeLastExtractStats(): ExtractStats | null {
  const s = lastStats;
  lastStats = null;
  return s;
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

interface Bbox {
  minLng: number;
  minLat: number;
  maxLng: number;
  maxLat: number;
}

function bboxForRadius(anchor: LatLng, radiusM: number): Bbox {
  const dLat = radiusM / 111_320;
  const dLng = radiusM / (111_320 * Math.cos((anchor.lat * Math.PI) / 180));
  return {
    minLat: anchor.lat - dLat,
    maxLat: anchor.lat + dLat,
    minLng: anchor.lng - dLng,
    maxLng: anchor.lng + dLng,
  };
}

function hasAnyPointInBbox(coords: [number, number][], bbox: Bbox): boolean {
  for (const [lng, lat] of coords) {
    if (lng >= bbox.minLng && lng <= bbox.maxLng && lat >= bbox.minLat && lat <= bbox.maxLat) {
      return true;
    }
  }
  return false;
}

/**
 * Sum of straight-line distances between consecutive points in
 * approximate meters. Equirectangular projection — good enough for
 * city-scale comparisons against a minimum-length filter.
 */
function linestringLengthMeters(coords: [number, number][]): number {
  if (coords.length < 2) return 0;
  let total = 0;
  for (let i = 1; i < coords.length; i++) {
    const a = coords[i - 1];
    const b = coords[i];
    const meanLatRad = ((a[1] + b[1]) / 2) * (Math.PI / 180);
    const dx = (b[0] - a[0]) * 111_320 * Math.cos(meanLatRad);
    const dy = (b[1] - a[1]) * 111_320;
    total += Math.sqrt(dx * dx + dy * dy);
  }
  return total;
}

/**
 * Remove duplicate consecutive points from a linestring. Mapbox vector
 * tiles sometimes emit them at z=14 due to tile-boundary quantization.
 */
function dedupConsecutive(coords: [number, number][]): [number, number][] {
  if (coords.length === 0) return [];
  const out: [number, number][] = [coords[0]];
  for (let i = 1; i < coords.length; i++) {
    const prev = out[out.length - 1];
    const cur = coords[i];
    if (prev[0] !== cur[0] || prev[1] !== cur[1]) {
      out.push(cur);
    }
  }
  return out;
}
