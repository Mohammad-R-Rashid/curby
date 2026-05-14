// ============================================================
// Block scoring
// ============================================================
// Each block gets a composite score in [0, 1] where 1 = easy to park.
//
// Inputs:
//   - bordering traffic congestion  (Mapbox traffic-v1)
//   - active_parks density          (Supabase, batch_occupancy RPC)
//   - recent departure rate         (Supabase, batch_departures RPC)
//
// Score direction matches the rest of the app: higher = better. The
// recommendation card and heat tiles read the same way.

import type { SupabaseClient } from '@supabase/supabase-js';

import type { CurbyRemoteConfig } from '../config.js';
import type { Block, TrafficSegment } from './types.js';
import { congestionLevelToNumber } from './vector-tile.js';

// ─── Block ⇆ traffic spatial join ───────────────────────────

/**
 * Distance from a traffic segment's midpoint to the *closest* block
 * centroid we'll accept it for. Blocks at z=14 are typically 80–200 m
 * wide; 120 m comfortably reaches across.
 */
const MAX_SEGMENT_ATTACH_DIST_M = 120;

/**
 * Assign each traffic segment to its nearest block centroid (within
 * `MAX_SEGMENT_ATTACH_DIST_M`) and average the resulting congestion
 * values per block. Cheap O(B × T) scan; B and T are both small for
 * neighborhood-scale queries.
 */
export function attachTrafficToBlocks(
  blocks: Block[],
  traffic: TrafficSegment[],
): void {
  if (blocks.length === 0 || traffic.length === 0) return;

  // Pre-compute block centroids in equirectangular meters for cheap
  // pairwise distance. The query area is small enough that distortion
  // is negligible.
  const blockXY = blocks.map((b) => latLngToLocalMeters(b.centroid.lat, b.centroid.lng, blocks[0].centroid));

  const sums = new Array<number>(blocks.length).fill(0);
  const counts = new Array<number>(blocks.length).fill(0);

  for (const seg of traffic) {
    const coords = seg.geometry.coordinates;
    if (coords.length < 2) continue;

    // Sample midpoint of the polyline as a coarse "this segment is here" proxy.
    const mid = coords[Math.floor(coords.length / 2)];
    const segXY = latLngToLocalMeters(mid[1], mid[0], blocks[0].centroid);

    let best = -1;
    let bestDistSq = MAX_SEGMENT_ATTACH_DIST_M * MAX_SEGMENT_ATTACH_DIST_M;
    for (let i = 0; i < blocks.length; i++) {
      const dx = blockXY[i].x - segXY.x;
      const dy = blockXY[i].y - segXY.y;
      const d2 = dx * dx + dy * dy;
      if (d2 < bestDistSq) {
        bestDistSq = d2;
        best = i;
      }
    }

    if (best >= 0) {
      sums[best] += congestionLevelToNumber(seg.congestion);
      counts[best] += 1;
    }
  }

  for (let i = 0; i < blocks.length; i++) {
    // No traffic segments matched this block → neutral medium. Same
    // motivation as the per-segment `unknown` case in
    // congestionLevelToNumber: we should NOT paint no-data blocks as
    // green, because that makes uncovered residential grids look
    // misleadingly easy.
    blocks[i].scoreInputs.congestion = counts[i] > 0 ? sums[i] / counts[i] : 0.4;
  }
}

// ─── Supabase signal queries ────────────────────────────────

/**
 * Returns true iff we got back any signal at all — used to flag
 * `fallback: true` in the response when the heat map degenerates to
 * a traffic-only view.
 */
export async function attachParkingSignalsToBlocks(
  blocks: Block[],
  supabase: SupabaseClient,
  cfg: CurbyRemoteConfig['heatMap'],
): Promise<boolean> {
  if (blocks.length === 0) return false;

  const points = blocks.map((b) => ({ lat: b.centroid.lat, lng: b.centroid.lng }));
  // Half the typical block width — picks up parks within the block
  // without reaching too far into neighbors.
  const radiusM = 75;

  const [occ, dep] = await Promise.all([
    fetchOccupancy(supabase, points, radiusM, blocks.length),
    fetchDepartures(supabase, points, radiusM, cfg.recentDepartureWindowMin, blocks.length),
  ]);

  let anyParkingSignal = false;
  for (let i = 0; i < blocks.length; i++) {
    const activeParks = occ[i] ?? 0;
    const recentDepartures = dep[i] ?? 0;
    const hectares = blocks[i].areaSqM / 10_000;
    blocks[i].scoreInputs.activeParks = activeParks;
    blocks[i].scoreInputs.recentDepartures = recentDepartures;
    blocks[i].scoreInputs.parksPerHectare = hectares > 0 ? activeParks / hectares : 0;
    if (activeParks > 0 || recentDepartures > 0) {
      anyParkingSignal = true;
    }
  }

  return anyParkingSignal;
}

