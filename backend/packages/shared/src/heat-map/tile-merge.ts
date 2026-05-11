// ============================================================
// Tile merge + label
// ============================================================
// Take the clustered blocks and produce the final wire-shape tiles:
// one polygon per cluster (turf-union'd), tagged with the difficulty
// bucket and the suggested fill color.

import union from '@turf/union';
import { featureCollection, polygon as turfPolygon } from '@turf/helpers';

import type { CurbyRemoteConfig } from '../config.js';
import type { Block, HeatMapDifficulty, HeatMapGeometry, HeatMapTile } from './types.js';

const TINT_EASY = '#3FD171';   // matches CurbyGlass.successTint
const TINT_MEDIUM = '#FF9F4D'; // matches CurbyGlass.warningTint
const TINT_HARD = '#F55747';   // matches CurbyGlass.destinationTint

/**
 * Group blocks by their assigned cluster, union each cluster's
 * polygons into one geometry, attach the per-tile stats, and return
 * tiles sorted by score (Easy first).
 */
export function buildTiles(
  blocks: Block[],
  cfg: CurbyRemoteConfig['heatMap'],
): HeatMapTile[] {
  if (blocks.length === 0) return [];

  // Group block ids by cluster id.
  const byCluster = new Map<number, Block[]>();
  for (const b of blocks) {
    const existing = byCluster.get(b.clusterId);
    if (existing) existing.push(b);
    else byCluster.set(b.clusterId, [b]);
  }

  const tiles: HeatMapTile[] = [];

  let tileIndex = 0;
  for (const [clusterId, clusterBlocks] of byCluster) {
    const geometry = unionBlocks(clusterBlocks);
    if (!geometry) continue;

    const totalArea = clusterBlocks.reduce((s, b) => s + b.areaSqM, 0);
    const weightedCongestion =
      totalArea > 0
        ? clusterBlocks.reduce((s, b) => s + b.scoreInputs.congestion * b.areaSqM, 0) / totalArea
        : 0;
    const activeParks = clusterBlocks.reduce((s, b) => s + b.scoreInputs.activeParks, 0);
    const recentDepartures = clusterBlocks.reduce((s, b) => s + b.scoreInputs.recentDepartures, 0);
    const weightedScore =
      totalArea > 0
        ? clusterBlocks.reduce((s, b) => s + b.score * b.areaSqM, 0) / totalArea
        : 0;

    const label = labelFor(weightedScore, cfg.bands);

    tiles.push({
      id: `tile-${tileIndex++}-c${clusterId}`,
      geometry,
      score: weightedScore,
      label,
      tint: tintFor(label),
      stats: {
        blockCount: clusterBlocks.length,
        avgCongestion: weightedCongestion,
        activeParks,
        recentDepartures,
        areaSqM: totalArea,
      },
    });
  }

  // Easiest tiles first — the iOS UI typically wants to highlight the
  // best zones first, with the harder ones beneath them.
  tiles.sort((a, b) => b.score - a.score);

  return tiles;
}

function unionBlocks(blocks: Block[]): HeatMapGeometry | null {
  if (blocks.length === 0) return null;
  if (blocks.length === 1) return blocks[0].polygon;

  const polys = blocks.map((b) => turfPolygon(b.polygon.coordinates));
  // turf v7: union takes a FeatureCollection<Polygon|MultiPolygon> and
  // returns a single Feature. Falls back to the first polygon if the
  // union resolves to null (shouldn't happen for contiguous inputs).
  let merged: ReturnType<typeof union> | null = null;
  try {
    merged = union(featureCollection(polys));
  } catch (e) {
    console.error('heat-map tile union failed:', e);
    return blocks[0].polygon;
  }

  if (!merged || !merged.geometry) return blocks[0].polygon;

  const g = merged.geometry;
  if (g.type === 'Polygon') {
    return { type: 'Polygon', coordinates: g.coordinates as [number, number][][] };
  }
  if (g.type === 'MultiPolygon') {
    return {
      type: 'MultiPolygon',
      coordinates: g.coordinates as [number, number][][][],
    };
  }
  return blocks[0].polygon;
}

function labelFor(
  score: number,
  bands: CurbyRemoteConfig['heatMap']['bands'],
): HeatMapDifficulty {
  if (score >= bands.easyMin) return 'easy';
  if (score < bands.hardMax) return 'hard';
  return 'medium';
}

function tintFor(label: HeatMapDifficulty): string {
  switch (label) {
    case 'easy':
      return TINT_EASY;
    case 'medium':
      return TINT_MEDIUM;
    case 'hard':
      return TINT_HARD;
  }
}
