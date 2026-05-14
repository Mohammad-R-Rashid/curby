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
  let blocks = extractBlocks(roads, anchor, radiusM);
  const extractStats = consumeLastExtractStats();

  // If road-graph polygonization failed entirely (turf.polygonize is
  // brittle on certain real-world tile topologies), fall back to a
  // simple grid tiling of the query bbox. Tiles won't follow street
  // geometry, but at least the user sees a heat map covering the area
  // they're looking at.
  let usedGridFallback = false;
  if (blocks.length === 0) {
    blocks = gridFallbackBlocks(anchor, radiusM);
    usedGridFallback = true;
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
      usedGridFallback,
    },
  };
}

/**
 * 4×4 grid of square cells covering the query bbox. Used as a last-
 * resort fallback when polygonize returns no blocks for an anchor.
 * Cells are constructed in WGS84 directly — good enough for the heat
 * map visual (cells span ~200 m at 805 m radius, comparable to a real
 * city block) without needing turf.
 */
function gridFallbackBlocks(anchor: LatLng, radiusM: number) {
  const dLat = radiusM / 111_320;
  const dLng = radiusM / (111_320 * Math.cos((anchor.lat * Math.PI) / 180));
  const minLat = anchor.lat - dLat;
  const maxLat = anchor.lat + dLat;
  const minLng = anchor.lng - dLng;
  const maxLng = anchor.lng + dLng;

  const cellsPerSide = 4;
  const latStep = (maxLat - minLat) / cellsPerSide;
  const lngStep = (maxLng - minLng) / cellsPerSide;

  const blocks: Array<{
    id: number;
    polygon: { type: 'Polygon'; coordinates: [number, number][][] };
    centroid: LatLng;
    areaSqM: number;
    score: number;
    scoreInputs: {
      congestion: number;
      activeParks: number;
      recentDepartures: number;
      parksPerHectare: number;
    };
    clusterId: number;
  }> = [];

  let id = 0;
  for (let i = 0; i < cellsPerSide; i++) {
    for (let j = 0; j < cellsPerSide; j++) {
      const cellMinLng = minLng + j * lngStep;
      const cellMaxLng = minLng + (j + 1) * lngStep;
      const cellMinLat = minLat + i * latStep;
      const cellMaxLat = minLat + (i + 1) * latStep;
      const cLng = cellMinLng + lngStep / 2;
      const cLat = cellMinLat + latStep / 2;
      blocks.push({
        id: id++,
        polygon: {
          type: 'Polygon',
          coordinates: [[
            [cellMinLng, cellMinLat],
            [cellMaxLng, cellMinLat],
            [cellMaxLng, cellMaxLat],
            [cellMinLng, cellMaxLat],
            [cellMinLng, cellMinLat],
          ]],
        },
        centroid: { lat: cLat, lng: cLng },
        areaSqM: lngStep * Math.cos((cLat * Math.PI) / 180) * 111_320 * latStep * 111_320,
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
  }
  return blocks;
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
