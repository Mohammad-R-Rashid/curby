// ============================================================
// Parking Heat Map — Types
// ============================================================
// Public contract between the API and iOS. Keep this lean — every
// field crossed-the-wire-shaped, no Mapbox/Supabase internals.

import type { LatLng } from '../types.js';

// ─── Tile / Response ────────────────────────────────────────

/**
 * Coarse difficulty bucket. Used as the primary label users see;
 * the numeric `score` is the precise underlying value.
 *
 * Convention: 1.0 = easy to park, 0.0 = hard. Matches the existing
 * "% Match" direction so the whole app reads the same way.
 */
export type HeatMapDifficulty = 'easy' | 'medium' | 'hard';

export interface HeatMapTile {
  /** Stable id within a single response; not durable across requests. */
  id: string;
  /** GeoJSON Polygon or MultiPolygon. Always closed; outer ring CCW. */
  geometry: HeatMapGeometry;
  /** Composite score in [0, 1]; 1 = easy. */
  score: number;
  /** Coarse label for UI display. */
  label: HeatMapDifficulty;
  /** Hex color suggested for the fill, matched to the iOS palette. */
  tint: string;
  stats: {
    /** Number of source blocks merged into this tile. */
    blockCount: number;
    /** Average congestion on the tile's bordering roads (0..1, 1 = severe). */
    avgCongestion: number;
    /** active_parks rows inside the tile at the moment of computation. */
    activeParks: number;
    /** parking_events of type 'parked'/'departed' inside the tile in the last window. */
    recentDepartures: number;
    /** Tile area in square meters (rough; turf-area). */
    areaSqM: number;
  };
}

/** GeoJSON Polygon or MultiPolygon — narrowed for this API. */
export type HeatMapGeometry =
  | { type: 'Polygon'; coordinates: [number, number][][] }
  | { type: 'MultiPolygon'; coordinates: [number, number][][][] };

export interface HeatMapResponse {
  /** ~5 tiles, score-descending (Easy first). */
  tiles: HeatMapTile[];
  /** The anchor we computed around. */
  anchor: LatLng;
  /** Radius (m) used. May be clamped from the query value. */
  radiusM: number;
  /** Number of clusters requested (currently always equals tiles.length unless degenerate). */
  clusterCount: number;
  /** ISO timestamp of compute. */
  computedAt: string;
  /**
   * True if there was insufficient parking signal (no active_parks rows in
   * the query area) and the score is congestion-only. The UI can use this
   * to show a "low confidence / beta" badge.
   */
  fallback: boolean;
}

// ─── Internal block / scoring shapes ────────────────────────
// Not part of the wire contract — kept here for module ergonomics.

export type GeoJSONPolygon = {
  type: 'Polygon';
  coordinates: [number, number][][];
};

export type GeoJSONLineString = {
  type: 'LineString';
  coordinates: [number, number][];
};

/**
 * One face of the road graph in the query area. Score is filled in
 * by block-scoring; clusterId by clustering.
 */
export interface Block {
  /** Stable index within a single compute pass. */
  id: number;
  polygon: GeoJSONPolygon;
  centroid: LatLng;
  /** Square meters. */
  areaSqM: number;
  /** Composite score in [0, 1]; 1 = easy. */
  score: number;
  scoreInputs: BlockScoreInputs;
  /** Filled in after clustering; same value across all blocks in a cluster. */
  clusterId: number;
}

export interface BlockScoreInputs {
  /** Mean congestion (0..1) on bordering road segments; 1 = severe. */
  congestion: number;
  /** active_parks count whose location is inside the block. */
  activeParks: number;
  /** parking_events 'departed' count inside block in the recent window. */
  recentDepartures: number;
  /** Density: activeParks per hectare. */
  parksPerHectare: number;
}

/** Edge canonicalization output — used to detect block-adjacency. */
export interface CanonicalEdge {
  a: string; // "lng,lat" stringified, rounded
  b: string;
}

// ─── Vector tile / Mapbox plumbing ──────────────────────────

/** A road linestring from Mapbox Streets v8 in WGS84 (lng,lat). */
export interface RoadSegment {
  geometry: GeoJSONLineString;
  /** OSM class tag — used to filter out service / footway / etc. */
  klass?: string;
}

/** A congestion-tagged segment from Mapbox traffic-v1. */
export interface TrafficSegment {
  geometry: GeoJSONLineString;
  /** Mapbox traffic-v1 categorical value. */
  congestion: 'unknown' | 'low' | 'moderate' | 'heavy' | 'severe';
}
