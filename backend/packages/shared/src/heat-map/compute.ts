// ============================================================
// Heat-map orchestrator
// ============================================================
// Pulls all the heat-map pieces together so the route handler only
// has to call one function. Steps documented inline.

import type { SupabaseClient } from '@supabase/supabase-js';

import type { CurbyRemoteConfig } from '../config.js';
import type { LatLng } from '../types.js';
import type { HeatMapResponse } from './types.js';
import { fetchRoadAndTrafficSegments } from './vector-tile.js';
import {
  buildAdjacency,
  consumeLastExtractStats,
  extractBlocks,
} from './block-extraction.js';
import {
  attachParkingSignalsToBlocks,
  attachTrafficToBlocks,
  computeBlockScores,
} from './block-scoring.js';
import { clusterBlocks } from './clustering.js';
import { buildTiles } from './tile-merge.js';

export interface HeatMapInputs {
  anchor: LatLng;
  radiusM: number;
  mapboxToken: string;
  supabase: SupabaseClient;
  cfg: CurbyRemoteConfig['heatMap'];
}

export async function computeHeatMap(inputs: HeatMapInputs): Promise<HeatMapResponse> {
  const { anchor, radiusM, mapboxToken, supabase, cfg } = inputs;

  // 1. Fetch road + traffic tiles in parallel.
  const { roads, traffic } = await fetchRoadAndTrafficSegments(anchor, radiusM, mapboxToken);

  // 2. Polygonize the road graph → block polygons (within radius).
  const blocks = extractBlocks(roads, anchor, radiusM);
  const extractStats = consumeLastExtractStats();

  if (blocks.length === 0) {
    return emptyResponse(anchor, radiusM, cfg.clusterCount, {
      trafficSegments: traffic.length,
      extract: extractStats,
    });
  }

  // 3. Attach traffic signal to each block (perimeter-segment average).
  attachTrafficToBlocks(blocks, traffic);

  // 4. Attach parking signals from Supabase. If everything comes back
  //    zero we degrade to a traffic-only heat map and flag fallback.
  const haveParkingSignal = await attachParkingSignalsToBlocks(blocks, supabase, cfg);
  const fallback = !haveParkingSignal;

  // 5. Composite score per block.
  computeBlockScores(blocks, cfg, fallback);

  // 6. Cluster (adjacency-constrained agglomerative) into ~K groups.
  const adjacency = buildAdjacency(blocks);
  clusterBlocks(blocks, adjacency, cfg.clusterCount);

  // 7. Union each cluster's blocks → final tile geometries + labels.
  const tiles = buildTiles(blocks, cfg);

  return {
    tiles,
    anchor,
    radiusM,
    clusterCount: tiles.length,
    computedAt: new Date().toISOString(),
    fallback,
    // Surfaced on every response while we're tuning block extraction.
    _debug: {
      trafficSegments: traffic.length,
      extract: extractStats,
    },
  };
}

function emptyResponse(
  anchor: LatLng,
  radiusM: number,
  clusterCount: number,
  debug?: HeatMapResponse['_debug'],
): HeatMapResponse {
  return {
    tiles: [],
    anchor,
    radiusM,
    clusterCount,
    computedAt: new Date().toISOString(),
    fallback: true,
    _debug: debug,
  };
}