async function fetchOccupancy(
  supabase: SupabaseClient,
  points: { lat: number; lng: number }[],
  radiusM: number,
  expectedLength: number,
): Promise<number[]> {
  try {
    const { data, error } = await supabase.rpc('batch_occupancy', {
      points,
      radius_m: radiusM,
    });
    if (error) {
      console.error('heat-map batch_occupancy error:', error);
      return new Array<number>(expectedLength).fill(0);
    }
    return parseIdxCount(data, 'parked_count');
  } catch (e) {
    console.error('heat-map batch_occupancy threw:', e);
    return new Array<number>(expectedLength).fill(0);
  }
}

async function fetchDepartures(
  supabase: SupabaseClient,
  points: { lat: number; lng: number }[],
  radiusM: number,
  windowMin: number,
  expectedLength: number,
): Promise<number[]> {
  try {
    const { data, error } = await supabase.rpc('batch_departures', {
      points,
      radius_m: radiusM,
      window_min: windowMin,
    });
    if (error) {
      console.error('heat-map batch_departures error:', error);
      return new Array<number>(expectedLength).fill(0);
    }
    return parseIdxCount(data, 'departure_count');
  } catch (e) {
    console.error('heat-map batch_departures threw:', e);
    return new Array<number>(expectedLength).fill(0);
  }
}

function parseIdxCount(
  rows: unknown,
  key: 'parked_count' | 'departure_count',
): number[] {
  if (!Array.isArray(rows)) return [];
  // The RPCs return { idx, parked_count | departure_count } rows; we
  // build a sparse array indexed by `idx`. Out-of-range indices are
  // tolerated so a misbehaving RPC can't OOB-crash the worker.
  const out: number[] = [];
  for (const row of rows as Array<Record<string, unknown>>) {
    const i = typeof row.idx === 'number' ? row.idx : Number(row.idx);
    if (!Number.isFinite(i) || i < 0) continue;
    out[i] = Number(row[key]) || 0;
  }
  return out;
}

// ─── Composite score ────────────────────────────────────────

/**
 * Compute each block's composite score in-place. Caller is expected to
 * have already populated `scoreInputs` via the two functions above.
 *
 * `fallback` toggles parking-data-aware vs traffic-only scoring. In
 * fallback mode the parking weights collapse to 0 so the response is
 * a clean traffic-only heat map.
 */
export function computeBlockScores(
  blocks: Block[],
  cfg: CurbyRemoteConfig['heatMap'],
  fallback: boolean,
): void {
  const w = normalizeWeights(cfg.weights, fallback);

  for (const b of blocks) {
    const fCongestion = clamp01(1 - b.scoreInputs.congestion);
    const fDensity = clamp01(1 - b.scoreInputs.parksPerHectare / cfg.parksPerHectareFull);
    const fTurnover = clamp01(
      (b.scoreInputs.recentDepartures / cfg.recentDepartureWindowMin)
        / cfg.departsPerMinFullTurnover,
    );

    b.score = clamp01(
      w.congestion * fCongestion + w.density * fDensity + w.turnover * fTurnover,
    );
  }
}

function normalizeWeights(
  w: CurbyRemoteConfig['heatMap']['weights'],
  fallback: boolean,
): CurbyRemoteConfig['heatMap']['weights'] {
  if (fallback) {
    return { congestion: 1, density: 0, turnover: 0 };
  }
  const total = w.congestion + w.density + w.turnover;
  if (total <= 0) return { congestion: 1, density: 0, turnover: 0 };
  return {
    congestion: w.congestion / total,
    density: w.density / total,
    turnover: w.turnover / total,
  };
}

function clamp01(x: number): number {
  return Math.max(0, Math.min(1, x));
}

// ─── Tiny local-meters projection ───────────────────────────

/**
 * Approximate WGS84 → local meters around a reference point. Good to
 * sub-meter accuracy over neighborhood-scale areas; *not* a real
 * projection. Used only for cheap nearest-neighbor distance comparisons.
 */
function latLngToLocalMeters(
  lat: number,
  lng: number,
  ref: { lat: number; lng: number },
): { x: number; y: number } {
  const cosRef = Math.cos((ref.lat * Math.PI) / 180);
  return {
    x: (lng - ref.lng) * 111_320 * cosRef,
    y: (lat - ref.lat) * 111_320,
  };
}
