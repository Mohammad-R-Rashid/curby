// ============================================================
// Heat-map module — public exports
// ============================================================

export type {
  HeatMapDifficulty,
  HeatMapGeometry,
  HeatMapResponse,
  HeatMapTile,
} from './types.js';

export { computeHeatMap } from './compute.js';
export type { HeatMapInputs } from './compute.js';
