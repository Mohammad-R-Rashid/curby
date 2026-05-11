// ============================================================
// Adjacency-constrained agglomerative clustering
// ============================================================
// Group blocks into ~K clusters so each cluster is a contiguous
// chunk of the road network (no two disconnected pieces sharing a
// cluster id). We greedily merge the *adjacent* cluster pair with the
// smallest score difference until we hit K clusters — i.e., the
// classic single-linkage agglomerative algorithm with a spatial
// adjacency constraint.

import type { Block } from './types.js';
import type { AdjacencyMap } from './block-extraction.js';

interface Cluster {
  id: number;
  /** Area-weighted mean score across member blocks. */
  score: number;
  /** Sum of member block areas. */
  totalAreaSqM: number;
  blockIds: number[];
}

/**
 * Mutates blocks' `clusterId` in-place and returns the cluster list.
 *
 * If the road graph has more than `targetClusters` connected components
 * the result will have at least that many — agglomeration can never
 * bridge a graph gap without violating contiguity.
 */
export function clusterBlocks(
  blocks: Block[],
  adjacency: AdjacencyMap,
  targetClusters: number,
): Cluster[] {
  if (blocks.length === 0) return [];

  // 1. Seed: one cluster per block.
  const clusters = new Map<number, Cluster>();
  for (const b of blocks) {
    clusters.set(b.id, {
      id: b.id,
      score: b.score,
      totalAreaSqM: b.areaSqM,
      blockIds: [b.id],
    });
  }

  // 2. Cluster adjacency = block adjacency. We maintain it as
  //    `clusterAdj: Map<clusterId, Set<clusterId>>` and keep it in sync
  //    on every merge.
  const clusterAdj = new Map<number, Set<number>>();
  for (const [id, neighbors] of adjacency.entries()) {
    clusterAdj.set(id, new Set(neighbors));
  }

  // 3. Greedily merge until we hit the target cluster count, or there
  //    are no eligible merges (the graph has only `clusters.size`
  //    connected components and we've already collapsed each one).
  while (clusters.size > targetClusters) {
    const pair = findClosestAdjacentPair(clusters, clusterAdj);
    if (!pair) break;
    mergeClusters(pair.a, pair.b, clusters, clusterAdj);
  }

  // 4. Stamp final clusterId onto blocks.
  for (const cluster of clusters.values()) {
    for (const blockId of cluster.blockIds) {
      const block = blocks.find((b) => b.id === blockId);
      if (block) block.clusterId = cluster.id;
    }
  }

  return Array.from(clusters.values());
}

function findClosestAdjacentPair(
  clusters: Map<number, Cluster>,
  clusterAdj: Map<number, Set<number>>,
): { a: number; b: number; diff: number } | null {
  let best: { a: number; b: number; diff: number } | null = null;

  for (const [aId, neighbors] of clusterAdj) {
    const aCluster = clusters.get(aId);
    if (!aCluster) continue;
    for (const bId of neighbors) {
      if (bId <= aId) continue; // each unordered pair seen once
      const bCluster = clusters.get(bId);
      if (!bCluster) continue;
      const diff = Math.abs(aCluster.score - bCluster.score);
      if (!best || diff < best.diff) {
        best = { a: aId, b: bId, diff };
      }
    }
  }

  return best;
}

function mergeClusters(
  aId: number,
  bId: number,
  clusters: Map<number, Cluster>,
  clusterAdj: Map<number, Set<number>>,
): void {
  const a = clusters.get(aId);
  const b = clusters.get(bId);
  if (!a || !b) return;

  // Area-weighted mean keeps tiny slivers from dominating the score.
  const totalArea = a.totalAreaSqM + b.totalAreaSqM;
  const newScore =
    totalArea > 0
      ? (a.score * a.totalAreaSqM + b.score * b.totalAreaSqM) / totalArea
      : (a.score + b.score) / 2;

  // Use the lower id as the surviving cluster.
  const survivorId = Math.min(aId, bId);
  const absorbedId = Math.max(aId, bId);

  const merged: Cluster = {
    id: survivorId,
    score: newScore,
    totalAreaSqM: totalArea,
    blockIds: [...a.blockIds, ...b.blockIds],
  };
  clusters.set(survivorId, merged);
  clusters.delete(absorbedId);

  // Rewire adjacency: survivor inherits union of both neighbor sets minus themselves.
  const aN = clusterAdj.get(aId) ?? new Set<number>();
  const bN = clusterAdj.get(bId) ?? new Set<number>();
  const newNeighbors = new Set<number>([...aN, ...bN]);
  newNeighbors.delete(aId);
  newNeighbors.delete(bId);
  clusterAdj.set(survivorId, newNeighbors);
  clusterAdj.delete(absorbedId);

  // Update every neighbor's adjacency set to point at the survivor.
  for (const nId of newNeighbors) {
    const n = clusterAdj.get(nId);
    if (!n) continue;
    n.delete(absorbedId);
    n.delete(aId === survivorId ? bId : aId);
    n.add(survivorId);
  }
}
